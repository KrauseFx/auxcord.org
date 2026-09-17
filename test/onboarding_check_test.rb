# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'rack/mock'
require 'sinatra/base'

ENV['CUSTOM_HOST_URL'] ||= 'https://example.test'
ENV['SESSION_SECRET'] ||= 'test-session-secret'

original_run = Sinatra::Base.method(:run!)
Sinatra::Base.singleton_class.define_method(:run!) { |*| nil }
require_relative '../server'
Sinatra::Base.singleton_class.define_method(:run!, original_run)

class OnboardingCheckTest < Minitest::Test
  Playlist = Struct.new(:id, :name)

  def setup
    playlist = Playlist.new('party-playlist-id', "7 auxcord.org - Don't Delete")
    spotify = Object.new
    spotify.define_singleton_method(:party_playlist) { playlist }
    spotify.define_singleton_method(:prepare_welcome_playlist_song!) { |_playlist| nil }

    @sonos = Object.new
    @sonos.define_singleton_method(:groups_cached) { [{ 'id' => 'group-id', 'name' => 'Living Room', 'playerIds' => ['player'] }] }
    @sonos.define_singleton_method(:group_to_use) { 'group-id' }
    @sonos.define_singleton_method(:playback_metadata) { {} } # nothing playing

    GlobalState[:spotify_instances][7] = spotify
    GlobalState[:sonos_instances][7] = @sonos
  end

  def teardown
    GlobalState[:spotify_instances].clear
    GlobalState[:sonos_instances].clear
  end

  def test_dashboard_requires_the_favorite_even_when_nothing_is_playing
    @sonos.define_singleton_method(:ensure_playlist_in_favorites) { |_playlist, force_refresh:| nil }

    response = Rack::MockRequest.new(test_app.new).get('/party.json')

    assert_equal 200, response.status
    assert_equal({}, JSON.parse(response.body))
  end

  def test_dashboard_shows_nothing_playing_once_the_favorite_exists
    @sonos.define_singleton_method(:ensure_playlist_in_favorites) { |_playlist, force_refresh:| { 'id' => 'favorite-id' } }

    response = Rack::MockRequest.new(test_app.new).get('/party.json')

    assert_equal({ 'nothing_playing' => true, 'group_to_use' => 'Living Room' }, JSON.parse(response.body))
  end

  private

  def test_app
    Class.new(SonosPartyMode::Server) do
      define_method(:initialize) do |app = nil|
        Sinatra::Base.instance_method(:initialize).bind(self).call(app)
      end
      define_method(:all_sessions?) { true }
      before { session[:user_id] = 7 }
    end
  end
end
