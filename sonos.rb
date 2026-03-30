# frozen_string_literal: true

require 'excon'
require 'json'
require_relative './db'

module SonosPartyMode
  class Sonos
    SUBSCRIPTION_REFRESH_INTERVAL = 60 * 60 * 24

    # Basic attributes
    attr_accessor :user_id
    attr_accessor :favorites_cached
    attr_reader :party_session_active

    # Queueing system
    attr_reader :current_item_id # it's being set by the `/callback` triggers

    # Session specific settings
    attr_accessor :target_volume

    # Caches
    attr_accessor :groups_cached

    # Optionally pass in `authorization_code` if this is the first time
    # the account is being used, this will store the token in the database
    def initialize(user_id:, authorization_code: nil)
      @user_id = user_id
      new_auth!(authorization_code: authorization_code) if authorization_code

      return if database_row.nil? # this is the case if a user didn't finish onboarding

      @target_volume = database_row[:volume] # default volume is defined as part of `db.rb`
      @group_to_use = database_row[:group]
      self.groups_cached = groups
      return if groups_cached.nil? # no household

      validate_group_to_use!(force_refresh: false)

      @party_session_active = database_row[:party_active] || false
      @currently_playing_guest_wished_song = database_row[:currently_playing_guest_wished_song] || false
      @current_item_id = database_row[:current_item_id]
      @subscriptions_refreshed_at = Time.at(0)

      resubscribe!
    end

    def subscribe_to_playback
      client_control_request("/groups/#{active_group_to_use}/playback/subscription", method: :post)
    end

    def subscribe_to_playback_metadata
      client_control_request("/groups/#{active_group_to_use}/playbackMetadata/subscription", method: :post)
    end

    def resubscribe!
      subscribe_to_playback
      subscribe_to_playback_metadata
      @subscriptions_refreshed_at = Time.now
    end

    def ensure_subscriptions!
      return if @subscriptions_refreshed_at && (Time.now - @subscriptions_refreshed_at) < SUBSCRIPTION_REFRESH_INTERVAL

      resubscribe!
    end

    def did_receive_new_playback_metadata(info)
      # See example output at the very bottom of this file
      @_playback_metadata = info
    end

    def playback_metadata
      # this is cached from the Sonos subscription
      if @_playback_metadata && @_playback_metadata['currentItem'] && @_playback_metadata['currentItem']['track'] && @_playback_metadata['currentItem']['track']['id']
        return @_playback_metadata
      end

      # fallback, in case we didn't get a Sonos message yet. I confirmed it's the exact same data
      return client_control_request("groups/#{active_group_to_use}/playbackMetadata")
    end

    def ensure_playlist_in_favorites(spotify_playlist_id, force_refresh: true)
      favs = favorites_cached unless force_refresh
      favs ||= client_control_request("/households/#{primary_household}/favorites")
      return favs.fetch('items').find do |fav|
        fav['service']['name'] == 'Spotify' &&
        fav['resource']['type'] == 'PLAYLIST' &&
        fav['resource']['id']['objectId'].include?(spotify_playlist_id)
      end
    rescue => ex
      puts "fav playlist error"
      puts ex.message
      return nil
    end

    def ensure_current_sonos_settings!
      return unless party_session_active

      ensure_volume!(target_volume)
      ensure_music_playing!
      unmute_speakers!
    end

    # Called every ~15s
    def refresh_caches
      self.groups_cached = groups
      validate_group_to_use!(force_refresh: false)
      self.favorites_cached = client_control_request("/households/#{primary_household}/favorites")
      ensure_subscriptions!
    end

    def playback_status
      status = client_control_request("/groups/#{active_group_to_use}/playback")
      return status.fetch('playbackState')
    end

    def playback_is_playing?
      %w[PLAYBACK_STATE_PLAYING PLAYBACK_STATE_BUFFERING].include?(playback_status)
    end

    def ensure_music_playing!
      return if playback_is_playing?

      play_music!
    end

    def play_music!
      puts 'Resuming playback for Sonos system'
      client_control_request("groups/#{active_group_to_use}/playback/play", method: :post)
    end

    def pause_playback!
      return unless playback_is_playing?

      puts 'Pausing playback for Sonos system'
      client_control_request("groups/#{active_group_to_use}/playback/pause", method: :post)
    end

    def skip_song!
      puts 'Skipping song'
      client_control_request("/groups/#{active_group_to_use}/playback/skipToNextTrack", method: :post)
    end

    def get_volume
      # {"volume"=>40, "muted"=>false, "fixed"=>false}
      client_control_request("groups/#{active_group_to_use}/groupVolume")
    end

    def ensure_volume!(goal_volume, check_first: true)
      if check_first # when volume is manually changed in admin panel, we want to skip that
        get_volume_cached = get_volume
        # If the speakers are unmuted, and the volume is correct, nothing to do here
        return if get_volume_cached.fetch('volume') == goal_volume && get_volume_cached.fetch('muted') == false
      end

      # The request below will set the volume
      client_control_request(
        "groups/#{active_group_to_use}/groupVolume",
        method: :post,
        body: { volume: goal_volume }
      )
      unmute_speakers!
    end

    def unmute_speakers!
      # This is a separate request. It seems like there is no good Sonos API endpoint
      # to check if any of the speakers in a given group is muted, so it's best to just
      # send this API request from time to time in the background
      client_control_request(
        "groups/#{active_group_to_use}/groupVolume/mute",
        method: :post,
        body: { muted: false }
      )
    end

    # ----------------
    # Under the hood
    # ----------------

    def primary_household
      return @_primary_household if @_primary_household

      # I don't have an account with multiple households, but for now let's just access the household
      # with the highest number of speakers associated
      household_speakers = households.collect do |household|
        household_groups = client_control_request("/households/#{household['id']}/groups").fetch('groups', nil)

        [
          household["id"],
          household_groups.collect { |a| a["playerIds"] }.flatten.count
        ]
      end.to_h
      
      @_primary_household = household_speakers.max_by { |k, v| v }.first
    rescue => ex
      puts ex
      puts ex.backtrace.join("\n")
      @_primary_household ||= households.first['id']
    end

    def households
      client_control_request('households').fetch('households')
    end

    def groups
      return nil if primary_household.nil?
      client_control_request("/households/#{primary_household}/groups").fetch('groups', nil)
    end

    def group_to_use
      active_group_to_use(force_refresh: false)
    end

    def group_to_use=(value)
      assign_group_to_use!(value, persist: true, resubscribe: true)
    end

    def currently_playing_guest_wished_song=(value)
      @currently_playing_guest_wished_song = !!value
      Db.sonos_tokens.where(user_id: user_id).update(
        currently_playing_guest_wished_song: @currently_playing_guest_wished_song
      )
    end

    def currently_playing_guest_wished_song
      @currently_playing_guest_wished_song
    end

    def current_item_id=(value)
      @current_item_id = value
      Db.sonos_tokens.where(user_id: user_id).update(current_item_id: value)
    end

    def access_token
      database_row.fetch(:access_token)
    end

    def database_row
      Db.sonos_tokens.where(user_id: user_id).first
    end

    def client_login
      Excon.new('https://api.sonos.com/login/v3/oauth/access')
    end

    def client_control
      Excon.new('https://api.ws.sonos.com/control/api/v1/')
    end

    def default_headers
      {
        'Authorization' => "Bearer #{access_token}",
        'Content-Type' => 'application/json'
      }
    end

    def refresh_token
      puts 'Refreshing API token...'
      refresh_token = database_row.fetch(:refresh_token)
      response = client_login.post(
        headers: {
          'Content-Type' => 'application/x-www-form-urlencoded',
          'Accept-Charset' => 'UTF-8',
          'Authorization' => "Basic #{Base64.strict_encode64("#{ENV.fetch('SONOS_KEY')}:#{ENV.fetch('SONOS_SECRET')}")}"
        },
        body: URI.encode_www_form({
                                    grant_type: 'refresh_token',
                                    refresh_token: refresh_token
                                  })
      )
      parsed_body = JSON.parse(response.body)
      access_token = parsed_body.fetch('access_token')
      Db.sonos_tokens.where(user_id: user_id).update(access_token: access_token) # important to use full query
    end

    def client_control_request(path, method: :get, body: nil)
      response = client_control.request(
        method: method,
        path: File.join(client_control.data[:path], path),
        headers: default_headers,
        body: Hash(body).to_json
      )
      parsed_body = JSON.parse(response.body)
      # Check if Sonos API token has expired
      # "=> {"fault"=>{"faultstring"=>"Access Token expired", "detail"=>{"errorcode"=>"keymanagement.service.access_token_expired"}}}"
      if parsed_body['fault'].to_s.length.positive?
        if ['keymanagement.service.invalid_access_token',
            'keymanagement.service.access_token_expired'].include?(parsed_body['fault']['detail']['errorcode'])
          refresh_token
          return client_control_request(path, method: method, body: body)
        else
          raise parsed_body['fault']['faultstring']
        end
      end

      return parsed_body
    end

    # Override party_session_active setter
    def party_session_active=(value)
      @party_session_active = value
      Db.sonos_tokens.where(user_id: user_id).update(party_active: value) # important to use full query
    end

    def new_auth!(authorization_code:)
      # Very important: the redirect_uri has to match exactly
      response = client_login.post(
        headers: {
          'Content-Type' => 'application/x-www-form-urlencoded',
          'Accept-Charset' => 'UTF-8',
          'Authorization' => "Basic #{Base64.strict_encode64("#{ENV.fetch('SONOS_KEY')}:#{ENV.fetch('SONOS_SECRET')}")}"
        },
        body: URI.encode_www_form({
                                    grant_type: 'authorization_code',
                                    code: authorization_code,
                                    redirect_uri: "#{ENV.fetch('CUSTOM_HOST_URL')}/sonos/authorized.html"
                                  })
      )

      response = JSON.parse(response.body)
      puts "sonos api response: #{response}"
      raise response['error'] if response['error'].to_s.length.positive?

      access_token = response.fetch('access_token')
      refresh_token = response.fetch('refresh_token')

      # Store the access token in the database
      Db.sonos_tokens.insert(
        user_id: user_id,
        access_token: access_token,
        refresh_token: refresh_token,
        expires_in: response.fetch('expires_in')
      )
      Db.sonos_tokens.where(user_id: user_id).update(household: primary_household)
    end

    def active_group_to_use(force_refresh: true)
      validate_group_to_use!(force_refresh: force_refresh)
      @group_to_use
    end

    def validate_group_to_use!(force_refresh: true)
      available_groups = if force_refresh || groups_cached.nil?
                           self.groups_cached = groups
                         else
                           groups_cached
                         end
      return nil if available_groups.nil? || available_groups.empty?

      return @group_to_use if available_groups.any? { |group| group['id'] == @group_to_use }

      fallback_group = available_groups.max_by { |group| group.fetch('playerIds', []).count }
      assign_group_to_use!(fallback_group.fetch('id'), persist: true, resubscribe: true)
      @group_to_use
    end

    def assign_group_to_use!(value, persist:, resubscribe:)
      @group_to_use = value
      Db.sonos_tokens.where(user_id: user_id).update(group: value) if persist
      resubscribe! if resubscribe && !value.nil?
      @group_to_use
    end
  end
