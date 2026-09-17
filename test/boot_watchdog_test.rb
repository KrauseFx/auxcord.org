# frozen_string_literal: true

require 'minitest/autorun'
require 'sinatra/base'

ENV['CUSTOM_HOST_URL'] ||= 'https://example.test'
ENV['SESSION_SECRET'] ||= 'test-session-secret'

original_run = Sinatra::Base.method(:run!)
Sinatra::Base.singleton_class.define_method(:run!) { |*| nil }
require_relative '../server'
Sinatra::Base.singleton_class.define_method(:run!, original_run)

class BootWatchdogTest < Minitest::Test
  def test_watchdog_fires_when_boot_does_not_finish_in_time
    fired = Queue.new

    SonosPartyMode::Server.start_boot_watchdog(0.01) { fired << true }

    assert fired.pop
  end

  def test_killed_watchdog_does_not_fire
    fired = false

    watchdog = SonosPartyMode::Server.start_boot_watchdog(0.05) { fired = true }
    watchdog.kill
    sleep(0.1)

    refute fired
  end

  def test_railway_waits_for_the_app_to_respond_before_switching_traffic
    config = JSON.parse(File.read(File.expand_path('../railway.json', __dir__))).fetch('deploy')

    assert_equal '/', config.fetch('healthcheckPath')
    assert_operator config.fetch('healthcheckTimeout'), :>, SonosPartyMode::Server::BOOT_TIMEOUT_SECONDS
    assert_equal 'ON_FAILURE', config.fetch('restartPolicyType')
  end
end
