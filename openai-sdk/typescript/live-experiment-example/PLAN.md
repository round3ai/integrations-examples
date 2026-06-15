# PLAN — Three.dev Live Experiments + OpenAI JS SDK (TypeScript)

This document is the build plan for a small, self-contained, **pedagogic** example
that shows a design partner how to integrate **Three.dev Live Experiments**
into a Node.js backend that uses the OpenAI JS SDK. It plays the same role for the
Live Experiments + OpenAI integration that
[`anthropic-sdk/go/middleware-example/`](../../../anthropic-sdk/go/middleware-example/)
plays for the Go + Bedrock observability integration.

## Context

- The design partner runs a Node.js backend with the OpenAI JS SDK
  (user-agent `OpenAI/JS 4.52.7`).
- The existing repo example is **observability-only** (non-proxy; it POSTs a copy of
  each request to `POST /api/v1/request`). Live Experiments use a **different,
  proxy-based model** not yet represented in the repo, so this example introduces it.
- Goal: a runnable example the partner can execute as-is to generate **real requests
  visible in Three.dev**, then copy into their backend.

## Three.dev Live Experiments contract

- **LLM calls go through the gateway proxy.** The OpenAI client points at
  `baseURL: https://gate.three.dev/v1` with `apiKey: <THREE_API_KEY>` (`r3_sk_…`).
  The gateway holds the real OpenAI provider credentials for the use case, so
  **no separate `OPENAI_API_KEY` is needed** — keeps the example self-contained.
- **Assign — call before every request:** `POST https://api.three.dev/api/v1/experiments/assign`
  with body `{ "session_id", "use_case" }` and `Authorization: Bearer <THREE_API_KEY>`.
  Returns `{ experiment_id, variant_slug, metadata }` (e.g.
  `metadata: {"model":"gpt-5-mini","provider":"openai"}`) or `null` (no experiment /
  control). Apply `metadata` to that turn — chat params to the body, `provider` to the
  `X-Three-AI-Provider` header — falling back to the default model on `null`.
- **Session id:** one UUID for the whole conversation, sent on every request via
  `X-Three-Session-ID`.
- **Session-tags:** `x-three-session-tag-<KEY>: <VALUE>` (set once, on every request).
- **Request-tags:** `X-Three-Tag-<KEY>: <VALUE>` (per individual request).
- **Metric reporting:** `POST https://api.three.dev/api/v1/metrics/report` with
  `{ metric, use_case, session_id, outcome }` (boolean field is `outcome` — verified
  against the live API). Must wait ≥5s after the first request.
- Required gateway headers: `X-Three-Use-Case`, `X-Three-AI-Provider: openai`,
  `X-Three-Session-ID`.

### Header families

| Purpose      | Header                              | Where set                              |
|--------------|-------------------------------------|----------------------------------------|
| Use case     | `X-Three-Use-Case: <slug>`          | client `defaultHeaders`                |
| Provider     | `X-Three-AI-Provider: openai`       | client `defaultHeaders`                |
| Session id   | `X-Three-Session-ID: <uuid>`        | client `defaultHeaders`                |
| Session tag  | `x-three-session-tag-<KEY>: <VAL>`  | client `defaultHeaders`                |
| Request tag  | `X-Three-Tag-<KEY>: <VAL>`          | `create(body, { headers })` (per turn) |

## Confirmed decisions

- **Language:** TypeScript (Node).
- **Assign cadence:** call `/assign` **before every** chat-completion request
  (including tool follow-up completions), applying the variant per request.
- **Session-tags header:** `x-three-session-tag-<KEY>`.
- **Credentials/setup:** same experience as the Go example — committed `.env`
  reusing the existing `THREE_API_KEY`, plus a commented `.env.example`, single run command.
- **Metrics:** report a quality metric at the end (full assign → run → measure loop).

## OpenAI Node v4.52.x API (verified against the SDK)

- Constructor accepts `{ apiKey, baseURL, defaultHeaders }`; `defaultHeaders` are sent
  on every request.
- Per-request headers: `chat.completions.create(body, { headers })` — `headers` is
  `Record<string, string | null | undefined>` and merges over `defaultHeaders`. This is
  the supported path for per-turn request-tags.
