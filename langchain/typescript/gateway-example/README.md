# Three.dev Gateway for LangChain.js and LangGraph (TypeScript)

Record every LLM call of an app built on [LangChain.js](https://js.langchain.com) and
[LangGraph](https://langchain-ai.github.io/langgraphjs/) in Three.dev. The app keeps its own
provider keys and its LangChain code; only the chat models change: each one points its base
URL at the Three.dev gateway and carries a few `x-three-*` headers. The gateway forwards
each call to the provider and records it.

This example is a small weather assistant. For each provider with keys in `.env` (OpenAI,
Anthropic, Gemini, OpenRouter, Azure OpenAI) it runs one conversation of three calls —
`invoke`, `stream` and an agent with a tool — and groups the conversation into one session
in Three.dev.

## How it works

**1. Point the chat models at the gateway.** Each model class takes the gateway URL and the
headers in its own fields (see [Provider wiring](#provider-wiring)):

```ts
const gateway = "https://gate.three.dev";

const openai = new ChatOpenAI({
  apiKey: process.env.OPENAI_API_KEY,          // your own OpenAI key
  model: "gpt-5.4-mini",
  configuration: {
    baseURL: `${gateway}/v1`,
    defaultHeaders: {
      "x-three-api-key": process.env.THREE_API_KEY!,
      "x-three-use-case": process.env.USE_CASE_SLUG!,
      "x-three-ai-provider": "openai",
    },
  },
});
```

**2. Send the session id with each call.** Headers passed per call merge with the model's
default headers, and the per-call value wins. Where they go depends on the class:

```ts
const headers = { "x-three-session-id": sessionId }; // one per conversation

await anthropic.invoke(messages, { headers });             // ChatAnthropic
await openai.invoke(messages, { options: { headers } });   // ChatOpenAI, invoke only
```

`ChatOpenAI` drops per-call headers on `stream` (see [Things to know](#provider-wiring)), so
this example puts the session id on the model instead, one `ChatOpenAI` per conversation.

**3. Set the session per agent run with middleware.** A `wrapModelCall` middleware reads the
session id from the run's `context` and adds it to every model call of the run, so one agent
serves many conversations:

```ts
const threeSession = createMiddleware({
  name: "ThreeSession",
  contextSchema: z.object({ sessionId: z.string() }),
  wrapModelCall: (request, handler) =>
    handler({
      ...request,
      modelSettings: {
        ...request.modelSettings,
        // ChatOpenAI: { options: { headers } }; ChatAnthropic: { headers }
        options: { headers: { "x-three-session-id": request.runtime.context.sessionId } },
      },
    }),
});

const agent = createAgent({ model: openai, tools, middleware: [threeSession] });
await agent.invoke({ messages }, { context: { sessionId } });
```

All of it is in [`src/providers.ts`](./src/providers.ts) and
[`src/index.ts`](./src/index.ts).

## Provider wiring

Every model sends `x-three-api-key`, `x-three-use-case` and `x-three-ai-provider`;
`<gateway>` is `THREE_GATEWAY_URL` (default `https://gate.three.dev`).

| Package | Class | Gateway URL | `x-three-ai-provider` | Extra header | Session (invoke / stream; agent middleware) |
|---|---|---|---|---|---|
| `@langchain/openai` | `ChatOpenAI` | `configuration.baseURL: <gateway>/v1` | `openai` | none | on the model; `{ options: { headers } }` |
| `@langchain/anthropic` | `ChatAnthropic` | `anthropicApiUrl: <gateway>` | `anthropic` | none | `{ headers }`; `{ headers }` |
| `@langchain/google-genai` | `ChatGoogleGenerativeAI` | `baseUrl: <gateway>` | `gemini` | none | on the model (`customHeaders`) |
| `@langchain/openai` (OpenRouter) | `ChatOpenAI` | `configuration.baseURL: <gateway>/v1` | `openrouter` | `x-three-ai-provider-baseurl: https://openrouter.ai/api/v1` | on the model; `{ options: { headers } }` |
| `@langchain/openai`, Azure v1 URLs | `ChatOpenAI` (model = deployment) | `configuration.baseURL: <gateway>/v1` | `azure_openai` | `x-three-ai-provider-baseurl: <AZURE_ENDPOINT>/openai/v1` | on the model; `{ options: { headers } }` |
| `@langchain/openai`, Azure deployment URLs | `AzureChatOpenAI` | `azureOpenAIEndpoint: <gateway>` | `azure_openai` | `x-three-ai-provider-baseurl: <AZURE_ENDPOINT>` | on the model |

The default headers go in `configuration.defaultHeaders` (`ChatOpenAI`, `AzureChatOpenAI`),
`clientOptions.defaultHeaders` (`ChatAnthropic`) or `customHeaders`
(`ChatGoogleGenerativeAI`).

Things to know:

- **Anthropic:** the URL has no `/v1`, like the Anthropic SDK's. This differs from the
  Vercel AI SDK, whose Anthropic `baseURL` includes `/v1`.
- **Session headers per class:** `ChatOpenAI` takes per-call headers in `options.headers`,
  `ChatAnthropic` in `headers`. The OpenAI form with `ChatAnthropic` silently drops the
  session: the requests are still recorded, just not grouped. In this example, a target
  with the wrong form for its class does not compile.
- **`ChatOpenAI.stream`:** in `@langchain/openai` 1.6, per-call `options.headers` reach
  `invoke` and agent runs, but not `stream`. For streams, put the session id in the model's
  `defaultHeaders`, one model per conversation, as this example does.
- **Streams and tokens:** `ChatOpenAI`'s `streamUsage` defaults to `true`, so streams are
  recorded with tokens.
- **gpt-6 models with tools:** LangChain.js does not switch to the Responses API on its own;
  set `useResponsesApi: true` on `ChatOpenAI` for them.
- **Azure:** `AZURE_ENDPOINT` is the resource address with no path
  (`https://<resource>.openai.azure.com`), and the model is the deployment name.
  `AZURE_API_VERSION` is used only with deployment URLs. It is an Azure API version such
  as `2025-04-01-preview` (the value after `api-version=` in the deployment's Target URI),
  not the model version. Azure answers a wrong value with `404 Resource not found`.
- **Embeddings:** `OpenAIEmbeddings` goes through the gateway, but embeddings are recorded
  without messages, tokens or cost.
- **Stored keys:** this example sends the app's own provider keys. To use the provider keys
  stored in Three.dev instead, see the Three.dev docs.

## What the app does

For each provider with keys in `.env` (the others are skipped with one line saying so):

1. `invoke` with a short prompt,
2. `stream`, printing the text as it streams,
3. an agent: `createAgent` with a mock `get_weather` tool ([`src/tools.ts`](./src/tools.ts),
   `tool()` with a zod `schema`) and the session middleware, asking which of two cities is
   warmer.

The three calls share one session id (`crypto.randomUUID()`), so each provider's
conversation is one session in Three.dev. For Azure, the three calls use v1 URLs; when
`AZURE_API_VERSION` is set, one more call uses deployment URLs, in the same session.

The app prints one short line per call (provider, call, first words of the answer). It
never prints keys or request headers.

## Prerequisites

- Node.js 22+
- [Task](https://taskfile.dev) (optional)
- A Three.dev API key (`r3_sk_...`)
- An API key for at least one of the providers

## Setup

```bash
cp .env.example .env
# Edit .env: THREE_API_KEY, USE_CASE_SLUG and the keys of the providers you want to run
```

| Variable | Required | Description |
|---|---|---|
| `THREE_API_KEY` | Yes | Three.dev API key (`r3_sk_...`), sent as `x-three-api-key` |
| `USE_CASE_SLUG` | Yes | Use case slug, sent as `x-three-use-case`. A new slug is created on its first request (up to 20 per organization) |
| `THREE_GATEWAY_URL` | No | Gateway base URL, no path (default: `https://gate.three.dev`) |
| `OPENAI_API_KEY` / `OPENAI_MODEL` | No | OpenAI key and model (default: `gpt-5.4-mini`) |
| `ANTHROPIC_API_KEY` / `ANTHROPIC_MODEL` | No | Anthropic key and model (default: `claude-haiku-5-5`) |
| `GOOGLE_GENERATIVE_AI_API_KEY` / `GOOGLE_MODEL` | No | Gemini key and model (default: `gemini-3.8-flash`) |
| `OPENROUTER_API_KEY` / `OPENROUTER_MODEL` | No | OpenRouter key and model (default: `qwen/qwen3.8-27b`) |
| `AZURE_API_KEY` / `AZURE_ENDPOINT` / `AZURE_DEPLOYMENT` | No | Azure OpenAI key, resource address (no path) and deployment name; all three are needed |
| `AZURE_API_VERSION` | No | Azure API version for the deployment-URL call, e.g. `2025-04-01-preview`; leave empty to skip that call |

## Running the example

```bash
task run
```

This installs dependencies, creates `.env` from `.env.example` if needed, and runs the
example. Without Task, use `npm install && npm start`. `task typecheck` type-checks the
code.

## What to verify in Three.dev

Open the use case (`USE_CASE_SLUG`) in Three.dev:

- **Requests:** one request per call, with the provider, model, messages, tokens and cost.
  The agent shows one request per step, with its tool calls and results.
- **Sessions:** one session per provider, holding that provider's calls (the app prints
  each session id).

## Design

- **Your own provider keys** — each model keeps its `apiKey`; the gateway forwards it to the
  provider and records the call.
- **The integration is only the models and one middleware** — the gateway URL plus the
  `x-three-*` headers, and the session middleware, all in `src/providers.ts`. The `invoke`
  / `stream` / `createAgent` calls in `src/index.ts` are ordinary LangChain code.
- **Session per conversation** — per call where the class supports it (`ChatAnthropic`),
  on the model otherwise; in an agent, per run through `context` and the middleware.
- **Typed, no casts** — each provider's session options are checked against its own class's
  call options under `strict`.
- **Fail fast on misconfiguration** — `THREE_GATEWAY_URL` and `AZURE_ENDPOINT` must have
  no path, so a value like `https://gate.three.dev/v1` is rejected instead of producing
  `/v1/v1` URLs.

## Project structure

```
├── src/
│   ├── index.ts        # The conversation per provider: invoke, stream, agent
│   ├── providers.ts    # Chat models pointed at the gateway, built from .env; session middleware
│   └── tools.ts        # Mock get_weather tool
├── .env.example        # Environment variable template
├── Taskfile.yml        # task install / task run / task typecheck
├── package.json
└── tsconfig.json
```
