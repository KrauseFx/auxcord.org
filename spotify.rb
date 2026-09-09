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

    attr_accessor :user_id, :queued_songs, :past_songs

    def initialize(user_id:, authorization_code: nil, redirect_uri: nil)
      self.user_id = user_id
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

    # This method will add songs to the queue (playlist) on Spotify, but not yet add it to the Sonos queue
    def add_song_to_queue(song)      
      queued_songs << song
    end

    # Actually send all songs wished for to the Sonos queue
    def add_next_song_to_sonos_queue!(sonos)
      # First, clear the Spotify playlist, in case there was anything left there
      spotify_request do
        playlist = party_playlist
        playlist.remove_tracks!(playlist.tracks)
      end

      next_song = queued_songs.shift
      if next_song.nil?
        puts 'No more auxcord songs in queue...'
        return false
      end
      past_songs << next_song
      spotify_request { party_playlist.add_tracks!([next_song]) }

      # Get the Sonos ID of the favorite playlist
      fav_id = sonos.ensure_playlist_in_favorites(party_playlist.id)

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
      spotify_request { party_playlist.remove_tracks!([next_song]) }
      return true
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
