# Three.dev Live Experiments for the OpenAI JS SDK (TypeScript)

Run an A/B experiment across a live conversation — let Three.dev decide which model
(or prompt, or parameters) each request uses, then measure which one wins. Your OpenAI
code stays the same except for the client's `baseURL` and `apiKey`.

## How it works

A Live Experiment has three moving parts:

**1. Route LLM calls through the Three.dev gateway.** Point the OpenAI client at the
gateway and authenticate with your Three.dev key. The gateway holds the real OpenAI
provider credentials for your use case, records every request, and applies the active
experiment — so there is **no `OPENAI_API_KEY`** in this example.

```ts
const client = new OpenAI({
  apiKey: process.env.THREE_API_KEY,        // r3_sk_... — NOT an OpenAI key
  baseURL: "https://gate.three.dev/v1",
  defaultHeaders: {
    "X-Three-Use-Case": useCaseSlug,
    "X-Three-AI-Provider": "openai",
    "X-Three-Session-ID": sessionId,        // groups the whole conversation
  },
});
```

**2. Ask which variant to use — before every request.** Call `/experiments/assign` with
the session id and use case. It returns the variant and its `metadata` (e.g.
`{"model":"gpt-5-mini","provider":"openai"}`), or `null` for the control group. Apply the
metadata to the request: chat params (`model`, …) go in the **body**; `provider` is routing
and goes in the **`X-Three-AI-Provider` header**, not the body (OpenAI rejects unknown body
params). `model` falls back to the default on control.

```ts
const assignment = await assign(cfg);                 // { variant_slug, metadata } | null
const variant = paramsFromAssignment(assignment, defaultModel); // -> { body, headers }
const res = await client.chat.completions.create(
  { ...variant.body, messages, tools },               // model + chat params
  { headers: variant.headers },                       // routing (e.g. provider)
);
```

**3. Report the outcome.** At the end of the session, report whether it achieved its goal —
`true` if it did, `false` if it didn't. Three.dev compares that quality metric across variants
to find the winner. Report an honest `false` whenever you know the outcome was negative: that
negative signal is what makes the comparison fair (always reporting `true` would make every
variant look perfect). Here the goal is "answered using live data", so success = the model
actually called the weather tool.

```ts
const achievedGoal = /* did the session meet its goal? */ usedWeatherTool;
await reportMetric(cfg, "response-quality", achievedGoal); // true OR false
```

## Sessions, tags, and the headers Three.dev reads

One `session_id` (a UUID) is generated per conversation and sent on every request, so the
dashboard groups all turns together. Tags come in two flavors:

| Purpose      | Header                              | Where it's set                          |
|--------------|-------------------------------------|-----------------------------------------|
| Use case     | `X-Three-Use-Case: <slug>`          | client `defaultHeaders`                 |
| Provider     | `X-Three-AI-Provider: openai`       | client `defaultHeaders`                 |
| Session id   | `X-Three-Session-ID: <uuid>`        | client `defaultHeaders`                 |
| Session-tag  | `x-three-session-tag-<KEY>: <VAL>`  | client `defaultHeaders` (whole session) |
| Request-tag  | `X-Three-Tag-<KEY>: <VAL>`          | `create(body, { headers })` (per call)  |

**Session-tags** describe the whole conversation (this example sets `channel=demo`,
`tier=free`). **Request-tags** describe a single call (this example sets `turn`, and
`phase=tool-followup` on tool follow-ups). See `createOpenAIClient` and
`requestTagHeaders` in [`src/three.ts`](./src/three.ts).

## Multi-turn conversation with tools

[`src/index.ts`](./src/index.ts) runs a scripted two-turn conversation. The model can call a
mock `get_weather` tool (defined in [`src/tools.ts`](./src/tools.ts)); the loop appends the
assistant's `tool_calls` message, runs the tool, feeds back a
`{ role: "tool", tool_call_id, content }` message, and lets the model answer. Message history
is kept across turns. Because the tool follow-up is itself an LLM request, `sendRequest`
(and therefore `/assign`) runs before it too — honoring "assign before every request".

## Prerequisites

- Node.js 18+ (uses the built-in global `fetch`)
- A Three.dev API key (`r3_sk_...`)
- A use case slug with the **OpenAI** provider configured in the Three.dev dashboard
- A metric slug configured for that use case
- (Optional, to see assignments) a running experiment on that use case

## Setup

```bash
cp .env.example .env
# Edit .env with your credentials
```

| Variable | Required | Description |
|---|---|---|
| `THREE_API_KEY` | Yes | Three.dev API key (`r3_sk_...`); also the OpenAI client `apiKey` |
| `USE_CASE_SLUG` | Yes | Three.dev use case identifier (from the dashboard) |
| `METRIC_SLUG` | Yes | Quality metric reported at the end of the session |
| `MODEL` | No | Model used when `/assign` returns control (default: `gpt-5.4-mini`) |
| `THREE_API_ENDPOINT` | No | Control-plane base URL (default: `https://api.three.dev`) |
| `THREE_GATEWAY_URL` | No | LLM gateway base URL (default: `https://gate.three.dev/v1`) |

## Running the example

```bash
task run
```

This installs dependencies, creates `.env` from `.env.example` if needed, and runs the
example. Without [Task](https://taskfile.dev), use `npm install && npm start` directly.

Expected output: the `session_id`, per-request `assign: variant=… model=…` lines, the
tool call and its result, the assistant's answers for both turns, and a final
`reported metric … = true` line.

## What to verify in Three.dev

- The session (matching the printed `session_id`) groups all requests of the conversation.
- Each request carries the session-tags (`channel`, `tier`) and request-tags (`turn`, and
  `phase=tool-followup` on follow-ups).
- If an experiment is running, requests show variant assignments (otherwise: control).
- The metric `response-quality = true` is recorded against the session.

## Design

- **Assign before every request** — each LLM call (including tool follow-ups) first asks
  `/assign`, so a variant change takes effect immediately.
- **Fail-soft** — `/assign` and `/metrics/report` errors are logged and the conversation
  still completes; `assign` falls back to the control/default model.
- **No OpenAI key** — the gateway holds the provider credentials; you authenticate with
  your Three.dev key only.
- **Minimal surface** — all Three.dev specifics live in `src/three.ts`; `src/index.ts`
  reads as an ordinary scripted conversation.

## Project structure

```
├── src/
│   ├── index.ts        # The example: assign → apply variant → send, the tool loop, the metric
│   ├── three.ts        # Reusable Three.dev helpers: assign, reportMetric, client + tag headers
│   └── tools.ts        # Mock get_weather tool + local executor
├── .env.example        # Environment variable template
├── Taskfile.yml        # One-command runner (task run)
├── PLAN.md             # Implementation plan for AI agents
├── package.json
└── tsconfig.json
```
