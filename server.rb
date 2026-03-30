# frozen_string_literal: true
require 'sinatra/base'
require 'rspotify'
require 'rqrcode'
require 'openssl'
require 'base64'
require 'securerandom'
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
    set :show_exceptions, false

    def load_tokens_from_db
      # Boot up code: load existing sessions into the `session` instances
      SonosPartyMode::Db.users.each do |user|
        begin
          sonos_obj = SonosPartyMode::Sonos.new(user_id: user[:id])
          spotify_obj = SonosPartyMode::Spotify.new(user_id: user[:id])

          # Important to check if there is an actual entry, since otherwise there will be empty objects in those hashes
          sonos_instances[user[:id]] ||= sonos_obj unless sonos_obj.database_row.nil?
          spotify_instances[user[:id]] ||= spotify_obj unless spotify_obj.database_row.nil?
        rescue => ex
          puts "Catching exception during bootup: #{ex.class}"
          puts ex.to_s
          puts ex.backtrace.join("\n")
        end
      end
      puts "Finished booting up #{sonos_instances.count} Sonos instances and #{spotify_instances.count} Spotify instances"
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
          sonos_instances.each do |user_id, sonos|
            begin
              sonos.ensure_current_sonos_settings!
            rescue => ex
              puts "Failed to enforce Sonos settings for user #{user_id}"
              puts ex
              puts ex.backtrace.join("\n")
            end
          end
          sleep(2)
        end
      end
      Thread.new do
        loop do
          sonos_instances.each do |user_id, sonos|
            begin
              sonos.refresh_caches
            rescue => ex
              puts "Failed to refresh Sonos caches for user #{user_id}"
              puts ex
              puts ex.backtrace.join("\n")
            end
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

    def csrf_token
      session[:csrf_token] ||= SecureRandom.hex(32)
    end

    def verify_csrf_token!
      submitted_token = params[:csrf_token].to_s
      submitted_token = request.env.fetch('HTTP_X_CSRF_TOKEN', '').to_s if submitted_token.empty?
      halt 403, 'Invalid CSRF token' if submitted_token.empty?
      halt 403, 'Invalid CSRF token' unless submitted_token.bytesize == csrf_token.bytesize &&
                                            Rack::Utils.secure_compare(submitted_token, csrf_token)
    end

    def verify_sonos_callback_signature!(raw_body)
      signing_key = ENV.fetch('SONOS_SECRET', '').to_s
      return if signing_key.empty?

      provided_signature = request.env.fetch('HTTP_X_SONOS_EVENT_SIGNATURE', '').to_s
      halt 401, 'Missing Sonos event signature' if provided_signature.empty?

      expected_signature = Base64.strict_encode64(
        OpenSSL::HMAC.digest('sha256', signing_key, raw_body)
      )
      halt 401, 'Invalid Sonos event signature' unless provided_signature.bytesize == expected_signature.bytesize &&
                                                      Rack::Utils.secure_compare(provided_signature, expected_signature)
    end

    def remove_user_from_memory!(user_id)
      sonos_instances.delete(user_id)
      spotify_instances.delete(user_id)
    end

    def queue_snapshot_tracks(spotify_instance, sonos_instance)
      queued_songs = spotify_instance.queued_songs.dup
      queued_songs.unshift(spotify_instance.past_songs.last) if spotify_instance.past_songs.count.positive? &&
                                                                 sonos_instance.currently_playing_guest_wished_song
      queued_songs.compact
    end

    def track_to_json(track)
      album_images = track.album.images || []
      album_image = album_images.last || album_images.first
      {
        album_cover: album_image && album_image['url'],
        name: track.name,
        artists: track.artists.map(&:name).join(', '),
        id: track.id.to_s,
        duration: track.duration_ms.to_i / 1000,
        uri: track.uri
      }
    end

    def json_for_script(data)
      json = data.is_a?(String) ? data : data.to_json
      json.gsub('<', '\u003c').gsub('>', '\u003e').gsub('&', '\u0026')
    end

    def process_sonos_callback(raw_body:, sonos_group_id:)
      info = JSON.parse(raw_body)
      puts "Received Sonos Web API callback for #{sonos_group_id}"

      filtered_instances = sonos_instances.values.find_all { |instance| instance.group_to_use == sonos_group_id }
      if filtered_instances.count.zero?
        puts "Couldn't find the Sonos instance for #{sonos_group_id}"
        return
      end

      spotify_instance = nil
      sonos_instance = nil
      filtered_instances.each do |instance|
        spotify_candidate = spotify_instances[instance.user_id]
        next if spotify_candidate.nil?

        spotify_instance = spotify_candidate
        sonos_instance = instance
        break
      end
      if spotify_instance.nil?
        puts "Couldn't find the Spotify instance for #{filtered_instances}"
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
        spotify_instance.queue_mutex.synchronize do
          transitioned_to_new_song = sonos_instance.current_item_id != info.fetch('itemId') &&
                                     sonos_instance.current_item_id == info.fetch('previousItemId')

          sonos_instance.current_item_id = info.fetch('itemId')

          if transitioned_to_new_song
            puts 'Queue the new song now'
            queued_successfully = spotify_instance.add_next_song_to_sonos_queue!(sonos_instance)
            sonos_instance.currently_playing_guest_wished_song = queued_successfully
          end
        end
      end

      if info['container']
        sonos_instance.did_receive_new_playback_metadata(info)

        if info['currentItem'] && info['currentItem']['track'] && info['currentItem']['track']['id']
          current_spotify_object_id = info['currentItem']['track']['id']['objectId']
          spotify_instance.find_song(current_spotify_object_id)
        end

        if info['nextItem'] && info['nextItem']['track'] && info['nextItem']['track']['id']
          next_spotify_object_id = info['nextItem']['track']['id']['objectId']
          spotify_instance.find_song(next_spotify_object_id)
        end
      end
    rescue => ex
      puts "Failed to process Sonos callback for #{sonos_group_id}"
      puts ex
      puts ex.backtrace.join("\n")
    end

    get '/' do
      @title = 'Login'

      @logged_out = params[:logged_out]
      @number_of_parties = SonosPartyMode::Db.users.count

      if session[:user_id].nil? || SonosPartyMode::Db.sonos_tokens.where(user_id: session[:user_id]).count.zero?
        session[:sonos_state_key] = SecureRandom.hex(32)
        redirect_uri = "#{HOST_URL}/sonos/authorized.html"
        @sonos_login_url = 'https://api.sonos.com/login/v3/oauth?' \
                           "client_id=#{ENV.fetch('SONOS_KEY')}&" \
                           'response_type=code&' \
                           "state=#{session[:sonos_state_key]}&" \
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
      sonos_instances.each do |user_id, sonos|
        begin
          sonos.ensure_current_sonos_settings!
        rescue => ex
          puts "Failed to ensure Sonos settings for user #{user_id}"
          puts ex
          puts ex.backtrace.join("\n")
        end
      end
    end

    get '/assets/*' do
      if [
        '/assets/aux-cable.png',
        '/assets/add-to-sonos-1.png',
        '/assets/add-to-sonos-2.png',
        '/assets/add-to-sonos-3.png',
        '/assets/favicon.ico',
        '/assets/favicon-16x16.png',
        '/assets/favicon-32x32.png',
        '/assets/apple-touch-icon.png',
        '/assets/android-chrome-512x512.png',
        '/assets/android-chrome-192x192.png',
        '/assets/logo.png',
        '/assets/spotify-logo.png'
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
        return erb :party, locals: pd.merge(initial_party_data: pd)
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
      return { redirect: '/' } if spotify_instance.nil? || sonos_instance.nil?

      spotify_playlist = spotify_instance.party_playlist
      spotify_playlist_id = spotify_playlist.id

      playback_metadata = sonos_instance.playback_metadata
      if Hash(Hash(playback_metadata.fetch('currentItem', nil)).fetch('track', nil)).fetch('id', nil).nil?
        sonos_groups = sonos_instance.groups_cached || sonos_instance.groups
        selected_group = sonos_groups&.find { |group| group['id'] == sonos_instance.group_to_use }
        # Nothing playing
        return {
          nothing_playing: true,
          group_to_use: selected_group ? selected_group['name'] : 'Unknown group'
        }
      end
      current_spotify_object_id = playback_metadata['currentItem']['track']['id']['objectId'] rescue nil
      if current_spotify_object_id
        current_spotify_track = spotify_instance.find_song(current_spotify_object_id)
        current_image = current_spotify_track&.album&.images&.[](1) || current_spotify_track&.album&.images&.last
        current_image_url = current_image && current_image['url']
      else
        current_spotify_track = nil
        current_image_url = nil
      end
      current_song_details = playback_metadata['currentItem']['track'] rescue nil
      if current_song_details.nil?
        current_song_details = { "name" => "Unknown"}
      end

      next_spotify_object_id = playback_metadata['nextItem']['track']['id']['objectId'] rescue nil
      if next_spotify_object_id
        next_spotify_track = spotify_instance.find_song(next_spotify_object_id)
        next_image = next_spotify_track&.album&.images&.[](1) || next_spotify_track&.album&.images&.last
        next_image_url = next_image && next_image['url']
      else
        next_spotify_track = nil
        next_image_url = nil
      end

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
      groups = Array(sonos_groups).collect do |group|
        {
          name: group.fetch('name'),
          id: group.fetch('id'),
          number_of_speakers: group.fetch('playerIds').count
        }
      end.sort_by { |group| group[:number_of_speakers] }.reverse
      selected_group = sonos_instance.group_to_use

      spotify_url = current_spotify_track ? current_spotify_track.external_urls['spotify'] : nil

      return {
        selected_group: selected_group,
        groups: groups,
        party_on: party_on,
        queued_songs: queued_songs_json(spotify_instance, sonos_instance),
        current_image_url: current_image_url,
        next_image_url: next_image_url,
        current_song_details: current_song_details,
        volume: volume,
        party_join_link: generate_invite_url(request, spotify_playlist_id),
        spotify_url: spotify_url
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
      verify_csrf_token!

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

        available_group_ids = Array(sonos.groups_cached || sonos.groups).map { |group| group['id'] }
        sonos.group_to_use = params[:group_to_use] if available_group_ids.include?(params[:group_to_use])

        # Now, trigger playing on the new group
        sonos.ensure_music_playing! if sonos.party_session_active # but only if the party is currently active
      end

      sonos.skip_song! if params[:skip_song]
    end

    get '/logout' do
      redirect '/'
    end

    post '/logout' do
      unless all_sessions?
        redirect '/'
        return
      end
      verify_csrf_token!

      user_id = session[:user_id]
      Db.sonos_tokens.where(user_id: user_id).delete
      Db.spotify_tokens.where(user_id: user_id).delete
      Db.users.where(id: user_id).delete
      remove_user_from_memory!(user_id)
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
      sonos_instance = sonos_instances[params[:user_id].to_i]
      if spotify_instance.nil? || sonos_instance.nil?
        redirect '/'
        return
      end

      spotify_playlist = spotify_instance.party_playlist
      if spotify_playlist.id != params[:playlist_id]
        redirect '/'
        return
      end

      # Fetch the current queue, so we can render it
      @queued_songs = queued_songs_json(spotify_instance, sonos_instance)

      erb :queue_song
    end

    # User submitted a song request
    post '/p/:user_id/:playlist_id/:song_id' do
      content_type :json

      user_id = params[:user_id].to_i
      spotify_instance = spotify_instances[user_id]
      sonos_instance = sonos_instances[user_id]
      if spotify_instance.nil? || sonos_instance.nil?
        status 404
        return { success: false, error: 'This party is no longer available' }.to_json
      end

      spotify_playlist = spotify_instance.party_playlist

      # To make sure the user actually has the full link, and the IDs match
      if spotify_playlist.id != params[:playlist_id]
        status 403
        return { success: false, error: 'Unauthorized' }.to_json
      end

      # Queue that song
      song_to_queue = spotify_instance.find_song(params.fetch(:song_id))
      if song_to_queue.nil?
        status 404
        return {
          success: false,
          error: 'This Spotify song is no longer available'
        }.to_json
      end

      result = spotify_instance.queue_mutex.synchronize do
        existing_track_ids = (spotify_instance.queued_songs + spotify_instance.past_songs).filter_map { |track| track&.id.to_s }
        if existing_track_ids.include?(song_to_queue.id.to_s)
          puts 'Already played this song'
          {
            success: false,
            error: 'Song was already played, or is already in the queue'
          }
        else
          spotify_instance.add_song_to_queue(song_to_queue)

          puts "sonos_instance.currently_playing_guest_wished_song: #{sonos_instance.currently_playing_guest_wished_song}"
          if sonos_instance.currently_playing_guest_wished_song
            {
              success: true,
              position: spotify_instance.queued_songs.count
            }
          else
            queued_successfully = spotify_instance.add_next_song_to_sonos_queue!(sonos_instance)
            sonos_instance.currently_playing_guest_wished_song = queued_successfully

            if queued_successfully
              {
                success: true,
                position: 0
              }
            else
              {
                success: false,
                error: 'Failed to queue the song on Sonos. Please try again in a moment.'
              }
            end
          end
        end
      end

      result.to_json
    end

    # -----------------------
    # Sonos Specific Code
    # -----------------------
    get '/sonos/authorized.html' do
      if params[:state].to_s.empty? || params[:state] != session[:sonos_state_key]
        session[:sonos_state_key] = nil
        redirect '/?error=invalid_sonos_state'
        return
      end
      session[:sonos_state_key] = nil

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
      raw_body = request.body.read.to_s
      verify_sonos_callback_signature!(raw_body)
      sonos_group_id = request.env.fetch('HTTP_X_SONOS_TARGET_VALUE', nil)

      Thread.new do
        process_sonos_callback(raw_body: raw_body, sonos_group_id: sonos_group_id)
      end

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
      spotify_instance = spotify_instances[user_id]
      if spotify_instance.nil?
        status 404
        return { error: 'This party is no longer available' }.to_json
      end

      spotify_playlist = spotify_instance.party_playlist

      # To make sure the user actually has the full link, and the IDs match
      return { error: 'Unauthorized' }.to_json if spotify_playlist.id != params[:playlist_id]
      return [].to_json if song_name.to_s.strip.empty?

      puts "Searching for Spotify song using name #{song_name}"
      songs = spotify_instance.search_for_song(song_name)
      return songs.collect do |song|
        {
          id: song.id,
          name: song.name,
          artists: song.artists.collect(&:name),
          thumbnail: (song.album.images[1] || song.album.images.last || {})['url']
        }
      end.to_json
    rescue => ex
      puts "Spotify search failed for user #{user_id}"
      puts ex
      puts ex.backtrace.join("\n")
      [].to_json
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
      spotify_instance.queue_mutex.synchronize do
        return queue_snapshot_tracks(spotify_instance, sonos_instance).collect do |track|
          track_to_json(track)
        end
      end
    end

    run!
  end
end

SonosPartyMode::Server if __FILE__ == $PROGRAM_NAME
