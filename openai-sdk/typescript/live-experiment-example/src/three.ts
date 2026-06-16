// three.ts — everything Three.dev–specific for Live Experiments lives here.
//
// Three.dev Live Experiments work through a gateway proxy. Your OpenAI client is
// pointed at the Three.dev gateway instead of api.openai.com; the gateway holds the
// real OpenAI provider credentials for your use case, records the request, and applies
// the active experiment. You ask the control plane which variant to use by calling
// /experiments/assign before each request, then report a quality metric at the end.
//
// This module exposes five helpers used by index.ts:
//   - createOpenAIClient()    build an OpenAI client wired to the gateway + session headers
//   - requestTagHeaders()     build per-request X-Three-Tag-<KEY> headers
//   - assign()                POST /experiments/assign — which variant for this session?
//   - paramsFromAssignment()  turn the assignment metadata into chat-completion params
//   - reportMetric()          POST /metrics/report — did the session achieve its goal?

import OpenAI from "openai";

/** Static configuration for one conversation/session. */
export interface ThreeConfig {
  /** Three.dev API key (r3_sk_...). Used both as the gateway apiKey and as the
   *  Authorization: Bearer token on the control-plane calls (assign / metrics). */
  apiKey: string;
  /** Three.dev use case slug — must match the use case configured in the dashboard. */
  useCase: string;
  /** Control-plane base URL (assign + metrics). Default: https://api.three.dev */
  apiEndpoint: string;
  /** LLM gateway base URL (OpenAI-compatible). Default: https://gate.three.dev/v1 */
  gatewayUrl: string;
  /** One stable identifier for the whole conversation. Sent on every request. */
  sessionId: string;
}

/** Response from /experiments/assign. The endpoint returns `null` when no experiment
 *  is running or the session was assigned to the control group. */
export interface Assignment {
  experiment_id: string;
  variant_slug: string;
  /** Variant configuration, e.g. { "model": "gpt-5-mini", "provider": "openai" }. */
  metadata: Record<string, unknown>;
}

/**
 * Build an OpenAI client that routes through the Three.dev gateway.
 *
 * The session-level headers below are sent on EVERY request made with this client:
 *   - X-Three-Use-Case        which use case is being recorded
 *   - X-Three-AI-Provider     which provider the gateway should forward to
 *   - X-Three-Session-ID      groups all requests into one conversation
 *   - x-three-session-tag-<K> optional session-level tags (apply to the whole session)
 *
 * Note that `apiKey` is the Three.dev key — NOT an OpenAI key. The gateway holds the
 * real OpenAI credentials for your use case, so no OPENAI_API_KEY is needed.
 */
export function createOpenAIClient(
  cfg: ThreeConfig,
  sessionTags: Record<string, string> = {},
): OpenAI {
  const defaultHeaders: Record<string, string> = {
    "X-Three-Use-Case": cfg.useCase,
    "X-Three-AI-Provider": "openai",
    "X-Three-Session-ID": cfg.sessionId,
  };

  // Session-tags: applied to every request in the session.
  for (const [key, value] of Object.entries(sessionTags)) {
    defaultHeaders[`x-three-session-tag-${key}`] = value;
  }

  return new OpenAI({
    apiKey: cfg.apiKey,
    baseURL: cfg.gatewayUrl,
    defaultHeaders,
  });
}

/**
 * Build per-request tag headers (X-Three-Tag-<KEY>: <VALUE>). Pass the result as the
 * `headers` of the second argument to `client.chat.completions.create(body, { headers })`.
 * These merge over (and can be used alongside) the client's session-level headers.
 */
export function requestTagHeaders(
  tags: Record<string, string>,
): Record<string, string> {
  const headers: Record<string, string> = {};
  for (const [key, value] of Object.entries(tags)) {
    headers[`X-Three-Tag-${key}`] = value;
  }
  return headers;
}

/**
 * Ask Three.dev which variant to use for this session. Call this BEFORE every LLM
 * request. Returns the assignment, or `null` for control / no active experiment.
 *
 * Fail-soft: any network or non-2xx error is logged and treated as control (returns
 * null) so the conversation always proceeds.
 */
export async function assign(cfg: ThreeConfig): Promise<Assignment | null> {
  try {
    const res = await fetch(`${cfg.apiEndpoint}/api/v1/experiments/assign`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${cfg.apiKey}`,
      },
      body: JSON.stringify({
        session_id: cfg.sessionId,
        use_case: cfg.useCase,
      }),
    });

    if (!res.ok) {
      console.warn(`assign: ${res.status} ${res.statusText} — falling back to control`);
      return null;
    }

    // A running experiment returns an Assignment; control / no experiment returns null.
    return (await res.json()) as Assignment | null;
  } catch (err) {
    console.warn(`assign failed (${String(err)}) — falling back to control`);
    return null;
  }
}

/**
 * Translate an assignment into the request configuration for one turn.
 *
 * A variant's `metadata` can carry two kinds of keys, with different destinations:
 *   - chat-completion parameters (model, temperature, top_p, max_tokens, …) → request body
 *   - `provider` → routing, which belongs in the X-Three-AI-Provider header, NOT the body
 *     (OpenAI rejects unknown body params, e.g. 400 "Unknown parameter: 'provider'").
 *
 * `model` is always set in the body — the variant's model wins, else `defaultModel`
 * (e.g. on control / no experiment). Spread `body` into `chat.completions.create(...)`
 * and merge `headers` into its request options.
 */
export function paramsFromAssignment(
  assignment: Assignment | null,
  defaultModel: string,
): { body: Record<string, unknown> & { model: string }; headers: Record<string, string> } {
  const { provider, model, ...params } = assignment?.metadata ?? {};
  return {
    body: {
      ...params, // any other chat params the variant sets (temperature, top_p, …)
      model: typeof model === "string" ? model : defaultModel,
    },
    headers: typeof provider === "string" ? { "X-Three-AI-Provider": provider } : {},
  };
}

/**
 * Report whether the session achieved its goal. Call once, at the end of the session.
 *
 * Three.dev needs the session's first request to be fully recorded before a metric can
 * attach to it (up to ~5s) — the caller is responsible for that delay. Fail-soft.
 */
export async function reportMetric(
  cfg: ThreeConfig,
  metric: string,
  outcome: boolean,
): Promise<void> {
  try {
    const res = await fetch(`${cfg.apiEndpoint}/api/v1/metrics/report`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${cfg.apiKey}`,
      },
      body: JSON.stringify({
        metric,
        use_case: cfg.useCase,
        session_id: cfg.sessionId,
        outcome,
      }),
    });
    if (!res.ok) {
      console.warn(`reportMetric: ${res.status} ${res.statusText}`);
    }
  } catch (err) {
    console.warn(`reportMetric failed (${String(err)})`);
  }
}
