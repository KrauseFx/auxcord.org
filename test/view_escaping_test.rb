# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
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

class ViewEscapingTest < Minitest::Test
  # Track, artist, playlist and group names come from Spotify and Sonos, so treat them as untrusted
  SCRIPT_BREAKOUT = '</script><script>alert(1)</script>'
  IMAGE_INJECTION = '<img src=x onerror=alert(1)>'

  Playlist = Struct.new(:id)

  def setup
    GlobalState[:sonos_instances].clear
    GlobalState[:spotify_instances].clear
  end

  def test_host_dashboard_embeds_party_data_once_without_breaking_out_of_the_script_block
    party_data_calls = 0
    data = dashboard_data
    app = authenticated_app do
      define_method(:party_data) do
        party_data_calls += 1
        data
      end
    end

    response = Rack::MockRequest.new(app.new).get('/party')

    assert_equal 200, response.status
    assert_equal 1, party_data_calls
    refute_includes response.body, SCRIPT_BREAKOUT
    embedded_json = response.body[/refreshUI\((\{.*\})\)$/, 1]
    refute_nil embedded_json
    refute_match(/[<>]/, embedded_json)
    assert_equal SCRIPT_BREAKOUT, JSON.parse(embedded_json).dig('current_song_details', 'name')
  end

  def test_guest_queue_page_escapes_queued_song_metadata
    playlist = Playlist.new('party-playlist-id')
    spotify = Object.new
    spotify.define_singleton_method(:party_playlist) { playlist }
    GlobalState[:spotify_instances][7] = spotify
    GlobalState[:sonos_instances][7] = Object.new
    app = Class.new(test_app) do
      define_method(:queued_songs_json) do |*|
        [{ album_cover: "\"><script>alert(1)</script>", name: IMAGE_INJECTION, artists: 'Simon & Garfunkel' }]
      end
    end

    response = Rack::MockRequest.new(app.new).get('/p/7/party-playlist-id')

    assert_equal 200, response.status
    refute_includes response.body, IMAGE_INJECTION
    refute_includes response.body, '<script>alert(1)'
    assert_includes response.body, '&lt;img src=x onerror=alert(1)&gt; - Simon &amp; Garfunkel'
    assert_includes response.body, 'src="&quot;&gt;&lt;script&gt;'
  end

  def test_onboarding_page_escapes_the_playlist_name
    app = authenticated_app do
      define_method(:party_data) do
        @spotify_playlist_name = IMAGE_INJECTION
        { erb: :add_playlist_to_favs }
      end
    end

    response = Rack::MockRequest.new(app.new).get('/party')

    assert_equal 200, response.status
    refute_includes response.body, IMAGE_INJECTION
    assert_includes response.body, '"&lt;img src=x onerror=alert(1)&gt;"'
  end

  private

  def dashboard_data
    {
      selected_group: 'group-id',
      groups: [],
      party_on: true,
      queued_songs: [{ album_cover: 'https://i.scdn.co/image/cover', name: SCRIPT_BREAKOUT, artists: IMAGE_INJECTION,
                       id: 'track-id', duration: 180, uri: 'spotify:track:track-id' }],
      current_image_url: 'https://i.scdn.co/image/current',
      next_image_url: nil,
      current_song_details: { 'name' => SCRIPT_BREAKOUT },
      volume: 20,
      party_join_link: 'https://example.test/p/7/party-playlist-id',
      spotify_url: nil
    }
  end

  def authenticated_app(&block)
    Class.new(test_app) do
      define_method(:all_sessions?) { true }
      class_eval(&block)
    end
  end

  def test_app
    Class.new(SonosPartyMode::Server) do
      define_method(:initialize) do |app = nil|
        Sinatra::Base.instance_method(:initialize).bind(self).call(app)
      end
    end
  end
end
