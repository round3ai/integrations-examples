# frozen_string_literal: true

# main.rb — Anthropic Ruby SDK + Three.dev manual reporting, with a system prompt
# and a tool call (a tiny weather assistant).
#
# You call the Anthropic SDK exactly as usual (your own key, straight to Anthropic),
# then hand each request/response to Three.record_request. A tool-use conversation makes TWO
# LLM calls — (1) the model asks to call get_weather, (2) it answers using the tool
# result — and BOTH are reported, under the same session_id, so the whole exchange is
# observable on the dashboard. See three.rb for the reporter and README.md for the rationale.

require "dotenv/load"
require "anthropic"
require "json"
require "securerandom"

require_relative "three"

MODEL = "claude-opus-4-8"

config = Three::Config.new(
  api_key: ENV.fetch("THREE_API_KEY"),
  use_case_slug: ENV.fetch("USE_CASE_SLUG"),
  endpoint: ENV["THREE_ENDPOINT"]
)

# Deliver any in-flight reports before the process exits. In a long-running Rails
# server, call Three.flush from your graceful-shutdown hook instead.
at_exit { Three.flush }

# Your own Anthropic client — calls go DIRECTLY to Anthropic, not through Three.dev.
client = Anthropic::Client.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"))

# A session ID groups all calls of this conversation into one thread on the dashboard.
# It is OPAQUE — it can be WHATEVER stable identifier you already have: a user ID, a
# conversation ID, an HTTP request ID, etc. No format constraints. It's also optional;
# omit it and calls are reported without grouping. Here we just generate a UUID.
# (Contrast with request_id below, which is NOT free-form — see call_and_report.)
session_id = SecureRandom.uuid

# --- the tool the model can call ---------------------------------------------------

# Anthropic tool schema. `params` below double as the reconstructed request body we
# report, so we keep them in Anthropic WIRE format throughout (see system note below).
TOOLS = [
  {
    name: "get_weather",
    description: "Get the current weather for a location. Returns temperature and conditions.",
    input_schema: {
      type: "object",
      properties: {
        location: { type: "string", description: "City and region, e.g. 'Madrid, Spain'" }
      },
      required: ["location"]
    }
  }
].freeze

SYSTEM_PROMPT = "You are a concise weather assistant. When asked about the weather, " \
                "use the get_weather tool, then answer in one short sentence."

# Mock implementation. In a real app this would call a weather API.
def get_weather(location)
  { location: location, temperature_c: 22, conditions: "Sunny" }
end

# Inference configuration — the single source of truth for every call. It is sent to
# the SDK AND reported verbatim to Three.dev, so whatever you set here is what shows up
# in the dashboard's request config (api3 parses these into inference_params). These are
# Anthropic WIRE field names; the Ruby SDK uses the same names except `system` (-> `system_`),
# which call_and_report translates. Each turn merges in its own `messages`.
INFERENCE = {
  model: MODEL,
  max_tokens: 4096,
  thinking: { type: "adaptive" },             # extended thinking ("reasoning"), Opus 4.8+ API
  output_config: { effort: "medium" },        # reasoning effort: low | medium | high | xhigh | max
  tool_choice: { type: "auto" },              # let the model decide whether to call a tool
  metadata: { user_id: "demo-user-123" },     # Anthropic metadata supports user_id
  system: SYSTEM_PROMPT,
  tools: TOOLS

  # Other inference params you can add (all reported the same way):
  #   stop_sequences: ["END"],                # custom stop strings
  #   service_tier: "auto",                   # priority/standard/auto
  #
  # Older reasoning API (pre-4.8 models): thinking: { type: "enabled", budget_tokens: 2000 }
  # Classic sampling params — temperature/top_p/top_k are DEPRECATED for reasoning models
  # like claude-opus-4-8 (the API returns 400). On older models you'd add:
  #   temperature: 0.7, top_p: 0.95, top_k: 40
}.freeze

# --- the SDK-call + report helper --------------------------------------------------

