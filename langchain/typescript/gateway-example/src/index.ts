// index.ts — a small weather assistant built on LangChain.js and LangGraph. Every LLM call
// goes through the Three.dev gateway (wired in providers.ts) and is recorded there.
//
// For each provider with keys in .env, the app runs one conversation of three calls:
// invoke, stream and an agent with a tool. The three calls share one session id, sent as
// x-three-session-id, so each conversation is one session in Three.dev.
// Run with `task run` / `npm start`.

import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { AIMessage, HumanMessage, SystemMessage, createAgent } from "langchain";
import { loadProviders, threeSession, type AnyProviderTarget } from "./providers.js";
import { getWeather } from "./tools.js";

// Load .env when present (Node 22+). Variables already set in the environment win.
if (existsSync(".env")) process.loadEnvFile(".env");

const instructions = "You are a concise weather assistant. Answer in one or two sentences.";

/** The first words of an answer, for a one-line summary. */
function preview(text: string, words = 12): string {
  const parts = text.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return "(no text)";
  return parts.slice(0, words).join(" ") + (parts.length > words ? " …" : "");
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function prompt(text: string) {
  return [new SystemMessage(instructions), new HumanMessage(text)];
}

async function runConversation(target: AnyProviderTarget) {
  const { name, deploymentChatModel } = target;

  // One session id per conversation, sent with each call: on the model or in the call
  // options, depending on the provider (see providers.ts). Per-call headers merge with the
  // model's default headers, and the per-call value wins.
  const sessionId = randomUUID();
  const model = target.model(sessionId);
  const callOptions = target.callOptions(sessionId);
  console.log(`\n[${name}] session ${sessionId}`);

  // 1. invoke
  const first = await model.invoke(
    prompt("In one sentence, what should I pack for a spring weekend in Paris?"),
    callOptions,
  );
  console.log(`[${name}] invoke: ${preview(first.text)}`);

  // 2. stream, printed as it streams.
  const stream = await model.stream(
    prompt("Give me one tip for staying cool on a hot day in Madrid."),
    callOptions,
  );
  process.stdout.write(`[${name}] stream: `);
  for await (const chunk of stream) process.stdout.write(chunk.text);
  process.stdout.write("\n");

  // 3. Agent — the model calls get_weather for each city, then answers. The middleware
  //    sets the session id on each of the agent's model calls, from the run's context.
  const agent = createAgent({
    model,
    tools: [getWeather],
    systemPrompt: instructions,
    middleware: [threeSession(target.modelSettings)],
  });
  const result = await agent.invoke(
    { messages: [new HumanMessage("Which is warmer right now, Paris or Lisbon? Use the weather tool.")] },
    { context: { sessionId } },
  );
  const answers = result.messages.filter(AIMessage.isInstance);
  const toolCalls = answers.flatMap((message) => message.tool_calls ?? []).length;
  console.log(`[${name}] agent (${toolCalls} tool calls): ${preview(answers.at(-1)?.text ?? "")}`);

  // Azure only: one call on deployment URLs, in the same session.
  if (deploymentChatModel) {
    const chat = await deploymentChatModel(sessionId).invoke(
      prompt("Is Lisbon usually warm in May? Answer in one sentence."),
      callOptions,
    );
    console.log(`[${name}] invoke (deployment URLs): ${preview(chat.text)}`);
  }
}

async function main(): Promise<void> {
  const { targets, skipped } = loadProviders();
  for (const line of skipped) console.log(`skipping ${line}`);
  if (targets.length === 0) {
    console.error("No provider keys set — add at least one to .env (see .env.example).");
    process.exitCode = 1;
    return;
  }

  const failed: string[] = [];
  for (const target of targets) {
    try {
      await runConversation(target);
    } catch (err) {
      failed.push(target.name);
      console.error(`[${target.name}] failed: ${errorMessage(err)}`);
    }
  }

  // process.exitCode instead of process.exit(), so piped output is not cut off.
  if (failed.length > 0) {
    console.error(`\nFailed: ${failed.join(", ")}.`);
    process.exitCode = 1;
  }
  if (failed.length < targets.length) {
    console.log(
      `\nDone. In Three.dev, open the use case "${process.env.USE_CASE_SLUG}": each call is on its ` +
        "Requests page, and each provider's conversation is one session on its Sessions page.",
    );
  }
}

main().catch((err) => {
  console.error(errorMessage(err));
  process.exitCode = 1;
});
