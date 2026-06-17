# frozen_string_literal: true

# three.rb — Three.dev manual reporting for Rails.
#
# Same idea as the standalone Ruby example (build a RecordRequest from your request +
# response and POST it to api3), with one Rails-idiomatic change: the async dispatch is
# an ActiveJob (ThreeReportJob) instead of a raw Thread. That makes reporting:
#   * Off the critical path — record_request enqueues and returns immediately, so neither
#     Three.dev's latency nor a Three.dev failure ever touches the web request.
#   * More robust than a thread — bounded by the job pool, retried, and (with a durable
#     queue like Sidekiq) able to survive a deploy/restart.
#
# Building the payload happens inline (a cheap, in-memory snapshot of the exact request/
# response); only the network POST runs in the job. This file has no Rails autoload
# dependency — it is required explicitly from config/initializers/three.rb.

require "base64"
require "json"
require "net/http"
require "securerandom"
require "time"
require "uri"

module Three
  DEFAULT_ENDPOINT = "https://api.three.dev"
  REQUEST_TIMEOUT_SECONDS = 10

  # Config holds everything Three.dev-specific. Build it once (see the initializer).
  Config = Struct.new(:api_key, :use_case_slug, :endpoint, keyword_init: true) do
    def initialize(api_key:, use_case_slug:, endpoint: nil)
      endpoint = DEFAULT_ENDPOINT if endpoint.nil? || endpoint.empty?
      super(api_key: api_key, use_case_slug: use_case_slug, endpoint: endpoint)
    end
  end

  class << self
    # new_request_id returns a UUIDv7 string. Generate it at the START of the request:
    # api3 derives the request's start_time from the timestamp embedded in the UUIDv7.
    # Requires Ruby 3.3+ (SecureRandom.uuid_v7).
    def new_request_id
      SecureRandom.uuid_v7
    end

    # record_request snapshots the request/response into a RecordRequest payload and
    # ENQUEUES delivery as an ActiveJob. Returns immediately; never raises into the caller.
    def record_request(config:, request_id:, provider:, path:, request_body:, response_body:,
                       status_code:, session_id: nil, user_tags: {}, session_tags: {})
      body = JSON.generate(build_payload(
        config: config, request_id: request_id, provider: provider, path: path,
        request_body: request_body, response_body: response_body, status_code: status_code,
        session_id: session_id, user_tags: user_tags, session_tags: session_tags
      ))
      ThreeReportJob.perform_later(body, config.api_key, config.endpoint)
      nil
    rescue StandardError => e
      Rails.logger.warn("[three] record_request skipped: #{e.class}: #{e.message}")
      nil
    end

    # deliver POSTs a prebuilt JSON body to api3's POST /api/v1/request. Called by
    # ThreeReportJob (i.e. off the request thread).
    def deliver(body, api_key, endpoint)
      uri = URI.parse("#{endpoint}/api/v1/request")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = REQUEST_TIMEOUT_SECONDS
      http.read_timeout = REQUEST_TIMEOUT_SECONDS

      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      req["Authorization"] = "Bearer #{api_key}"
      req.body = body

      res = http.request(req)
      Rails.logger.info("[three] api3 responded #{res.code}")
      res
    end

    private

    def build_payload(config:, request_id:, provider:, path:, request_body:, response_body:,
                      status_code:, session_id:, user_tags:, session_tags:)
      payload = {
        id: request_id,
        use_case_slug: config.use_case_slug,
        provider: provider,
        input: {
          content: Base64.strict_encode64(request_body),
          content_type: "application/json",
          path: path
        },
        output: {
          content: Base64.strict_encode64(response_body),
          status_code: status_code,
          received_at: Time.now.utc.iso8601(9),
          content_type: "application/json",
          content_chunks_received_at: []
        }
      }
      payload[:session_id] = session_id if session_id && !session_id.empty?
      payload[:user_tags] = user_tags if user_tags && !user_tags.empty?
      payload[:session_tags] = session_tags if session_tags && !session_tags.empty?
      payload
    end
  end
end
