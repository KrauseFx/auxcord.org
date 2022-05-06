require "excon"
require "json"
require_relative "./db"

module SonosPartyMode
  class Sonos
    # Basic attributes
    attr_accessor :user_id
    attr_accessor :session_id
    attr_accessor :party_session_active
    attr_accessor :group_to_use
    
    # Queueing system
    attr_accessor :current_item_id # it's being set by the `/callback` triggers
    attr_accessor :currently_playing_guest_wished_song

    # Session specific settings
    attr_accessor :target_volume

    # Optionally pass in `authorization_code` if this is the first time
    # the account is being used, this will store the token in the database
    def initialize(user_id:, authorization_code: nil)
      @user_id = user_id
      self.new_auth!(authorization_code: authorization_code) if authorization_code

      return nil if database_row.nil? # this is the case if a user didn't finish onboarding

      @target_volume = database_row[:volume] # default volume is defined as part of `db.rb`
      @group_to_use = database_row[:group]
      groups_cached = self.groups
      unless groups_cached.collect { |a| a["id"] }.include?(@group_to_use)
        # The group ID doesn't exist any more, fallback to the default one (most speakers)
        @group_to_use = groups_cached.sort_by { |a| a["playerIds"].count }.reverse.first.fetch("id")
      end

      @party_session_active = false
      @currently_playing_guest_wished_song = false

      self.subscribe_to_playback
    end


    def subscribe_to_playback
      client_control_request("/groups/#{group_to_use}/playback/subscription", method: :post)
    end

    def ensure_playlist_in_favorites(spotify_playlist_id)
      favs = client_control_request("/households/#{primary_household}/favorites")
      matched = favs.fetch("items").find do |fav|
        fav["service"]["name"] == "Spotify" &&
          fav["resource"]["type"] == "PLAYLIST" &&
          fav["resource"]["id"]["objectId"].include?(spotify_playlist_id)
      end

      return matched
    end

    def ensure_current_sonos_settings!
      return unless self.party_session_active

      self.ensure_volume!(self.target_volume)
      self.ensure_music_playing!
      self.unmute_speakers!
    end

    def playback_status
      status = client_control_request("/groups/#{group_to_use}/playback")
      return status.fetch("playbackState")
    end

    def playback_is_playing?
      ["PLAYBACK_STATE_PLAYING", "PLAYBACK_STATE_BUFFERING"].include?(playback_status)
    end

    def ensure_music_playing!
      return if playback_is_playing?
  
      play_music!
    end

    def play_music!
      puts "Resuming playback for Sonos system"
      client_control_request("groups/#{group_to_use}/playback/play", method: :post)
    end

    def pause_playback!
      return unless playback_is_playing?

      puts "Pausing playback for Sonos system"
      client_control_request("groups/#{group_to_use}/playback/pause", method: :post)
    end

    def skip_song!
      puts "Skipping song"
      client_control_request("/groups/#{group_to_use}/playback/skipToNextTrack", method: :post)
    end

    def get_volume
      # {"volume"=>40, "muted"=>false, "fixed"=>false}
      client_control_request("groups/#{group_to_use}/groupVolume")
    end

    def ensure_volume!(goal_volume, check_first: true)
      if check_first # when volume is manually changed in admin panel, we want to skip that
        get_volume_cached = get_volume
        # If the speakers are unmuted, and the volume is correct, nothing to do here
        return if get_volume_cached.fetch("volume") == goal_volume && get_volume_cached.fetch("muted") == false
      end

      # The request below will set the volume
      client_control_request(
        "groups/#{group_to_use}/groupVolume",
        method: :post,
        body: { volume: goal_volume }
      )
      unmute_speakers!
    end

    def unmute_speakers!
      # This is a separate request. It seems like there is no good Sonos API endpoint
      # to check if any of the speakers in a given group is muted, so it's best to just 
      # send this API request from time to time in the background
      client_control_request(
        "groups/#{group_to_use}/groupVolume/mute",
        method: :post,
        body: { muted: false }
      )
    end

    # Basic info about the media currently playing
    def metadata_status
      client_control_request("groups/#{group_to_use}/playbackMetadata")
    end

    # ----------------
    # Under the hood
    # ----------------

    def primary_household
      households.first.fetch("id")
    end

    def households
      client_control_request("households").fetch("households")
    end

    def groups
      client_control_request("/households/#{primary_household}/groups").fetch("groups")
    end

    # private
    def access_token
      database_row.fetch(:access_token)
    end

    def database_row
      Db.sonos_tokens.where(user_id: user_id).first
    end

    def client_login
      Excon.new("https://api.sonos.com/login/v3/oauth/access")
    end

    def client_control
      Excon.new("https://api.ws.sonos.com/control/api/v1/")
    end

    def default_headers
      {
        "Authorization" => "Bearer #{access_token}",
        "Content-Type" => "application/json"
      }
    end

    def refresh_token
      puts "Refreshing API token..."
      refresh_token = database_row.fetch(:refresh_token)
      response = client_login.post(
        headers: {
          "Content-Type" => "application/x-www-form-urlencoded",
          "Accept-Charset" => "UTF-8",
          "Authorization" => "Basic #{Base64.strict_encode64(ENV.fetch('SONOS_KEY') + ":" + ENV.fetch('SONOS_SECRET'))}"
        },
        body: URI.encode_www_form({
          grant_type: "refresh_token",
          refresh_token: refresh_token,
        })
      )
      parsed_body = JSON.parse(response.body)
      access_token = parsed_body.fetch("access_token")
      Db.sonos_tokens.where(user_id: user_id).update(access_token: access_token) # important to use full query
    end

    def client_control_request(path, method: :get, body: nil)
      response = client_control.request(
        method: method,
        path: File.join(client_control.data[:path], path),
        headers: default_headers,
        body: Hash(body).to_json
      )
      parsed_body = JSON.parse(response.body)
      # Check if Sonos API token has expired
      # "=> {"fault"=>{"faultstring"=>"Access Token expired", "detail"=>{"errorcode"=>"keymanagement.service.access_token_expired"}}}"
      if parsed_body["fault"].to_s.length > 0
        if ["keymanagement.service.invalid_access_token", "keymanagement.service.access_token_expired"].include?(parsed_body["fault"]["detail"]["errorcode"])
          self.refresh_token
          return client_control_request(path, method: method, body: body)
        else
          raise parsed_body["fault"]["faultstring"]
        end
      end

      return parsed_body
    end

    def new_auth!(authorization_code:)
      # Very important: the redirect_uri has to match exactly
      response = client_login.post(
        headers: {
          "Content-Type" => "application/x-www-form-urlencoded",
          "Accept-Charset" => "UTF-8",
          "Authorization" => "Basic #{Base64.strict_encode64(ENV.fetch('SONOS_KEY') + ":" + ENV.fetch('SONOS_SECRET'))}"
        },
        body: URI.encode_www_form({
          grant_type: "authorization_code",
          code: authorization_code,
          redirect_uri: "http://localhost:4567/sonos/authorized.html"
        })
      )

      response = JSON.parse(response.body)
      access_token = response.fetch("access_token")
      refresh_token = response.fetch("refresh_token")
      
      # Store the access token in the database
      Db.sonos_tokens.insert(
        user_id: user_id,
        access_token: access_token,
        refresh_token: refresh_token,
        expires_in: response.fetch("expires_in"),
      )
    end
  end
end