# ============================================================================
# THIS is the only change you add to get Three.dev observability — the manual-
# reporting approach. You keep calling the SDK exactly as before; after each call
# you hand the request + response to Three.record_request. There is no proxy and no SDK
# patching.
#
# It is deliberately OFF your critical path, in two independent ways:
#
#   1) Latency-isolated — Three.record_request returns immediately. The HTTPS POST to
#      Three.dev (api3) runs on a background thread inside three.rb, so Three.dev's
#      network latency is NEVER added to your LLM call or your request handling.
#
#   2) Failure-isolated — this whole helper is wrapped in a rescue, and three.rb
#      additionally swallows every error in its background thread. If Three.dev is
#      down, slow, or returns an error — or if serialization here fails — your LLM
#      call and business logic are completely unaffected. Reporting can never raise
#      into your application.
#
# (The tiny JSON serialization below runs inline on purpose: it snapshots the exact
# request/response now, before later turns mutate the shared conversation. It is
# local CPU work, not network latency.)
# ============================================================================
def report_to_three(config, session_id, request_id, request_params, response_obj, status_code)
  Three.record_request(
    config: config, request_id: request_id, provider: "anthropic", path: "/v1/messages",
    request_body: JSON.generate(request_params),
    response_body: JSON.generate(response_obj.respond_to?(:to_h) ? response_obj.to_h : response_obj),
    status_code: status_code, session_id: session_id
  )
rescue StandardError => e
  # Never let reporting affect the application. Visible only with THREE_DEBUG=1.
  warn "[three] reporting skipped: #{e.class}: #{e.message}" if ENV["THREE_DEBUG"]
end

# call_and_report runs one Messages call (your normal critical-path code) and then
# reports it via the off-path helper above.
#
# `params` is in Anthropic WIRE format (so the reported request body matches the API):
# it uses the key `system`. The Ruby SDK renames that param to `system_` (to avoid
# Ruby's Kernel#system), so we translate it only for the actual call — a concrete
# example of the reconstruction noted in the README.
def call_and_report(client, config, session_id, params)
  # request_id is NOT free-form: it must be a UUIDv7, generated NOW (at request start).
  # api3 validates the version and derives the request's start_time from the timestamp
  # embedded in the UUIDv7 — so it can't be a random string or a uuid_v4. One per call.
  request_id = Three.new_request_id

  sdk_params = params.dup
  sdk_params[:system_] = sdk_params.delete(:system) if sdk_params.key?(:system)

  begin
    # === CRITICAL PATH: your normal Anthropic call, unchanged by Three.dev. ===
    message = client.messages.create(**sdk_params)
  rescue Anthropic::Errors::APIStatusError => e
    # Report the failure too (still off the critical path), then surface the error.
    report_to_three(config, session_id, request_id, params,
                    { error: { type: e.class.name, message: e.message } },
                    (e.respond_to?(:status) ? e.status : 500))
    warn "Anthropic call failed: #{e.message}"
    exit 1
  end

  report_to_three(config, session_id, request_id, params, message, 200)
  message
end

# Pull the plain text out of a response message.
def answer_text(message)
  message.content.filter_map { |block| block.text if block.type.to_s == "text" }.join("\n")
end

# --- the conversation --------------------------------------------------------------

messages = [{ role: "user", content: "What's the weather like in Madrid right now?" }]

# Turn 1 — the model decides whether to call the tool. The full INFERENCE config is
# reported with this call.
message = call_and_report(client, config, session_id, INFERENCE.merge(messages: messages))

tool_uses = message.content.select { |block| block.type.to_s == "tool_use" }

if tool_uses.empty?
  # No tool needed — the model answered directly.
  puts answer_text(message)
else
  # Append the assistant's turn (clean blocks only — no SDK-internal fields). With
  # extended thinking enabled, the thinking blocks MUST be passed back verbatim
  # (including their signature) or the next call is rejected.
  assistant_content = message.content.filter_map do |block|
    case block.type.to_s
    when "text"              then { type: "text", text: block.text }
    when "tool_use"          then { type: "tool_use", id: block.id, name: block.name, input: block.input }
    when "thinking"          then { type: "thinking", thinking: block.thinking, signature: block.signature }
    when "redacted_thinking" then { type: "redacted_thinking", data: block.data }
    end
  end
  messages << { role: "assistant", content: assistant_content }

  # Execute each requested tool call and collect the results.
  tool_results = tool_uses.map do |tu|
    args = tu.input.respond_to?(:to_h) ? tu.input.to_h : tu.input
    location = args["location"] || args[:location]
    weather = get_weather(location)
    puts "[tool] get_weather(#{location.inspect}) -> #{weather.to_json}"
    { type: "tool_result", tool_use_id: tu.id, content: JSON.generate(weather) }
  end
  messages << { role: "user", content: tool_results }

  # Turn 2 — the model answers using the tool result. Reported as a second record,
  # carrying the same INFERENCE config.
  final = call_and_report(client, config, session_id, INFERENCE.merge(messages: messages))
  puts answer_text(final)
end
