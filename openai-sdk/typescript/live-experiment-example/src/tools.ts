// tools.ts — the tools the model can call, plus a local executor.
// In a real app these would call your own services; here they return canned data
// so the example is deterministic and self-contained.

import type { ChatCompletionTool } from "openai/resources/chat/completions";

export const tools: ChatCompletionTool[] = [
  {
    type: "function",
    function: {
      name: "get_weather",
      description: "Get the current weather for a city.",
      parameters: {
        type: "object",
        properties: {
          city: { type: "string", description: "City name, e.g. 'Paris'" },
        },
        required: ["city"],
      },
    },
  },
];

/** Run a tool by name and return its result as a JSON string for the model. */
export function executeTool(name: string, args: Record<string, unknown>): string {
  if (name === "get_weather") {
    const city = String(args.city ?? "unknown");
    return JSON.stringify({ city, temperatureC: 21, condition: "sunny" });
  }
  return JSON.stringify({ error: `unknown tool: ${name}` });
}
