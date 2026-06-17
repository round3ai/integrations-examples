# frozen_string_literal: true

# ThreeReportJob delivers one RecordRequest to api3, off the web request's thread.
class ThreeReportJob < ApplicationJob
  queue_as :default

  # Reporting is best-effort and must never disrupt the app. Retry a few transient
  # failures, then give up silently — the block runs after attempts are exhausted,
  # so the error is swallowed instead of re-raised.
  retry_on(StandardError, attempts: 3, wait: 5.seconds) { |_job, _error| nil }

  def perform(body, api_key, endpoint)
    Three.deliver(body, api_key, endpoint)
  end
end
