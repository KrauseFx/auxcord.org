require "sinatra"
require "pry" # TODO: remove
require "rspotify"
require_relative "./sonos"
require_relative "./spotify"
require_relative "./db"

enable :sessions

# General
RSpotify::authenticate(ENV.fetch("SPOTIFY_CLIENT_ID"), ENV.fetch("SPOTIFY_CLIENT_SECRET"))

get "/" do
  # redirect_uri = request.scheme + "://" + request.host + (request.port == 4567 ? ":#{request.port}" : "") + "/sonos/authorized.html"

  if SonosPartyMode::Db.sonos_tokens.where(user_id: session[:user_id]).count == 0
    redirect_uri = "http://localhost:4567/sonos/authorized.html"
    @sonos_login_url = "https://api.sonos.com/login/v3/oauth?" +
                    "client_id=#{ENV.fetch('SONOS_KEY')}&" + 
                    "response_type=code&" + 
                    "state=TESTSTATE&" + 
                    "scope=playback-control-all&" + 
                    "redirect_uri=#{ERB::Util.url_encode(redirect_uri)}"
    return erb :login
  elsif SonosPartyMode::Spotify.spotify_user(session[:user_id]).nil?
    @spotify_login_url = "/auth/spotify"
    return erb :login
  else
    # Success
    redirect :manager
  end
end

get "/manager" do
  unless all_sessions?
    redirect "/"
    return
  end

  # playlist = SonosPartyMode::Spotify.party_playlist(session[:user_id])

  # tracks = RSpotify::Track.search('Know')
  # playlist.add_tracks!(tracks)

  erb :manager
end

get "/party" do
  unless all_sessions?
    redirect "/"
    return
  end

  sonos = sonos_instances[session[:user_id]]
  playlist = sonos.ensure_playlist_in_favorites
  sonos.ensure_music_playing!(playlist)
  sonos.ensure_volume!(10)

  erb :party
end

def all_sessions?
  session[:user_id] = 7 # TODO: remove

  return false unless (
    SonosPartyMode::Db.sonos_tokens.where(user_id: session[:user_id]).count > 0 &&
    !SonosPartyMode::Spotify.spotify_user(session[:user_id]).nil?)

  sonos_instances[session[:user_id]] ||= SonosPartyMode::Sonos.new(user_id: session[:user_id])
  return true
end

def sonos_instances
  @sonos_instances ||= {}
end

# -----------------------
# Sonos Specific Code
# -----------------------

get "/sonos/authorized.html" do
  # So, this user is serious, they onboarded Sonos, so we now create an entry for them
  # First, create a new user
  user_id = SonosPartyMode::Db.users.insert

  # Then store this inside the session
  session[:user_id] = user_id

  # Now process the Sonos login
  authorization_code = params.fetch(:code)
  sonos_instances[user_id] = SonosPartyMode::Sonos.new(user_id: user_id)
  sonos_instances[user_id].new_auth(
    authorization_code: authorization_code,
  )

  redirect "/"
end

# -----------------------
# Spotify Specific Code
# -----------------------

SPOTIFY_REDIRECT_PATH = '/auth/spotify/callback'
SPOTIFY_REDIRECT_URI = "http://localhost:4567#{SPOTIFY_REDIRECT_PATH}"

get SPOTIFY_REDIRECT_PATH do
  if params[:state] == Hash(session)["state_key"]
    session[:state_key] = nil

    SonosPartyMode::Spotify.new(
      authorization_code: params[:code],
      user_id: session[:user_id]
    )
  end
  redirect "/"
end

get '/auth/spotify' do
  session[:state_key] = SecureRandom.hex

  redirect("https://accounts.spotify.com/authorize?" + 
          URI.encode_www_form(
            client_id: ENV['SPOTIFY_CLIENT_ID'],
            response_type: 'code',
            redirect_uri: SPOTIFY_REDIRECT_URI,
            scope: SonosPartyMode::Spotify.permission_scope,
            state: session[:state_key]
          ))
end
