require "excon"
require "json"
require "pry"
require_relative "./db"

module SonosPartyMode
  class Sonos
    # Basic attributes
    attr_accessor :user_id
    attr_accessor :session_id
    attr_accessor :party_session_active

    # Session specific settings
    attr_accessor :target_volume

    def initialize(user_id:)
      @user_id = user_id
      @target_volume = 5 # TODO: load from db
      @party_session_active = false
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

    def ensure_playlist_in_favorites(spotify_playlist_id)
      favs = client_control_request("/households/#{primary_household}/favorites")
      matched = favs.fetch("items").find do |fav|
        fav["service"]["name"] == "Spotify" &&
          fav["resource"]["type"] == "PLAYLIST" &&
          fav["resource"]["id"]["objectId"].include?(spotify_playlist_id)
      end
      binding.pry if matched.nil?

      return matched
    end

    def ensure_current_sonos_settings!
      # return unless self.party_session_active

      self.ensure_volume!(self.target_volume)
      self.ensure_music_playing!
      # TODO: add more here
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
  
      puts "Resuming playback for Sonos system"
      client_control_request("groups/#{group_to_use}/playback/play", method: :post)
    end

    def get_volume
      # {"volume"=>40, "muted"=>false, "fixed"=>false}
      client_control_request("groups/#{group_to_use}/groupVolume")
    end

    def ensure_volume!(goal_volume)
      return if get_volume.fetch("volume") == goal_volume

      client_control_request(
        "groups/#{group_to_use}/groupVolume",
        method: :post,
        body: { volume: goal_volume }
      )
    end

    # ----------------
    # Under the hood
    # ----------------

    def primary_household
      households.first.fetch("id")
    end

    def group_to_use
      groups.first.fetch("id") # TODO: offer control
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
          client_control_request(path, method: method, body: body)
        else
          raise parsed_body["fault"]["faultstring"]
        end
      end

      return parsed_body
    end
  end
end
