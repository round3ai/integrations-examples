// tools.ts — the tool the agent can call. In a real app it would call your own weather
// service; here it returns canned data so the example is deterministic and self-contained.

import { tool } from "langchain";
import { z } from "zod";

const temperaturesC = new Map<string, number>([
  ["paris", 18],
  ["lisbon", 24],
  ["london", 14],
  ["madrid", 27],
]);

export const getWeather = tool(
  async ({ city }) => ({
    city,
    // "Lisbon, Portugal" -> "lisbon"; unknown cities get a default.
    temperatureC: temperaturesC.get(city.split(",")[0].trim().toLowerCase()) ?? 20,
    condition: "sunny",
  }),
  {
    name: "get_weather",
    description: "Get the current weather for a city.",
    schema: z.object({
      city: z.string().describe("City name, e.g. 'Paris'"),
    }),
  },
);
