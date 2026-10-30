// Archil persistent disk for the OSD Lab.
// See /docs/archil.md for usage documentation.
//
// The lab keeps its per-game OSD profiles in localStorage, so a browser that
// clears its storage (or a different machine) boots with defaults. This module
// is the durable side of that story: an Archil disk holding the profile
// snapshot, so files and context survive between runs. Node-only — the API key
// never reaches the browser; the Convex actions in src/convex/archil.ts are the
// only callers.

import * as archil from "disk";

/** Default disk name; override with ARCHIL_DISK_NAME. */
const DEFAULT_DISK_NAME = "nds-mister-core";

/** Where the OSD profile snapshot lives on the disk. */
export const PROFILE_KEY = "osd/profiles.json";

export interface ProfileSnapshot {
  /** ISO timestamp written by the last save. */
  savedAt: string;
  /** The lab's stored profiles, stored verbatim. */
  profiles: unknown;
}

export interface ArchilStatus {
  configured: boolean;
  diskName: string;
  diskId: string | null;
  files: string[];
  error: string | null;
}

let configured = false;

function errorMessage(err: unknown) {
  return err instanceof Error ? err.message : String(err);
}

/** The account API key, read from the environment only. */
export function archilApiKey(): string | null {
  const key = process.env.ARCHIL_API_KEY?.trim();
  return key ? key : null;
}

export function isArchilConfigured(): boolean {
  return archilApiKey() !== null;
}

export function diskName(): string {
  return process.env.ARCHIL_DISK_NAME?.trim() || DEFAULT_DISK_NAME;
}

function configureOnce() {
  if (configured) return;
  const apiKey = archilApiKey();
  if (!apiKey) {
    throw new Error(
      "ARCHIL_API_KEY is not set — add an Archil API key to enable the persistent disk.",
    );
  }
  archil.configure({
    apiKey,
    region: process.env.ARCHIL_REGION?.trim() || undefined,
  });
  configured = true;
}

/**
 * The project's disk: looked up by name, created on first run so every later
 * run opens the same disk and the same files.
 */
export async function openWorkspaceDisk() {
  configureOnce();
  const name = diskName();
  const existing = await archil.listDisks({ name });
  const match = existing.find((candidate) => candidate.name === name);
  if (match) return match;
  const { disk } = await archil.createDisk({ name });
  return disk;
}

/** Write the OSD profile snapshot to the disk. */
export async function saveOsdProfiles(profiles: unknown) {
  const disk = await openWorkspaceDisk();
  const snapshot: ProfileSnapshot = { savedAt: new Date().toISOString(), profiles };
  const body = JSON.stringify(snapshot, null, 2);
  const { etag } = await disk.putObject(PROFILE_KEY, body, "application/json");
  return {
    diskName: disk.name,
    diskId: disk.id,
    key: PROFILE_KEY,
    bytes: body.length,
    etag: etag ?? null,
  };
}

/** Read the OSD profile snapshot back; `profiles` is null before the first save. */
export async function loadOsdProfiles() {
  const disk = await openWorkspaceDisk();
  const meta = await disk.headObject(PROFILE_KEY);
  if (!meta) {
    return {
      diskName: disk.name,
      diskId: disk.id,
      key: PROFILE_KEY,
      savedAt: null,
      profiles: null,
    };
  }
  const text = new TextDecoder().decode(await disk.getObject(PROFILE_KEY));
  let snapshot: Partial<ProfileSnapshot>;
  try {
    snapshot = JSON.parse(text) as Partial<ProfileSnapshot>;
  } catch {
    throw new Error(`${PROFILE_KEY} on ${disk.name} is not valid JSON.`);
  }
  return {
    diskName: disk.name,
    diskId: disk.id,
    key: PROFILE_KEY,
    savedAt: typeof snapshot.savedAt === "string" ? snapshot.savedAt : null,
    profiles: snapshot.profiles ?? null,
  };
}

/**
 * Health check: is a key configured, does the disk open, what does it hold?
 * Never throws — a missing key or an Archil error is reported, not raised, so
 * the lab degrades to local-only profiles instead of breaking.
 */
export async function archilStatus(): Promise<ArchilStatus> {
  const name = diskName();
  if (!isArchilConfigured()) {
    return {
      configured: false,
      diskName: name,
      diskId: null,
      files: [],
      error: "ARCHIL_API_KEY is not set.",
    };
  }
  try {
    const disk = await openWorkspaceDisk();
    const page = await disk.listObjects("osd/", { recursive: true, limit: 20 });
    return {
      configured: true,
      diskName: disk.name,
      diskId: disk.id,
      files: page.objects.map((object) => object.key),
      error: null,
    };
  } catch (err) {
    return {
      configured: true,
      diskName: name,
      diskId: null,
      files: [],
      error: errorMessage(err),
    };
  }
}
