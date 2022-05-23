require "sinatra/base"
require "sinatra/reloader" # TODO: Remove
require "better_errors" # TODO: Remove
require "pry" # TODO: Remove
require "rspotify"
require "rqrcode"
require_relative "./sonos"
require_relative "./spotify"
require_relative "./db"

module SonosPartyMode
  class Server < Sinatra::Base
    # Session management
    use Rack::Session::Cookie, :key => 'rack.session',
                           :path => '/',
                           :secret => ENV.fetch('SESSION_SECRET')

    # Server Config
    set :bind, '0.0.0.0'

    # Development mode
    configure :development do
      register Sinatra::Reloader
      use BetterErrors::Middleware
      BetterErrors.application_root = __dir__
    end

    def initialize
      super

      puts "Booting up Jukebox and refreshing auth tokens..."

      # General
      RSpotify::authenticate(ENV.fetch("SPOTIFY_CLIENT_ID"), ENV.fetch("SPOTIFY_CLIENT_SECRET"))

      # Boot up code: load existing sessions into the `session` instances
      SonosPartyMode::Db.users.each do |user|
        sonos_obj = SonosPartyMode::Sonos.new(user_id: user[:id])
        spotify_obj = SonosPartyMode::Spotify.new(user_id: user[:id])

        # Important to check if there is an actual entry, since otherwise there will be empty objects in those hashes
        sonos_instances[user[:id]] ||= sonos_obj unless sonos_obj.database_row.nil?
        spotify_instances[user[:id]] ||= spotify_obj unless spotify_obj.database_row.nil?
      end

      # Ongoing background thread to monitor all Sonos systems
      Thread.new do
        loop do
          self.ensure_current_sonos_settings!
          sleep(2)
        end
      end
      Thread.new do
        loop do
          sonos_instances.each do |user_id, sonos|
            sonos.refresh_caches
          end
          sleep(15)
        end
      end
    end

    # -----------------------
    # Session specific code
    # -----------------------

    def all_sessions?
      return sonos_instances[session[:user_id]] && spotify_instances[session[:user_id]]
    end

    get "/" do
      @title = "Login"

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

      pd = party_data
      if pd[:redirect] == "/party"
        redirect "/party" # to remove the `submitted` GET parameter
      elsif pd[:erb] == :add_playlist_to_favs
        @already_submitted = params["submitted"].to_s == "true"
        return erb :add_playlist_to_favs
      else
        erb :party, locals: pd
      end
    end

    get "/party.json" do
      unless all_sessions?
        redirect "/"
        return
      end

      content_type :json
      pd = party_data
      if pd[:redirect] || pd[:erb]
        return {}.to_json
      end
      return pd.to_json
    end

    def party_data
      spotify_instance = spotify_instances[session[:user_id]]
      sonos_instance = sonos_instances[session[:user_id]]

      spotify_playlist = spotify_instance.party_playlist
      spotify_playlist_id = spotify_playlist.id

      playback_metadata = sonos_instance.playback_metadata
      current_spotify_object_id = playback_metadata["currentItem"]["track"]["id"]["objectId"]
      current_spotify_track = spotify_instance.find_song(current_spotify_object_id)
      current_image_url = current_spotify_track.album.images[1]["url"]
      current_song_details = playback_metadata["currentItem"]["track"]

      next_spotify_object_id = playback_metadata["nextItem"]["track"]["id"]["objectId"]
      next_spotify_track = spotify_instance.find_song(next_spotify_object_id)
      next_image_url = next_spotify_track.album.images[1]["url"]

      sonos_instance_playlist = sonos_instance.ensure_playlist_in_favorites(spotify_playlist_id, force_refresh: params["submitted"].to_s == "true")
      if sonos_instance_playlist.nil?
        # User doesn't have the Spotify playlist in their favorites, show them the onboarding instructions
        @spotify_playlist_name = spotify_playlist.name
        spotify_instance.prepare_welcome_playlist_song!(spotify_playlist)
        return {
          erb: :add_playlist_to_favs
        }
      elsif params["submitted"].to_s == "true"
        return {
          redirect: "/party" # to remove the `submitted` GET parameter
        }
      end

      # Generate the invite URL
      host = request.scheme + "://" + request.host + (request.port == 4567 ? ":#{request.port}" : "")
      party_join_link = host + "/party/join/" + session[:user_id].to_s + "/" + spotify_playlist_id

      # Prepare all other variables needed to render the host dashboard
      volume = sonos_instance.database_row.fetch(:volume)
      party_on = sonos_instance.party_session_active

      queued_songs = spotify_instance.queued_songs.dup # `.dup` to not modify the actual queue

      # Manually prefix the most recently queued song, as it's already in the Sonos queue
      if spotify_instance.past_songs.count > 0 && sonos_instance.currently_playing_guest_wished_song
        queued_songs.unshift(spotify_instance.past_songs.last)
      end

      sonos_groups = sonos_instance.groups_cached || sonos_instance.groups
      groups = sonos_groups.collect do |group|
        {
          name: group.fetch("name"),
          id: group.fetch("id"),
          number_of_speakers: group.fetch("playerIds").count
        }
      end.sort_by { |group| group[:number_of_speakers] }.reverse
      selected_group = sonos_instance.group_to_use

      # Generate a QR code for the invite URL
      qr_code = RQRCode::QRCode.new(party_join_link)

      return {
        selected_group: selected_group,
        groups: groups,
        party_on: party_on,
        queued_songs: queued_songs.collect do |track|
          {
            album_cover: track.album.images[-1]["url"],
            name: track.name,
            artists: track.artists.map(&:name).join(", "),
            id: track.id.to_s,
            duration: track.duration_ms.to_i / 1000,
            uri: track.uri,
          }
        end,
        current_image_url: current_image_url,
        next_image_url: next_image_url,
        current_song_details: current_song_details,
        volume: volume,
        party_join_link: party_join_link,
        qr_code: qr_code.as_svg(
          color: "000",
          shape_rendering: "crispEdges",
          module_size: 4,
          standalone: true,
          use_path: true
        )
      }
    end

    post "/party/host/update" do
      unless all_sessions?
        redirect "/"
        return
      end

      sonos = sonos_instances[session[:user_id]]

      if params[:volume]
        volume = params[:volume].to_i
        if sonos.party_session_active
          sonos.ensure_volume!(volume, check_first: false) # First, set the volume
        end
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

    get "/logout" do
      unless all_sessions?
        redirect "/"
        return
      end

      Db.sonos_tokens.where(user_id: session[:user_id]).delete
      Db.spotify_tokens.where(user_id: session[:user_id]).delete

      redirect "/"
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

    # User submitted a song request
    post "/party/join/:user_id/:playlist_id/:song_id" do
      content_type :json
      
      user_id = params[:user_id].to_i
      spotify_instance = spotify_instances[user_id]
      spotify_playlist = spotify_instance.party_playlist
      sonos_instance = sonos_instances[user_id]

      # To make sure the user actually has the full link, and the IDs match
      if spotify_playlist.id != params[:playlist_id]
        redirect "/"
        return
      end

      # Queue that song
      spotify_instance.add_song_to_queue(spotify_instance.find_song(params.fetch(:song_id)))

      current_metadata = sonos_instance.playback_metadata
      next_object_id = current_metadata.fetch("nextItem")["track"]["id"]["objectId"] # e.g. spotify:track:01LcEnzRdYXfpJmmLPmdMz
      
      # Check if we can queue right away, or if we have to wait for the next song to start
      # This basically means, that no user wished song is currently playing, but the default playlist only
      if sonos_instance.currently_playing_guest_wished_song
        return {
          success: true,
          position: spotify_instance.queued_songs.count
        }.to_json
      else
        binding.pry if spotify_instance.queued_songs.count != 1
        sonos_instance.currently_playing_guest_wished_song = true
        Thread.new do # async
          spotify_instance.add_next_song_to_sonos_queue!(sonos_instance)
        end
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

    # Sonos callback information (ping, hook)
    post "/callback" do
      info = JSON.parse(request.body.read)
      sonos_group_id = request.env.fetch("HTTP_X_SONOS_TARGET_VALUE")
      puts "Received Sonos Web API callback for #{sonos_group_id}"

      # Find the matching sonos session to use
      sonos_instance = sonos_instances.values.find { |a| a.group_to_use == sonos_group_id }
      return if sonos_instance.nil? # not a Sonos system we actively manage (any more)

      spotify_instance = spotify_instances[sonos_instance.user_id]
      return if spotify_instance.nil? # not yet fully connected

      puts "\n\nSonos Notification\n\n"
      puts JSON.pretty_generate(info)
      puts "\n\n"

      if info["playbackState"]
        if !["PLAYBACK_STATE_PLAYING", "PLAYBACK_STATE_BUFFERING"].include?(info.fetch("playbackState"))
          puts "user paused the group..."
          sonos_instance.play_music! if sonos_instance.party_session_active
        end
      end
      
      if info["itemId"]
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

      if info["container"]
        sonos_instance.did_receive_new_playback_metadata(info)

        # Pre-load the song's information from Spotify to get the album cover and other details
        # which is used by the party host's dashboard, reducing the load time from 5s to 0.5s
        current_spotify_object_id = info["currentItem"]["track"]["id"]["objectId"]
        current_spotify_track = spotify_instance.find_song(current_spotify_object_id)

        next_spotify_object_id = info["nextItem"]["track"]["id"]["objectId"]
        next_spotify_track = spotify_instance.find_song(next_spotify_object_id)
      end
    end

    # -----------------------
    # Spotify Specific Code
    # -----------------------

    SPOTIFY_REDIRECT_PATH = '/auth/spotify/callback'
    SPOTIFY_REDIRECT_URI = "http://localhost:4567#{SPOTIFY_REDIRECT_PATH}"

    get SPOTIFY_REDIRECT_PATH do
      if params[:state] == Hash(session)["state_key"]
        session[:state_key] = nil

        new_spotify = SonosPartyMode::Spotify.new(
          user_id: session[:user_id],
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
