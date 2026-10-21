"use node";

import { v } from "convex/values";
import { action, type ActionCtx } from "./_generated/server";

/**
 * OmniRoute gateway connection layer.
 *
 * Everything the app (now or later) needs to talk to a self-hosted OmniRoute
 * gateway — https://github.com/diegosouzapw/OmniRoute — behind its
 * OpenAI-compatible `/v1` surface. The gateway itself is not bundled: it runs
 * separately (npm, Docker, or a remote host) and this module only reads its
 * location and key from the deployment environment:
 *
 *   OMNIROUTE_BASE_URL   gateway origin, default http://localhost:20128
 *   OMNIROUTE_API_KEY    key from Dashboard → Endpoints (optional on a
 *                        keyless local gateway, required once REQUIRE_API_KEY
 *                        is on)
 *   OMNIROUTE_MODEL      default routing model, default "auto"
 *   OMNIROUTE_TIMEOUT_MS request timeout, default 30000
 *
 * Set those in the Freebuff "Keys" tab (they land in the Convex deployment
 * environment); never hard-code them here. See docs/omniroute.md.
 */

const DEFAULT_BASE_URL = "http://localhost:20128";
const DEFAULT_MODEL = "auto";
const DEFAULT_TIMEOUT_MS = 30_000;
const PROBE_TIMEOUT_MS = 8_000;

function gatewayConfig() {
  const baseUrl = (process.env.OMNIROUTE_BASE_URL ?? DEFAULT_BASE_URL).replace(
    /\/+$/,
    "",
  );
  const apiKey = process.env.OMNIROUTE_API_KEY?.trim() || null;
  const model = process.env.OMNIROUTE_MODEL?.trim() || DEFAULT_MODEL;
  const timeoutMs = Number(process.env.OMNIROUTE_TIMEOUT_MS ?? DEFAULT_TIMEOUT_MS);
  return {
    baseUrl,
    apiKey,
    model,
    timeoutMs: Number.isFinite(timeoutMs) && timeoutMs > 0 ? timeoutMs : DEFAULT_TIMEOUT_MS,
    baseUrlFromEnv: Boolean(process.env.OMNIROUTE_BASE_URL),
  };
}

function requestHeaders(apiKey: string | null, json: boolean) {
  const headers: Record<string, string> = {};
  if (json) headers["Content-Type"] = "application/json";
  if (apiKey) headers["Authorization"] = `Bearer ${apiKey}`;
  return headers;
}

function errorMessage(err: unknown) {
  return err instanceof Error ? err.message : String(err);
}

/** Chat and model discovery spend the gateway's tokens — sign-in required. */
async function requireUser(ctx: ActionCtx) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) throw new Error("Sign in to use the AI gateway.");
  return identity.subject;
}

/**
 * Probe the gateway without spending tokens. Reports whether it is running
 * and reachable from this deployment, plus enough context to debug a bad
 * URL or missing key. Never returns the key itself.
 */
export const status = action({
  args: {},
  handler: async () => {
    const { baseUrl, apiKey, model, baseUrlFromEnv } = gatewayConfig();
    const started = Date.now();
    try {
      const res = await fetch(`${baseUrl}/v1/models`, {
        headers: requestHeaders(apiKey, false),
        signal: AbortSignal.timeout(PROBE_TIMEOUT_MS),
      });
      let modelCount: number | null = null;
      if (res.ok) {
        try {
          const body: unknown = await res.json();
          const data = (body as { data?: unknown })?.data;
          if (Array.isArray(data)) modelCount = data.length;
        } catch {
          /* body shape unknown — reachability alone is enough */
        }
      }
      return {
        reachable: res.ok,
        httpStatus: res.status,
        baseUrl,
        baseUrlFromEnv,
        model,
        keyPresent: apiKey !== null,
        modelCount,
        latencyMs: Date.now() - started,
        error: res.ok ? null : `Gateway responded with HTTP ${res.status}.`,
      };
    } catch (err) {
      return {
        reachable: false,
        httpStatus: null,
        baseUrl,
        baseUrlFromEnv,
        model,
        keyPresent: apiKey !== null,
        modelCount: null,
        latencyMs: Date.now() - started,
        error: errorMessage(err),
      };
    }
  },
});

