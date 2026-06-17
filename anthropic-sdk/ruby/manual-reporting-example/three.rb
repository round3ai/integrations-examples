# frozen_string_literal: true

# three.rb — everything Three.dev-specific for manual reporting lives here.
#
# Three.dev's "manual reporting" integration does NOT proxy your traffic and does
# NOT patch your SDK. You call the Anthropic / OpenAI SDK exactly as you do today
# (with your own provider key, straight to the provider), then hand the request and
# response to Three.record_request(...). The reporter builds the api3 RecordRequest payload
# and POSTs it to Three.dev on a background thread — fire-and-forget, so a slow or
# unreachable Three.dev never adds latency to (or breaks) your LLM calls.
#
# Why manual? The official Anthropic and OpenAI Ruby SDKs are Stainless-generated and
# expose no middleware/interceptor hook and no settable HTTP transport, so there is no
# Ruby equivalent of the Anthropic Go SDK's option.WithMiddleware. Manual reporting is
# the explicit, upgrade-proof, no-monkey-patch way to get the same data to Three.dev.
#
# This module exposes:
#   - Three::Config        configuration (api key, use case, endpoint)
#   - Three.new_request_id generate a UUIDv7 at request START (api3 derives start_time from it)
#   - Three.record_request         build + asynchronously POST one RecordRequest to api3
#   - Three.flush          block until in-flight reports finish (call before process exit)

require "base64"
require "json"
require "net/http"
require "securerandom"
require "time"
require "uri"

module Three
  # Default api3 base URL. Override via Config#endpoint for staging/local instances.
  DEFAULT_ENDPOINT = "https://api.three.dev"

  # Bound each reporting POST so a slow/unreachable endpoint can't pile up threads.
  REQUEST_TIMEOUT_SECONDS = 10

  # Config holds everything Three.dev-specific for a process.
  #   api_key       Three.dev API key (r3_sk_...). Sent as: Authorization: Bearer <api_key>.
  #   use_case_slug Three.dev use case identifier — must match the dashboard slug.
  #   endpoint      api3 base URL. Defaults to DEFAULT_ENDPOINT when nil/empty.
  Config = Struct.new(:api_key, :use_case_slug, :endpoint, keyword_init: true) do
    def initialize(api_key:, use_case_slug:, endpoint: nil)
      endpoint = DEFAULT_ENDPOINT if endpoint.nil? || endpoint.empty?
      super(api_key: api_key, use_case_slug: use_case_slug, endpoint: endpoint)
    end
  end

  @threads = []
  @mutex = Mutex.new

  class << self
    # new_request_id returns a UUIDv7 string. Generate it at the START of the request:
    # api3 reads the timestamp embedded in the UUIDv7 and uses it as the request start
    # time (for latency). Requires Ruby 3.3+ (SecureRandom.uuid_v7).
    def new_request_id
      SecureRandom.uuid_v7
    end

    # record_request builds a RecordRequest and POSTs it to api3 asynchronously.
    #
    # Fire-and-forget: returns immediately; the POST runs on a background thread and
    # every error/exception in the reporting path is swallowed, so reporting can never
    # affect your application.
    #
    #   request_body / response_body  raw JSON strings. NOTE: these are reconstructed
    #                                 from SDK params/objects, not the original wire
    #                                 bytes (see README) — high fidelity, but not byte-exact.
    #   provider                      "anthropic" | "openai"
    #   path                          "/v1/messages" | "/v1/chat/completions"
    #   status_code                   HTTP status of the provider call (200 on success)
    #   session_id                    optional; groups requests into one conversation
    #   user_tags / session_tags      optional String => String maps
    def record_request(config:, request_id:, provider:, path:, request_body:, response_body:,
               status_code:, session_id: nil, user_tags: {}, session_tags: {})
      payload = build_payload(
        config: config, request_id: request_id, provider: provider, path: path,
        request_body: request_body, response_body: response_body, status_code: status_code,
        session_id: session_id, user_tags: user_tags, session_tags: session_tags
      )

      thread = Thread.new { safe_report(config, payload) }
      @mutex.synchronize { @threads << thread }
      nil
    rescue StandardError => e
      # Belt-and-suspenders: even building the payload must never raise into the
      # caller. The network POST itself is already isolated on the background thread.
      warn "[three] record_request skipped: #{e.class}: #{e.message}" if ENV["THREE_DEBUG"]
      nil
    end

    # flush blocks until all in-flight reports have completed. Call it before your
    # process exits (e.g. at_exit { Three.flush }) so the last reports aren't lost.
    # In a long-running Rails server, call it from your graceful-shutdown hook instead.
    def flush
      threads = @mutex.synchronize do
        live = @threads.dup
        @threads.clear
        live
      end
      threads.each(&:join)
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

    # safe_report POSTs the payload to api3's POST /api/v1/request. All errors are
    # swallowed: a Three.dev outage must never surface in the calling application.
    # Set THREE_DEBUG=1 to log the api3 status code / any error to stderr.
    def safe_report(config, payload)
      uri = URI.parse("#{config.endpoint}/api/v1/request")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = REQUEST_TIMEOUT_SECONDS
      http.read_timeout = REQUEST_TIMEOUT_SECONDS

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{config.api_key}"
      request.body = JSON.generate(payload)

      response = http.request(request)
      warn "[three] api3 responded #{response.code}" if ENV["THREE_DEBUG"]
    rescue StandardError => e
      warn "[three] report failed: #{e.class}: #{e.message}" if ENV["THREE_DEBUG"]
    end
  end
end
