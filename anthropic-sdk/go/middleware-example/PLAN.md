# Three.dev Observability Middleware for Anthropic SDK Go + Amazon Bedrock

## Goal

Add non-blocking observability to any Go application that uses the Anthropic SDK Go with Amazon Bedrock Runtime. Every LLM request/response is asynchronously captured and reported to the Three.dev API. The integration must:

- Be a single `option.WithMiddleware(...)` line added to the existing `anthropic.NewClient(...)` call
- Never be in the critical path — all reporting is fire-and-forget
- Never crash or degrade the application, even if Three.dev is unreachable
- Require zero changes to existing business logic (no changes to `Messages.New` calls, prompt construction, response handling, etc.)

## Prerequisites

- Go 1.21+ project using `github.com/anthropics/anthropic-sdk-go` with `bedrock.WithConfig` or `bedrock.WithLoadDefaultConfig`
- A Three.dev API key (`r3_sk_...`)
- A Three.dev use case slug (configured in the Three.dev dashboard)

## Step 1: Add dependencies

Add `github.com/google/uuid` to the project. This is used to generate UUIDv7 identifiers for each reported request.

```
go get github.com/google/uuid
```

The Anthropic SDK Go (`github.com/anthropics/anthropic-sdk-go`) and the AWS SDK v2 are already present in the project.

## Step 2: Create the observability package

Create a new package at `observability/middleware.go` (relative to the module root). This is a single file containing the full implementation.

### 2.1 Config struct

Define a `Config` struct with three fields:

| Field | Type | Required | Description |
|---|---|---|---|
| `APIKey` | `string` | Yes | Three.dev API key (`r3_sk_...`). Sent as `Authorization: Bearer <key>`. |
| `UseCaseSlug` | `string` | Yes | Three.dev use case identifier. |
| `Endpoint` | `string` | No | Three.dev API base URL. Default: `https://api.three.dev`. |

### 2.2 NewMiddleware constructor

`NewMiddleware(cfg Config) option.Middleware` — the only public function. Returns an `option.Middleware` compatible with the Anthropic SDK Go.

**Middleware ordering is critical.** The middleware must be registered AFTER `bedrock.WithConfig` or `bedrock.WithLoadDefaultConfig` in the client options list. The Anthropic SDK builds the middleware chain in reverse registration order, so the last-registered middleware is innermost — meaning it runs after the Bedrock middleware has already transformed the request. This is required so the captured request path is `/model/{model}/invoke` (the Bedrock wire format), not `/v1/messages` (the Anthropic API format).

Correct registration order:

```go
client := anthropic.NewClient(
    bedrock.WithLoadDefaultConfig(ctx),                         // outermost
    option.WithMiddleware(observability.NewMiddleware(cfg)),     // innermost
)
```

### 2.3 Middleware logic

The middleware function receives `(*http.Request, option.MiddlewareNext)` and returns `(*http.Response, error)`.

1. **Before the call:**
   - Generate a UUIDv7 request ID using `github.com/google/uuid`
   - Record start time
   - Drain the request body (read all bytes), then replace `r.Body` with a new `io.NopCloser(bytes.NewReader(...))` so downstream handlers can still read it
   - Capture `r.URL.Path` and request `Content-Type` header

2. **Execute the call:** `res, err := next(r)`

3. **After the call:**
   - Record end time and any error
   - If no error: drain the response body (same read-and-replace pattern), capture status code and response `Content-Type`

4. **Report asynchronously:** increment the package-level `sync.WaitGroup`, then launch `go func() { defer wg.Done(); safeReport(cfg, capturedData) }()`

5. **Return the original `(res, err)` unmodified.** The middleware is transparent.

Extract a `drainBody(rc io.ReadCloser) ([]byte, io.ReadCloser)` helper to avoid duplicating the read-close-replace pattern for request and response bodies. It should handle `nil` and `http.NoBody` gracefully.

### 2.4 Internal captured struct

A private struct holding all data from one request/response cycle:

- `requestID` (string) — UUIDv7
- `sessionID` (string) — optional, read from context via `WithSessionID`
- `startTime`, `endTime` (time.Time)
- `path` (string) — the URL path
- `statusCode` (int)
- `reqBody`, `resBody` ([]byte)
- `reqContentType`, `resContentType` (string)
- `callErr` (error) — non-nil if the call itself failed

### 2.5 Reporting

**`safeReport(cfg, captured)`** — wraps `reportToAPI` in `defer func() { recover() }()`. This is the only goroutine entry point. All panics and errors are swallowed. Reporting must never affect the calling application.

**`reportToAPI(cfg, captured)`** — builds the JSON payload and POSTs it to `{cfg.Endpoint}/api/v1/request`.

- Use a package-level `http.Client` with a 10-second timeout
- Set headers: `Content-Type: application/json`, `Authorization: Bearer <cfg.APIKey>`
- Discard the response body (drain to `io.Discard`)
- Return silently on any error (connection refused, timeout, non-2xx, etc.)

### 2.6 Payload structs

Define typed Go structs for the JSON payload instead of using `map[string]any`. Use `json:"..."` tags. Use `omitempty` for optional fields.

**`recordRequest`** (top-level):

