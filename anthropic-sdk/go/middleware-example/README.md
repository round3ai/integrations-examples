# Three.dev Observability for Anthropic SDK Go + Amazon Bedrock

Captures every LLM request/response and reports it to Three.dev — without a proxy, without changing your business logic.

## How it works

The observability layer is a single middleware added to your existing `anthropic.NewClient(...)` call. It intercepts every Bedrock request/response, then asynchronously POSTs the captured data to Three.dev. The middleware is fire-and-forget: it never blocks, never fails your LLM calls, and silently discards any reporting errors.

```go
apiKey      := os.Getenv("THREE_API_KEY")
useCaseSlug := os.Getenv("USE_CASE_SLUG")
endpoint    := os.Getenv("THREE_ENDPOINT")

client := anthropic.NewClient(
    bedrock.WithLoadDefaultConfig(ctx),
    // Must be registered last — the SDK builds the middleware chain in reverse,
    // so last = innermost. This ensures the middleware sees the Bedrock-transformed
    // request (/model/{model}/invoke) rather than the Anthropic API path (/v1/messages).
    option.WithMiddleware(observability.NewMiddleware(observability.Config{
        APIKey:      apiKey,
        UseCaseSlug: useCaseSlug,
        Endpoint:    endpoint,
    })),
)
```

That's the entire integration. All `client.Messages.New(...)` calls continue to work exactly as before.

## Session tracking

To group related requests into a single conversation on the Three.dev dashboard, attach a session ID to the context before each call. Use any string that identifies a session in your system — a user ID, conversation ID, HTTP request ID, or any other stable identifier. The middleware treats it as opaque and imposes no format constraints.

```go
// Use whatever makes sense as a session identifier in your system:
ctx = observability.WithSessionID(ctx, userID)           // tie to a user
ctx = observability.WithSessionID(ctx, conversationID)   // from your own DB
ctx = observability.WithSessionID(ctx, requestID)        // from an HTTP header
ctx = observability.WithSessionID(ctx, uuid.New().String()) // generate if none exists

message, err := client.Messages.New(ctx, ...)
```

The session ID is optional — if not set, the field is omitted from the payload and calls are reported without session grouping.

## Flushing reports

The middleware reports asynchronously — it fires a goroutine per request and returns immediately. Call `observability.Flush()` before your process exits to ensure all in-flight reports are delivered.

**CLI / short-lived program** — call it early in `main()` so it runs last:

```go
func main() {
    defer observability.Flush()
    // ... rest of setup and calls ...
}
```

**HTTP server** — call it in your graceful shutdown handler, after the server has stopped accepting new requests:

```go
server.Shutdown(ctx)
observability.Flush()
```

Skipping `Flush` won't crash your application, but any reports still in flight when the process exits will be lost.

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
| `USE_CASE_SLUG` | Yes | Three.dev use case identifier (from the dashboard) |
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
- **Minimal** — one middleware line, three config fields, optional per-call session tracking, no changes to existing code.

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
