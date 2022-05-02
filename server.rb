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
    set :bind, '0.0.0.0'

    def initialize
      super

      # General
      RSpotify::authenticate(ENV.fetch("SPOTIFY_CLIENT_ID"), ENV.fetch("SPOTIFY_CLIENT_SECRET"))

      # Boot up code: load existing sessions into the `session` instances
      SonosPartyMode::Db.users.each do |user|
        sonos_instances[user[:id]] ||= SonosPartyMode::Sonos.new(user_id: user[:id])
        spotify_instances[user[:id]] ||= SonosPartyMode::Spotify.new(user_id: user[:id])
      end

      # Ongoing background thread to monitor all Sonos systems
      Thread.new do
        loop do
          self.ensure_current_sonos_settings!
          sleep(2)
        end
      end
    end

    # -----------------------
    # Session specific code
    # -----------------------

    def all_sessions?
      session[:user_id] = 10 # TODO: remove

      return sonos_instances[session[:user_id]] && spotify_instances[session[:user_id]]
    end

    get "/" do
      @title = "Login"

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
        # Success: user is logged in
        redirect :party
      end
    end

    def ensure_current_sonos_settings!
      sonos_instances.each do |user_id, sonos|
        sonos.ensure_current_sonos_settings!
      end
    end

    # -----------------------
    # Admin Dashboard
    # -----------------------

    get "/party" do
      @title = "Party Host"
      unless all_sessions?
        redirect "/"
        return
      end

      spotify_instance = spotify_instances[session[:user_id]]
      spotify_playlist = spotify_instance.party_playlist
      spotify_playlist_id = spotify_playlist.id

      sonos = sonos_instances[session[:user_id]]
      playlist = sonos.ensure_playlist_in_favorites(spotify_playlist_id)

      if playlist.nil?
        # User doesn't have the Spotify playlist in their favorites
        @spotify_playlist_name = spotify_playlist.name
        @already_submitted = params.fetch("submitted").to_s == "true"
        return erb :add_playlist_to_favs        
      end

      # Prepare all the variables needed
      @party_join_link = request.scheme + "://" + request.host + (request.port == 4567 ? ":#{request.port}" : "") + "/party/join/" + session[:user_id].to_s + "/" + spotify_playlist_id
      @volume = sonos.database_row.fetch(:volume)
      @party_on = sonos.party_session_active      

      @queued_songs = spotify_instance.queued_songs
      # Manually prefix the most recently queued song, as it's already in the Sonos queue
      @queued_songs.unshift(spotify_instance.past_songs.last) if spotify_instance.past_songs.count > 0

      @groups = sonos.groups.collect do |group|
        {
          name: group.fetch("name"),
          id: group.fetch("id"),
          number_of_speakers: group.fetch("playerIds").count
        }
      end.sort_by { |group| group[:number_of_speakers] }.reverse
      @selected_group = sonos.group_to_use

      # Generate a QR code for the invite URL
      @qr_code = RQRCode::QRCode.new(@party_join_link)
      binding.pry

      erb :party
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

      if params[:group_to_use]
        # First, pause playback at the current group
        sonos.pause_playback!

        # Update the currently used group in the database, as well as the current session
        Db.sonos_tokens.where(user_id: session[:user_id]).update(group: params[:group_to_use]) # now, store in db for next run, important to use full query
        sonos.group_to_use = params[:group_to_use]

        # Now, trigger playing on the new group
        sonos.ensure_music_playing! if sonos.party_session_active # but only if the party is currently active
      end

      if params[:skip_song]
        sonos.skip_song!
      end
    end

    # -----------------------
    # Guest code
    # -----------------------

    get "/party/join/:user_id/:playlist_id" do
      @title = "Queue a Song"

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
      spotify_instance = spotify_instances[user_id]
      spotify_playlist = spotify_instance.party_playlist
      sonos = sonos_instances[user_id]

      # To make sure the user actually has the full link, and the IDs match
      if spotify_playlist.id != params[:playlist_id]
        redirect "/"
        return
      end

      # Queue that song
      spotify_instance.add_song_to_queue(RSpotify::Track.find(params.fetch(:song_id)))

      current_metadata = sonos.metadata_status
      next_object_id = current_metadata.fetch("nextItem")["track"]["id"]["objectId"] # e.g. spotify:track:01LcEnzRdYXfpJmmLPmdMz
      
      # Check if we can queue right away, or if we have to wait for the next song to start
      # This basically means, that no user wished song is currently playing, but the default playlist only
      if sonos.currently_playing_guest_wished_song
        return {
          success: true,
          position: spotify_instance.queued_songs.count
        }.to_json
      else
        binding.pry if spotify_instance.queued_songs.count != 1
        spotify_instance.add_next_song_to_sonos_queue!(sonos)
        sonos.currently_playing_guest_wished_song = true
        return {
          success: true,
          position: 0
        }.to_json
      end
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
      new_sonos = SonosPartyMode::Sonos.new(
        user_id: user_id,
        authorization_code: authorization_code
      )
      sonos_instances[user_id] = new_sonos

      redirect "/"
    end

    # Sonos callback information
    post "/callback" do
      info = JSON.parse(request.body.read)
      sonos_group_id = request.env.fetch("HTTP_X_SONOS_TARGET_VALUE")
      puts "Received Sonos Web API callback for #{sonos_group_id}"

      # Find the matching sonos session to use
      sonos_instance = sonos_instances.values.find { |a| a.group_to_use == sonos_group_id }
      return if sonos_instance.nil?

      spotify_instance = spotify_instances[sonos_instance.user_id]

      if !["PLAYBACK_STATE_PLAYING", "PLAYBACK_STATE_BUFFERING"].include?(info.fetch("playbackState"))
        puts "user paused the group..."
        sonos_instance.play_music! if sonos_instance.party_session_active
      end

      if sonos_instance.current_item_id != info.fetch("itemId") && 
        sonos_instance.current_item_id == info.fetch("previousItemId")

        # Set it immediately, as the Sonos web requests do take some time to complete
        sonos_instance.current_item_id = info.fetch("itemId") # always set it

        # This means, the user has skipped to the next song, or the song has finished playing
        # we use this to do proper queueing of upcoming songs

        # We queue the next song (after this one's finished)
        if spotify_instance.add_next_song_to_sonos_queue!(sonos_instance)
          sonos_instance.currently_playing_guest_wished_song = true
        else
          sonos_instance.currently_playing_guest_wished_song = false
        end

        sonos_instance.current_item_id = info.fetch("itemId")
      end

      sonos_instance.current_item_id = info.fetch("itemId") # always set it

      # => {"playbackState"=>"PLAYBACK_STATE_PLAYING",
      #   "isDucking"=>false,
      #   "itemId"=>"3d6iqwIjxdilDioPqbhU4cJPTGs=",
      #   "positionMillis"=>14,
      #   "previousItemId"=>"FwZvKUVmIj3zb3OsjfPQjF8BWsg=",
      #   "previousPositionMillis"=>60368,
      #   "playModes"=>{"repeat"=>false, "repeatOne"=>false, "shuffle"=>false, "crossfade"=>false},
      #   "availablePlaybackActions"=>
      #    {"canSkip"=>true,
      #     "canSkipBack"=>true,
      #     "canSeek"=>true,
      #     "canPause"=>true,
      #     "canStop"=>true,
      #     "canRepeat"=>true,
      #     "canRepeatOne"=>true,
      #     "canCrossfade"=>true,
      #     "canShuffle"=>true}}
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
        new_spotify.new_auth!(
          authorization_code: params[:code],
          redirect_uri: SPOTIFY_REDIRECT_URI
        )
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