| JSON field | Type | Value |
|---|---|---|
| `id` | string | The UUIDv7 request ID |
| `use_case_slug` | string | From `cfg.UseCaseSlug` |
| `provider` | string | Always `"amazon_bedrock_runtime"` |
| `input` | object | See `recordInput` below |
| `output` | object | See `recordOutput` below |

**`recordInput`**:

| JSON field | Type | Value |
|---|---|---|
| `content` | string | Base64-encoded request body |
| `path` | string | The URL path (e.g., `/model/anthropic.claude-sonnet-4-6/invoke`) |
| `content_type` | string | Request Content-Type header. Omit if empty. |

**`recordOutput`**:

| JSON field | Type | Value |
|---|---|---|
| `content` | string | Base64-encoded response body |
| `status_code` | int | HTTP status code |
| `received_at` | string | End time in RFC3339Nano UTC |
| `content_chunks_received_at` | []string | Always empty `[]` (reserved for streaming) |
| `content_type` | string | Response Content-Type header. Omit if empty. |

Add `session_id` (string, `omitempty`) to `recordRequest` — omitted when blank so calls without a session ID are unaffected.

Use `encoding/base64` (StdEncoding) for body encoding.

### 2.7 Package-level Flush

Declare a package-level `var wg sync.WaitGroup`. Expose one exported function:

```go
func Flush() { wg.Wait() }
```

This allows callers to block until all in-flight reporting goroutines complete, which is required before process exit. Document two usage patterns:

- **CLI / short-lived program**: `defer observability.Flush()` early in `main()`
- **HTTP server graceful shutdown**: call `observability.Flush()` in the shutdown handler after `server.Shutdown()`, before the process exits

Skipping `Flush` will not crash the application, but any reports still in flight when the process exits will be lost.

### 2.8 Per-call session ID

Define a public `WithSessionID(ctx context.Context, sessionID string) context.Context` function that stores the session ID in the context using an unexported package-level key type (to avoid collisions with other packages).

```go
type contextKey struct{}

func WithSessionID(ctx context.Context, sessionID string) context.Context {
    return context.WithValue(ctx, contextKey{}, sessionID)
}
```

The middleware reads it from `r.Context()` before the call and stores it in the `captured` struct.

The session ID is **any string** that identifies a conversation or session in the customer's system. The middleware treats it as opaque and imposes no format constraints. Customers should use whatever natural identifier they already have:

- A user ID — to group all requests from one user
- A conversation ID — from their own database
- An HTTP request/trace ID — propagated from an upstream service
- A generated UUID — when no natural identifier exists

The caller sets it once per conversation and passes the enriched context to each `client.Messages.New(ctx, ...)` call in that session. When no session ID is set, the field is omitted from the payload.

## Step 3: Integrate into existing code

Locate the place where `anthropic.NewClient(...)` is called. Add two changes:

1. Import the observability package
2. Add `option.WithMiddleware(observability.NewMiddleware(...))` as the **last** option in the `NewClient` call

Example — before:

```go
client := anthropic.NewClient(
    bedrock.WithLoadDefaultConfig(ctx),
)
```

After:

```go
apiKey      := os.Getenv("THREE_API_KEY")
useCaseSlug := os.Getenv("USE_CASE_SLUG")
endpoint    := os.Getenv("THREE_ENDPOINT")

client := anthropic.NewClient(
    bedrock.WithLoadDefaultConfig(ctx),
    option.WithMiddleware(observability.NewMiddleware(observability.Config{
        APIKey:      apiKey,
        UseCaseSlug: useCaseSlug,
        Endpoint:    endpoint,
    })),
)
```

Add `defer observability.Flush()` early in the function that initialises the client. In a CLI this belongs at the top of `main()`. In an HTTP server it belongs in the graceful shutdown handler, called after `server.Shutdown()`.

No other changes are needed to the client setup. To enable session tracking, attach a session ID to the context before each call:

```go
// Use any stable identifier from your system:
ctx = observability.WithSessionID(ctx, userID)           // user ID
ctx = observability.WithSessionID(ctx, conversationID)   // conversation ID
ctx = observability.WithSessionID(ctx, uuid.New().String()) // generate if none exists

message, err := client.Messages.New(ctx, ...)
```

Session tracking is optional — calls without a session ID are reported normally, just without session grouping.

## Step 4: Environment configuration

Two required environment variables, two optional:

| Variable | Required | Description |
|---|---|---|
| `THREE_API_KEY` | Yes | Three.dev API key (`r3_sk_...`) |
| `USE_CASE_SLUG` | Yes | Three.dev use case identifier (from the dashboard) |
| `THREE_ENDPOINT` | No | Override the Three.dev API base URL (default: `https://api.three.dev`) |
| `AWS_BEARER_TOKEN_BEDROCK` | Yes | Bedrock API key for bearer token auth |
| `AWS_REGION` | Yes | AWS region for the Bedrock Runtime endpoint |

## Design constraints

- **Non-blocking**: All reporting runs in a goroutine. The middleware returns immediately after dispatching the report.
- **Crash-safe**: `safeReport` catches all panics via `defer recover()`. A failure in reporting (network error, malformed payload, etc.) is silently discarded.
- **Transparent**: The middleware reads request/response bodies but always replaces them with fresh readers. Downstream handlers and the SDK see no difference.
- **No new dependencies on the call path**: The only external call added is the async POST to Three.dev, which runs in a separate goroutine with its own HTTP client and timeout.
