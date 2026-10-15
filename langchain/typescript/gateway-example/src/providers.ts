// providers.ts — one LangChain.js chat model per provider, pointed at the Three.dev gateway,
// and the agent middleware that carries the session id. This is the whole integration: the
// rest of the app is ordinary LangChain code.
//
// Each model keeps the app's own provider key (apiKey) and changes two things:
//   - the base URL: the gateway path for that provider (see the table in the README)
//   - the default headers: x-three-api-key, x-three-use-case and x-three-ai-provider, sent on
//     every request made with the model.
//
// The session id (x-three-session-id) travels differently per class:
//   - ChatAnthropic: per call, in `headers`. One model serves every conversation.
//   - ChatOpenAI / AzureChatOpenAI: on the model, one model per conversation. Per-call
//     `options.headers` reach invoke but not stream in @langchain/openai 1.6.
//   - ChatGoogleGenerativeAI: on the model, one model per conversation.
// In an agent, the threeSession middleware sets it on every model call of a run.

import { ChatAnthropic } from "@langchain/anthropic";
import type { BaseChatModel, BaseChatModelCallOptions } from "@langchain/core/language_models/chat_models";
import { ChatGoogleGenerativeAI } from "@langchain/google-genai";
import { AzureChatOpenAI, ChatOpenAI } from "@langchain/openai";
import { createMiddleware } from "langchain";
import { z } from "zod";

/** One provider the app talks to, with the models its conversation uses. */
export interface ProviderTarget<CallOptions extends BaseChatModelCallOptions> {
  /** Label printed in the output. */
  name: string;
  /** The model for one conversation (invoke, stream, agent), given its session id. */
  model: (sessionId: string) => BaseChatModel<CallOptions>;
  /** Call options that carry the session id on invoke / stream (empty when it is on the model). */
  callOptions: (sessionId: string) => Partial<CallOptions>;
  /** The agent middleware's modelSettings that carry the session id. */
  modelSettings: (sessionId: string) => Record<string, unknown>;
  /** Azure only: a model on deployment URLs, run once when set. */
  deploymentChatModel?: (sessionId: string) => BaseChatModel<CallOptions>;
}

/**
 * A target of any provider. defineTarget checks each target against its own model's call
 * options (e.g. `headers` for ChatAnthropic), then widens it.
 */
export type AnyProviderTarget = ProviderTarget<BaseChatModelCallOptions>;

function defineTarget<CallOptions extends BaseChatModelCallOptions>(
  target: ProviderTarget<CallOptions>,
): AnyProviderTarget {
  return target;
}

const sessionHeaders = (sessionId: string) => ({ "x-three-session-id": sessionId });

// ChatOpenAI and AzureChatOpenAI: the session id is on the model; in an agent, the
// middleware passes it in options.headers.
const openaiSession = {
  callOptions: () => ({}),
  modelSettings: (sessionId: string) => ({ options: { headers: sessionHeaders(sessionId) } }),
};

/**
 * Sets the session id on every model call of an agent run, from the run's context
 * (`agent.invoke(input, { context: { sessionId } })`). One agent can then serve many
 * conversations, each with its own session.
 */
export function threeSession(modelSettings: (sessionId: string) => Record<string, unknown>) {
  return createMiddleware({
    name: "ThreeSession",
    contextSchema: z.object({ sessionId: z.string() }),
    wrapModelCall: (request, handler) =>
      handler({
        ...request,
        modelSettings: {
          ...request.modelSettings,
          ...modelSettings(request.runtime.context.sessionId),
        },
      }),
  });
}

function env(name: string): string | undefined {
  const value = process.env[name]?.trim();
  return value ? value : undefined;
}

function requireEnv(name: string): string {
  const value = env(name);
  if (!value) throw new Error(`Missing required env var: ${name} (see .env.example)`);
  return value;
}

// The per-provider paths are appended to these URLs, so a path here (e.g. the /v1 that
// the OpenAI SDK example puts in THREE_GATEWAY_URL) would produce URLs like /v1/v1.
function originOnly(name: string, value: string, example: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error(`${name} is not a valid URL: ${value}`);
  }
  if (url.pathname !== "/" || url.search || url.hash) {
    throw new Error(`${name} must have no path, e.g. ${example} (got ${value})`);
  }
  return url.origin;
}

