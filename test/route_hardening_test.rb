# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'minitest/mock'
require 'rack/mock'
require 'sinatra/base'

ENV['CUSTOM_HOST_URL'] ||= 'https://example.test'
ENV['SESSION_SECRET'] ||= 'test-session-secret'
ENV['SONOS_KEY'] ||= 'test-sonos-key'
ENV['SONOS_SECRET'] ||= 'test-sonos-secret'
ENV['SPOTIFY_CLIENT_ID'] ||= 'test-client-id'
ENV['SPOTIFY_CLIENT_SECRET'] ||= 'test-client-secret'

original_run = Sinatra::Base.method(:run!)
Sinatra::Base.singleton_class.define_method(:run!) { |*| nil }
require_relative '../server'
Sinatra::Base.singleton_class.define_method(:run!, original_run)

class RouteHardeningTest < Minitest::Test
  Playlist = Struct.new(:id)
  Album = Struct.new(:images)
  Artist = Struct.new(:name)

  # Just enough of a Sequel dataset for the routes under test
  class Table
    def initialize(rows = [], conditions = {})
      @rows = rows
      @conditions = conditions
    end

    def where(conditions)
      Table.new(@rows, @conditions.merge(conditions))
    end

    def to_a
      @rows.select { |row| @conditions.all? { |key, value| row[key] == value } }
    end

    def count
      to_a.count
    end

    def insert(attributes = {})
      id = @rows.map { |row| row[:id] }.max.to_i + 1
      @rows << attributes.merge(id: id)
      id
    end

    def delete
      matching = to_a
      @rows.reject! { |row| matching.include?(row) }
    end
  end

  def setup
    GlobalState[:sonos_instances].clear
    GlobalState[:spotify_instances].clear
    @users = Table.new([{ id: 7 }])
    @sonos_tokens = Table.new([{ id: 1, user_id: 7 }])
    @spotify_tokens = Table.new([{ id: 1, user_id: 7 }])
  end

  def test_cross_site_posts_are_rejected
    request = Rack::MockRequest.new(test_app.new)

    assert_equal 403, request.post('/party/host/update', 'HTTP_ORIGIN' => 'https://evil.example').status
    [nil, 'http://example.org', SonosPartyMode::Server::HOST_URL].each do |origin|
      env = origin ? { 'HTTP_ORIGIN' => origin } : {}
      refute_equal 403, request.post('/party/host/update', env).status, "Origin #{origin.inspect} must be allowed"
    end
  end

  def test_session_cookie_is_not_sent_along_with_cross_site_requests
    response = with_database { Rack::MockRequest.new(test_app.new).get('/') }

    assert_equal 200, response.status
    assert_match(/SameSite=Lax/i, response['Set-Cookie'])
  end

  def test_sonos_login_state_is_random_and_survives_reloading_the_login_page
    request = Rack::MockRequest.new(test_app.new)
    first_response = with_database { request.get('/') }
    session_cookie = first_response['Set-Cookie'][/rack\.session=[^;]+/]
    second_response = with_database { request.get('/', 'HTTP_COOKIE' => session_cookie) }

    state = sonos_login_state(first_response.body)
    assert_match(/\A\h{32}\z/, state)
    assert_equal state, sonos_login_state(second_response.body)
  end

  def test_sonos_login_without_matching_state_creates_no_account
    app_with_login_state = Class.new(test_app) do
      before { session[:sonos_state_key] = 'expected-state' }
    end
    reject_login = ->(*) { raise 'Sonos login must not be processed' }

    responses = with_database do
      SonosPartyMode::Sonos.stub(:new, reject_login) do
        [
          Rack::MockRequest.new(app_with_login_state.new).get('/sonos/authorized.html?code=code&state=forged-state'),
          Rack::MockRequest.new(test_app.new).get('/sonos/authorized.html?code=code&state=TESTSTATE')
        ]
      end
    end

    responses.each do |response|
      assert_equal 302, response.status
      assert_equal 'http://example.org/', response.location
    end
    assert_equal [{ id: 7 }], @users.to_a
  end

  def test_logout_requires_post_and_stops_the_party_immediately
    GlobalState[:sonos_instances][7] = Object.new
    GlobalState[:spotify_instances][7] = Object.new
    request = Rack::MockRequest.new(authenticated_app.new)

    assert_equal 404, with_database { request.get('/logout') }.status
    assert GlobalState[:spotify_instances].key?(7)

    response = with_database { request.post('/logout') }

    assert response.redirect?
    assert_equal 'http://example.org/?logged_out=true', response.location
    assert_empty @users.to_a
    assert_empty @sonos_tokens.to_a
    assert_empty @spotify_tokens.to_a
    refute GlobalState[:sonos_instances].key?(7)
    refute GlobalState[:spotify_instances].key?(7)
  end

  def test_qr_code_requires_a_logged_in_host
    assert_equal 401, Rack::MockRequest.new(test_app.new).get('/qr_code.png').status
  end

  def test_guest_page_is_unavailable_instead_of_crashing_without_a_sonos_session
    GlobalState[:spotify_instances][7] = guest_spotify(past_songs: [Object.new])

    response = Rack::MockRequest.new(test_app.new).get('/p/7/party-playlist-id')

    assert_equal 503, response.status
  end

  def test_search_does_not_fetch_audio_features_and_handles_missing_album_images
    track = Object.new
    track.define_singleton_method(:id) { 'track-id' }
    track.define_singleton_method(:name) { 'Song' }
    track.define_singleton_method(:artists) { [Artist.new('Artist')] }
    track.define_singleton_method(:album) { Album.new([]) }
    track.define_singleton_method(:audio_features) { raise 'Audio features must not be fetched' }
    spotify = guest_spotify
    spotify.define_singleton_method(:search_for_song) { |_name| [track] }
    GlobalState[:spotify_instances][7] = spotify

    response = Rack::MockRequest.new(test_app.new).get('/spotify/search/7/party-playlist-id?song_name=song')

    assert_equal 200, response.status
    assert_equal [{ 'id' => 'track-id', 'name' => 'Song', 'artists' => ['Artist'], 'thumbnail' => nil }],
                 JSON.parse(response.body)
  end

  def test_search_without_song_name_returns_no_results
    GlobalState[:spotify_instances][7] = guest_spotify

    response = Rack::MockRequest.new(test_app.new).get('/spotify/search/7/party-playlist-id')

    assert_equal 200, response.status
    assert_equal({}, JSON.parse(response.body))
  end

  def test_dashboard_handles_a_selected_group_that_no_longer_exists
    sonos = Object.new
    sonos.define_singleton_method(:groups_cached) { [{ 'id' => 'other-group', 'name' => 'Kitchen', 'playerIds' => [] }] }
    sonos.define_singleton_method(:group_to_use) { 'removed-group' }
    sonos.define_singleton_method(:playback_metadata) { {} }
    GlobalState[:spotify_instances][7] = guest_spotify
    GlobalState[:sonos_instances][7] = sonos

    response = Rack::MockRequest.new(authenticated_app.new).get('/party.json')

    assert_equal 200, response.status
    assert_equal({ 'nothing_playing' => true, 'group_to_use' => 'Unknown group' }, JSON.parse(response.body))
  end

  def test_whitelisted_icon_assets_exist
    %w[favicon-16x16.png favicon-32x32.png android-chrome-192x192.png android-chrome-512x512.png].each do |file|
      response = Rack::MockRequest.new(test_app.new).get("/assets/#{file}")

      assert_equal 'image/png', response.content_type, file
      refute_empty response.body, file
    end
  end

  private

  def guest_spotify(past_songs: [])
    Object.new.tap do |spotify|
      spotify.define_singleton_method(:party_playlist) { Playlist.new('party-playlist-id') }
      spotify.define_singleton_method(:queued_songs) { [] }
      spotify.define_singleton_method(:past_songs) { past_songs }
    end
  end

  def sonos_login_state(html)
    html[/api\.sonos\.com[^"]*state=(\h+)/, 1]
  end

  def with_database(&block)
    SonosPartyMode::Db.stub(:users, @users) do
      SonosPartyMode::Db.stub(:sonos_tokens, @sonos_tokens) do
        SonosPartyMode::Db.stub(:spotify_tokens, @spotify_tokens, &block)
      end
    end
  end

  def test_app
    Class.new(SonosPartyMode::Server) do
      define_method(:initialize) do |app = nil|
        Sinatra::Base.instance_method(:initialize).bind(self).call(app)
      end
    end
  end

  def authenticated_app
    Class.new(test_app) do
      before { session[:user_id] = 7 }
    end
  end
end