end

# {
#   "container": {
#     "name": "Work",
#     "type": "track",
#     "id": {
#       "serviceId": "12",
#       "objectId": "spotify:track:3KliPMvk1EvFZu9cvkj8p1",
#       "accountId": "sn_1"
#     },
#     "service": {
#       "name": "Spotify",
#       "id": "12",
#       "images": [
#       ]
#     },
#     "imageUrl": "https://i.scdn.co/image/ab67616d0000b2733c9f7b8faf039c7607d12255",
#     "images": [
#       {
#         "url": "https://i.scdn.co/image/ab67616d0000b2733c9f7b8faf039c7607d12255",
#         "height": 0,
#         "width": 0
#       }
#     ],
#     "tags": [
#       "TAG_EXPLICIT"
#     ],
#     "explicit": true
#   },
#   "currentItem": {
#     "track": {
#       "type": "track",
#       "name": "Work",
#       "imageUrl": "http://192.168.0.168:1400/getaa?s=1&u=x-sonos-spotify%3aspotify%253atrack%253a3KliPMvk1EvFZu9cvkj8p1%3fsid%3d12%26flags%3d8232%26sn%3d1",
#       "images": [
#         {
#           "url": "http://192.168.0.168:1400/getaa?s=1&u=x-sonos-spotify%3aspotify%253atrack%253a3KliPMvk1EvFZu9cvkj8p1%3fsid%3d12%26flags%3d8232%26sn%3d1",
#           "height": 0,
#           "width": 0
#         }
#       ],
#       "album": {
#         "name": "Britney Jean (Deluxe Version)",
#         "explicit": false
#       },
#       "artist": {
#         "name": "Britney Spears",
#         "explicit": false
#       },
#       "id": {
#         "serviceId": "12",
#         "objectId": "spotify:track:3KliPMvk1EvFZu9cvkj8p1",
#         "accountId": "sn_1"
#       },
#       "service": {
#         "name": "Spotify",
#         "id": "12",
#         "images": [
#         ]
#       },
#       "durationMillis": 247000,
#       "tags": [
#         "TAG_EXPLICIT"
#       ],
#       "explicit": true,
#       "advertisement": false,
#       "quality": {
#         "bitDepth": 0,
#         "sampleRate": 0,
#         "lossless": false,
#         "immersive": false
#       }
#     },
#     "deleted": false,
#     "policies": {
#       ...
#     }
#   },
#   "nextItem": {
#     "track": {
#       "type": "track",
#       "name": "Inner Tale",
#       "imageUrl": "http://192.168.0.168:1400/getaa?s=1&u=x-sonos-spotify%3aspotify%253atrack%253a4aAPW97U3nrnELAknGdV2L%3fsid%3d12%26flags%3d8232%26sn%3d1",
#       "images": [
#         {
#           "url": "http://192.168.0.168:1400/getaa?s=1&u=x-sonos-spotify%3aspotify%253atrack%253a4aAPW97U3nrnELAknGdV2L%3fsid%3d12%26flags%3d8232%26sn%3d1",
#           "height": 0,
#           "width": 0
#         }
#       ],
#       "album": {
#         "name": "Orchestra",
#         "explicit": false
#       },
#       "artist": {
#         "name": "Worakls",
#         "explicit": false
#       },
#       "id": {
#         "serviceId": "12",
#         "objectId": "spotify:track:4aAPW97U3nrnELAknGdV2L",
#         "accountId": "sn_1"
#       },
#       "service": {
#         "name": "Spotify",
#         "id": "12",
#         "images": [
#         ]
#       },
#       "durationMillis": 259000,
#       "explicit": false,
#       "advertisement": false,
#       "quality": {
#         "bitDepth": 0,
#         "sampleRate": 0,
#         "lossless": false,
#         "immersive": false
#       }
#     },
#     "deleted": false,
#     "policies": {
#       ...
#     }
#   }
# }
