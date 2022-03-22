require "sinatra"
require "pry"
require_relative "./sonos"
require_relative "./db"

enable :sessions
# set :session_store, Rack::Session::Pool

get "/" do
  # redirect_uri = request.scheme + "://" + request.host + (request.port == 4567 ? ":#{request.port}" : "") + "/sonos/authorized.html"
  redirect_uri = "http://localhost:4567/sonos/authorized.html"
  @sonos_login_url = "https://api.sonos.com/login/v3/oauth?" +
                  "client_id=#{ENV.fetch('SONOS_KEY')}&" + 
                  "response_type=code&" + 
                  "state=TESTSTATE&" + 
                  "scope=playback-control-all&" + 
                  "redirect_uri=#{ERB::Util.url_encode(redirect_uri)}"
  erb :login
end

get "/sonos/authorized.html" do
  # So, this user is serious, they onboarded Sonos, so we now create an entry for them
  # First, create a new user
  user_id = SonosPartyMode::Db.users.insert

  # Then store this inside the session
  session[:user_id] = user_id

  # Now process the Sonos login
  authorization_code = params.fetch(:code)
  sonos = SonosPartyMode::Sonos.new(
    authorization_code: authorization_code,
    user_id: user_id
  )
end