- Tool calling: `body.tools` = `[{ type:"function", function:{ name, description, parameters } }]`;
  reply at `response.choices[0].message`; tool calls at
  `message.tool_calls[].{ id, function.{ name, arguments } }`; reply with the assistant
  message verbatim + one `{ role:"tool", tool_call_id, content }` per call, then call
  `create` again.

## File layout

```
openai-sdk/typescript/live-experiment-example/
├── src/
│   ├── index.ts        # The example: assign → apply variant → send, tool loop, metric (linear)
│   ├── three.ts        # Three.dev helper: assign(), reportMetric(), createOpenAIClient(),
│   │                   #   requestTagHeaders(), paramsFromAssignment()
│   └── tools.ts        # Tool definitions + local executor (mock get_weather)
├── package.json
├── tsconfig.json
├── .env.example        # commented template
├── .env                # gitignored; local copy reuses existing THREE_API_KEY (matches Go example)
├── .gitignore          # node_modules/, dist/, .env  (matches Go example — .env not committed)
├── Taskfile.yml        # go-task runner: setup / env / run / default (mirrors Go example)
├── README.md           # pedagogic, human-facing
└── PLAN.md             # this document
```
Also update the root `README.md` to add an "OpenAI SDK (TypeScript) + Three.dev Live
Experiments" section, mirroring the existing Anthropic entry.

## Build steps

### Step 1 — Scaffold

