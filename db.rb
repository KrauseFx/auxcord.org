# frozen_string_literal: true

require 'sequel'

module SonosPartyMode
  class Db
    def self.ensure_column(table_name, column_name, type, **options)
      existing_columns = shared_database.schema(table_name).map(&:first)
      return if existing_columns.include?(column_name)

      shared_database.alter_table(table_name) do
        add_column column_name, type, **options
      end
    end

    def self.shared_database
      @shared_database ||= Sequel.connect(ENV.fetch('DATABASE_URL'))
    end

    def self.users
      unless shared_database.table_exists?(:users)
        shared_database.create_table :users do
          primary_key :id
        end
      end
      shared_database[:users]
    end

    def self.sonos_tokens
      unless shared_database.table_exists?(:sonos_tokens)
        shared_database.create_table :sonos_tokens do
          primary_key :id
          foreign_key :user_id, :users
          String :access_token
          String :refresh_token
          String :expires_in
          Int :volume, default: 20
          String :group
          String :household
          TrueClass :party_active
          TrueClass :currently_playing_guest_wished_song, default: false
          String :current_item_id
        end
      end
      ensure_column(:sonos_tokens, :currently_playing_guest_wished_song, TrueClass, default: false)
      ensure_column(:sonos_tokens, :current_item_id, String)
      return shared_database[:sonos_tokens]
    end

    def self.spotify_tokens
      unless shared_database.table_exists?(:spotify_tokens)
        shared_database.create_table :spotify_tokens do
          primary_key :id
          foreign_key :user_id, :users
          String :options
          String :playlist_id
          String :queue_track_ids, text: true
          String :past_track_ids, text: true
        end
      end
      ensure_column(:spotify_tokens, :queue_track_ids, String, text: true)
      ensure_column(:spotify_tokens, :past_track_ids, String, text: true)
      return shared_database[:spotify_tokens]
    end
  end
end
