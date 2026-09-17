# frozen_string_literal: true

require 'excon'
require 'rspotify'
require 'json'
require 'base64'
require 'uri'
# require "pry"
require_relative './db'

module SonosPartyMode
  class Spotify
    class ReauthorizationRequired < StandardError; end
    class TokenRefreshFailed < StandardError; end
    class SonosInsertFailed < StandardError; end

    attr_accessor :user_id, :queued_songs, :past_songs

    def initialize(user_id:, authorization_code: nil, redirect_uri: nil)
      self.user_id = user_id
      # Guards the in-memory queue state. Never held while talking to Spotify or Sonos
      @queue_mutex = Mutex.new
      # Serializes Sonos inserts, so songs reach the Sonos queue in the order guests picked them
      @sonos_insert_mutex = Mutex.new
      @pending_sonos_inserts = 0
      new_auth!(authorization_code: authorization_code, redirect_uri: redirect_uri) if authorization_code

      return if database_row.nil? # this is the case if a user didn't finish onboarding

      self.queued_songs = []
      self.past_songs = []
    end

    def spotify_user
      return nil if database_row.nil?

      RSpotify::User.new(JSON.parse(database_row.fetch(:options)))
    end

    def database_row
      query = Db.spotify_tokens.where(user_id: user_id)
      return nil if query.empty?

      return query.first
    end

    def party_playlist
      return @_playlist if @_playlist

      return party_playlist_without_refresh
    end

    def party_playlist_without_refresh
      # Find or create the Party playlist
      playlist_id = database_row.fetch(:playlist_id)
      unless playlist_id
        puts "Creating new playlist for user id #{user_id}"
        playlist = spotify_request { spotify_user.create_playlist!("#{user_id} auxcord.org - Don't Delete") }
        playlist_id = playlist.id
        Db.spotify_tokens.where(user_id: user_id).update(playlist_id: playlist_id)
        prepare_welcome_playlist_song!(playlist)
        puts "Finished creating playlist with id #{playlist_id}"

        # Verify that the playlist was created and contains one song
        raise 'Playlist was not created' if spotify_request { playlist.tracks.count } == 0
      end
      return (@_playlist = spotify_request { RSpotify::Playlist.find(spotify_user.id, playlist_id) })
    end

    def spotify_request(&request)
      failed_access_token = spotify_credentials['token']
      request.call
    rescue RestClient::Unauthorized
      refresh_and_retry_spotify_request(failed_access_token, &request)
    end

    def refresh_and_retry_spotify_request(failed_access_token, &request)
      @refresh_mutex ||= Mutex.new
      @refresh_mutex.synchronize do
        # A concurrent request may already have refreshed and persisted the token.
        if spotify_credentials['token'] == failed_access_token
          refresh_spotify_credentials!
        else
          RSpotify::User.new(spotify_options)
        end
      end
      return request.call
    rescue RestClient::Unauthorized
      raise ReauthorizationRequired, 'Spotify authorization is no longer valid'
    end

    def refresh_spotify_credentials!
      options = spotify_options
      credentials = options.fetch('credentials')
      refresh_token = credentials['refresh_token']
      raise ReauthorizationRequired, 'Spotify authorization is no longer valid' if refresh_token.to_s.empty?

      auth_string = Base64.strict_encode64("#{ENV.fetch('SPOTIFY_CLIENT_ID')}:#{ENV.fetch('SPOTIFY_CLIENT_SECRET')}")
      response = Excon.post(
        'https://accounts.spotify.com/api/token',
        body: URI.encode_www_form({
                                    'grant_type' => 'refresh_token',
                                    'refresh_token' => refresh_token
                                  }),
        headers: {
          'Authorization' => "Basic #{auth_string}",
          'Content-Type' => 'application/x-www-form-urlencoded'
        }
      )
      unless response.status == 200
        error_code = JSON.parse(response.body).fetch('error', nil)
        raise ReauthorizationRequired, 'Spotify authorization is no longer valid' if response.status == 400 && error_code == 'invalid_grant'

        raise TokenRefreshFailed, "Spotify token refresh failed with status #{response.status}"
      end

      refreshed = JSON.parse(response.body)
      access_token = refreshed.fetch('access_token')
      expires_in = refreshed.fetch('expires_in').to_i
      credentials['token'] = access_token
      credentials['access_token'] = access_token
      credentials['expires_in'] = expires_in
      credentials['expires_at'] = Time.now.to_i + expires_in
      credentials['expires'] = true
      credentials['refresh_token'] = refreshed['refresh_token'] unless refreshed['refresh_token'].to_s.empty?

      Db.spotify_tokens.where(user_id: user_id).update(options: JSON.generate(options))
      RSpotify::User.new(options) # Re-prime RSpotify's in-memory credentials before retrying.
    rescue ReauthorizationRequired, TokenRefreshFailed
      raise
    rescue Excon::Error, JSON::ParserError, KeyError
      raise TokenRefreshFailed, 'Spotify token refresh failed'
    end

    def spotify_options
      JSON.parse(database_row.fetch(:options))
    rescue JSON::ParserError, KeyError, NoMethodError, TypeError
      raise ReauthorizationRequired, 'Spotify authorization is no longer valid'
    end

    def spotify_credentials
      spotify_options.fetch('credentials')
    rescue KeyError
      raise ReauthorizationRequired, 'Spotify authorization is no longer valid'
    end

    def spotify_account_id(row)
      JSON.parse(row.fetch(:options)).dig('info', 'id')
    rescue JSON::ParserError, KeyError, TypeError
      nil
    end

    private :party_playlist_without_refresh, :spotify_request, :refresh_and_retry_spotify_request,
            :refresh_spotify_credentials!, :spotify_options, :spotify_credentials,
            :spotify_account_id

    # Add a welcome song to the playlist, so Sonos can handle the playlist
    # Sonos app doesn't handle empty playlists well
    def prepare_welcome_playlist_song!(playlist)
      return if spotify_request { playlist.tracks.count }.positive?

      hello_there_song = RSpotify::Track.search('Hello there dillon francis').first
      spotify_request { playlist.add_tracks!([hello_there_song]) }
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

    # Adds a guest's song to the auxcord queue (not yet the Sonos queue). Returns
    # - :duplicate if it's already waiting or up next on Sonos
    # - :waiting if another guest song is up next on Sonos, so it gets queued once that one starts
    # - :queue_now if the caller should call `run_reserved_sonos_insert!` right away
    def enqueue_guest_song(song, sonos)
      @queue_mutex.synchronize do
        songs = queued_songs.dup
        songs << past_songs.last if past_songs.any? && sonos.currently_playing_guest_wished_song
        return :duplicate if songs.any? { |track| track.id.to_s == song.id.to_s }

        queued_songs << song
        return :waiting if sonos.currently_playing_guest_wished_song || @pending_sonos_inserts.positive?

        @pending_sonos_inserts += 1
        return :queue_now
      end
    end

    # Called for every Sonos playback event. Returns true when Sonos moved on to the next song while
    # guest songs are waiting, in which case the caller runs `run_reserved_sonos_insert!`
    def song_changed!(sonos, item_id:, previous_item_id:)
      @queue_mutex.synchronize do
        song_over = !previous_item_id.nil? &&
                    sonos.current_item_id != item_id &&
                    sonos.current_item_id == previous_item_id
        sonos.current_item_id = item_id # always set it
        return false unless song_over

        # Whatever guest song was up next is now playing
        sonos.currently_playing_guest_wished_song = false
        return false if queued_songs.empty?

        @pending_sonos_inserts += 1
        return true
      end
    end

    # Queues the next waiting guest song on Sonos, for a slot reserved by `enqueue_guest_song` or
    # `song_changed!`. Guests who show up meanwhile wait in line instead of jumping ahead.
    def run_reserved_sonos_insert!(sonos)
      queued = add_next_song_to_sonos_queue!(sonos)
      @queue_mutex.synchronize { sonos.currently_playing_guest_wished_song = true } if queued
      return queued
    ensure
      @queue_mutex.synchronize { @pending_sonos_inserts -= 1 }
    end

    # 0 once the song is on the Sonos queue, otherwise its place in the auxcord queue
    def queued_position(song)
      @queue_mutex.synchronize { (queued_songs.index { |track| track.equal?(song) } || -1) + 1 }
    end

    def remove_queued_song(song)
      @queue_mutex.synchronize { queued_songs.delete_if { |track| track.equal?(song) } }
    end

    # Actually send the next song wished for to the Sonos queue. Returns false if no song is waiting.
    # The song only leaves `queued_songs` once Sonos accepted it, so if any step fails (and raises)
    # it stays first in line for the next attempt.
    def add_next_song_to_sonos_queue!(sonos)
      @sonos_insert_mutex.synchronize do
        next_song = @queue_mutex.synchronize { queued_songs.first }
        if next_song.nil?
          puts 'No more auxcord songs in queue...'
          return false
        end

        # First, clear the Spotify playlist, in case there was anything left there
        spotify_request do
          playlist = party_playlist
          playlist.remove_tracks!(playlist.tracks)
        end
        spotify_request { party_playlist.add_tracks!([next_song]) }

        begin
          # Get the Sonos ID of the favorite playlist
          fav = sonos.ensure_playlist_in_favorites(party_playlist)
          raise SonosInsertFailed, "Couldn't find the auxcord playlist in the Sonos favorites" if fav.nil?

          # Queue the one song from that playlist into the Sonos Queue
          puts "Queueing #{next_song.name} by #{next_song.artists.first.name} to Sonos"
          response = sonos.client_control_request(
            "/groups/#{sonos.group_to_use}/favorites",
            method: :post,
            body: {
              favoriteId: fav.fetch('id'),
              action: 'INSERT_NEXT'
            }
          )
          raise SonosInsertFailed, "Sonos didn't queue the song: #{response['errorCode']}" if response.is_a?(Hash) && response['errorCode']
        rescue StandardError
          remove_from_party_playlist(next_song)
          raise
        end

        @queue_mutex.synchronize do
          queued_songs.delete_if { |track| track.equal?(next_song) }
          past_songs << next_song
        end
        remove_from_party_playlist(next_song)
        return true
      end
    end

    # Best effort, as the next insert clears the playlist anyway
    def remove_from_party_playlist(song)
      spotify_request { party_playlist.remove_tracks!([song]) }
    rescue StandardError => ex
      puts "Failed to remove #{song.id} from the auxcord playlist for user #{user_id}: #{ex.class}: #{ex}"
    end
    private :remove_from_party_playlist

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
      tokens = Db.spotify_tokens.where(user_id: user_id)
      if tokens.empty?
        tokens.insert(user_id: user_id, options: JSON.pretty_generate(options.to_hash))
      else
        matching_rows = tokens.all.select { |row| spotify_account_id(row) == info_parsed.fetch('id') }
        playlist_id = matching_rows.filter_map { |row| row[:playlist_id] }.first
        tokens.update(options: JSON.pretty_generate(options.to_hash), playlist_id: playlist_id)
      end
    end
  end
end
