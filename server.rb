require "sinatra/base"
require "pry" # TODO: remove
require "rspotify"
require "rqrcode"
require_relative "./sonos"
require_relative "./spotify"
require_relative "./db"

module SonosPartyMode
  class Server < Sinatra::Base
    enable :sessions

    def initialize
      super

      # General
      RSpotify::authenticate(ENV.fetch("SPOTIFY_CLIENT_ID"), ENV.fetch("SPOTIFY_CLIENT_SECRET"))

      # Boot up code: load existing sessions into the `session` instances
      SonosPartyMode::Db.users.each do |user|
        sonos_instances[user[:id]] ||= SonosPartyMode::Sonos.new(user_id: user[:id])
        spotify_instances[user[:id]] ||= SonosPartyMode::Spotify.new(user_id: user[:id])

        # Clear all Sonos Spotify Party playlists for now (# TODO: We might want to change this)
        puts "Clearing previous songs from Party Playlists for user with id #{user[:id]}"
        party_playlist = spotify_instances[user[:id]].party_playlist
        party_playlist.remove_tracks!(party_playlist.tracks) if party_playlist
      end

      # Ongoing background thread to monitor all Sonos systems
      Thread.new do
        loop do
          self.ensure_current_sonos_settings!
          sleep(2)
        end
      end
    end

    def ensure_current_sonos_settings!
      sonos_instances.each do |user_id, sonos|
        sonos.ensure_current_sonos_settings!
      end
    end

    get "/" do
      session[:user_id] = 10 # TODO: remove
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
      elsif spotify_instances[session[:user_id]].nil?
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

      erb :manager
    end

    get "/party" do
      unless all_sessions?
        redirect "/"
        return
      end

      spotify_playlist_id = spotify_instances[session[:user_id]].party_playlist.id

      sonos = sonos_instances[session[:user_id]]
      playlist = sonos.ensure_playlist_in_favorites(spotify_playlist_id)

      # Prepare all the variables needed
      @party_join_link = request.scheme + "://" + request.host + (request.port == 4567 ? ":#{request.port}" : "") + "/party/join/" + session[:user_id].to_s + "/" + spotify_playlist_id
      @volume = sonos.database_row.fetch(:volume)
      @party_on = sonos.party_session_active      

      # Generate a QR code for the invite URL
      @qr_code = RQRCode::QRCode.new(@party_join_link)

      erb :party
    end

    get "/party/join/:user_id/:playlist_id" do
      # No auth here, we just verify the 2 IDs
      spotify_playlist = spotify_instances[params[:user_id].to_i].party_playlist
      if spotify_playlist.id != params[:playlist_id]
        redirect "/"
        return
      end

      erb :queue_song
    end

    post "/party/join/:user_id/:playlist_id/:song_id" do
      content_type :json

      user_id = params[:user_id].to_i
      spotify_playlist = spotify_instances[user_id].party_playlist
      sonos = sonos_instances[user_id]

      # To make sure the user actually has the full link, and the IDs match
      if spotify_playlist.id != params[:playlist_id]
        redirect "/"
        return
      end

      # Step 1: Search Spotify for that specific song based on the ID that's passed in
      # song = RSpotify::Track.search(params[:song]).to_a.first
      song = RSpotify::Track.find(params.fetch(:song_id))

      # Step 2: Add the resulting song onto the favorite playlist, ready to be queueue
      spotify_instances[user_id].add_song_to_party_playlist(song) do
        # Step 3: Get the Sonos ID of the favorite playlist
        fav_id = sonos.ensure_playlist_in_favorites(spotify_playlist.id)

        # Step 4: Queue all songs from that playlist into the Sonos Queue
        play_fav = sonos.client_control_request(
          "/groups/#{sonos.group_to_use}/favorites", 
          method: :post, 
          body: {
            favoriteId: fav_id.fetch("id"),
            action: "INSERT_NEXT"
          }
        )
        # Step 5: Remove all songs we just added to the queue, from the Sonos playlist
        # This is done by the block inside `spotify.rb`
      end

      # Step 6: Render success message to the (guest) end-user
      # TODO: maybe also verify response status here
      # binding.pry

      return {success: true}.to_json
    end

    post "/party/host/update" do
      unless all_sessions?
        redirect "/"
        return
      end

      sonos = sonos_instances[session[:user_id]]

      if params[:volume]
        volume = params[:volume].to_i
        sonos.ensure_volume!(volume, check_first: false) # First, set the volume
        sonos.target_volume = volume # Then, set it as the target volume for when a user changes it
        Db.sonos_tokens.where(user_id: session[:user_id]).update(volume: volume) # now, store in db for next run, important to use full query
      end

      if params[:party_toggle]
        if params[:party_toggle] == "true"
          sonos.party_session_active = true
          sonos.ensure_music_playing!
        else
          sonos.party_session_active = false
          sonos.pause_playback!
        end
      end
    end

    def all_sessions?
      session[:user_id] = 10 # TODO: remove

      return sonos_instances[session[:user_id]] && spotify_instances[session[:user_id]]
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
      new_sonos = SonosPartyMode::Sonos.new(user_id: user_id)
      new_sonos.new_auth!(
        authorization_code: authorization_code,
      )
      sonos_instances[user_id] = new_sonos

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

        new_spotify = SonosPartyMode::Spotify.new(user_id: session[:user_id])
        new_spotify.new_auth!(authorization_code: authorization_code)
        spotify_instances[session[:user_id]] = new_spotify
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

    get '/spotify/search/:user_id/:playlist_id' do
      content_type :json

      song_name = params.fetch(:song_name)
      user_id = params[:user_id].to_i
      spotify_playlist = spotify_instances[user_id].party_playlist

      # To make sure the user actually has the full link, and the IDs match
      if spotify_playlist.id != params[:playlist_id]
        return { error: "Unauthorized" }.to_json
      end

      puts "Searching for Spotify song using name #{song_name}"
      songs = spotify_instances[user_id].search_for_song(song_name)
      return songs.collect do |song|
        {
          id: song.id,
          name: song.name,
          artists: song.artists.collect { |artist| artist.name },
          thumbnail: song.album.images[1]["url"],
        }
      end.to_json
    end

    # Caching state
    def sonos_instances
      @sonos_instances ||= {}
    end

    def spotify_instances
      @spotify_instances ||= {}
    end

    run!
  end
end

if __FILE__ == $0
  SonosPartyMode::Server
end
