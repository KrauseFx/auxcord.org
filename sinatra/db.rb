require "sequel"

module SonosPartyMode
  class Db
    def self.shared_database
      @shared_database ||= Sequel.connect(ENV.fetch("DATABASE_URL"))
    end

    def self.users
      if !shared_database.table_exists?(:users)
        shared_database.create_table :users do
          primary_key :id
        end
      end
      shared_database[:users]
    end

    def self.sonos_tokens
      if !shared_database.table_exists?(:sonos_tokens)
        shared_database.create_table :sonos_tokens do
          primary_key :id
          foreign_key :user_id, :users
          String :access_token
          String :refresh_token
          String :expires_in
        end
      end
      return shared_database[:sonos_tokens]
    end

    def self.spotify_tokens
      if !shared_database.table_exists?(:spotify_tokens)
        shared_database.create_table :spotify_tokens do
          primary_key :id
          foreign_key :user_id, :users
          String :options
          String :playlist_id
        end
      end
      return shared_database[:spotify_tokens]
    end
  end
end
