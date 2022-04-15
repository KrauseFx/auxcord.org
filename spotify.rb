require "excon"
require "rspotify"
require "json"
require "pry"
require_relative "./db"

module SonosPartyMode
  class Spotify
    attr_accessor :user_id

    # To prevent the same song from being queued again
    # attr_accessor :previously_queued_songs

    def initialize(user_id:)
      self.user_id = user_id
      # self.previously_queued_songs = []
    end

    def new_auth!(authorization_code:)
      auth_string = Base64.strict_encode64(ENV['SPOTIFY_CLIENT_ID'] + ':' + ENV['SPOTIFY_CLIENT_SECRET'])
      auth_response = Excon.post(
        'https://accounts.spotify.com/api/token',
          body: URI.encode_www_form({
            'grant_type' => 'authorization_code',
            'redirect_uri' => SPOTIFY_REDIRECT_URI,
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

    def spotify_user
      return nil if spotify_user_row.nil?
      RSpotify::User.new(JSON.parse(spotify_user_row.fetch(:options)))
    end

    def spotify_user_row
      query = Db.spotify_tokens.where(user_id: user_id)
      return nil if query.empty?
      return query.first
    end

    def party_playlist
      return @_playlist if @_playlist

      # Find or create the Party playlist
      playlist_id = spotify_user_row.fetch(:playlist_id)
      if !playlist_id
        playlist_id = spotify_user.create_playlist!("SonosPartyMode - Don't Delete").id
        Db.spotify_tokens.where(user_id: user_id).update(playlist_id: playlist_id) # use full query syntax
      end
      return (@_playlist = RSpotify::Playlist.find(spotify_user.id, playlist_id))
    end

    def search_for_song(name)
      # TODO: also search for album and artist
      return RSpotify::Track.search(name)
    end

    def add_song_to_party_playlist(song)
      # Verify we haven't queued this song before
      # return if previously_queued_songs.include?(song.id)

      party_playlist.add_tracks!([song])
      yield
      party_playlist.remove_tracks!([song])
    end

    def permission_scope
      return %w(
        playlist-read-private
        user-read-private
        user-read-email
        playlist-modify-public
        user-library-read
        user-library-modify
      ).join(' ')
    end
  end
end
