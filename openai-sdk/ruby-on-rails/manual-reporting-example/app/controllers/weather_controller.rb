# frozen_string_literal: true

require "openai"

# WeatherController is a tiny weather assistant: a system prompt + a get_weather tool,
# exactly like the standalone OpenAI Ruby example — but as a Rails endpoint.
#
#   GET /weather?city=Madrid
#
# A tool-use conversation makes TWO LLM calls (the model asks for the tool, then answers
# using the result). BOTH are reported to Three.dev via `report` below — under the same
# session id (Current.session_id) — and reporting is off the request's critical path
# because Three.record_request enqueues an ActiveJob (see lib/three.rb).
class WeatherController < ApplicationController
  MODEL = "gpt-5.5"

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

  # Inference configuration — sent to the SDK AND reported verbatim to Three.dev (api3
  # parses it into the request's inference params). For OpenAI the system prompt is a
  # MESSAGE (role: "system"), not a param. Each turn merges in its own `messages`.
  INFERENCE = {
    model: MODEL,
    max_completion_tokens: 4096,
    tool_choice: "auto",
    tools: TOOLS
    # temperature/top_p are typically REJECTED by reasoning models like gpt-5.5 (400).
    # On a non-reasoning model (e.g. gpt-4o-mini) you'd add: temperature: 0.7, top_p: 0.95
  }.freeze

  def show
    city = params.fetch(:city, "Madrid, Spain")
    messages = [
      { role: "system", content: SYSTEM_PROMPT },
      { role: "user", content: "What's the weather like in #{city} right now?" }
    ]

    # Turn 1 — the model decides whether to call the tool.
    completion = call_and_report(INFERENCE.merge(messages: messages))
    reply = completion.choices.first.message
    tool_calls = reply.tool_calls || []

    if tool_calls.empty?
      return render(json: { answer: answer_text(completion) })
    end

    # Append the assistant's turn (clean fields only — no SDK internals).
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
      weather = get_weather(args["location"])
      messages << { role: "tool", tool_call_id: tc.id, content: JSON.generate(weather) }
    end

    # Turn 2 — the model answers using the tool result. Reported as a second record.
    final = call_and_report(INFERENCE.merge(messages: messages))
    render(json: { answer: answer_text(final) })
  rescue OpenAI::Errors::APIStatusError => e
    render(json: { error: e.message }, status: :bad_gateway)
  end

  private

  def client
    @client ||= OpenAI::Client.new(api_key: ENV.fetch("OPENAI_API_KEY"))
  end

  # Mock implementation. In a real app this would call a weather API.
  def get_weather(location)
    { location: location, temperature_c: 22, conditions: "Sunny" }
  end

  # Runs one Chat Completions call (the critical path) and then reports it off-path.
  def call_and_report(params)
    # request_id is NOT free-form: it must be a UUIDv7, generated NOW (at request start).
    # api3 derives the request start_time from the timestamp embedded in the UUIDv7.
    request_id = Three.new_request_id

    begin
      completion = client.chat.completions.create(**params)
    rescue OpenAI::Errors::APIStatusError => e
      report(request_id, params, { error: { type: e.class.name, message: e.message } },
             (e.respond_to?(:status) ? e.status : 500))
      raise
    end

    report(request_id, params, completion, 200)
    completion
  end

  # === The only change for Three.dev observability — the manual-reporting approach. ===
  # It is OFF the critical path: Three.record_request enqueues an ActiveJob and returns
  # immediately, so neither Three.dev's latency nor a Three.dev failure touches this
  # request. The rescue is a final safety net.
  def report(request_id, request_params, response_obj, status_code)
    Three.record_request(
      config: THREE_CONFIG, request_id: request_id, provider: "openai", path: "/v1/chat/completions",
      request_body: JSON.generate(request_params),
      response_body: JSON.generate(response_obj.respond_to?(:to_h) ? response_obj.to_h : response_obj),
      status_code: status_code, session_id: Current.session_id
    )
  rescue StandardError => e
    Rails.logger.warn("[three] reporting skipped: #{e.class}: #{e.message}")
  end

  def answer_text(completion)
    completion.choices.first.message.content.to_s
  end
end
