# frozen_string_literal: true
require 'sinatra/base'
require 'rspotify'
require 'rqrcode'
require_relative './sonos'
require_relative './spotify'
require_relative './db'

GlobalState = {}
GlobalState[:spotify_instances] = {}
GlobalState[:sonos_instances] = {}

module SonosPartyMode
  class Server < Sinatra::Base
    HOST_URL = ENV.fetch('CUSTOM_HOST_URL') # e.g. "http://localhost:4567"
    raise "Don't add trailing /" if HOST_URL.end_with?('/')

    # Session management
    use Rack::Session::Cookie, key: 'rack.session',
                               path: '/',
                               secret: ENV.fetch('SESSION_SECRET')

    # Server Config
    set :bind, '0.0.0.0'

    def load_tokens_from_db
      # Boot up code: load existing sessions into the `session` instances
      SonosPartyMode::Db.users.each do |user|
        sonos_obj = SonosPartyMode::Sonos.new(user_id: user[:id])
        spotify_obj = SonosPartyMode::Spotify.new(user_id: user[:id])

        # Important to check if there is an actual entry, since otherwise there will be empty objects in those hashes
        sonos_instances[user[:id]] ||= sonos_obj unless sonos_obj.database_row.nil?
        spotify_instances[user[:id]] ||= spotify_obj unless spotify_obj.database_row.nil?
      end
    end

    def initialize
      super

      puts 'Booting up auxcord.org and refreshing auth tokens...'

      # General
      RSpotify.authenticate(ENV.fetch('SPOTIFY_CLIENT_ID'), ENV.fetch('SPOTIFY_CLIENT_SECRET'))

      load_tokens_from_db

      # Ongoing background thread to monitor all Sonos systems
      Thread.new do
        loop do
          ensure_current_sonos_settings!
          sleep(2)
        end
      end
      Thread.new do
        loop do
          sonos_instances.each do |_user_id, sonos|
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

    get '/' do
      @title = 'Login'

      @logged_out = params[:logged_out]

      if session[:user_id].nil? || SonosPartyMode::Db.sonos_tokens.where(user_id: session[:user_id]).count.zero?
        redirect_uri = "#{HOST_URL}/sonos/authorized.html"
        @sonos_login_url = 'https://api.sonos.com/login/v3/oauth?' \
                           "client_id=#{ENV.fetch('SONOS_KEY')}&" \
                           'response_type=code&' \
                           'state=TESTSTATE&' \
                           'scope=playback-control-all&' \
                           "redirect_uri=#{ERB::Util.url_encode(redirect_uri)}"
        return erb :login
      elsif spotify_instances[session[:user_id]].nil?
        @spotify_login_url = '/auth/spotify'
        return erb :login
      else
        # Success: user is logged in
        redirect :party
      end
    end

    def ensure_current_sonos_settings!
      sonos_instances.each do |_user_id, sonos|
        sonos.ensure_current_sonos_settings!
      end
    end

    get '/assets/*' do
      if [
        '/assets/aux-cable.png',
        '/assets/add-to-sonos-1.png',
        '/assets/add-to-sonos-2.png',
        '/assets/add-to-sonos-3.png',
        '/assets/favicon.ico',
        '/assets/favicon-16x16.ico',
        '/assets/favicon-32x32.ico',
        '/assets/apple-touch-icon.png',
        '/assets/android-chrome-512x512',
        '/assets/android-chrome-192x192',
        '/assets/logo.png',
      ].include?(request.path) || request.path.start_with?('/assets/memes/')
        return send_file File.join('views', request.path)
      else
        return nil
      end
    end

    # -----------------------
    # Admin Dashboard
    # -----------------------

    get '/party' do
      @title = 'Host'
      unless all_sessions?
        redirect '/'
        return
      end

      pd = party_data
      if pd[:redirect] == '/party'
        redirect '/party' # to remove the `submitted` GET parameter
      elsif pd[:erb] == :add_playlist_to_favs
        @already_submitted = params['submitted'].to_s == 'true'
        return erb :add_playlist_to_favs
      else
        return erb :party, locals: pd
      end
    end

    get '/party.json' do
      unless all_sessions?
        redirect '/'
        return
      end

      content_type :json
      pd = party_data
      return {}.to_json if pd[:redirect] || pd[:erb]

      return pd.to_json
    end

    def party_data
      spotify_instance = spotify_instances[session[:user_id]]
      sonos_instance = sonos_instances[session[:user_id]]

      spotify_playlist = spotify_instance.party_playlist
      spotify_playlist_id = spotify_playlist.id

      playback_metadata = sonos_instance.playback_metadata
      if playback_metadata['currentItem']['track']['id'].nil?
        sonos_groups = sonos_instance.groups_cached || sonos_instance.groups
        # Nothing playing
        return {
          nothing_playing: true,
          group_to_use: sonos_groups.find { |a| a['id'] == sonos_instance.group_to_use }['name']
        }
      end
      current_spotify_object_id = playback_metadata['currentItem']['track']['id']['objectId']
      current_spotify_track = spotify_instance.find_song(current_spotify_object_id)
      current_image_url = current_spotify_track.album.images[1]['url']
      current_song_details = playback_metadata['currentItem']['track']

      next_spotify_object_id = playback_metadata['nextItem']['track']['id']['objectId']
      next_spotify_track = spotify_instance.find_song(next_spotify_object_id)
      next_image_url = next_spotify_track.album.images[1]['url']

      sonos_instance_playlist = sonos_instance.ensure_playlist_in_favorites(spotify_playlist_id,
                                                                            force_refresh: params['submitted'].to_s == 'true')
      if sonos_instance_playlist.nil?
        # User doesn't have the Spotify playlist in their favorites, show them the onboarding instructions
        @spotify_playlist_name = spotify_playlist.name
        spotify_instance.prepare_welcome_playlist_song!(spotify_playlist)
        return {
          erb: :add_playlist_to_favs
        }
      elsif params['submitted'].to_s == 'true'
        return {
          redirect: '/party' # to remove the `submitted` GET parameter
        }
      end

      # Prepare all other variables needed to render the host dashboard
      volume = sonos_instance.database_row.fetch(:volume)
      party_on = sonos_instance.party_session_active

      sonos_groups = sonos_instance.groups_cached || sonos_instance.groups
      groups = sonos_groups.collect do |group|
        {
          name: group.fetch('name'),
          id: group.fetch('id'),
          number_of_speakers: group.fetch('playerIds').count
        }
      end.sort_by { |group| group[:number_of_speakers] }.reverse
      selected_group = sonos_instance.group_to_use

      return {
        selected_group: selected_group,
        groups: groups,
        party_on: party_on,
        queued_songs: queued_songs_json(spotify_instance, sonos_instance),
        current_image_url: current_image_url,
        next_image_url: next_image_url,
        current_song_details: current_song_details,
        volume: volume,
        party_join_link: generate_invite_url(request, spotify_playlist_id)
      }
    end

    def generate_invite_url(request, spotify_playlist_id)
      # Generate the invite URL
      host = "#{request.scheme}://#{request.host}#{request.port == 4567 ? ":#{request.port}" : ''}"
      return "#{host}/p/#{session[:user_id]}/#{spotify_playlist_id}"
    end

    get "/qr_code.png" do
      content_type :png
      cache_control :no_cache
      headers("Pragma" => "no-cache", "Expires" => "0")

      spotify_instance = spotify_instances[session[:user_id]]
      spotify_playlist = spotify_instance.party_playlist
      party_join_link = generate_invite_url(request, spotify_playlist.id)

      # Generate a QR code for the invite URL
      qr_code = RQRCode::QRCode.new(party_join_link)
      png = qr_code.as_png(
        color: 'black',
        shape_rendering: 'crispEdges',
        module_size: 3,
        standalone: true,
        use_path: true,
        bit_depth: 1,
        color_mode: ChunkyPNG::COLOR_GRAYSCALE,
        file: nil,
        fill: "white",
        module_px_size: 6,
        resize_exactly_to: false,
        resize_gte_to: false,
        size: 300
      )
      return png.to_blob
    end

    post '/party/host/update' do
      unless all_sessions?
        redirect '/'
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
        if params[:party_toggle] == 'true'
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

      sonos.skip_song! if params[:skip_song]
    end

    get '/logout' do
      unless all_sessions?
        redirect '/'
        return
      end

      Db.sonos_tokens.where(user_id: session[:user_id]).delete
      Db.spotify_tokens.where(user_id: session[:user_id]).delete
      Db.users.where(id: session[:user_id]).delete
      session.delete(:user_id)

      redirect '/?logged_out=true'
    end

    # -----------------------
    # Guest code
    # -----------------------

    get '/p/:user_id/:playlist_id' do
      @title = 'Queue a Song'

      # No auth here, we just verify the 2 IDs
      spotify_instance = spotify_instances[params[:user_id].to_i]
      spotify_playlist = spotify_instance.party_playlist
      if spotify_playlist.id != params[:playlist_id]
        redirect '/'
        return
      end

      # Fetch the current queue, so we can render it
      sonos_instance = sonos_instances[params[:user_id].to_i]
      @queued_songs = queued_songs_json(spotify_instance, sonos_instance)

      erb :queue_song
    end

    # User submitted a song request
    post '/p/:user_id/:playlist_id/:song_id' do
      content_type :json

      user_id = params[:user_id].to_i
      spotify_instance = spotify_instances[user_id]
      spotify_playlist = spotify_instance.party_playlist
      sonos_instance = sonos_instances[user_id]

      # To make sure the user actually has the full link, and the IDs match
      if spotify_playlist.id != params[:playlist_id]
        redirect '/'
        return
      end

      # Queue that song
      song_to_queue = spotify_instance.find_song(params.fetch(:song_id))
      
      # Verify we haven't already played this song
      if queued_songs_json(spotify_instance, sonos_instance).any? { |song| song[:id] == song_to_queue.id.to_s }
        puts "Already played this song"
        return {
          success: false,
          error: 'Song was already played, or is already in the queue'
        }.to_json
      end
      spotify_instance.add_song_to_queue(song_to_queue)

      # Check if we can queue right away, or if we have to wait for the next song to start
      # This basically means, that no user wished song is currently playing, but the default playlist only
      puts "sonos_instance.currently_playing_guest_wished_song: #{sonos_instance.currently_playing_guest_wished_song}"
      if sonos_instance.currently_playing_guest_wished_song
        return {
          success: true,
          position: spotify_instance.queued_songs.count
        }.to_json
      else
        if spotify_instance.queued_songs.count != 1
          puts 'Something went wrong'
          puts spotify_instance.queued_songs
        end
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
    get '/sonos/authorized.html' do
      # So, this user is serious, they onboarded Sonos, so we now create an entry for them
      # First, create a new user
      user_id = SonosPartyMode::Db.users.insert

      # Now process the Sonos login
      authorization_code = params.fetch(:code)
      new_sonos = SonosPartyMode::Sonos.new(
        user_id: user_id,
        authorization_code: authorization_code
      )

      # Now look if we have an existing auth for that user
      # If there is, we gotta delete the 2 entries we just made
      # and use the existing one instead
      # we do this only because the initializer also takes care of the db write
      # and a refactor would be too much work atm
      primary_household = new_sonos.primary_household
      if primary_household.nil?
        # User doesn't actually have a sonos system attached
        # Delete the entry again
        Db.sonos_tokens.where(user_id: user_id).delete
        Db.users.where(id: user_id).delete
        redirect "/?error=no_sonos_system"
        return;
      end
      existing_entries = SonosPartyMode::Db.sonos_tokens.where(household: primary_household)
      entries_without_matching_spotify = existing_entries.to_a.find_all do |sonos_entry|
        SonosPartyMode::Db.spotify_tokens.where(user_id: sonos_entry[:user_id]).count.zero?
      end
      if existing_entries.count > entries_without_matching_spotify.count
        # Now delete all those entries, as one of the Sonos instances got a Spotify session attached
        entries_without_matching_spotify.each do |sonos_entry|
          SonosPartyMode::Db.sonos_tokens.where(id: sonos_entry[:id]).delete
          SonosPartyMode::Db.users.where(id: user_id).delete
        end
        sonos_db_entry = SonosPartyMode::Db.sonos_tokens.where(household: primary_household).first
        new_sonos = SonosPartyMode::Sonos.new(user_id: sonos_db_entry[:user_id])
        user_id = sonos_db_entry[:user_id]

        raise "Something went wrong here #{primary_household}... Sonos session" if new_sonos.nil?
      elsif existing_entries.count > 1
        # Delete all the entries besides the most recent one
        # As we have half-onboarded tokens here for some reason
        oldest_entry = existing_entries.to_a.sort_by { |entry| entry[:id] }.first
        existing_entries.to_a.each do |sonos_entry|
          next if sonos_entry[:id] == oldest_entry[:id]
          SonosPartyMode::Db.sonos_tokens.where(id: sonos_entry[:id]).delete
          SonosPartyMode::Db.users.where(id: user_id).delete
        end
        new_sonos = SonosPartyMode::Sonos.new(user_id: oldest_entry[:user_id])
        user_id = oldest_entry[:user_id]
      end

      # Then store this inside the session, and update `sonos_instances`
      session[:user_id] = user_id
      sonos_instances[user_id] = new_sonos

      redirect '/'
    end

    # Sonos callback information (ping, hook)
    post '/callback' do
      info = JSON.parse(request.body.read)
      sonos_group_id = request.env.fetch('HTTP_X_SONOS_TARGET_VALUE')
      puts "Received Sonos Web API callback for #{sonos_group_id}"

      # Find the matching sonos session to use
      filtered_instances = sonos_instances.values.find_all { |a| a.group_to_use == sonos_group_id }
      if filtered_instances.count.zero? # not a Sonos system we actively manage (any more)
        puts "Couldn't find the Sonos instance for #{sonos_group_id}"
        return
      end

      # iterate over multiple, in case there was half an auth, and we have an old session
      spotify_instance = nil
      sonos_instance = nil
      filtered_instances.each do |ins|
        spotify_instance = spotify_instances[ins.user_id]
        if spotify_instance
          sonos_instance = ins
          break
        end
      end
      if spotify_instance.nil? # not yet fully connected
        puts "Couldn't find the spotify instance for #{filtered_instances}"
        return
      end

      puts "\n\nSonos Notification\n\n"
      puts JSON.pretty_generate(info)
      puts "\n\n"

      if info['playbackState'] && !%w[PLAYBACK_STATE_PLAYING
                                      PLAYBACK_STATE_BUFFERING].include?(info.fetch('playbackState'))
        puts 'user paused the group...'
        sonos_instance.play_music! if sonos_instance.party_session_active
      end

      if info['itemId']
        if sonos_instance.current_item_id != info.fetch('itemId') &&
           sonos_instance.current_item_id == info.fetch('previousItemId')
          puts 'mismatching item IDs, this means the song is over'

          # Set it immediately, as the Sonos web requests do take some time to complete
          sonos_instance.current_item_id = info.fetch('itemId') # always set it

          # This means, the user has skipped to the next song, or the song has finished playing
          # we use this to do proper queueing of upcoming songs

          # We queue the next song (after this one's finished)
          puts 'Queue the new song now'
          sonos_instance.currently_playing_guest_wished_song = spotify_instance.add_next_song_to_sonos_queue!(sonos_instance)
          sonos_instance.current_item_id = info.fetch('itemId')
        end

        sonos_instance.current_item_id = info.fetch('itemId') # always set it
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

      if info['container']
        sonos_instance.did_receive_new_playback_metadata(info)

        # Pre-load the song's information from Spotify to get the album cover and other details
        # which is used by the party host's dashboard, reducing the load time from 5s to 0.5s
        # Even not assigning the variable, this is a cache
        if info['currentItem'] && info['currentItem']["track"] && info['currentItem']['track']["id"]
          current_spotify_object_id = info['currentItem']['track']['id']['objectId']
          spotify_instance.find_song(current_spotify_object_id)
        end

        if info['nextItem'] && info['nextItem']['track'] && info['nextItem']['track']["id"]
          next_spotify_object_id = info['nextItem']['track']['id']['objectId']
          spotify_instance.find_song(next_spotify_object_id)
        end
        # the `info` `track` entries are `nil` when there is no playlist playing atm
        # this is handled already with `#nothing-playing`
      end

      # Respond to Sonos
      #
      # When you receive an event, send a 200 OK response to let the Sonos cloud know that your client received it. Any response outside of the 200 range will be considered an error, including no response. Sonos also considers a 301 redirect an error as it does not follow redirects for events.
      # If Sonos isn’t able to send an event to your client, it retries every second for three tries. After the third try, if the Sonos cloud receives another error response or no response, it drops the event. Sonos does not backlog or replay events.
      # Make sure that your client responds to events quickly (within 1 second). To make sure that apps don’t accidentally run over the timeout limit, we recommend that you defer any lengthy event processing until after you’ve sent the 200 OK response.
      # As a best practice, you should unsubscribe to namespaces before terminating your event service.
      status 200
      body ''
    end

    # -----------------------
    # Spotify Specific Code
    # -----------------------

    SPOTIFY_REDIRECT_PATH = '/auth/spotify/callback'
    SPOTIFY_REDIRECT_URI = "#{HOST_URL}#{SPOTIFY_REDIRECT_PATH}".freeze

    get SPOTIFY_REDIRECT_PATH do
      if params[:state] == Hash(session)['state_key']
        session[:state_key] = nil

        new_spotify = SonosPartyMode::Spotify.new(
          user_id: session[:user_id],
          authorization_code: params[:code],
          redirect_uri: SPOTIFY_REDIRECT_URI
        )
        spotify_instances[session[:user_id]] = new_spotify
      else
        puts "Mismatching #{params[:state]}"
      end
      redirect '/'
    end

    get '/auth/spotify' do
      session[:state_key] = SecureRandom.hex

      redirect('https://accounts.spotify.com/authorize?' +
              URI.encode_www_form(
                client_id: ENV.fetch('SPOTIFY_CLIENT_ID', nil),
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
      return { error: 'Unauthorized' }.to_json if spotify_playlist.id != params[:playlist_id]
      return {}.to_json if song_name.to_s.strip.empty?

      puts "Searching for Spotify song using name #{song_name}"
      songs = spotify_instances[user_id].search_for_song(song_name)
      return songs.collect do |song|
        audio_features = song.audio_features
        {
          id: song.id,
          name: song.name,
          artists: song.artists.collect(&:name),
          thumbnail: song.album.images[1]['url'],
          danceability: audio_features.danceability,
          energy: audio_features.energy,
          tempo: audio_features.tempo,
          loudness: audio_features.loudness,
          liveness: audio_features.liveness,
          acousticness: audio_features.acousticness,
          speechiness: audio_features.speechiness,
          valence: audio_features.valence,
        }
      end.to_json
    end

    # Caching state
    def sonos_instances
      GlobalState[:sonos_instances]
    end

    def spotify_instances
      GlobalState[:spotify_instances]
    end

    # Others
    def queued_songs_json(spotify_instance, sonos_instance)
      queued_songs = spotify_instance.queued_songs.dup # `.dup` to not modify the actual queue

      # Manually prefix the most recently queued song, as it's already in the Sonos queue
      queued_songs.unshift(spotify_instance.past_songs.last) if spotify_instance.past_songs.count.positive? && sonos_instance.currently_playing_guest_wished_song

      return queued_songs.collect do |track|
        {
          album_cover: track.album.images[-1]['url'],
          name: track.name,
          artists: track.artists.map(&:name).join(', '),
          id: track.id.to_s,
          duration: track.duration_ms.to_i / 1000,
          uri: track.uri
        }
      end
    end

    run!
  end
end

SonosPartyMode::Server if __FILE__ == $PROGRAM_NAME
