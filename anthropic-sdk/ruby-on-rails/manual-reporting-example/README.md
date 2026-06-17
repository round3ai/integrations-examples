# Three.dev Observability for the Anthropic Ruby SDK on Rails (manual reporting)

The same weather assistant as the [standalone Ruby example](../../ruby/manual-reporting-example), wired the **Rails-idiomatic** way: a minimal API-only Rails app that reports each LLM call to Three.dev **without a proxy and without patching the SDK** — and off the request's critical path via **ActiveJob**.

## How it works

You call the Anthropic SDK exactly as usual in your controller, then hand the request/response to `Three.record_request`. That method builds the api3 `RecordRequest` payload and **enqueues an ActiveJob** (`ThreeReportJob`) to POST it — so the web request never waits on Three.dev and is never affected by a Three.dev failure.

The Rails-specific pieces (everything else is identical to the standalone example):

| Concern | Where |
|---|---|
| Build the `Three::Config` once | `config/initializers/three.rb` |
| The reporter (`record_request` / `deliver`) | `lib/three.rb` |
| Off-path async dispatch | `app/jobs/three_report_job.rb` (ActiveJob) |
| Per-request `session_id` propagation | `app/models/current.rb` (`CurrentAttributes`) + `app/controllers/application_controller.rb` |
| The call site (system prompt + tool + reasoning) | `app/controllers/weather_controller.rb` |

## Async / critical-path isolation

- **Off the critical path** — `Three.record_request` enqueues and returns immediately; the HTTPS POST runs in `ThreeReportJob`, not in the web request.
- **Failure-isolated** — the job retries a few times then gives up silently (`retry_on … { }`), and the controller wraps reporting in a rescue. A Three.dev outage cannot affect the response.
- **Adapter** — this example uses ActiveJob's in-process `:async` adapter (set in `config/application.rb`) so it runs with **no Redis/Sidekiq**. For production durability (survives deploys, real retries), switch `config.active_job.queue_adapter` to `:sidekiq`.

## Session tracking

`ApplicationController` sets `Current.session_id = request.request_id` per request, and the controller passes it to every `Three.record_request`. `session_id` is opaque — swap `request.request_id` for `current_user.id`, a conversation id, or any stable identifier.

## Prerequisites

- Ruby **3.3+** (for `SecureRandom.uuid_v7`)
- An Anthropic API key (`sk-ant-...`)
- A Three.dev API key (`r3_sk_...`) and a use case slug

## Setup & run

```bash
cp .env.example .env     # set THREE_API_KEY, USE_CASE_SLUG, ANTHROPIC_API_KEY
task run                 # checks Ruby, bundles, starts the server on :3000
```

Then, in another terminal:

```bash
curl "http://localhost:3000/weather?city=Madrid"
# => {"answer":"It's sunny and 22°C in Madrid right now."}
```

Watch the server logs for `[three] api3 responded 200` — one line per LLM call (two for a tool-use conversation), delivered by the background job. Then check the Three.dev dashboard for the requests grouped under the request's session id.

## Project structure

```
├── bin/rails                           # Rails CLI entrypoint (needed by `rails server`)
├── app/
│   ├── controllers/
│   │   ├── application_controller.rb   # sets Current.session_id per request
│   │   └── weather_controller.rb       # system prompt + get_weather tool + reasoning
│   ├── jobs/
│   │   ├── application_job.rb
│   │   └── three_report_job.rb         # off-path delivery of one RecordRequest
│   └── models/
│       └── current.rb                  # CurrentAttributes: session_id
├── config/
│   ├── application.rb                  # api_only, ActiveJob :async adapter
│   ├── initializers/three.rb           # builds THREE_CONFIG, requires lib/three.rb
│   └── routes.rb                       # GET /weather
├── lib/
│   └── three.rb                        # the reporter (record_request, deliver)
├── Gemfile                             # rails + anthropic + dotenv-rails
└── Taskfile.yml                        # task run
```
