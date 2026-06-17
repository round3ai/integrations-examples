# Three.dev Integration Examples

Practical, runnable examples showing how to integrate Three.dev observability into your AI applications — across different languages, SDKs, and cloud providers.

Each example is self-contained. Clone the repo, pick the example closest to your stack, follow its README, and you'll have Three.dev capturing your LLM traffic in minutes.

---

## Examples

### Anthropic SDK (Go) + Amazon Bedrock

**[`anthropic-sdk/go/middleware-example`](./anthropic-sdk/go/middleware-example)**

Adds Three.dev observability to the official [Anthropic Go SDK](https://github.com/anthropics/anthropic-sdk-go) when routing through **Amazon Bedrock**. A single middleware line captures every request and response and reports it to Three.dev asynchronously — zero added latency, no proxy, no changes to your business logic.

| | |
|---|---|
| **Language** | Go 1.21+ |
| **LLM Provider** | Amazon Bedrock |
| **Integration style** | SDK middleware |
| **What you need** | Three.dev API key · AWS Bedrock credentials |

```go
client := anthropic.NewClient(
    bedrock.WithLoadDefaultConfig(ctx),
    option.WithMiddleware(observability.NewMiddleware(observability.Config{
        APIKey:      os.Getenv("THREE_API_KEY"),
        UseCaseSlug: "my-use-case",
    })),
)
```

---

### Anthropic SDK (Ruby) — Manual Reporting

**[`anthropic-sdk/ruby/manual-reporting-example`](./anthropic-sdk/ruby/manual-reporting-example)**

Adds Three.dev observability to the official [Anthropic Ruby SDK](https://github.com/anthropics/anthropic-sdk-ruby) without a proxy and without patching the SDK. The Ruby SDK has no middleware hook, so you call it normally and hand each request/response to `Three.record_request(...)`, which reports to Three.dev asynchronously — off your inference critical path.

| | |
|---|---|
| **Language** | Ruby 3.3+ |
| **LLM Provider** | Anthropic |
| **Integration style** | Manual reporting (no proxy, no patching) |
| **What you need** | Three.dev API key · Anthropic API key |

```ruby
message = client.messages.create(**params)            # your normal call, unchanged

Three.record_request(
  config: config, request_id: request_id, provider: "anthropic", path: "/v1/messages",
  request_body:  JSON.generate(params),
  response_body: JSON.generate(message.to_h),
  status_code:   200, session_id: session_id,
)
```

---

### OpenAI SDK (Ruby) — Manual Reporting

**[`openai-sdk/ruby/manual-reporting-example`](./openai-sdk/ruby/manual-reporting-example)**

The same manual-reporting pattern for the official [OpenAI Ruby SDK](https://github.com/openai/openai-ruby). Call the SDK as usual, then report the request/response to Three.dev asynchronously — no proxy, no monkey-patching.

| | |
|---|---|
| **Language** | Ruby 3.3+ |
| **LLM Provider** | OpenAI |
| **Integration style** | Manual reporting (no proxy, no patching) |
| **What you need** | Three.dev API key · OpenAI API key |

```ruby
completion = client.chat.completions.create(**params) # your normal call, unchanged

Three.record_request(
  config: config, request_id: request_id, provider: "openai", path: "/v1/chat/completions",
  request_body:  JSON.generate(params),
  response_body: JSON.generate(completion.to_h),
  status_code:   200, session_id: session_id,
)
```

---

### Anthropic SDK (Ruby on Rails) — Manual Reporting

**[`anthropic-sdk/ruby-on-rails/manual-reporting-example`](./anthropic-sdk/ruby-on-rails/manual-reporting-example)**

The same weather assistant as the standalone Ruby example, wired the Rails way: a minimal API-only app where a controller calls the SDK and reports each call to Three.dev via **ActiveJob** — off the request's critical path. Shows the Rails-idiomatic pieces: an initializer for config, `lib/three.rb`, an ActiveJob reporter, and `CurrentAttributes` for per-request session id.

| | |
|---|---|
| **Language** | Ruby on Rails (Ruby 3.3+) |
| **LLM Provider** | Anthropic |
| **Integration style** | Manual reporting via ActiveJob (no proxy, no patching) |
| **What you need** | Three.dev API key · Anthropic API key |

```ruby
# app/controllers/weather_controller.rb
message = client.messages.create(**sdk_params)         # your normal call, unchanged
Three.record_request(                                  # enqueues ActiveJob, returns immediately
  config: THREE_CONFIG, request_id: request_id, provider: "anthropic", path: "/v1/messages",
  request_body: JSON.generate(params), response_body: JSON.generate(message.to_h),
  status_code: 200, session_id: Current.session_id,
)
```

---

### OpenAI SDK (Ruby on Rails) — Manual Reporting

**[`openai-sdk/ruby-on-rails/manual-reporting-example`](./openai-sdk/ruby-on-rails/manual-reporting-example)**

The same Rails wiring for the official OpenAI Ruby SDK: a controller calls `chat.completions`, and each call is reported to Three.dev via ActiveJob, off the request's critical path.

| | |
|---|---|
| **Language** | Ruby on Rails (Ruby 3.3+) |
| **LLM Provider** | OpenAI |
| **Integration style** | Manual reporting via ActiveJob (no proxy, no patching) |
| **What you need** | Three.dev API key · OpenAI API key |

```ruby
# app/controllers/weather_controller.rb
completion = client.chat.completions.create(**params)  # your normal call, unchanged
Three.record_request(                                  # enqueues ActiveJob, returns immediately
  config: THREE_CONFIG, request_id: request_id, provider: "openai", path: "/v1/chat/completions",
  request_body: JSON.generate(params), response_body: JSON.generate(completion.to_h),
  status_code: 200, session_id: Current.session_id,
)
```

---

### OpenAI SDK (TypeScript) + Live Experiments

**[`openai-sdk/typescript/live-experiment-example`](./openai-sdk/typescript/live-experiment-example)**

Runs a Three.dev **Live Experiment** across a multi-turn, tool-using conversation with the official [OpenAI JS SDK](https://github.com/openai/openai-node). The OpenAI client is pointed at the Three.dev gateway; before each request the app calls `/assign` to pick the active variant, tags requests at the session and request level, and reports a quality metric at the end — the full assign → run → measure loop.

| | |
|---|---|
| **Language** | TypeScript (Node.js 18+) |
| **LLM Provider** | OpenAI (via the Three.dev gateway) |
| **Integration style** | Gateway proxy + `/assign` |
| **What you need** | Three.dev API key · use case with OpenAI configured |

```ts
const client = new OpenAI({
  apiKey: process.env.THREE_API_KEY,        // r3_sk_... — gateway holds the OpenAI key
  baseURL: "https://gate.three.dev/v1",
  defaultHeaders: { "X-Three-Use-Case": useCaseSlug, "X-Three-AI-Provider": "openai" },
});

const assignment = await assign(cfg);       // pick the variant for this request
const variant = paramsFromAssignment(assignment, defaultModel); // { body, headers }
await client.chat.completions.create(
  { ...variant.body, messages, tools },     // model + chat params
  { headers: variant.headers },             // routing (e.g. provider)
);
```

---

## Getting started

Every example has its own README with step-by-step instructions. The general flow is:

1. **Get a Three.dev API key** — log in at [three.dev](https://three.dev) and create an API key (`r3_sk_...`).
2. **Create a use-case slug** — in the Three.dev dashboard, create a use case and copy its slug.
3. **Choose an example** — navigate to the relevant folder and follow its README.
4. **Set environment variables** — copy `.env.example` to `.env` and fill in your credentials.
5. **Run** — each example includes a one-command runner (usually `task run` or `go run .`).

---

## Repository structure

```
integrations-examples/
├── anthropic-sdk/
│   ├── go/
│   │   └── middleware-example/         # Anthropic Go SDK + Amazon Bedrock (observability)
│   ├── ruby/
│   │   └── manual-reporting-example/   # Anthropic Ruby SDK + manual reporting (no proxy)
│   └── ruby-on-rails/
│       └── manual-reporting-example/   # Anthropic Ruby SDK on Rails + manual reporting (ActiveJob)
└── openai-sdk/
    ├── ruby/
    │   └── manual-reporting-example/   # OpenAI Ruby SDK + manual reporting (no proxy)
    ├── ruby-on-rails/
    │   └── manual-reporting-example/   # OpenAI Ruby SDK on Rails + manual reporting (ActiveJob)
    └── typescript/
        └── live-experiment-example/    # OpenAI JS SDK + Three.dev Live Experiments
```

More examples are on the way. Check back soon or open an issue to request a specific language, SDK, or provider.

---

## Prerequisites (common across examples)

- A [Three.dev](https://three.dev) account and API key
- Credentials for the LLM provider used by the example you choose (see each example's README)

---

## Contributing

Found a bug or want to add an example for your stack? PRs are welcome. Please keep each example self-contained with its own README and `.env.example`.
