# Three.dev Observability for Anthropic SDK Go + Amazon Bedrock

Captures every LLM request/response and reports it to Three.dev — without a proxy, without changing your business logic.

## How it works

The observability layer is a single middleware added to your existing `anthropic.NewClient(...)` call. It intercepts every Bedrock request/response, then asynchronously POSTs the captured data to Three.dev. The middleware is fire-and-forget: it never blocks, never fails your LLM calls, and silently discards any reporting errors.

```go
client := anthropic.NewClient(
    bedrock.WithLoadDefaultConfig(ctx),
    option.WithMiddleware(observability.NewMiddleware(observability.Config{
        APIKey:      os.Getenv("THREE_API_KEY"),
        UseCaseSlug: "my-use-case",
    })),
)
```

That's the entire integration. All `client.Messages.New(...)` calls continue to work exactly as before.

## Prerequisites

- Go 1.21+
- AWS credentials with Bedrock Runtime access
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
| `THREE_ENDPOINT` | No | Three.dev API base URL (default: `https://api.three.dev`) |
| `AWS_BEARER_TOKEN_BEDROCK` | Yes | Bedrock API key — bearer token auth from the AWS Bedrock console |
| `AWS_REGION` | Yes | AWS region for the Bedrock Runtime endpoint |

## Running the example

```bash
task run
```

## Design

- **Non-blocking** — reporting runs in a background goroutine. Zero added latency on the LLM call path.
- **Crash-safe** — all panics and errors in the reporting path are silently recovered. A Three.dev outage has no effect on your application.
- **Transparent** — the middleware reads request/response bodies but replaces them with fresh readers. The SDK sees no difference.
- **Minimal** — one middleware line, three config fields, no changes to existing code.

## Middleware ordering

The observability middleware must be registered **after** `bedrock.WithLoadDefaultConfig` in the options list. The SDK builds the chain in reverse order, so the last-registered middleware is innermost — it sees the Bedrock-transformed request. This is required for correct data capture.

## Project structure

```
├── main.go                       # Example usage
├── observability/
│   └── middleware.go             # Config, NewMiddleware, payload structs, reporting
├── .env.example                  # Environment variable template
├── PLAN.md                       # Implementation plan for AI agents
├── go.mod
└── go.sum
```
