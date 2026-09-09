# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'rack/mock'
require 'sinatra/base'
require_relative '../spotify'

class SpotifyAuthTest < Minitest::Test
  class MemoryDataset
    attr_reader :rows

    def initialize(rows)
      @rows = rows
    end

    def where(_conditions)
      self
    end

    def empty?
      rows.empty?
    end

    def first
      rows.first
    end

    def all
      rows
    end

    def update(attributes)
      rows.each { |row| row.merge!(attributes) }
      rows.length
    end

    def insert(attributes)
      rows << attributes
      attributes
    end
  end

  Response = Struct.new(:status, :body)
  Playlist = Struct.new(:id)

  class PlaylistMutationDouble
    attr_reader :add_calls, :remove_calls

    def initialize(fail_on:, always_fail: false)
      @fail_on = fail_on
      @always_fail = always_fail
      @add_calls = 0
      @remove_calls = 0
    end

    def id
      'party-playlist-id'
    end

    def tracks
      []
    end

    def add_tracks!(_tracks)
      @add_calls += 1
      fail_if_needed!(:add, @add_calls)
    end

    def remove_tracks!(_tracks)
      @remove_calls += 1
      fail_if_needed!(:remove, @remove_calls)
    end

    private

    def fail_if_needed!(operation, calls)
      return unless operation == @fail_on
      return unless @always_fail || calls == 1

      raise RestClient::Unauthorized
    end
  end

  Artist = Struct.new(:name)
  Song = Struct.new(:name, :artists)

  class SonosDouble
    attr_reader :control_requests

    def initialize
      @control_requests = []
    end

    def ensure_playlist_in_favorites(_playlist_id)
      { 'id' => 'favorite-id' }
    end

    def group_to_use
      'group-id'
    end

    def client_control_request(path, options)
      control_requests << [path, options]
    end
  end

  def setup
    @original_spotify_client_id = ENV.fetch('SPOTIFY_CLIENT_ID', nil)
    @original_spotify_client_secret = ENV.fetch('SPOTIFY_CLIENT_SECRET', nil)
    @original_custom_host_url = ENV.fetch('CUSTOM_HOST_URL', nil)
    @original_session_secret = ENV.fetch('SESSION_SECRET', nil)
    ENV['SPOTIFY_CLIENT_ID'] = 'test-client-id'
    ENV['SPOTIFY_CLIENT_SECRET'] = 'test-client-secret'
    ENV['CUSTOM_HOST_URL'] = 'https://example.test'
    ENV['SESSION_SECRET'] = 'test-session-secret'
    if defined?(GlobalState)
      GlobalState[:spotify_instances].clear
      GlobalState[:sonos_instances].clear
    end

    @stored_options = {
      'credentials' => {
        'token' => 'expired-access-token',
        'access_token' => 'expired-access-token',
        'refresh_token' => 'stored-refresh-token',
        'expires_at' => 0
      },
      'info' => { 'id' => 'spotify-user-id' }
    }
    @dataset = MemoryDataset.new(
      [
        {
          id: 1,
          user_id: 7,
          options: JSON.generate(@stored_options),
          playlist_id: 'party-playlist-id'
        }
      ]
    )
  end

  def test_unauthorized_playlist_lookup_refreshes_persists_and_retries_once
    lookup_count = 0
    playlist = Playlist.new('party-playlist-id')
    playlist_lookup = lambda do |_owner_id, _playlist_id|
      lookup_count += 1
      raise RestClient::Unauthorized if lookup_count == 1

      playlist
    end
    refresh_response = Response.new(200, JSON.generate(
                                           access_token: 'fresh-access-token',
                                           refresh_token: 'rotated-refresh-token',
                                           expires_in: 3600
                                         ))

    result = with_spotify_stubs(playlist_lookup: playlist_lookup, token_response: refresh_response) do
      SonosPartyMode::Spotify.new(user_id: 7).party_playlist
    end

    assert_same playlist, result
    assert_equal 2, lookup_count

    credentials = JSON.parse(@dataset.first.fetch(:options)).fetch('credentials')
    assert_equal 'fresh-access-token', credentials.fetch('token')
    assert_equal 'fresh-access-token', credentials.fetch('access_token')
    assert_equal 'rotated-refresh-token', credentials.fetch('refresh_token')
    assert_equal 3600, credentials.fetch('expires_in')
    assert_equal true, credentials.fetch('expires')
    assert_operator credentials.fetch('expires_at'), :>, Time.now.to_i
    registered_credentials = RSpotify::User.class_variable_get(:@@users_credentials).fetch('spotify-user-id')
    assert_equal 'fresh-access-token', registered_credentials.fetch('token')
  end

  def test_failed_refresh_requires_reauthorization_without_retrying
    lookup_count = 0
    playlist_lookup = lambda do |_owner_id, _playlist_id|
      lookup_count += 1
      raise RestClient::Unauthorized
    end
    refresh_response = Response.new(400, JSON.generate(error: 'invalid_grant'))

    error = assert_raises(SonosPartyMode::Spotify::ReauthorizationRequired) do
      with_spotify_stubs(playlist_lookup: playlist_lookup, token_response: refresh_response) do
        SonosPartyMode::Spotify.new(user_id: 7).party_playlist
      end
    end

    assert_equal 1, lookup_count
    assert_match(/Spotify authorization/i, error.message)
  end

  def test_invalid_client_refresh_failure_remains_an_operational_error
    playlist_lookup = ->(*) { raise RestClient::Unauthorized }
    refresh_response = Response.new(400, JSON.generate(error: 'invalid_client'))

    assert_raises(SonosPartyMode::Spotify::TokenRefreshFailed) do
      with_spotify_stubs(playlist_lookup: playlist_lookup, token_response: refresh_response) do
        SonosPartyMode::Spotify.new(user_id: 7).party_playlist
      end
    end
  end

  def test_spotify_server_failure_remains_an_operational_error
    playlist_lookup = ->(*) { raise RestClient::Unauthorized }
    refresh_response = Response.new(500, JSON.generate(error: 'invalid_grant'))

    assert_raises(SonosPartyMode::Spotify::TokenRefreshFailed) do
      with_spotify_stubs(playlist_lookup: playlist_lookup, token_response: refresh_response) do
        SonosPartyMode::Spotify.new(user_id: 7).party_playlist
      end
    end
  end

  def test_second_unauthorized_response_requires_reauthorization_without_looping
    lookup_count = 0
    playlist_lookup = lambda do |_owner_id, _playlist_id|
      lookup_count += 1
      raise RestClient::Unauthorized
    end
    refresh_response = Response.new(200, JSON.generate(
                                           access_token: 'fresh-access-token',
                                           expires_in: 3600
                                         ))

    assert_raises(SonosPartyMode::Spotify::ReauthorizationRequired) do
      with_spotify_stubs(playlist_lookup: playlist_lookup, token_response: refresh_response) do
        SonosPartyMode::Spotify.new(user_id: 7).party_playlist
      end
    end

    assert_equal 2, lookup_count
    credentials = JSON.parse(@dataset.first.fetch(:options)).fetch('credentials')
    assert_equal 'stored-refresh-token', credentials.fetch('refresh_token')
  end

  def test_cached_playlist_remove_refreshes_and_retries_once
    playlist = PlaylistMutationDouble.new(fail_on: :remove)

    result = exercise_queue_mutation(playlist)

    assert_equal true, result
    assert_equal 3, playlist.remove_calls
    assert_equal 1, playlist.add_calls
    assert_equal 'fresh-access-token', stored_credentials.fetch('token')
  end

  def test_cached_playlist_add_refreshes_and_retries_once
    playlist = PlaylistMutationDouble.new(fail_on: :add)

    result = exercise_queue_mutation(playlist)

    assert_equal true, result
    assert_equal 2, playlist.add_calls
    assert_equal 2, playlist.remove_calls
    assert_equal 'fresh-access-token', stored_credentials.fetch('token')
  end

  def test_second_unauthorized_playlist_mutation_requires_reauthorization
    playlist = PlaylistMutationDouble.new(fail_on: :remove, always_fail: true)

    assert_raises(SonosPartyMode::Spotify::ReauthorizationRequired) do
      exercise_queue_mutation(playlist)
    end

    assert_equal 2, playlist.remove_calls
  end

  def test_mutation_retry_reuses_cached_playlist_without_recursive_locking
    playlist = PlaylistMutationDouble.new(fail_on: :remove)
    playlist_lookup = ->(*) { raise RestClient::Unauthorized }

    result = exercise_queue_mutation(playlist, playlist_lookup: playlist_lookup)

    assert_equal true, result
    assert_equal 3, playlist.remove_calls
  end

  def test_new_authorization_updates_existing_row_and_preserves_playlist
    authorize_spotify(profile_id: 'spotify-user-id')

    assert_equal 1, @dataset.rows.length
    assert_equal 'party-playlist-id', @dataset.first.fetch(:playlist_id)
    credentials = JSON.parse(@dataset.first.fetch(:options)).fetch('credentials')
    assert_equal 'fresh-access-token', credentials.fetch('token')
    assert_equal 'fresh-refresh-token', credentials.fetch('refresh_token')
  end

  def test_new_authorization_for_a_different_spotify_account_clears_playlist
    authorize_spotify(profile_id: 'different-spotify-user-id')

    assert_nil @dataset.first.fetch(:playlist_id)
  end

  def test_new_authorization_inserts_a_new_token_row
    @dataset = MemoryDataset.new([])
    authorize_spotify(profile_id: 'spotify-user-id')

    assert_equal 1, @dataset.rows.length
    assert_equal 7, @dataset.first.fetch(:user_id)
    assert_equal 'spotify-user-id', JSON.parse(@dataset.first.fetch(:options)).dig('info', 'id')
  end

  def test_new_authorization_reconciles_existing_duplicate_rows
    @dataset.rows << {
      id: 2,
      user_id: 7,
      options: JSON.generate(@stored_options),
      playlist_id: nil
    }
    authorize_spotify(profile_id: 'spotify-user-id')

    assert_equal ['party-playlist-id'], @dataset.rows.map { |row| row[:playlist_id] }.uniq
    assert_equal 1, @dataset.rows.map { |row| row[:options] }.uniq.length
  end

  def test_malformed_legacy_credentials_require_reauthorization
    @dataset.first[:options] = nil

    assert_raises(SonosPartyMode::Spotify::ReauthorizationRequired) do
      SonosPartyMode::Db.stub(:spotify_tokens, @dataset) do
        SonosPartyMode::Spotify.new(user_id: 7).party_playlist
      end
    end
  end

  def test_sonos_authorization_does_not_log_oauth_credentials
    sonos_source = File.read(File.expand_path('../sonos.rb', __dir__))

    refute_includes sonos_source, 'sonos api response:'
  end

  def test_spotify_reauthorization_redirects_to_oauth_flow
    load_server_without_running
    GlobalState[:spotify_instances][7] = :stale
    response = Rack::MockRequest.new(spotify_reauthorization_test_app.new).get('/party')

    assert_equal 302, response.status
    assert_equal 'http://example.org/auth/spotify', response.location
    refute GlobalState[:spotify_instances].key?(7)
  end

  def test_party_json_signals_reauthorization_without_redirecting_to_spotify
    load_server_without_running
    GlobalState[:spotify_instances][7] = :stale
    response = Rack::MockRequest.new(spotify_reauthorization_test_app.new).get('/party.json')

    assert_equal 401, response.status
    assert_nil response.location
    assert_equal({ 'reauthorization_required' => true }, JSON.parse(response.body))
    refute GlobalState[:spotify_instances].key?(7)
  end

  def test_party_json_signals_reauthorization_after_callback_invalidates_spotify
    load_server_without_running
    GlobalState[:sonos_instances][7] = Object.new
    response = Rack::MockRequest.new(authenticated_route_test_app.new).get('/party.json')

    assert_equal 401, response.status
    assert_nil response.location
    assert_equal({ 'reauthorization_required' => true }, JSON.parse(response.body))
  end

  def test_party_polling_redirects_the_host_when_reauthorization_is_required
    party_javascript = File.read(File.expand_path('../views/js/_party.js.erb', __dir__))

    assert_includes party_javascript, 'xhr.status === 401'
    assert_includes party_javascript, 'window.location.href = "/auth/spotify";'
  end

  def test_guest_party_page_does_not_redirect_into_owner_oauth
    load_server_without_running
    GlobalState[:spotify_instances][7] = reauthorization_required_spotify
    response = Rack::MockRequest.new(route_test_app.new).get('/p/7/party-playlist-id')

    assert_equal 503, response.status
    assert_nil response.location
  end

  def test_guest_search_does_not_redirect_into_owner_oauth
    load_server_without_running
    GlobalState[:spotify_instances][7] = reauthorization_required_spotify
    response = Rack::MockRequest.new(route_test_app.new)
                                .get('/spotify/search/7/party-playlist-id?song_name=test')

    assert_equal 503, response.status
    assert_nil response.location
    assert_equal 'spotify_reauthorization_required', JSON.parse(response.body).fetch('error')
  end

  def test_guest_song_submission_does_not_redirect_into_owner_oauth
    load_server_without_running
    GlobalState[:spotify_instances][7] = reauthorization_required_spotify
    response = Rack::MockRequest.new(route_test_app.new).post('/p/7/party-playlist-id/song-id')

    assert_equal 503, response.status
    assert_nil response.location
    assert_equal 'spotify_reauthorization_required', JSON.parse(response.body).fetch('error')
  end

  def test_guest_routes_are_unavailable_after_owner_spotify_instance_is_invalidated
    load_server_without_running
    request = Rack::MockRequest.new(route_test_app.new)

    party_response = request.get('/p/7/party-playlist-id')
    search_response = request.get('/spotify/search/7/party-playlist-id?song_name=test')
    submission_response = request.post('/p/7/party-playlist-id/song-id')

    assert_equal [503, 503, 503], [party_response.status, search_response.status, submission_response.status]
    assert_nil party_response.location
    assert_nil search_response.location
    assert_nil submission_response.location
  end

  def test_guest_cannot_start_spotify_oauth_without_a_sonos_session
    load_server_without_running
    response = Rack::MockRequest.new(route_test_app.new).get('/auth/spotify')

    assert_equal 302, response.status
    assert_equal 'http://example.org/', response.location
  end

  def test_sonos_callback_acknowledges_revoked_spotify_authorization
    load_server_without_running
    spotify = Object.new
    spotify.define_singleton_method(:user_id) { 7 }
    spotify.define_singleton_method(:add_next_song_to_sonos_queue!) do |_sonos|
      raise SonosPartyMode::Spotify::ReauthorizationRequired
    end
    sonos = Struct.new(:group_to_use, :user_id, :current_item_id).new('group-id', 7, 'previous-item')
    GlobalState[:spotify_instances][7] = spotify
    GlobalState[:sonos_instances][7] = sonos

    response = Rack::MockRequest.new(route_test_app.new).post(
      '/callback',
      'HTTP_X_SONOS_TARGET_VALUE' => 'group-id',
      input: JSON.generate(itemId: 'new-item', previousItemId: 'previous-item')
    )

    assert_equal 200, response.status
    refute GlobalState[:spotify_instances].key?(7)
  end

  def teardown
    ENV['SPOTIFY_CLIENT_ID'] = @original_spotify_client_id
    ENV['SPOTIFY_CLIENT_SECRET'] = @original_spotify_client_secret
    ENV['CUSTOM_HOST_URL'] = @original_custom_host_url
    ENV['SESSION_SECRET'] = @original_session_secret
  end

  private

  def with_spotify_stubs(playlist_lookup:, token_response:, &block)
    SonosPartyMode::Db.stub(:spotify_tokens, @dataset) do
      RSpotify::Playlist.stub(:find, playlist_lookup) do
        with_singleton_method(Excon, :post, ->(*) { token_response }) do
          block.call
        end
      end
    end
  end

  def exercise_queue_mutation(playlist, playlist_lookup: ->(*) { playlist })
    token_response = Response.new(200, JSON.generate(
                                         access_token: 'fresh-access-token',
                                         expires_in: 3600
                                       ))
    with_spotify_stubs(playlist_lookup: playlist_lookup, token_response: token_response) do
      spotify = SonosPartyMode::Spotify.new(user_id: 7)
      spotify.instance_variable_set(:@_playlist, playlist)
      spotify.queued_songs << Song.new('Test song', [Artist.new('Test artist')])
      spotify.add_next_song_to_sonos_queue!(SonosDouble.new)
    end
  end

  def stored_credentials
    JSON.parse(@dataset.first.fetch(:options)).fetch('credentials')
  end

  def authorize_spotify(profile_id:)
    token_response = Response.new(200, JSON.generate(
                                         access_token: 'fresh-access-token',
                                         refresh_token: 'fresh-refresh-token',
                                         expires_in: 3600
                                       ))
    profile_response = Response.new(200, JSON.generate(id: profile_id))
    SonosPartyMode::Db.stub(:spotify_tokens, @dataset) do
      with_singleton_method(Excon, :post, ->(*) { token_response }) do
        with_singleton_method(Excon, :get, ->(*) { profile_response }) do
          SonosPartyMode::Spotify.new(
            user_id: 7,
            authorization_code: 'authorization-code',
            redirect_uri: 'https://example.test/auth/spotify/callback'
          )
        end
      end
    end
  end

  def with_singleton_method(object, method_name, replacement, &block)
    singleton_class = object.singleton_class
    original_method = object.method(method_name)
    singleton_class.define_method(method_name, replacement)
    block.call
  ensure
    singleton_class.define_method(method_name, original_method)
  end

  def load_server_without_running
    return if defined?(SonosPartyMode::Server)

    original_run = Sinatra::Base.method(:run!)
    Sinatra::Base.singleton_class.define_method(:run!) { |*| nil }
    require_relative '../server'
  ensure
    Sinatra::Base.singleton_class.define_method(:run!, original_run) if original_run
  end

  def spotify_reauthorization_test_app
    Class.new(SonosPartyMode::Server) do
      define_method(:initialize) do |app = nil|
        Sinatra::Base.instance_method(:initialize).bind(self).call(app)
      end
      define_method(:all_sessions?) { true }
      define_method(:party_data) do
        session[:user_id] = 7
        raise SonosPartyMode::Spotify::ReauthorizationRequired
      end
    end
  end

  def route_test_app
    Class.new(SonosPartyMode::Server) do
      define_method(:initialize) do |app = nil|
        Sinatra::Base.instance_method(:initialize).bind(self).call(app)
      end
    end
  end

  def authenticated_route_test_app
    Class.new(route_test_app) do
      before { session[:user_id] = 7 }
    end
  end

  def reauthorization_required_spotify
    Object.new.tap do |spotify|
      spotify.define_singleton_method(:party_playlist) do
        raise SonosPartyMode::Spotify::ReauthorizationRequired
      end
    end
  end
end
