# frozen_string_literal: true

require_relative "boot"

require "rails"
# Only the frameworks this example needs — no ActiveRecord, so no database required.
require "action_controller/railtie"
require "active_job/railtie"

Bundler.require(*Rails.groups)

module ManualReportingExample
  class Application < Rails::Application
    config.load_defaults 7.2

    # API-only: no views, cookies, or sessions.
    config.api_only = true
    config.eager_load = false

    # No credentials store in this example — a dev secret keeps the stack happy.
    config.secret_key_base = ENV.fetch("SECRET_KEY_BASE", "dev-only-secret-not-for-production")

    # ActiveJob with the in-process :async adapter — no Redis/Sidekiq required to run
    # the example. For production durability (survives deploys, retries), switch to
    # :sidekiq (or another backend) here.
    config.active_job.queue_adapter = :async

    # Log to stdout so you can see the "[three] api3 responded ..." lines while it runs.
    config.logger = ActiveSupport::Logger.new($stdout)
    config.log_level = :info
  end
end
