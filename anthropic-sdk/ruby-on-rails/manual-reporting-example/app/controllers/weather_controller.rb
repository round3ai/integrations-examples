# frozen_string_literal: true

require "anthropic"

# WeatherController is a tiny weather assistant: a system prompt + a get_weather tool +
# reasoning, exactly like the standalone Ruby example — but as a Rails endpoint.
#
#   GET /weather?city=Madrid
#
# A tool-use conversation makes TWO LLM calls (the model asks for the tool, then answers
# using the result). BOTH are reported to Three.dev via `report` below — under the same
# session id (Current.session_id) — and reporting is off the request's critical path
# because Three.record_request enqueues an ActiveJob (see lib/three.rb).
class WeatherController < ApplicationController
  MODEL = "claude-opus-4-8"

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

  # Inference configuration — sent to the SDK AND reported verbatim to Three.dev (api3
  # parses it into the request's inference params). These are Anthropic WIRE field names;
  # the Ruby SDK uses the same names except `system` (-> `system_`), which `call_and_report`
  # translates. Each turn merges in its own `messages`.
  INFERENCE = {
    model: MODEL,
    max_tokens: 4096,
    thinking: { type: "adaptive" },            # extended thinking ("reasoning"), Opus 4.8+ API
    output_config: { effort: "medium" },       # reasoning effort: low | medium | high | xhigh | max
    tool_choice: { type: "auto" },
    metadata: { user_id: "demo-user-123" },
    system: SYSTEM_PROMPT,
    tools: TOOLS
  }.freeze

  def show
    city = params.fetch(:city, "Madrid, Spain")
    messages = [{ role: "user", content: "What's the weather like in #{city} right now?" }]

    # Turn 1 — the model decides whether to call the tool.
    message = call_and_report(INFERENCE.merge(messages: messages))
    tool_uses = message.content.select { |block| block.type.to_s == "tool_use" }

    if tool_uses.empty?
      return render(json: { answer: answer_text(message) })
    end

    # Append the assistant's turn (clean blocks only — thinking blocks must be passed
    # back verbatim, including their signature, or the next call is rejected).
    messages << { role: "assistant", content: clean_assistant_blocks(message) }

    # Execute each requested tool call and append the results.
    tool_uses.each do |tu|
      args = tu.input.respond_to?(:to_h) ? tu.input.to_h : tu.input
      weather = get_weather(args["location"] || args[:location])
      messages << {
        role: "user",
        content: [{ type: "tool_result", tool_use_id: tu.id, content: JSON.generate(weather) }]
      }
    end

    # Turn 2 — the model answers using the tool result. Reported as a second record.
    final = call_and_report(INFERENCE.merge(messages: messages))
    render(json: { answer: answer_text(final) })
  rescue Anthropic::Errors::APIStatusError => e
    render(json: { error: e.message }, status: :bad_gateway)
  end

  private

  def client
    @client ||= Anthropic::Client.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
  end

  # Mock implementation. In a real app this would call a weather API.
  def get_weather(location)
    { location: location, temperature_c: 22, conditions: "Sunny" }
  end

  # Runs one Messages call (the critical path) and then reports it off-path.
  def call_and_report(params)
    # request_id is NOT free-form: it must be a UUIDv7, generated NOW (at request start).
    # api3 derives the request start_time from the timestamp embedded in the UUIDv7.
    request_id = Three.new_request_id

    sdk_params = params.dup
    sdk_params[:system_] = sdk_params.delete(:system) if sdk_params.key?(:system)

    begin
      message = client.messages.create(**sdk_params)
    rescue Anthropic::Errors::APIStatusError => e
      report(request_id, params, { error: { type: e.class.name, message: e.message } },
             (e.respond_to?(:status) ? e.status : 500))
      raise
    end

    report(request_id, params, message, 200)
    message
  end

  # === The only change for Three.dev observability — the manual-reporting approach. ===
  # It is OFF the critical path: Three.record_request enqueues an ActiveJob and returns
  # immediately, so neither Three.dev's latency nor a Three.dev failure touches this
  # request. The rescue is a final safety net.
  def report(request_id, request_params, response_obj, status_code)
    Three.record_request(
      config: THREE_CONFIG, request_id: request_id, provider: "anthropic", path: "/v1/messages",
      request_body: JSON.generate(request_params),
      response_body: JSON.generate(response_obj.respond_to?(:to_h) ? response_obj.to_h : response_obj),
      status_code: status_code, session_id: Current.session_id
    )
  rescue StandardError => e
    Rails.logger.warn("[three] reporting skipped: #{e.class}: #{e.message}")
  end

  def clean_assistant_blocks(message)
    message.content.filter_map do |block|
      case block.type.to_s
      when "text"              then { type: "text", text: block.text }
      when "tool_use"          then { type: "tool_use", id: block.id, name: block.name, input: block.input }
      when "thinking"          then { type: "thinking", thinking: block.thinking, signature: block.signature }
      when "redacted_thinking" then { type: "redacted_thinking", data: block.data }
      end
    end
  end

  def answer_text(message)
    message.content.filter_map { |block| block.text if block.type.to_s == "text" }.join("\n")
  end
end