/** Build the models for every provider whose keys are set in .env. */
export function loadProviders(): { targets: AnyProviderTarget[]; skipped: string[] } {
  const gateway = originOnly(
    "THREE_GATEWAY_URL",
    env("THREE_GATEWAY_URL") ?? "https://gate.three.dev",
    "https://gate.three.dev",
  );

  // Headers shared by every provider; x-three-ai-provider is added per provider below.
  const three = {
    "x-three-api-key": requireEnv("THREE_API_KEY"),
    "x-three-use-case": requireEnv("USE_CASE_SLUG"),
  };

  const targets: AnyProviderTarget[] = [];
  const skipped: string[] = [];

  // OpenAI — Chat Completions. streamUsage defaults to true, so streams carry token usage.
  const openaiKey = env("OPENAI_API_KEY");
  if (openaiKey) {
    const openaiModel = env("OPENAI_MODEL") ?? "gpt-5.4-mini";
    targets.push(
      defineTarget({
        name: "openai",
        model: (sessionId) =>
          new ChatOpenAI({
            apiKey: openaiKey,
            model: openaiModel,
            configuration: {
              baseURL: `${gateway}/v1`,
              defaultHeaders: {
                ...three,
                "x-three-ai-provider": "openai",
                ...sessionHeaders(sessionId),
              },
            },
          }),
        ...openaiSession,
      }),
    );
  } else {
    skipped.push("openai (OPENAI_API_KEY not set)");
  }

  // Anthropic — the URL has no /v1 (the Anthropic SDK adds /v1/messages), unlike the
  // Vercel AI SDK's. Per-call headers go in `headers`, not `options.headers`: with
  // options.headers the requests are still recorded, but not grouped into the session.
  const anthropicKey = env("ANTHROPIC_API_KEY");
  if (anthropicKey) {
    const anthropic = new ChatAnthropic({
      apiKey: anthropicKey,
      model: env("ANTHROPIC_MODEL") ?? "claude-haiku-5-5",
      anthropicApiUrl: gateway,
      clientOptions: {
        defaultHeaders: { ...three, "x-three-ai-provider": "anthropic" },
      },
    });
    targets.push(
      defineTarget({
        name: "anthropic",
        model: () => anthropic,
        callOptions: (sessionId) => ({ headers: sessionHeaders(sessionId) }),
        modelSettings: (sessionId) => ({ headers: sessionHeaders(sessionId) }),
      }),
    );
  } else {
    skipped.push("anthropic (ANTHROPIC_API_KEY not set)");
  }

  // Gemini — the URL has no path (the Google SDK adds /v1beta/models/...) and the provider
  // value is "gemini".
  const googleKey = env("GOOGLE_GENERATIVE_AI_API_KEY");
  if (googleKey) {
    const googleModel = env("GOOGLE_MODEL") ?? "gemini-3.8-flash";
    targets.push(
      defineTarget({
        name: "gemini",
        model: (sessionId) =>
          new ChatGoogleGenerativeAI({
            apiKey: googleKey,
            model: googleModel,
            baseUrl: gateway,
            customHeaders: {
              ...three,
              "x-three-ai-provider": "gemini",
              ...sessionHeaders(sessionId),
            },
          }),
        callOptions: () => ({}),
        modelSettings: () => ({}),
      }),
    );
  } else {
    skipped.push("gemini (GOOGLE_GENERATIVE_AI_API_KEY not set)");
  }

  // OpenRouter — through ChatOpenAI; the gateway needs OpenRouter's own base URL in
  // x-three-ai-provider-baseurl.
  const openrouterKey = env("OPENROUTER_API_KEY");
  if (openrouterKey) {
    const openrouterModel = env("OPENROUTER_MODEL") ?? "qwen/qwen3.8-27b";
    targets.push(
      defineTarget({
        name: "openrouter",
        model: (sessionId) =>
          new ChatOpenAI({
            apiKey: openrouterKey,
            model: openrouterModel,
            configuration: {
              baseURL: `${gateway}/v1`,
              defaultHeaders: {
                ...three,
                "x-three-ai-provider": "openrouter",
                "x-three-ai-provider-baseurl": "https://openrouter.ai/api/v1",
                ...sessionHeaders(sessionId),
              },
            },
          }),
        ...openaiSession,
      }),
    );
  } else {
    skipped.push("openrouter (OPENROUTER_API_KEY not set)");
  }

  // Azure OpenAI — the model is the deployment name, and AZURE_ENDPOINT is the resource
  // address with no path (https://<resource>.openai.azure.com).
  const azureKey = env("AZURE_API_KEY");
  const azureEndpointValue = env("AZURE_ENDPOINT");
  const azureDeployment = env("AZURE_DEPLOYMENT");
  if (azureKey && azureEndpointValue && azureDeployment) {
    const azureEndpoint = originOnly(
      "AZURE_ENDPOINT",
      azureEndpointValue,
      "https://<resource>.openai.azure.com",
    );

    // Deployment URLs, only when AZURE_API_VERSION is set. It is an Azure API version such
    // as 2025-04-01-preview, not the model version; a wrong value gets 404 from Azure.
    const apiVersion = env("AZURE_API_VERSION");

    targets.push(
      defineTarget({
        name: "azure",
        // v1 URLs: ChatOpenAI with the deployment name as the model.
        model: (sessionId) =>
          new ChatOpenAI({
            apiKey: azureKey,
            model: azureDeployment,
            configuration: {
              baseURL: `${gateway}/v1`,
              defaultHeaders: {
                ...three,
                "x-three-ai-provider": "azure_openai",
                "x-three-ai-provider-baseurl": `${azureEndpoint}/openai/v1`,
                ...sessionHeaders(sessionId),
              },
            },
          }),
        deploymentChatModel: apiVersion
          ? (sessionId) =>
              new AzureChatOpenAI({
                azureOpenAIApiKey: azureKey,
                azureOpenAIEndpoint: gateway,
                azureOpenAIApiDeploymentName: azureDeployment,
                azureOpenAIApiVersion: apiVersion,
                // Without it, the request body carries ChatOpenAI's default model
                // (gpt-3.5-turbo), and Three.dev records that as the model.
                model: azureDeployment,
                configuration: {
                  defaultHeaders: {
                    ...three,
                    "x-three-ai-provider": "azure_openai",
                    "x-three-ai-provider-baseurl": azureEndpoint,
                    ...sessionHeaders(sessionId),
                  },
                },
              })
          : undefined,
        ...openaiSession,
      }),
    );
  } else {
    skipped.push("azure (AZURE_API_KEY, AZURE_ENDPOINT and AZURE_DEPLOYMENT not all set)");
  }

  return { targets, skipped };
}
