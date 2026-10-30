"use node";

import { v } from "convex/values";
import { action, type ActionCtx } from "./_generated/server";
import { archilStatus, loadOsdProfiles, saveOsdProfiles } from "../lib/archil";

/**
 * Archil persistent disk layer for the OSD Lab.
 *
 * The lab's OSD profiles live in localStorage, i.e. in one browser on one
 * machine. These node actions keep the same snapshot on an Archil disk
 * (https://docs.archil.com/sdks/typescript), so the menu state, cheats and
 * per-game saves a player configured survive between runs. The disk is part of
 * the project's server workflow: the API key is read here from the deployment
 * environment and never reaches the browser.
 *
 *   ARCHIL_API_KEY    account API key from the Archil dashboard (required)
 *   ARCHIL_DISK_NAME  disk to open, default "nds-mister-core"
 *   ARCHIL_REGION     optional Archil region, e.g. aws-us-east-1
 *
 * Set them in the Freebuff "Keys" tab (they land in the Convex deployment
 * environment); never hard-code them here. See docs/archil.md.
 */

function errorMessage(err: unknown) {
  return err instanceof Error ? err.message : String(err);
}

/** Profiles are player data — sign-in required to read or write them. */
async function requireUser(ctx: ActionCtx) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) throw new Error("Sign in to sync your OSD profile to Archil.");
  return identity.subject;
}

/**
 * Probe the disk without touching the snapshot: whether an API key is set,
 * whether the disk opens (created on first use), and what it holds.
 */
export const status = action({
  args: {},
  handler: async () => archilStatus(),
});

/** Persist the lab's stored profiles (`{ base, games }`) as JSON. */
export const saveProfile = action({
  args: { profiles: v.string() },
  handler: async (ctx, args) => {
    await requireUser(ctx);
    let profiles: unknown;
    try {
      profiles = JSON.parse(args.profiles);
    } catch {
      return { ok: false as const, error: "profiles must be JSON.", diskName: null };
    }
    try {
      return { ok: true as const, error: null, ...(await saveOsdProfiles(profiles)) };
    } catch (err) {
      return { ok: false as const, error: errorMessage(err), diskName: null };
    }
  },
});

/** Restore the snapshot written by `saveProfile`, or null before the first save. */
export const loadProfile = action({
  args: {},
  handler: async (ctx) => {
    await requireUser(ctx);
    try {
      return { ok: true as const, error: null, ...(await loadOsdProfiles()) };
    } catch (err) {
      return {
        ok: false as const,
        error: errorMessage(err),
        diskName: null,
        profiles: null,
        savedAt: null,
      };
    }
  },
});
