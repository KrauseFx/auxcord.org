# frozen_string_literal: true

require 'excon'
require 'rspotify'
require 'json'
require 'thread'
# require "pry"
require_relative './db'

module SonosPartyMode
  class Spotify
    attr_accessor :user_id
    attr_reader :queued_songs, :past_songs, :queue_mutex

    def initialize(user_id:, authorization_code: nil, redirect_uri: nil)
      self.user_id = user_id
      @queue_mutex = Mutex.new
      new_auth!(authorization_code: authorization_code, redirect_uri: redirect_uri) if authorization_code

      return if database_row.nil? # this is the case if a user didn't finish onboarding

      @queued_songs = []
      @past_songs = []
      load_queue_state!
    end

    def spotify_user
      return nil if database_row.nil?
      return @_spotify_user if @_spotify_user

      options = JSON.parse(database_row.fetch(:options))
      options['credentials'] ||= {}
      options['credentials']['access_refresh_callback'] = access_refresh_callback
      @_spotify_user = RSpotify::User.new(options)
    end

    def database_row
      query = Db.spotify_tokens.where(user_id: user_id)
      return nil if query.empty?

      return query.order(Sequel.desc(:id)).first
    end

    def party_playlist
      return @_playlist if @_playlist

      # Find or create the Party playlist
      playlist_id = database_row.fetch(:playlist_id)
      unless playlist_id
        puts "Creating new playlist for user id #{user_id}"
        playlist = spotify_user.create_playlist!("#{user_id} auxcord.org - Don't Delete")
        playlist_id = playlist.id
        prepare_welcome_playlist_song!(playlist)
        puts "Finished creating playlist with id #{playlist_id}"

        # Verify that the playlist was created and contains one song
        raise 'Playlist was not created' if playlist.tracks.count == 0

        # Remember the Spotify playlist ID
        Db.spotify_tokens.where(user_id: user_id).update(playlist_id: playlist_id) # use full query syntax
      end
      return (@_playlist = RSpotify::Playlist.find(spotify_user.id, playlist_id))
    end

    # Add a welcome song to the playlist, so Sonos can handle the playlist
    # Sonos app doesn't handle empty playlists well
    def prepare_welcome_playlist_song!(playlist)
      return if playlist.tracks.count.positive?

      hello_there_song = RSpotify::Track.search('Hello there dillon francis').first
      playlist.add_tracks!([hello_there_song])
    end

    def search_for_song(name)
      return RSpotify::Track.search(name)
    end

    # Search for a specific Spotify song using the Spotify ID, including a local cache
    def find_song(song_id)
      return nil if song_id.to_s.length == 0

      song_id.gsub!('spotify:track:', '')
      @_song_cache ||= {}
      return @_song_cache[song_id] if @_song_cache[song_id]

      @_song_cache[song_id] = RSpotify::Track.find(song_id)
    rescue => ex
      puts ex
      puts ex.backtrace.join("\n")
      puts "Using song_id #{song_id}"
      nil
    end

    # This method will add songs to the queue (playlist) on Spotify, but not yet add it to the Sonos queue
    def add_song_to_queue(song)
      queued_songs << song
      persist_queue_state!
    end

    # Actually send all songs wished for to the Sonos queue
    def add_next_song_to_sonos_queue!(sonos, retries: 3, retry_delay: 1)
      next_song = queued_songs.first
      if next_song.nil?
        puts 'No more auxcord songs in queue...'
        return false
      end

      attempt = 0
      begin
        attempt += 1

        # First, clear the Spotify playlist, in case there was anything left there
        clear_party_playlist!
        party_playlist.add_tracks!([next_song])

        # Get the Sonos ID of the favorite playlist
        fav_id = sonos.ensure_playlist_in_favorites(party_playlist.id)
        raise 'Missing Sonos favorite for Spotify playlist' if fav_id.nil?

        # Queue the one song from that playlist into the Sonos Queue
        puts "Queueing #{next_song.name} by #{next_song.artists.first.name} to Sonos"
        sonos.client_control_request(
          "/groups/#{sonos.group_to_use}/favorites",
          method: :post,
          body: {
            favoriteId: fav_id.fetch('id'),
            action: 'INSERT_NEXT'
          }
        )

        queued_songs.shift
        past_songs << next_song
        persist_queue_state!
        true
      rescue => ex
        puts "Failed to queue next Sonos song for user #{user_id} (attempt #{attempt}/#{retries})"
        puts ex
        puts ex.backtrace.join("\n")
        retry if attempt < retries && sleep(retry_delay * attempt)

        false
      ensure
        cleanup_playlist_song!(next_song)
      end
    end

    def self.permission_scope
      return %w[
        playlist-read-private
        playlist-modify-public
        user-library-modify
      ].join(' ')
    end

    def new_auth!(authorization_code:, redirect_uri:)
      auth_string = Base64.strict_encode64("#{ENV.fetch('SPOTIFY_CLIENT_ID')}:#{ENV.fetch('SPOTIFY_CLIENT_SECRET')}")
      auth_response = Excon.post(
        'https://accounts.spotify.com/api/token',
        body: URI.encode_www_form({
                                    'grant_type' => 'authorization_code',
                                    'redirect_uri' => redirect_uri,
                                    'code' => authorization_code
                                  }),
        headers: {
          'Authorization' => "Basic #{auth_string}",
          'Content-Type' => 'application/x-www-form-urlencoded'
        }
      )
      parsed_credentials = JSON.parse(auth_response.body)

      # Manually re-name key, via https://github.com/guilhermesad/rspotify/issues/90#issuecomment-519603961
      parsed_credentials['token'] = parsed_credentials['access_token']

      info_response = Excon.get('https://api.spotify.com/v1/me',
                                headers: {
                                  'Authorization' => "Bearer #{parsed_credentials.fetch('access_token')}"
                                })
      info_parsed = JSON.parse(info_response.body)

      options = {
        'credentials' => parsed_credentials,
        'info' => info_parsed
      }
      RSpotify::User.new(options)
      save_authorized_user!(options)
      @_spotify_user = nil
    end

    def access_refresh_callback
      @access_refresh_callback ||= proc do |new_access_token, token_lifetime|
        refreshed_options = JSON.parse(database_row.fetch(:options))
        refreshed_options['credentials'] ||= {}
        refreshed_options['credentials']['token'] = new_access_token
        refreshed_options['credentials']['access_token'] = new_access_token
        refreshed_options['credentials']['expires_in'] = token_lifetime
        refreshed_options['credentials']['expires_at'] = Time.now.to_i + token_lifetime.to_i
        persist_spotify_options!(refreshed_options)
      end
    end

    def save_authorized_user!(options)
      query = Db.spotify_tokens.where(user_id: user_id)
      latest_row = query.order(Sequel.desc(:id)).first
      payload = {
        user_id: user_id,
        options: JSON.pretty_generate(options.to_hash),
        playlist_id: latest_row && latest_row[:playlist_id],
        queue_track_ids: latest_row && latest_row[:queue_track_ids],
        past_track_ids: latest_row && latest_row[:past_track_ids]
      }

      if latest_row
        Db.spotify_tokens.where(id: latest_row[:id]).update(payload.reject { |key, _| key == :user_id })
        query.exclude(id: latest_row[:id]).delete
      else
        Db.spotify_tokens.insert(payload)
      end
    end

    def persist_spotify_options!(options)
      Db.spotify_tokens.where(user_id: user_id).update(options: JSON.pretty_generate(options))
    end

    def load_queue_state!
      queued_ids = deserialize_track_ids(database_row[:queue_track_ids])
      past_ids = deserialize_track_ids(database_row[:past_track_ids])

      @queued_songs = queued_ids.map { |track_id| find_song(track_id) }.compact
      @past_songs = past_ids.map { |track_id| find_song(track_id) }.compact

      persist_queue_state! if queued_ids.length != @queued_songs.length || past_ids.length != @past_songs.length
    end

    def persist_queue_state!
      return if database_row.nil?

      Db.spotify_tokens.where(user_id: user_id).update(
        queue_track_ids: JSON.generate(queued_song_ids),
        past_track_ids: JSON.generate(past_song_ids)
      )
    end

    def queued_song_ids
      queued_songs.filter_map { |track| track&.id.to_s if track&.id.to_s.length.positive? }
    end

    def past_song_ids
      past_songs.filter_map { |track| track&.id.to_s if track&.id.to_s.length.positive? }
    end

    def deserialize_track_ids(raw_ids)
      parsed_ids = JSON.parse(raw_ids.to_s)
      return parsed_ids if parsed_ids.is_a?(Array)

      []
    rescue JSON::ParserError
      []
    end

    def clear_party_playlist!
      current_tracks = party_playlist.tracks
      party_playlist.remove_tracks!(current_tracks) if current_tracks.any?
    end

    def cleanup_playlist_song!(song)
      return if song.nil?

      party_playlist.remove_tracks!([song])
    rescue => ex
      puts "Failed to clean up temporary Spotify queue song for user #{user_id}"
      puts ex
    end
  end
end
