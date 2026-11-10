# Archil persistent disk

The OSD Lab keeps its profiles in `localStorage`
(`nds-mister-test-osd-profiles-v2`): one base profile for the console and one
snapshot per cartridge. That is the browser's SD card — and it dies with the
browser. Archil gives the same snapshot a real home, so the menu state, cheats
and per-game values a player configured are still there on the next run, on any
machine.

Integration: `src/lib/archil.ts` (disk access) and `src/convex/archil.ts` (the
server actions). The disk is part of the project's server workflow: the API key
is read from the deployment environment and never reaches the browser.

## Why a disk and not a table

The snapshot is a file the lab already serialises (`{ base, games }`). A disk
keeps it as a file — the same shape the core writes to the MiSTer SD card — and
the disk can hold the rest of the workflow later (ROM manifests, `.cht` files,
save data) without a schema change.

## Environment

Set these in the Freebuff **Keys / API keys** tab (they land in the Convex
deployment environment — never commit them). `.env.example` lists them empty.

| Variable            | Required | Default            | Meaning                                                        |
| ------------------- | -------- | ------------------ | -------------------------------------------------------------- |
| `ARCHIL_API_KEY`    | yes      | —                  | Account API key from the Archil dashboard.                     |
| `ARCHIL_DISK_NAME`  | no       | `nds-mister-core`  | Disk to open; created on first use.                             |
| `ARCHIL_REGION`     | no       | `aws-us-east-1`    | Archil region — `aws-us-east-1`, `aws-us-west-2`, `aws-eu-west-1`, `gcp-us-central1`. |

The `disk` package (npm, v1.9.0) has no native dependencies and requires
Node.js 22.19 or later.

## Action surface

All three are Convex node actions in `src/convex/archil.ts`:

- `archil.status` — tokenless probe: whether a key is set, whether the disk
  opens, the disk id and the files under `osd/`. Never throws.
- `archil.saveProfile` — writes the lab's stored profiles to
  `osd/profiles.json` with a `savedAt` timestamp. Arg: `profiles`, the JSON
  string of `{ base, games }`. Requires sign-in.
- `archil.loadProfile` — reads the snapshot back, `profiles: null` before the
  first save. Requires sign-in.

```tsx
import { useAction } from "convex/react";
import { api } from "@/convex/_generated/api";

const save = useAction(api.archil.saveProfile);
const load = useAction(api.archil.loadProfile);

await save({ profiles: JSON.stringify(storedProfiles) });
const snapshot = await load();
if (snapshot.ok && snapshot.profiles) {
  /* restore { base, games } into the lab */
}
```

With no key configured the actions report `{ ok: false, error: "ARCHIL_API_KEY
is not set." }` (or `configured: false` from `status`), so the lab keeps
working on `localStorage` alone.

## Verify

Run the disk helper directly from the repo root with the key in the
environment (Bun loads `.env.local`):

```bash
bun -e "import { archilStatus } from './src/lib/archil.ts'; console.log(await archilStatus())"
```

`configured: true` with a `diskId` means Archil answered; the first call
creates the disk when it does not exist yet.
