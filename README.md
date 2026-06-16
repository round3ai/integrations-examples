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
│   └── go/
│       └── middleware-example/         # Anthropic Go SDK + Amazon Bedrock (observability)
└── openai-sdk/
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
