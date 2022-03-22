require "excon"
require "json"
require "pry"
require_relative "./db"

module SonosPartyMode
  class Sonos
    attr_accessor :user_id
    attr_accessor :session_id

    def initialize(user_id:)
      @user_id = user_id
    end
      
    def new_auth(authorization_code:)
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

    def ensure_playlist_in_favorites
      spotify_playlist_id = SonosPartyMode::Spotify.party_playlist(user_id).id
      favs = client_control_request("/households/#{primary_household}/favorites")
      matched = favs.fetch("items").find do |fav|
        fav["service"]["name"] == "Spotify" &&
          fav["resource"]["type"] == "PLAYLIST" &&
          fav["resource"]["id"]["objectId"].include?(spotify_playlist_id)
      end

      return matched
    end

    def ensure_music_playing!(playlist)
      playback_session = client_control_request(
        "groups/#{group_to_use}/playbackSession/joinOrCreate",
        method: :post,
        body: { 
          appId: "com.krausefx.partyMode",
          appContext: "appidandappcontext"
         }
      )
      if playback_session["errorCode"] == "ERROR_SESSION_IN_PROGRESS"
        # The API doesn't seem to allow us to remotely kill a session that wasn't started by us
        # TODO: this part is also called if it's our session
        return false
      end

      binding.pry
    
      if playback_session["sessionState"] == "SESSION_STATE_CONNECTED"
        self.session_id = playback_session["sessionId"]

        binding.pry
        # TODO: don't do the below again if it's already complete
        # Start playing the Party Playlist
        play_fav = client_control_request(
          "/groups/#{group_to_use}/favorites", 
          method: :post, 
          body: { favoriteId: playlist["id"] }
        )

        # Now trigger playback
        client_control_request("groups/#{group_to_use}/playback/play", method: :post)
      end
    end

    def ensure_volume!(goal_volume)
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

    private
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

    def client_control_request(path, method: :get, body: nil)
      response = client_control.request(
        method: method,
        path: File.join(client_control.data[:path], path),
        headers: default_headers,
        body: Hash(body).to_json
      )
      return JSON.parse(response.body)
    end
  end
end
