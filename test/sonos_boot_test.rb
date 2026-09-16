# frozen_string_literal: true

require 'base64'
require 'minitest/autorun'
require 'minitest/mock'
require_relative '../sonos'

class SonosBootTest < Minitest::Test
  Response = Struct.new(:status, :body)

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

    assert_same matching_favorite, sonos.ensure_playlist_in_favorites('target-playlist')
  end

  private

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
