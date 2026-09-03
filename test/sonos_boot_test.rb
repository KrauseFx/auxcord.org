# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../sonos'

class SonosBootTest < Minitest::Test
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
end
