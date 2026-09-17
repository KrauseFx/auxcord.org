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

class SonosReauthorizationTest < Minitest::Test
  Response = Struct.new(:status, :body)

  # Just enough of a Sequel dataset for the Sonos login route
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
    alias all to_a

    def first
      to_a.first
    end

    def count
      to_a.count
    end

    def empty?
      to_a.empty?
    end

    def insert(attributes = {})
      id = @rows.map { |row| row[:id] }.max.to_i + 1
      @rows << attributes.merge(id: id)
      id
    end

    def update(attributes)
      to_a.each { |row| row.merge!(attributes) }
    end

    def delete
      matching = to_a
      @rows.reject! { |row| matching.include?(row) }
    end
  end

  # The Sonos API only accepts the token issued by the login in this test
  class SonosApi
    def data
      { path: '/control/api/v1/' }
    end

    def request(options)
      return Response.new(401, '{"error": "access_denied", "error_description": "Invalid Token"}') unless
        options.fetch(:headers).fetch('Authorization') == 'Bearer fresh-access-token'

      case options.fetch(:path)
      when %r{/households/household-id/groups\z}
        Response.new(200, JSON.generate(groups: [{ id: 'current-group', name: 'Living Room', playerIds: ['player'] }]))
      when %r{/households\z}
        Response.new(200, JSON.generate(households: [{ id: 'household-id' }]))
      else
        Response.new(200, '{}')
      end
    end
  end

  def setup
    GlobalState[:sonos_instances].clear
    GlobalState[:spotify_instances].clear
    @users = Table.new([{ id: 7 }])
    @sonos_tokens = Table.new(
      [{ id: 1, user_id: 7, access_token: 'expired-access-token', refresh_token: 'revoked-refresh-token',
         household: 'household-id', group: 'stale-group', volume: 20 }]
    )
    @spotify_tokens = Table.new([{ id: 1, user_id: 7, options: '{}', playlist_id: 'party-playlist-id' }])
  end

  def test_signing_in_again_repairs_account_with_revoked_sonos_tokens
    token_exchange = Response.new(200, JSON.generate(access_token: 'fresh-access-token',
                                                     refresh_token: 'fresh-refresh-token',
                                                     expires_in: 86_400))
    token_refresh = Response.new(400, '{"error": "invalid_request"}')
    login = Object.new
    login.define_singleton_method(:post) do |options|
      options.fetch(:body).include?('grant_type=authorization_code') ? token_exchange : token_refresh
    end

    app = Class.new(test_app) do
      before { session[:sonos_state_key] = 'login-state' }
    end

    response = with_database do
      with_instance_method(SonosPartyMode::Sonos, :client_login, login) do
        with_instance_method(SonosPartyMode::Sonos, :client_control, SonosApi.new) do
          Rack::MockRequest.new(app.new).get('/sonos/authorized.html?code=authorization-code&state=login-state')
        end
      end
    end

    assert_equal 302, response.status
    assert_equal [7], @sonos_tokens.to_a.map { |row| row[:user_id] }
    stored = @sonos_tokens.first
    assert_equal 'fresh-access-token', stored[:access_token]
    assert_equal 'fresh-refresh-token', stored[:refresh_token]
    assert_equal 'current-group', stored[:group]
    assert_equal 'current-group', GlobalState[:sonos_instances].fetch(7).group_to_use
  end

  def test_party_sends_host_back_to_sonos_login_when_authorization_is_revoked
    app = Class.new(test_app) do
      define_method(:all_sessions?) { true }
      define_method(:party_data) { raise SonosPartyMode::Sonos::ReauthorizationRequired }
    end

    response = Rack::MockRequest.new(app.new).get('/party')

    assert_equal 302, response.status
    assert_equal 'http://example.org/', response.location
  end

  private

  def with_database(&block)
    SonosPartyMode::Db.stub(:users, @users) do
      SonosPartyMode::Db.stub(:sonos_tokens, @sonos_tokens) do
        SonosPartyMode::Db.stub(:spotify_tokens, @spotify_tokens, &block)
      end
    end
  end

  def with_instance_method(klass, method_name, value)
    original_method = klass.instance_method(method_name)
    klass.define_method(method_name) { |*| value }
    yield
  ensure
    klass.define_method(method_name, original_method)
  end

  def test_app
    Class.new(SonosPartyMode::Server) do
      define_method(:initialize) do |app = nil|
        Sinatra::Base.instance_method(:initialize).bind(self).call(app)
      end
    end
  end
end

