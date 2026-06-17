# Three.dev Observability for the Anthropic Ruby SDK (manual reporting)

Captures every LLM request/response and reports it to Three.dev — **without a proxy and without monkey-patching the SDK**. You keep calling the Anthropic SDK exactly as you do today; you just hand each request/response to `Three.record_request(...)` afterward.

## How it works

`three.rb` exposes a tiny reporter. After each call you pass the request params and the response; it builds the Three.dev `RecordRequest` payload and POSTs it to api3 on a **background thread**. Reporting is fire-and-forget: it never blocks your call, never raises into your code, and silently discards any error.

```ruby
require "anthropic"
require_relative "three"

config = Three::Config.new(
  api_key: ENV["THREE_API_KEY"],        # r3_sk_...
  use_case_slug: ENV["USE_CASE_SLUG"],
)

client     = Anthropic::Client.new(api_key: ENV["ANTHROPIC_API_KEY"]) # your key, direct to Anthropic
session_id = SecureRandom.uuid
request_id = Three.new_request_id        # generate at request START (api3 derives start_time from it)

params  = { model: "claude-opus-4-8", max_tokens: 1024,
            messages: [{ role: "user", content: "Say hello." }] }
message = client.messages.create(**params)

Three.record_request(
  config: config, request_id: request_id, provider: "anthropic", path: "/v1/messages",
  request_body:  JSON.generate(params),
  response_body: JSON.generate(message.to_h),
  status_code:   200, session_id: session_id,
)
```

That's the whole integration. Your `client.messages.create(...)` calls are unchanged — Three.dev never sees your Anthropic key or your traffic.

## Session tracking

Pass a `session_id` to group related requests into a single conversation on the Three.dev dashboard. Use any string stable across the turns of a conversation — a user ID, a conversation ID, an HTTP request ID, or a generated UUID. It's optional; omit it and requests are reported without session grouping.

## Flushing reports

Reporting runs on background threads. Call `Three.flush` before your process exits so in-flight reports aren't lost.

- **CLI / short-lived script** — `at_exit { Three.flush }` (this example does that in `main.rb`).
- **Rails server** — call `Three.flush` from your graceful-shutdown hook, after the server stops accepting new requests.

Skipping `flush` won't crash anything, but reports still in flight at exit are lost.

## A note on fidelity (important)

Because there's no SDK hook, the reported `request_body`/`response_body` are **reconstructed** from the SDK params (`JSON.generate(params)`) and the response object (`message.to_h`) — they are **not** the original wire bytes. api3 parses these to derive tokens/cost/model, and the SDK's typed models mirror the API closely, so fidelity is high — but it is a reconstruction, not byte-exact capture. This is the trade-off for a no-proxy, no-monkey-patch integration.

## Error reporting

To observe failures too, report them in your rescue block:

```ruby
rescue Anthropic::Errors::APIStatusError => e
  Three.record_request(
    config: config, request_id: request_id, provider: "anthropic", path: "/v1/messages",
    request_body:  JSON.generate(params),
    response_body: JSON.generate(error: { type: e.class.name, message: e.message }),
    status_code:   e.status, session_id: session_id,
  )
end
```

## Prerequisites

- Ruby **3.3+** (for `SecureRandom.uuid_v7`)
- An Anthropic API key (`sk-ant-...`)
- A Three.dev API key (`r3_sk_...`)
- A use case slug configured in the Three.dev dashboard

## Setup

```bash
cp .env.example .env
# Edit .env with your credentials
```

| Variable | Required | Description |
|---|---|---|
| `THREE_API_KEY` | Yes | Three.dev API key (`r3_sk_...`) |
| `USE_CASE_SLUG` | Yes | Three.dev use case identifier (from the dashboard) |
| `ANTHROPIC_API_KEY` | Yes | Your Anthropic API key (`sk-ant-...`) — used directly against Anthropic |
| `THREE_ENDPOINT` | No | api3 base URL (default: `https://api.three.dev`) |
| `THREE_DEBUG` | No | Set to `1` to log api3 reporting status/errors to stderr |

## Running the example

```bash
task run
```

`task run` is self-contained: it checks your Ruby version (>= 3.3), creates `.env` from the template if missing, runs `bundle install`, then runs `main.rb`. If your Ruby is too old it stops early with install instructions (it can't install a Ruby toolchain for you).

Equivalent manual steps: `bundle install && bundle exec ruby main.rb`.

## Design

- **Non-blocking** — each report runs on a background thread. Zero added latency on the LLM call path.
- **Crash-safe** — every error in the reporting path is swallowed. A Three.dev outage has no effect on your application.
- **No proxy, no patching** — your SDK calls are untouched; nothing intercepts your traffic.
- **Minimal** — one `Three.record_request(...)` call per request, three config fields, optional session tracking.

## Project structure

```
├── main.rb            # Example usage (Anthropic SDK + Three.record_request)
├── three.rb           # The Three.dev reporter (Config, record_request, flush)
├── Gemfile            # anthropic + dotenv
├── .env.example       # Environment variable template
└── Taskfile.yml       # task setup / run
```
