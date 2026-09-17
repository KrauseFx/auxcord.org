# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'minitest/mock'
require 'rack/mock'
require 'sinatra/base'

ENV['CUSTOM_HOST_URL'] ||= 'https://example.test'
ENV['SESSION_SECRET'] ||= 'test-session-secret'
ENV['SPOTIFY_CLIENT_ID'] ||= 'test-client-id'
ENV['SPOTIFY_CLIENT_SECRET'] ||= 'test-client-secret'

original_run = Sinatra::Base.method(:run!)
Sinatra::Base.singleton_class.define_method(:run!) { |*| nil }
require_relative '../server'
Sinatra::Base.singleton_class.define_method(:run!, original_run)

class QueueReliabilityTest < Minitest::Test
  Artist = Struct.new(:name)
  Track = Struct.new(:id, :name, :artists)

  class PlaylistDouble
    attr_reader :tracks

    def initialize
      @tracks = []
    end

    def id
      'party-playlist-id'
    end

    def add_tracks!(tracks)
      @tracks += tracks
    end

    def remove_tracks!(tracks)
      @tracks -= tracks
    end
  end

  class SonosDouble
    attr_accessor :group_to_use, :currently_playing_guest_wished_song, :current_item_id, :user_id,
                  :party_session_active
    attr_reader :inserts, :calls

    # `insert_response` is what Sonos answers to INSERT_NEXT, `before_insert` runs before answering
    def initialize(insert_response: {}, before_insert: nil)
      @group_to_use = 'group-id'
      @user_id = 7
      @currently_playing_guest_wished_song = false
      @insert_response = insert_response
      @before_insert = before_insert
      @inserts = []
      @calls = []
    end

    def ensure_playlist_in_favorites(_playlist_id)
      { 'id' => 'favorite-id' }
    end

    def client_control_request(path, method: :get, body: nil)
      @before_insert&.call
      @inserts << [path, method, body]
      @insert_response
    end

    %i[pause_playback! ensure_music_playing! subscribe! play_music!].each do |name|
      define_method(name) { @calls << name }
    end
  end

  class MemoryDataset
    def where(_conditions)
      self
    end

    def empty?
      false
    end

    def first
      { user_id: 7, options: '{}', playlist_id: 'party-playlist-id' }
    end

    def update(_attributes); end
  end

  def setup
    GlobalState[:spotify_instances].clear
    GlobalState[:sonos_instances].clear
    @playlist = PlaylistDouble.new
  end

  # --- Queueing on Sonos ---

  def test_failed_sonos_insert_keeps_the_song_first_in_line_and_no_guest_song_up_next
    sonos = SonosDouble.new(insert_response: { 'errorCode' => 'ERROR_INVALID_PARAMETER' })
    spotify = build_spotify
    song = track('song-1')

    assert_equal :queue_now, spotify.enqueue_guest_song(song, sonos)
    assert_raises(SonosPartyMode::Spotify::SonosInsertFailed) { spotify.run_reserved_sonos_insert!(sonos) }

    assert_equal [song], spotify.queued_songs
    assert_empty spotify.past_songs
    refute sonos.currently_playing_guest_wished_song
    assert_empty @playlist.tracks
    # The failed attempt doesn't block the next one
    assert_equal :queue_now, spotify.enqueue_guest_song(track('song-2'), sonos)
  end

  def test_successful_insert_moves_the_song_to_sonos_and_marks_a_guest_song_up_next
    sonos = SonosDouble.new
    spotify = build_spotify
    song = track('song-1')

    spotify.enqueue_guest_song(song, sonos)
    assert_equal true, spotify.run_reserved_sonos_insert!(sonos)

    assert_empty spotify.queued_songs
    assert_equal [song], spotify.past_songs
    assert sonos.currently_playing_guest_wished_song
    assert_equal 0, spotify.queued_position(song)
    assert_equal({ favoriteId: 'favorite-id', action: 'INSERT_NEXT' }, sonos.inserts.last.last)
    assert_empty @playlist.tracks
  end

  def test_guests_arriving_while_a_song_is_being_queued_wait_in_line
    sonos = SonosDouble.new
    spotify = build_spotify

    assert_equal :queue_now, spotify.enqueue_guest_song(track('song-1'), sonos)
    second_song = track('song-2')
    assert_equal :waiting, spotify.enqueue_guest_song(second_song, sonos)
    assert_equal 2, spotify.queued_position(second_song)
  end

  def test_concurrent_submissions_of_the_same_song_queue_it_once
    sonos = SonosDouble.new
    spotify = build_spotify

    results = Array.new(10) do
      Thread.new { spotify.enqueue_guest_song(track('same-song'), sonos) }
    end.map(&:value)

    assert_equal 9, results.count(:duplicate)
    assert_equal 1, spotify.queued_songs.count
  end

  def test_song_change_reserves_one_insert_per_transition
    sonos = SonosDouble.new
    sonos.current_item_id = 'item-1'
    sonos.currently_playing_guest_wished_song = true
    spotify = build_spotify
    spotify.queued_songs << track('song-1')

    assert spotify.song_changed!(sonos, item_id: 'item-2', previous_item_id: 'item-1')
    refute spotify.song_changed!(sonos, item_id: 'item-2', previous_item_id: 'item-1')
    refute sonos.currently_playing_guest_wished_song
    assert_equal :waiting, spotify.enqueue_guest_song(track('song-2'), sonos)
  end

  def test_event_without_previous_item_is_not_a_song_change
    sonos = SonosDouble.new
    spotify = build_spotify
    spotify.queued_songs << track('song-1')

    refute spotify.song_changed!(sonos, item_id: 'item-1', previous_item_id: nil)
    assert_equal 'item-1', sonos.current_item_id
  end

  # --- Guest song submission ---

  def test_guest_is_told_when_the_song_could_not_be_queued_and_can_try_again
    sonos = SonosDouble.new(insert_response: { 'errorCode' => 'ERROR_INVALID_PARAMETER' })
    spotify = register_party(sonos)

    response = submit_song('song-1')

    assert_equal 200, response.status
    body = JSON.parse(response.body)
    refute body.fetch('success')
    assert_match(/try again/, body.fetch('error'))
    assert_empty spotify.queued_songs
    refute sonos.currently_playing_guest_wished_song
  end

  def test_guest_gets_success_only_once_sonos_has_the_song
    sonos = SonosDouble.new
    register_party(sonos)

    response = submit_song('song-1')

    assert_equal({ 'success' => true, 'position' => 0 }, JSON.parse(response.body))
    assert_equal 1, sonos.inserts.count
    assert sonos.currently_playing_guest_wished_song
  end

  def test_unknown_song_returns_an_error_instead_of_crashing
    register_party(SonosDouble.new, songs: {})

    response = submit_song('removed-song')

    assert_equal 200, response.status
    assert_match(/Couldn't find this song/, JSON.parse(response.body).fetch('error'))
  end

  def test_song_submission_without_a_sonos_instance_is_unavailable
    register_party(SonosDouble.new)
    GlobalState[:sonos_instances].clear

    response = submit_song('song-1')

    assert_equal 503, response.status
    refute JSON.parse(response.body).fetch('success')
  end

  # --- Sonos callbacks ---

  def test_callback_acknowledges_before_queueing_the_next_song_and_does_not_double_queue
    release = Queue.new
    sonos = SonosDouble.new(before_insert: -> { release.pop })
    sonos.current_item_id = 'item-1'
    spotify = register_party(sonos)
    spotify.queued_songs << track('song-1')
    threads = []
    app = callback_test_app(threads)

    event = JSON.generate(itemId: 'item-2', previousItemId: 'item-1')
    first = Rack::MockRequest.new(app.new).post('/callback', 'HTTP_X_SONOS_TARGET_VALUE' => 'group-id', input: event)
    retried = Rack::MockRequest.new(app.new).post('/callback', 'HTTP_X_SONOS_TARGET_VALUE' => 'group-id', input: event)

    assert_equal [200, 200], [first.status, retried.status]
    assert_empty sonos.inserts # the insert is still waiting in the background
    release << :go
    threads.each(&:join)

    assert_equal 1, sonos.inserts.count
    assert_equal ['song-1'], spotify.past_songs.map(&:id)
    assert sonos.currently_playing_guest_wished_song
  end

  def test_callback_without_target_header_or_previous_item_is_handled
    sonos = SonosDouble.new
    spotify = register_party(sonos)
    spotify.queued_songs << track('song-1')
    threads = []
    request = Rack::MockRequest.new(callback_test_app(threads).new)

    missing_header = request.post('/callback', input: JSON.generate(itemId: 'item-1'))
    first_event = request.post('/callback', 'HTTP_X_SONOS_TARGET_VALUE' => 'group-id', input: JSON.generate(itemId: 'item-1'))
    threads.each(&:join)

    assert_equal 400, missing_header.status
    assert_equal 200, first_event.status
    assert_empty sonos.inserts
  end

  # --- Subscriptions ---

  def test_changing_the_group_resubscribes_to_the_new_group
    sonos = SonosDouble.new
    register_party(sonos)
    app = Class.new(route_test_app) do
      define_method(:all_sessions?) { true }
      before { session[:user_id] = 7 }
    end

    response = SonosPartyMode::Db.stub(:sonos_tokens, MemoryDataset.new) do
      Rack::MockRequest.new(app.new).post('/party/host/update', params: { group_to_use: 'new-group' })
    end

    assert_equal 200, response.status
    assert_equal 'new-group', sonos.group_to_use
    assert_equal %i[pause_playback! subscribe!], sonos.calls
  end

  def test_subscriptions_are_renewed_daily_not_on_every_refresh
    subscription_calls = []
    sonos = SonosPartyMode::Sonos.allocate
    sonos.group_to_use = 'group-id'
    sonos.define_singleton_method(:groups) { [] }
    sonos.define_singleton_method(:primary_household) { 'household-id' }
    sonos.define_singleton_method(:client_control_request) do |path, method: :get, body: nil|
      subscription_calls << path if path.end_with?('/subscription')
      {}
    end

    sonos.refresh_caches
    sonos.refresh_caches
    assert_equal 2, subscription_calls.count

    sonos.instance_variable_set(:@subscribed_at, Time.now - SonosPartyMode::Sonos::SUBSCRIPTION_RENEWAL_INTERVAL - 1)
    sonos.refresh_caches
    assert_equal 4, subscription_calls.count
  end

  private

  def track(id)
    Track.new(id, "Song #{id}", [Artist.new('Artist')])
  end

  def build_spotify
    spotify = SonosPartyMode::Db.stub(:spotify_tokens, MemoryDataset.new) do
      SonosPartyMode::Spotify.new(user_id: 7)
    end
    playlist = @playlist
    spotify.define_singleton_method(:party_playlist) { playlist }
    spotify.define_singleton_method(:spotify_request) { |&request| request.call }
    spotify
  end

  def register_party(sonos, songs: nil)
    spotify = build_spotify
    spotify.define_singleton_method(:find_song) do |song_id|
      songs ? songs[song_id] : Track.new(song_id, "Song #{song_id}", [Artist.new('Artist')])
    end
    GlobalState[:spotify_instances][7] = spotify
    GlobalState[:sonos_instances][7] = sonos
    spotify
  end

  def submit_song(song_id)
    Rack::MockRequest.new(route_test_app.new).post("/p/7/party-playlist-id/#{song_id}")
  end

  def route_test_app
    Class.new(SonosPartyMode::Server) do
      define_method(:initialize) do |app = nil|
        Sinatra::Base.instance_method(:initialize).bind(self).call(app)
      end
    end
  end

  # Collects the background threads, so tests can wait for them
  def callback_test_app(threads)
    Class.new(route_test_app) do
      define_method(:run_in_background) do |spotify_instance, jobs|
        threads << super(spotify_instance, jobs)
      end
    end
  end
end