/**
 * OpenAI-compatible chat completion through the gateway. The default model
 * comes from OMNIROUTE_MODEL ("auto" routes across connected providers with
 * automatic fallback); pass `model` to pin one model or combo id.
 */
export const chat = action({
  args: {
    messages: v.array(
      v.object({
        role: v.union(
          v.literal("system"),
          v.literal("user"),
          v.literal("assistant"),
        ),
        content: v.string(),
      }),
    ),
    model: v.optional(v.string()),
    maxTokens: v.optional(v.number()),
    temperature: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    await requireUser(ctx);
    const { baseUrl, apiKey, model, timeoutMs } = gatewayConfig();
    const chosenModel = args.model ?? model;

    const payload: Record<string, unknown> = {
      model: chosenModel,
      messages: args.messages,
    };
    if (args.maxTokens !== undefined) payload.max_tokens = args.maxTokens;
    if (args.temperature !== undefined) payload.temperature = args.temperature;

    const started = Date.now();
    try {
      const res = await fetch(`${baseUrl}/v1/chat/completions`, {
        method: "POST",
        headers: requestHeaders(apiKey, true),
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(timeoutMs),
      });
      const latencyMs = Date.now() - started;

      if (!res.ok) {
        const detail = await res.text().catch(() => "");
        return {
          ok: false as const,
          error: `Gateway responded with HTTP ${res.status}.`,
          detail: detail.slice(0, 500),
          model: chosenModel,
          latencyMs,
        };
      }

      const body = (await res.json()) as {
        model?: unknown;
        choices?: { message?: { content?: unknown }; finish_reason?: unknown }[];
        usage?: {
          prompt_tokens?: unknown;
          completion_tokens?: unknown;
          total_tokens?: unknown;
        };
      };
      const choice = body.choices?.[0];
      return {
        ok: true as const,
        content: typeof choice?.message?.content === "string" ? choice.message.content : "",
        model: typeof body.model === "string" ? body.model : chosenModel,
        finishReason: typeof choice?.finish_reason === "string" ? choice.finish_reason : null,
        usage:
          body.usage && typeof body.usage === "object"
            ? {
                promptTokens: typeof body.usage.prompt_tokens === "number" ? body.usage.prompt_tokens : null,
                completionTokens:
                  typeof body.usage.completion_tokens === "number" ? body.usage.completion_tokens : null,
                totalTokens: typeof body.usage.total_tokens === "number" ? body.usage.total_tokens : null,
              }
            : null,
        decision: res.headers.get("x-omniroute-decision"),
        latencyMs,
      };
    } catch (err) {
      return {
        ok: false as const,
        error: errorMessage(err),
        detail: null,
        model: chosenModel,
        latencyMs: Date.now() - started,
      };
    }
  },
});

/** Model discovery (`GET /v1/models`) — what the gateway can currently route. */
export const models = action({
  args: { limit: v.optional(v.number()) },
  handler: async (ctx, args) => {
    await requireUser(ctx);
    const { baseUrl, apiKey, timeoutMs } = gatewayConfig();
    const limit = Math.min(Math.max(args.limit ?? 100, 1), 500);
    try {
      const res = await fetch(`${baseUrl}/v1/models`, {
        headers: requestHeaders(apiKey, false),
        signal: AbortSignal.timeout(Math.min(timeoutMs, PROBE_TIMEOUT_MS * 2)),
      });
      if (!res.ok) {
        return {
          ok: false as const,
          error: `Gateway responded with HTTP ${res.status}.`,
          models: [] as string[],
          total: 0,
        };
      }
      const body = (await res.json()) as { data?: { id?: unknown }[] };
      const ids = (Array.isArray(body.data) ? body.data : [])
        .map((entry) => (typeof entry?.id === "string" ? entry.id : null))
        .filter((id): id is string => id !== null);
      return {
        ok: true as const,
        error: null,
        models: ids.slice(0, limit),
        total: ids.length,
      };
    } catch (err) {
      return {
        ok: false as const,
        error: errorMessage(err),
        models: [] as string[],
        total: 0,
      };
    }
  },
});
