# OmniRoute connection

NDS MiSTer Test ships a connection layer for a self-hosted
[OmniRoute](https://github.com/diegosouzapw/OmniRoute) gateway — one
OpenAI-compatible endpoint (`/v1`) in front of ~375 AI providers, with
automatic fallback and `auto` routing. The gateway is **not** part of this
repo and **not running by default**: start one locally (npm or Docker), on a
LAN box, or on a VPS, point the app at it, and every current and future AI
feature in this project uses the same three Convex actions.

Connection layer: `src/convex/omniroute.ts`
Compose file for a local gateway: `docker-compose.yml`

## 1. Run a gateway

**Docker Compose (this repo)** — recommended:

```bash
docker compose up -d          # dashboard + API on 127.0.0.1:20128
docker compose logs -f omniroute
docker compose down
```

Gateway state persists in `./omniroute-data/`. The port is loopback-only;
before exposing it beyond this machine, set `REQUIRE_API_KEY=true` in the
gateway's `.env` and only then widen the binding.

**npm (global):**

```bash
npm install -g omniroute
omniroute serve               # dashboard + API on port 20128
omniroute serve --headless    # /v1 proxy only, no dashboard (OMNIROUTE_HEADLESS=1)
```

**Docker (plain CLI):**

```bash
docker run -d --name omniroute --restart unless-stopped \
  -p 127.0.0.1:20128:20128 \
  -v "$PWD/omniroute-data:/app/data" \
  -e DATA_DIR=/app/data \
  diegosouzapw/omniroute:latest
```

**Remote / VPS:** OmniRoute's own docs cover source builds, the `cli`, `web`
and sidecar compose profiles, reverse-proxy `basePath` and remote mode —
see the [OmniRoute repo](https://github.com/diegosouzapw/OmniRoute) and its
`docs/` directory.

Whichever way it runs, open the dashboard once, connect the provider accounts
you want (free tiers included), then copy the gateway key from
**Dashboard → Endpoints**.

## 2. Configure this app

Four environment variables, read by the Convex actions at call time. Set them
in the Freebuff **Keys / API keys** tab (they land in the Convex deployment
environment — never commit them):

| Variable               | Required | Default                 | Meaning                                            |
| ---------------------- | -------- | ----------------------- | -------------------------------------------------- |
| `OMNIROUTE_BASE_URL`   | no       | `http://localhost:20128`| Gateway origin, without `/v1`.                     |
| `OMNIROUTE_API_KEY`    | yes\*    | —                       | Bearer key from Dashboard → Endpoints.             |
| `OMNIROUTE_MODEL`      | no       | `auto`                  | Default routing model or combo id.                 |
| `OMNIROUTE_TIMEOUT_MS` | no       | `30000`                 | Per-request timeout.                               |

\* A fresh local gateway runs keyless (`REQUIRE_API_KEY=false`), so the key
is optional there — add one before the gateway serves anything off-localhost.

`auto` variants worth knowing: `auto/fast` (lowest latency), `auto/cheap`
(cheapest per token), `auto/coding` (quality-first for code),
`auto/subscription` (only quota you already pay for, fails closed).

## 3. The action surface

All three are Convex node actions in `src/convex/omniroute.ts`; the key never
reaches the browser.

- `omniroute.status` — tokenless probe: reachable, HTTP status, gateway URL,
  configured model, whether a key is set, model count, latency, error text.
  This is the health check to call first.
- `omniroute.chat` — OpenAI-compatible chat completion. Args: `messages`
  (required), `model`, `maxTokens`, `temperature`. Returns the assistant
  `content`, resolved `model`, `usage`, the gateway's
  `X-OmniRoute-Decision` routing header and latency. Requires sign-in.
- `omniroute.models` — model discovery via `GET /v1/models`. Args: `limit`
  (1–500, default 100). Returns `{ models, total, ok, error }`. Requires
  sign-in.

Example, from any client component:

```tsx
import { useAction } from "convex/react";
import { api } from "@/convex/_generated/api";

const chat = useAction(api.omniroute.chat);
const result = await chat({
  messages: [{ role: "user", content: "Which OSD group controls scanlines?" }],
});
if (result.ok) console.log(result.content, result.model, result.usage);
```

## 4. Other AI clients

The same gateway serves any OpenAI-compatible client — point it at
`<BASE_URL>/v1` with the OmniRoute key as the API key and `auto` as the
model. OmniRoute also ships one-command setup for ~37 CLIs and agents:

```bash
omniroute configure           # interactive picker for Claude Code, Codex, Cursor, …
omniroute run claude-code     # launch a client already wired to the gateway
```

Typical environment for a client:

```bash
export OPENAI_BASE_URL=http://localhost:20128/v1
export OPENAI_API_KEY=<omniroute-key>
export OPENAI_MODEL=auto
```

## 5. Verify

```bash
curl http://localhost:20128/v1/models          # list what the gateway can route
curl http://localhost:20128/v1/chat/completions \
  -H "Authorization: Bearer <omniroute-key>" \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"Hello!"}]}'
```

Then call `omniroute.status` from the app — with the gateway stopped it
returns `reachable: false` and the fetch error text instead of throwing, so
every consumer can degrade cleanly until the gateway is up.
