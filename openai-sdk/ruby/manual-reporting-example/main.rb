# frozen_string_literal: true

# main.rb — OpenAI Ruby SDK + Three.dev manual reporting, with a system prompt and a
# tool call (a tiny weather assistant).
#
# You call the OpenAI SDK exactly as usual (your own key, straight to OpenAI), then hand
# each request/response to Three.record_request. A tool-use conversation makes TWO LLM
# calls — (1) the model asks to call get_weather, (2) it answers using the tool result —
# and BOTH are reported, under the same session_id, so the whole exchange is observable
# on the dashboard. See three.rb for the reporter and README.md for the rationale.

require "dotenv/load"
require "openai"
require "json"
require "securerandom"

require_relative "three"

MODEL = "gpt-5.5"

config = Three::Config.new(
  api_key: ENV.fetch("THREE_API_KEY"),
  use_case_slug: ENV.fetch("USE_CASE_SLUG"),
  endpoint: ENV["THREE_ENDPOINT"]
)

# Deliver any in-flight reports before the process exits. In a long-running Rails
# server, call Three.flush from your graceful-shutdown hook instead.
at_exit { Three.flush }

# Your own OpenAI client — calls go DIRECTLY to OpenAI, not through Three.dev.
client = OpenAI::Client.new(api_key: ENV.fetch("OPENAI_API_KEY"))

# A session ID groups all calls of this conversation into one thread on the dashboard.
# It is OPAQUE — it can be WHATEVER stable identifier you already have: a user ID, a
# conversation ID, an HTTP request ID, etc. No format constraints. It's also optional;
# omit it and calls are reported without grouping. Here we just generate a UUID.
# (Contrast with request_id below, which is NOT free-form — see call_and_report.)
session_id = SecureRandom.uuid

# --- the tool the model can call ---------------------------------------------------

# OpenAI tool schema (note the `type: "function"` wrapper and `parameters`). `params`
# below double as the reconstructed request body we report, so we keep them in OpenAI
# WIRE format throughout — for OpenAI the SDK param names match the wire names exactly.
TOOLS = [
  {
    type: "function",
    function: {
      name: "get_weather",
      description: "Get the current weather for a location. Returns temperature and conditions.",
      parameters: {
        type: "object",
        properties: {
          location: { type: "string", description: "City and region, e.g. 'Madrid, Spain'" }
        },
        required: ["location"]
      }
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
# in the dashboard's request config (api3 parses these into inference_params). For OpenAI
# the system prompt is a MESSAGE (role: "system"), not a param. Each turn merges in its
# own `messages`.
INFERENCE = {
  model: MODEL,
  max_completion_tokens: 4096,
  tool_choice: "auto",              # let the model decide whether to call a tool
  tools: TOOLS

  # Notes:
  # - temperature/top_p are typically REJECTED by reasoning models like gpt-5.5 (400).
  #   On a non-reasoning model (e.g. gpt-4o-mini) you'd add: temperature: 0.7, top_p: 0.95
  # - metadata: { user_id: "u_123" } is also reported (requires store: true).
}.freeze

# --- the SDK-call + report helper --------------------------------------------------

# ============================================================================
# THIS is the only change you add to get Three.dev observability — the manual-
# reporting approach. You keep calling the SDK exactly as before; after each call
# you hand the request + response to Three.record_request. There is no proxy and no
# SDK patching.
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
    config: config, request_id: request_id, provider: "openai", path: "/v1/chat/completions",
    request_body: JSON.generate(request_params),
    response_body: JSON.generate(response_obj.respond_to?(:to_h) ? response_obj.to_h : response_obj),
    status_code: status_code, session_id: session_id
  )
rescue StandardError => e
  # Never let reporting affect the application. Visible only with THREE_DEBUG=1.
  warn "[three] reporting skipped: #{e.class}: #{e.message}" if ENV["THREE_DEBUG"]
end

# call_and_report runs one Chat Completions call (your normal critical-path code) and
# then reports it via the off-path helper above. For OpenAI the params are already in
# wire format, so (unlike Anthropic) there is no param renaming to do.
def call_and_report(client, config, session_id, params)
  # request_id is NOT free-form: it must be a UUIDv7, generated NOW (at request start).
  # api3 validates the version and derives the request's start_time from the timestamp
  # embedded in the UUIDv7 — so it can't be a random string or a uuid_v4. One per call.
  request_id = Three.new_request_id

  begin
    # === CRITICAL PATH: your normal OpenAI call, unchanged by Three.dev. ===
    completion = client.chat.completions.create(**params)
  rescue OpenAI::Errors::APIStatusError => e
    # Report the failure too (still off the critical path), then surface the error.
    report_to_three(config, session_id, request_id, params,
                    { error: { type: e.class.name, message: e.message } },
                    (e.respond_to?(:status) ? e.status : 500))
    warn "OpenAI call failed: #{e.message}"
    exit 1
  end

  report_to_three(config, session_id, request_id, params, completion, 200)
  completion
end

# Pull the assistant's text out of a completion.
def answer_text(completion)
  completion.choices.first.message.content.to_s
end

# --- the conversation --------------------------------------------------------------

# For OpenAI the system prompt is the first message, not a separate param.
messages = [
  { role: "system", content: SYSTEM_PROMPT },
  { role: "user", content: "What's the weather like in Madrid right now?" }
]

# Turn 1 — the model decides whether to call the tool. The full INFERENCE config is
# reported with this call.
completion = call_and_report(client, config, session_id, INFERENCE.merge(messages: messages))
reply = completion.choices.first.message
tool_calls = reply.tool_calls || []

if tool_calls.empty?
  # No tool needed — the model answered directly.
  puts answer_text(completion)
else
  # Append the assistant's turn (clean blocks only — no SDK-internal fields).
  messages << {
    role: "assistant",
    content: reply.content,
    tool_calls: tool_calls.map do |tc|
      { id: tc.id, type: "function",
        function: { name: tc.function.name, arguments: tc.function.arguments } }
    end
  }

  # Execute each requested tool call and append a `tool` message with the result.
  tool_calls.each do |tc|
    args = JSON.parse(tc.function.arguments) rescue {}
    location = args["location"]
    weather = get_weather(location)
    puts "[tool] get_weather(#{location.inspect}) -> #{weather.to_json}"
    messages << { role: "tool", tool_call_id: tc.id, content: JSON.generate(weather) }
  end

  # Turn 2 — the model answers using the tool result. Reported as a second record,
  # carrying the same INFERENCE config.
  final = call_and_report(client, config, session_id, INFERENCE.merge(messages: messages))
  puts answer_text(final)
end
