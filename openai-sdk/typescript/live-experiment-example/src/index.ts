// index.ts — integrate a Three.dev Live Experiment into a multi-turn, tool-using
// conversation with the OpenAI SDK. Read this file top to bottom: the experiment flow
// (assign -> apply variant -> send request) is the whole point and lives in `sendRequest`.
//
// The reusable Three.dev helpers (the actual HTTP calls and header conventions) are in
// three.ts; the mock tool is in tools.ts. Run with `npm start` / `task run`.

import "dotenv/config";
import { v4 as uuidv4 } from "uuid";
import type {
  ChatCompletionCreateParamsNonStreaming,
  ChatCompletionMessage,
  ChatCompletionMessageParam,
} from "openai/resources/chat/completions";
import {
  type ThreeConfig,
  assign,
  createOpenAIClient,
  paramsFromAssignment,
  reportMetric,
  requestTagHeaders,
} from "./three.js";
import { executeTool, tools } from "./tools.js";

// --- Configuration (from .env) ----------------------------------------------

function env(name: string, fallback?: string): string {
  const value = process.env[name] ?? fallback;
  if (!value) {
    console.error(`Missing required env var: ${name} (see .env.example)`);
    process.exit(1);
  }
  return value;
}

const three: ThreeConfig = {
  apiKey: env("THREE_API_KEY"),
  useCase: env("USE_CASE_SLUG"),
  apiEndpoint: env("THREE_API_ENDPOINT", "https://api.three.dev"),
  gatewayUrl: env("THREE_GATEWAY_URL", "https://gate.three.dev/v1"),
  sessionId: uuidv4(), // one session id for the whole conversation
};
const defaultModel = env("MODEL", "gpt-5.4-mini");
const metricSlug = env("METRIC_SLUG", "response-quality");

// The OpenAI client routes through the Three.dev gateway. The session-tags passed here
// (channel, tier) are attached to every request made with this client.
const client = createOpenAIClient(three, { channel: "demo", tier: "free" });

// Conversation state, shared across turns.
const messages: ChatCompletionMessageParam[] = [
  { role: "system", content: "You are a concise, helpful assistant." },
];
let firstRequestAt: number | null = null;

// The session's goal: did the assistant ground its answer in live data by calling the
// weather tool? We report this as the quality metric — true if achieved, false if not.
let achievedGoal = false;

// --- The Live Experiment in three steps -------------------------------------
//
// This runs before EVERY model request (every turn, and every tool follow-up).
async function sendRequest(
  turn: number,
  extraTags: Record<string, string> = {},
): Promise<ChatCompletionMessage> {
  // 1. ASSIGN — ask Three.dev which variant this session should use right now.
  //    Returns null for the control group / when no experiment is active.
  const assignment = await assign(three);

  // 2. APPLY — the variant's metadata configures the request: chat params (model, …) go
  //    in the body; `provider` is routing and goes in a header. On control, the body
  //    falls back to the default model.
  const variant = paramsFromAssignment(assignment, defaultModel);
  console.log(
    `  → assign: variant=${assignment?.variant_slug ?? "control"} model=${variant.body.model}`,
  );

  // 3. SEND — make the call through the gateway. Per-request headers carry the variant's
  //    routing plus request-tags (turn, phase); the use-case/provider/session/session-tag
  //    headers are already on the client.
  const response = await client.chat.completions.create(
    {
      ...variant.body,
      messages,
      tools,
      tool_choice: "auto",
    } as ChatCompletionCreateParamsNonStreaming,
    { headers: { ...variant.headers, ...requestTagHeaders({ turn: String(turn), ...extraTags }) } },
  );

  if (firstRequestAt === null) firstRequestAt = Date.now();
  return response.choices[0].message;
}

// --- One user turn: send the request, then resolve any tool calls -----------

async function ask(userText: string, turn: number): Promise<void> {
  console.log(`\nturn ${turn} — user: ${userText}`);
  messages.push({ role: "user", content: userText });

  let message = await sendRequest(turn);

  while (message.tool_calls && message.tool_calls.length > 0) {
    messages.push(message); // the assistant message that asked for tools
    for (const call of message.tool_calls) {
      if (call.function.name === "get_weather") achievedGoal = true; // grounded in live data
      const result = executeTool(call.function.name, JSON.parse(call.function.arguments || "{}"));
      console.log(`  · tool ${call.function.name}(${call.function.arguments}) -> ${result}`);
      messages.push({ role: "tool", tool_call_id: call.id, content: result });
    }
    // The tool follow-up is itself a model request, so it gets its own /assign call.
    message = await sendRequest(turn, { phase: "tool-followup" });
  }

  messages.push(message);
  console.log(`  assistant: ${message.content ?? ""}`);
}

// --- Run the conversation ---------------------------------------------------

async function main(): Promise<void> {
  console.log(`session_id: ${three.sessionId}`);

  await ask("What's the weather in Paris?", 1); // triggers the tool
  await ask("How does that compare to a typical day in London?", 2); // keeps history

  // Report whether the session achieved its goal — the experiment's quality signal.
  // Send `true` when it did, `false` when it didn't. Report an honest `false` whenever you
  // know the outcome was negative: that negative signal is what lets the experiment compare
  // variants fairly (always reporting `true` would make every variant look perfect).
  // Three.dev needs the first request to finish recording first (up to ~5s).
  const elapsed = Date.now() - (firstRequestAt ?? Date.now());
  if (elapsed < 5000) await new Promise((resolve) => setTimeout(resolve, 5000 - elapsed));
  await reportMetric(three, metricSlug, achievedGoal);
  console.log(`\nreported metric "${metricSlug}" = ${achievedGoal} for session ${three.sessionId}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
