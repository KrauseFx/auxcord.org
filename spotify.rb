require "excon"
require "rspotify"
require "json"
require "pry"
require_relative "./db"

module SonosPartyMode
  class Spotify
    attr_accessor :user_id
    attr_accessor :queued_songs
    attr_accessor :past_songs

    def initialize(user_id:, authorization_code: nil, redirect_uri: nil)
      self.user_id = user_id
      if authorization_code
        self.new_auth!(authorization_code: authorization_code, redirect_uri: redirect_uri)
      end

      return nil if database_row.nil? # this is the case if a user didn't finish onboarding

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

      # Find or create the Party playlist
      playlist_id = database_row.fetch(:playlist_id)
      if !playlist_id
        playlist = spotify_user.create_playlist!("#{user_id} - Jukebox for Sonos - Don't Delete")
        playlist_id = playlist.id
        self.prepare_welcome_playlist_song!(playlist)

        # Remember the Spotify playlist ID
        Db.spotify_tokens.where(user_id: user_id).update(playlist_id: playlist_id) # use full query syntax
      end
      return (@_playlist = RSpotify::Playlist.find(spotify_user.id, playlist_id))
    end

    # Add a welcome song to the playlist, so Sonos can handle the playlist
    # Sonos app doesn't handle empty playlists well
    def prepare_welcome_playlist_song!(playlist)
      return if playlist.tracks.count > 0

      hello_there_song = RSpotify::Track.search("Hello there dillon francis").first
      playlist.add_tracks!([hello_there_song])
    end

    def search_for_song(name)
      return RSpotify::Track.search(name)
    end

    # Search for a specific Spotify song using the Spotify ID, including a local cache
    def find_song(song_id)
      song_id.gsub!("spotify:track:", "")
      @_song_cache ||= {}
      return @_song_cache[song_id] if @_song_cache[song_id]
      @_song_cache[song_id] = RSpotify::Track.find(song_id)
    end

    # This method will add songs to the queue (playlist) on Spotify, but not yet add it to the Sonos queue
    def add_song_to_queue(song)
      # Verify we haven't queued this song before # TODO
      # return if previously_queued_songs.include?(song.id)
      queued_songs << song
    end

    # Actually send all songs wished for to the Sonos queue
    def add_next_song_to_sonos_queue!(sonos)
      # First, clear the Spotify playlist, in case there was anything left there
      party_playlist.remove_tracks!(party_playlist.tracks)

      next_song = queued_songs.shift
      if next_song.nil?
        puts "No more Jukebox songs in queue..."
        return false
      end
      self.past_songs << next_song
      party_playlist.add_tracks!([next_song])

      # Get the Sonos ID of the favorite playlist
      fav_id = sonos.ensure_playlist_in_favorites(party_playlist.id)

      # Queue the one song from that playlist into the Sonos Queue
      puts "Queueing #{next_song.name} by #{next_song.artists.first.name} to Sonos"
      play_fav = sonos.client_control_request(
        "/groups/#{sonos.group_to_use}/favorites", 
        method: :post, 
        body: {
          favoriteId: fav_id.fetch("id"),
          action: "INSERT_NEXT"
        }
      )
      party_playlist.remove_tracks!([next_song])
      return true
    end

    def self.permission_scope
      return %w(
        playlist-read-private
        playlist-modify-public
        user-library-modify
      ).join(' ')
    end

    def new_auth!(authorization_code:, redirect_uri:)
      auth_string = Base64.strict_encode64(ENV['SPOTIFY_CLIENT_ID'] + ':' + ENV['SPOTIFY_CLIENT_SECRET'])
      auth_response = Excon.post(
        'https://accounts.spotify.com/api/token',
          body: URI.encode_www_form({
            'grant_type' => 'authorization_code',
            'redirect_uri' => redirect_uri,
            'code' => authorization_code,
          }),
          headers: {
            'Authorization' => "Basic #{auth_string}",
            "Content-Type" => "application/x-www-form-urlencoded",
          }
      )
      parsed_credentials = JSON.parse(auth_response.body)

      # Manually re-name key, via https://github.com/guilhermesad/rspotify/issues/90#issuecomment-519603961
      parsed_credentials["token"] = parsed_credentials["access_token"]

      info_response = Excon.get('https://api.spotify.com/v1/me',
        headers: {
          'Authorization' => "Bearer #{parsed_credentials.fetch("access_token")}"
        }
      )
      info_parsed = JSON.parse(info_response.body)

      options = {
        'credentials' => parsed_credentials,
        'info' => info_parsed
      }
      user = RSpotify::User.new(options)
      Db.spotify_tokens.insert(
        user_id: user_id,
        options: JSON.pretty_generate(options.to_hash)
      )
    end
  end
end
