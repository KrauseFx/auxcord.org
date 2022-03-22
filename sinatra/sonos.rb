require "excon"
require "json"
require "pry"
require_relative "./db"

module SonosPartyMode
  class Sonos
    def initialize(authorization_code:, user_id:)
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

    def client_login
      Excon.new("https://api.sonos.com/login/v3/oauth/access")
    end

    def client_control
      Excon.new("https://api.ws.sonos.com/control/api/v1/")
    end
  end
end
