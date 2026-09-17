# frozen_string_literal: true

require 'base64'
require 'minitest/autorun'
require 'minitest/mock'
require_relative '../sonos'

class SonosBootTest < Minitest::Test
  Response = Struct.new(:status, :body)
  Playlist = Struct.new(:id, :name)
  PARTY_PLAYLIST = Playlist.new('target-playlist', "1896 auxcord.org - Don't Delete")

  class MemoryDataset
    attr_reader :rows

    def initialize(rows)
      @rows = rows
    end

    def where(_conditions)
      self
    end

    def first
      rows.first
    end

    def update(attributes)
      rows.each { |row| row.merge!(attributes) }
    end
  end

  # Mimics the Excon connection: every request is answered by the given block
  class ControlConnection
    attr_reader :requests

    def initialize(&responder)
      @responder = responder
      @requests = []
    end

    def data
      { path: '/control/api/v1/' }
    end

    def request(options)
      requests << options
      @responder.call(options)
    end
  end

  INVALID_TOKEN = Response.new(401, '{"error": "access_denied", "error_description": "Invalid Token"}')

  def setup
    @original_sonos_key = ENV.fetch('SONOS_KEY', nil)
    @original_sonos_secret = ENV.fetch('SONOS_SECRET', nil)
    ENV['SONOS_KEY'] = 'test-sonos-key'
    ENV['SONOS_SECRET'] = 'test-sonos-secret'
    @dataset = MemoryDataset.new([{ user_id: 7, access_token: 'expired-token', refresh_token: 'stored-refresh-token' }])
  end

  def teardown
    ENV['SONOS_KEY'] = @original_sonos_key
    ENV['SONOS_SECRET'] = @original_sonos_secret
  end

  def test_unauthorized_response_refreshes_token_and_retries
    connection = ControlConnection.new do |options|
      if options.fetch(:headers).fetch('Authorization') == 'Bearer fresh-token'
        Response.new(200, '{"households": [{"id": "household-id"}]}')
      else
        INVALID_TOKEN
      end
    end
    refresh_response = Response.new(200, '{"access_token": "fresh-token"}')

    households = with_sonos_api(connection, refresh_response, &:households)

    assert_equal [{ 'id' => 'household-id' }], households
    assert_equal 2, connection.requests.count
    assert_equal 'fresh-token', @dataset.first.fetch(:access_token)
  end

  def test_token_rejected_after_refresh_requires_reauthorization_instead_of_missing_household
    connection = ControlConnection.new { INVALID_TOKEN }
    refresh_response = Response.new(200, '{"access_token": "fresh-token"}')

    assert_raises(SonosPartyMode::Sonos::ReauthorizationRequired) do
      with_sonos_api(connection, refresh_response, &:primary_household)
    end
    assert_equal 2, connection.requests.count
  end

  def test_revoked_refresh_token_requires_reauthorization
    connection = ControlConnection.new { INVALID_TOKEN }
    refresh_response = Response.new(400, '{"error": "invalid_request"}')

    assert_raises(SonosPartyMode::Sonos::ReauthorizationRequired) do
      with_sonos_api(connection, refresh_response, &:groups)
    end
    assert_equal 1, connection.requests.count
  end
  def test_lazy_initialization_does_not_call_sonos_api
    sonos_class = Class.new(SonosPartyMode::Sonos) do
      attr_reader :groups_called

      def database_row
        {
          volume: 20,
          group: 'group-id',
          party_active: true
        }
      end

      def groups
        @groups_called = true
        raise 'Sonos API must not be called during boot'
      end
    end

    sonos = sonos_class.new(user_id: 1, eager_load: false)

    assert_nil sonos.groups_called
    assert_equal 20, sonos.target_volume
    refute sonos.party_session_active
  end

  def test_missing_households_are_treated_as_no_connected_household
    sonos = SonosPartyMode::Sonos.allocate
    sonos.define_singleton_method(:client_control_request) { |_path| {} }

    assert_empty sonos.households
    assert_nil sonos.primary_household
  end

  def test_playlist_lookup_skips_malformed_favorites
    matching_favorite = {
      'service' => { 'name' => 'Spotify' },
      'resource' => {
        'type' => 'PLAYLIST',
        'id' => { 'objectId' => 'spotify:playlist:target-playlist' }
      }
    }
    favorites = {
      'items' => [
        { 'service' => nil, 'resource' => nil },
        {
          'service' => { 'name' => 'Spotify' },
          'resource' => { 'type' => 'PLAYLIST', 'id' => nil }
        },
        matching_favorite
      ]
    }
    sonos = SonosPartyMode::Sonos.allocate
    sonos.define_singleton_method(:primary_household) { 'household-id' }
    sonos.define_singleton_method(:client_control_request) { |_path| favorites }

    assert_same matching_favorite, sonos.ensure_playlist_in_favorites(PARTY_PLAYLIST)
  end

  # The documented favorite object has no `resource`, so there's no Spotify ID to match on
  def test_playlist_lookup_matches_documented_favorites_by_playlist_name
    matching_favorite = { 'id' => '7', 'name' => "1896 auxcord.org - Don't Delete",
                          'description' => 'Spotify Playlist', 'service' => { 'name' => 'Spotify', 'id' => '9' } }
    favorites = {
      'version' => '1',
      'items' => [
        { 'id' => '5', 'name' => 'Heart', 'service' => { 'name' => 'Sonos Radio', 'id' => '303' } },
        { 'id' => '6', 'name' => "1881 auxcord.org - Don't Delete", 'service' => { 'name' => 'Spotify', 'id' => '9' } },
        matching_favorite
      ]
    }

    assert_same matching_favorite, sonos_with_favorites(favorites).ensure_playlist_in_favorites(PARTY_PLAYLIST)
  end

  def test_playlist_lookup_prefers_spotify_id_over_name_when_sonos_provides_it
    renamed_favorite = {
      'name' => 'Renamed in Spotify',
      'resource' => { 'type' => 'PLAYLIST', 'id' => { 'objectId' => 'spotify:playlist:target-playlist' } }
    }
    other_playlist_with_same_name = {
      'name' => "1896 auxcord.org - Don't Delete",
      'resource' => { 'type' => 'PLAYLIST', 'id' => { 'objectId' => 'spotify:playlist:other-playlist' } }
    }
    favorites = { 'items' => [other_playlist_with_same_name, renamed_favorite] }

    assert_same renamed_favorite, sonos_with_favorites(favorites).ensure_playlist_in_favorites(PARTY_PLAYLIST)
  end

  def test_missing_playlist_logs_favorite_fields_without_favorite_names
    favorites = { 'items' => [{ 'id' => '5', 'name' => 'Private station name', 'service' => { 'name' => 'Sonos Radio' } }] }
    sonos = sonos_with_favorites(favorites)

    output, = capture_io { assert_nil sonos.ensure_playlist_in_favorites(PARTY_PLAYLIST, force_refresh: true) }

    assert_includes output, 'Playlist not found in 1 Sonos favorites'
    assert_includes output, 'id+name+service'
    assert_includes output, 'Sonos Radio'
    refute_includes output, 'Private station name'
  end

  def test_found_favorites_are_cached_for_dashboard_polling
    favorites = { 'items' => [{ 'id' => '7', 'name' => "1896 auxcord.org - Don't Delete" }] }
    requests = 0
    sonos = SonosPartyMode::Sonos.allocate
    sonos.define_singleton_method(:primary_household) { 'household-id' }
    sonos.define_singleton_method(:client_control_request) do |_path|
      requests += 1
      favorites
    end

    2.times { refute_nil sonos.ensure_playlist_in_favorites(PARTY_PLAYLIST, force_refresh: false) }

    assert_equal 1, requests
  end

  private

  def sonos_with_favorites(favorites)
    sonos = SonosPartyMode::Sonos.allocate
    sonos.define_singleton_method(:primary_household) { 'household-id' }
    sonos.define_singleton_method(:client_control_request) { |_path| favorites }
    sonos
  end

  def with_sonos_api(connection, refresh_response)
    login = Object.new
    login.define_singleton_method(:post) { |*| refresh_response }
    sonos = SonosPartyMode::Sonos.allocate
    sonos.user_id = 7
    sonos.define_singleton_method(:client_control) { connection }
    sonos.define_singleton_method(:client_login) { login }

    SonosPartyMode::Db.stub(:sonos_tokens, @dataset) do
      yield sonos
    end
  end
end