- `package.json`: `"type": "module"`; deps `openai ~4.52.7`, `uuid ^9`, `dotenv ^16`;
  devDeps `typescript ^5.5`, `tsx ^4`, `@types/node`, `@types/uuid`. Scripts:
  `"start": "tsx src/index.ts"` (single-command run, like Go's `task run`),
  `"build": "tsc"`, `"typecheck": "tsc --noEmit"`.
- `tsconfig.json`: `target ES2022`, `module ESNext`, `moduleResolution "Bundler"`,
  `strict: true`, `esModuleInterop`, `resolveJsonModule`, `rootDir src`, `outDir dist`.

### Step 2 — `src/three.ts` (all Three.dev specifics live here)

- `ThreeConfig` = `{ apiKey, useCase, apiEndpoint, gatewayUrl, sessionId }`.
- `Assignment` = `{ experiment_id, variant_slug, metadata: Record<string, unknown> }`.
- `createOpenAIClient(cfg, sessionTags)` → `new OpenAI({ apiKey, baseURL, defaultHeaders })`
  with `X-Three-Use-Case`, `X-Three-AI-Provider: openai`, `X-Three-Session-ID`, and one
  `x-three-session-tag-<KEY>` per session tag.
- `requestTagHeaders(tags)` → `{ "X-Three-Tag-<KEY>": value, … }` for the `create()` 2nd arg.
- `assign(cfg)` → `POST {apiEndpoint}/api/v1/experiments/assign`; returns `Assignment | null`;
  **fail-soft** (logs a warning and returns `null` on non-OK so the conversation never crashes).
- `reportMetric(cfg, metric, outcome)` → `POST {apiEndpoint}/api/v1/metrics/report` with a
  boolean `outcome` (`true`/`false`); fail-soft.
- `paramsFromAssignment(assignment, defaultModel)` → `{ body, headers }`. Chat params from
  `metadata` (model, temperature, top_p, …) go in `body` with `model` resolved (metadata
  wins, else `defaultModel`); `provider` is routing and goes in `headers` as
  `X-Three-AI-Provider` (NOT the body — OpenAI rejects unknown body params). Spread `body`
  into `create(...)` and merge `headers` into its request options.
- Uses Node 18+ global `fetch` (no extra dependency).

### Step 3 — `src/tools.ts` (the mock tool)

- The `tools` array (mock `get_weather`) + an `executeTool` that returns canned JSON.
  Kept separate so it doesn't distract from the experiment flow in `index.ts`.

### Step 4 — `src/index.ts` (the example — linear and assign-first)

Read top to bottom. The `/assign` call is the centerpiece, not hidden behind abstraction:

- Compact config: read env (`THREE_API_KEY`, `USE_CASE_SLUG` required; the rest with
  defaults) into a `ThreeConfig`; generate one `sessionId` UUID. Build the client via
  `createOpenAIClient(three, { channel: "demo", tier: "free" })` (session-tags).
- `sendRequest(turn, extraTags?)` — the Live Experiment in three visible steps, run before
  EVERY request: (1) **`assign(three)`**, (2) `paramsFromAssignment(...)` → `{ body, headers }`
  to apply the variant, (3) `chat.completions.create({ ...variant.body, messages, tools },
  { headers: { ...variant.headers, ...requestTagHeaders({ turn, ...extraTags }) } })`.
- `ask(userText, turn)` — push the user message, `sendRequest`, then while the reply has
  `tool_calls`: append it, run each tool, append `{ role:"tool", tool_call_id, content }`,
  and `sendRequest` again with a `phase: "tool-followup"` request-tag.
- `main()` — two scripted `ask(...)` calls, then the ≥5s wait and
  `reportMetric(three, metricSlug, achievedGoal)`. `achievedGoal` is a computed boolean
  (here: did the model call the weather tool?), demonstrating that the outcome can be
  reported as `true` OR `false` — report an honest `false` when the goal wasn't met.

### Step 5 — Env configuration

| Variable             | Required | Purpose                                                    |
|----------------------|----------|------------------------------------------------------------|
| `THREE_API_KEY`      | Yes      | `r3_sk_…`; Bearer auth for assign/metrics **and** OpenAI client `apiKey`. |
| `USE_CASE_SLUG`      | Yes      | Three.dev use case; `X-Three-Use-Case` + assign/report body. |
| `METRIC_SLUG`        | Yes      | Quality metric reported at the end.                        |
| `MODEL`              | No       | Default model when `/assign` returns control. Default `gpt-5.4-mini`. |
| `THREE_API_ENDPOINT` | No       | Control-plane base URL. Default `https://api.three.dev`.   |
| `THREE_GATEWAY_URL`  | No       | LLM gateway base URL. Default `https://gate.three.dev/v1`. |

- `.env.example`: heavily commented (mirrors Go), explaining each var, the dual use of
  `THREE_API_KEY`, and that no `OPENAI_API_KEY` is needed.
- `.env`: gitignored (matches Go example); local copy reuses the existing `THREE_API_KEY`
  and `USE_CASE_SLUG=amazon-bedrock-integration` so it runs locally (see Open items).
- `.gitignore`: `node_modules/`, `dist/`, `.env` (matches the Go example — `.env` not committed).

### Step 6 — Docs

- `README.md` (pedagogic): intro/value-prop → "How it works" (gateway client,
  assign-per-turn, metric) → header-families table → multi-turn+tools explanation →
  prerequisites (Node 18+, Three.dev key, use-case + metric slugs) → setup → env-var table →
  run (`task run`) → "what to verify in Three.dev" → project tree.
- Update root `README.md` with the new example entry, mirroring the Anthropic section.

## Verification (end-to-end, generates real requests)

1. `cd openai-sdk/typescript/live-experiment-example && npm install`.
2. Ensure `.env` has a valid `USE_CASE_SLUG`/`METRIC_SLUG` for the gateway use case.
3. `npm start`. Expect stdout: the `session_id`, per-turn `variant=… model=…` lines, the
   tool-driven weather answer (turn 1), a comparative answer (turn 2), then
   `reported metric "…" = true`.
4. In the Three.dev dashboard, confirm: the session (matching the printed id) groups multiple
   requests; each carries the session-tags (`channel`, `tier`) and request-tags (`turn`, and
   `phase=tool-followup` on follow-ups); variant assignments appear per turn (or control); the
   metric is recorded against the session.
5. Fail-soft check: point `THREE_API_ENDPOINT` at a bad host → warnings logged but the
   conversation still completes.

## Open items / risks to confirm during build

- **Use-case / metric slug validity:** the reused `THREE_API_KEY` is from the Bedrock/Anthropic
  Go demo. For OpenAI-gateway experiments to actually route, an OpenAI use case (and metric)
  must exist for that key. Confirm the correct slugs with the design partner; otherwise commit
  placeholders and document it. This is the only thing blocking a fully out-of-the-box run.
- **Metric body boolean field name:** RESOLVED — verified against the live API: the field is
  `outcome` (a `value` body returns 422 "missing field `outcome`"). Code uses `outcome`.
- **Assign control shape:** handles both `null` and a 200 with `{}`/`{"variant_slug":"control"}`
  via graceful fallback — no code change needed either way.
