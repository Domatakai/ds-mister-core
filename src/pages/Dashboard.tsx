import { DsScreen } from "@/components/osd/DsScreen";
import { OsdPanel } from "@/components/osd/OsdPanel";
import { useAuth } from "@/hooks/use-auth";
import {
  OSD_ROOT,
  ROMS,
  activeCheats,
  defaultValues,
  loadedRom,
  rowsFor,
  type OsdNode,
  type OsdValues,
} from "@/lib/osd-tree";
import { LogOut } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { Link, useNavigate } from "react-router";

type Submenu = Extract<OsdNode, { kind: "submenu" }>;

interface MenuFrame {
  node: Submenu;
  index: number;
}

interface LogEntry {
  time: string;
  text: string;
}

const STORAGE_KEY = "nds-mister-test-osd-profiles-v2";
const LEGACY_KEY = "nds-mister-test-osd-profile-v1";

const IDLE_STATUS = "↑↓ rows · ←→ values · OK open · ESC back";

interface StoredProfiles {
  /** Profile in force when no cartridge is loaded. */
  base: OsdValues;
  /** One snapshot per game, keyed by ROM title — a profile per game. */
  games: Record<string, OsdValues>;
}

function readProfiles(): StoredProfiles {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) {
      const parsed = JSON.parse(raw) as Partial<StoredProfiles>;
      return {
        base: { ...defaultValues(), ...(parsed.base ?? {}) },
        games: parsed.games ?? {},
      };
    }
    // Migrate the single-profile layout written by the old build.
    const legacy = localStorage.getItem(LEGACY_KEY);
    if (legacy)
      return { base: { ...defaultValues(), ...(JSON.parse(legacy) as OsdValues) }, games: {} };
  } catch {
    /* storage unavailable — session-only profile */
  }
  return { base: defaultValues(), games: {} };
}

/** The stored snapshot for a game, falling back to the console profile. */
function valuesFor(profiles: StoredProfiles, title: string | null): OsdValues {
  const saved = title ? profiles.games[title] : undefined;
  return {
    ...defaultValues(),
    ...profiles.base,
    ...(saved ?? {}),
    "cart.rom": title ?? "— EMPTY —",
  };
}

function timestamp() {
  return new Date().toLocaleTimeString("en-GB", { hour12: false });
}

/**
 * The OSD Lab: the core's full menu tree, running against a simulated video
 * output. Arrow keys drive it exactly like a MiSTer keyboard, values persist
 * to a local profile the way the core persists to the SD card.
 */
export default function Dashboard() {
  const { user, signOut } = useAuth();
  const navigate = useNavigate();

  const [stored] = useState<StoredProfiles>(readProfiles);
  const profilesRef = useRef<StoredProfiles>(stored);

  const [values, setValues] = useState<OsdValues>(() => {
    const title = stored.base["cart.rom"] ?? "";
    return valuesFor(stored, ROMS.some((r) => r.title === title) ? title : null);
  });
  const [stack, setStack] = useState<MenuFrame[]>([{ node: OSD_ROOT, index: 0 }]);
  const [osdOpen, setOsdOpen] = useState(true);
  const [status, setStatus] = useState(IDLE_STATUS);
  const [log, setLog] = useState<LogEntry[]>([]);
  const [booting, setBooting] = useState(false);
  const [fps, setFps] = useState(59.83);
  const [frameMs, setFrameMs] = useState(16.71);
  const [frameTimes, setFrameTimes] = useState<number[]>([]);

  const frame = stack[stack.length - 1];
  const rows = rowsFor(frame.node, values);
  const rom = loadedRom(values);
  const cheatsOn = activeCheats(values);
  const breadcrumb = stack.map((f) => f.node.label).join(" › ");

  useEffect(() => {
    const stored = profilesRef.current;
    if (rom) stored.games = { ...stored.games, [rom.title]: values };
    else stored.base = values;
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(stored));
    } catch {
      /* storage unavailable — session-only profile */
    }
  }, [values, rom]);

  // Simulated core timing: speed and frameskip move the measured rate, the
  // frame-time buffer feeds the diagnostics graph on the top screen.
  const speed = values["emu.speed"] ?? "100%";
  const frameskip = values["emu.frameskip"] ?? "Off";
  const autoskip = values["emu.autoskip"] ?? "Off";
  useEffect(() => {
    const base = speed === "Max" ? 239.76 : (Number.parseInt(speed) / 100) * 59.826;
    const variance = frameskip === "Off" && autoskip === "Off" ? 0.05 : 0.35;
    const tick = () => {
      const measured = base - Math.random() * variance;
      setFps(measured);
      const ms = 1000 / measured;
      setFrameMs(ms);
      setFrameTimes((prev) => [...prev.slice(-39), ms]);
    };
    tick();
    const id = setInterval(tick, 600);
    return () => clearInterval(id);
  }, [speed, frameskip, autoskip]);

  const pushLog = (text: string) => {
    setStatus(text);
    setLog((prev) => [{ time: timestamp(), text }, ...prev].slice(0, 5));
  };

  const setRowValue = (id: string, next: string, label: string) => {
    setValues((prev) => ({ ...prev, [id]: next }));
    pushLog(`${label}: ${next}`);
  };

  const cycle = (child: Extract<OsdNode, { kind: "choice" | "toggle" }>, dir: number) => {
    if (child.kind === "toggle") {
      const next = (values[child.id] ?? "Off") === "On" ? "Off" : "On";
      setRowValue(child.id, next, child.label);
      return;
    }
    const options = child.options;
    const current = options.indexOf(values[child.id] ?? options[0]);
    const next = options[(current + dir + options.length) % options.length];
    if (child.id === "cart.rom" && next !== "— EMPTY —") {
      // Each cartridge keeps its own profile: load the game's snapshot,
      // or the console profile when it has never been booted here.
      const stored = profilesRef.current;
      setValues(valuesFor(stored, next));
      const cart = ROMS.find((r) => r.title === next);
      if (cart) {
        const region = values["bios.region"] ?? "Auto";
        pushLog(
          region === "Auto"
            ? `${cart.title} (${cart.region}) booted — region lock: none`
            : `${cart.title} (${cart.region}) booted on ${region} region`,
        );
      }
      return;
    }
    setRowValue(child.id, next, child.label);
  };

  const runAction = (id: string, label: string) => {
    switch (id) {
      case "cart.erase":
        pushLog("Save data erased");
        break;
      case "cart.eject":
        setValues(valuesFor(profilesRef.current, null));
        pushLog("Cartridge ejected");
        break;
      case "cheats.file":
        pushLog("Cheat file .cht parsed — per-game codes armed");
        break;
      case "cheats.clear":
        setValues((prev) => ({
          ...prev,
          "cheats.hearts": "Off",
          "cheats.coins": "Off",
          "cheats.karts": "Off",
        }));
        pushLog("All cheats disabled");
        break;
      case "reset.soft":
      case "reset.hard":
        setBooting(true);
        window.setTimeout(() => setBooting(false), 1200);
        pushLog(`${label} — ARM9/ARM7 restarted`);
        break;
      case "reset.profile": {
        const stored = profilesRef.current;
        if (rom) stored.games = { ...stored.games, [rom.title]: defaultValues() };
        else stored.base = defaultValues();
        setValues(defaultValues());
        pushLog("OSD profile reset to defaults");
        break;
      }
      default:
        pushLog(label);
    }
  };

  const activateAt = (index: number) => {
    const child = frame.node.children[index];
    if (!child) return;
    if (child.kind === "submenu") {
      setStack((prev) => [...prev, { node: child, index: 0 }]);
      setStatus(IDLE_STATUS);
      return;
    }
    if (child.kind === "action") {
      runAction(child.id, child.label);
      return;
    }
    cycle(child, 1);
  };

  const move = (dir: number) => {
    setStack((prev) => {
      const next = [...prev];
      const last = next[next.length - 1];
      const count = last.node.children.length;
      next[next.length - 1] = { ...last, index: (last.index + dir + count) % count };
      return next;
    });
  };

  const goBack = () => {
    if (stack.length > 1) {
      setStack((prev) => prev.slice(0, -1));
      setStatus(IDLE_STATUS);
    } else {
      setOsdOpen(false);
    }
  };

  const handleKey = (event: KeyboardEvent) => {
    if (event.key === "F12") {
      event.preventDefault();
      setOsdOpen((open) => !open);
      return;
    }
    if (!osdOpen) return;
    switch (event.key) {
      case "ArrowUp":
        event.preventDefault();
        move(-1);
        break;
      case "ArrowDown":
        event.preventDefault();
        move(1);
        break;
      case "ArrowRight":
        event.preventDefault();
        activateAt(frame.index);
        break;
      case "ArrowLeft":
        event.preventDefault();
        if (stack.length > 1) goBack();
        else {
          const child = frame.node.children[frame.index];
          if (child && (child.kind === "choice" || child.kind === "toggle")) cycle(child, -1);
        }
        break;
      case "Enter":
        event.preventDefault();
        activateAt(frame.index);
        break;
      case "Escape":
      case "Backspace":
        event.preventDefault();
        goBack();
        break;
      default:
        break;
    }
  };

  const keyRef = useRef(handleKey);
  useEffect(() => {
    keyRef.current = handleKey;
  });
  useEffect(() => {
    const listener = (event: KeyboardEvent) => keyRef.current(event);
    window.addEventListener("keydown", listener);
    return () => window.removeEventListener("keydown", listener);
  }, []);

  const handleSignOut = async () => {
    await signOut();
    navigate("/");
  };

  const handleRowClick = (index: number) => {
    if (index === frame.index) activateAt(index);
    else setStack((prev) => {
      const next = [...prev];
      next[next.length - 1] = { ...next[next.length - 1], index };
      return next;
    });
  };

  return (
    <div className="min-h-screen bg-background text-foreground">
      <header className="sticky top-0 z-40 border-b border-border/80 bg-background/85 backdrop-blur-md">
        <div className="mx-auto flex h-14 w-full max-w-[1180px] items-center justify-between px-6 lg:px-10">
          <div className="flex items-baseline gap-3">
            <Link to="/" className="text-[14px] font-semibold tracking-[0.03em]">
              NDS MiSTer Test
            </Link>
            <span className="label-mono text-muted-foreground">OSD Lab</span>
          </div>
          <div className="flex items-center gap-4">
            {user?.email && (
              <span className="hidden font-mono text-[11px] text-muted-foreground sm:inline">
                {user.email}
              </span>
            )}
            <button
              type="button"
              onClick={handleSignOut}
              className="flex items-center gap-2 border border-border px-3 py-1.5 font-mono text-[11px] uppercase tracking-[0.14em] text-muted-foreground transition-colors hover:border-foreground/30 hover:text-foreground"
            >
              <LogOut className="size-3.5" />
              Sign out
            </button>
          </div>
        </div>
      </header>

      <main className="mx-auto w-full max-w-[1180px] px-6 pb-16 pt-10 lg:px-10">
        <div className="border-b border-border pb-8">
          <p className="label-mono text-muted-foreground">Simulator · v0.6.0-alpha</p>
          <h1 className="mt-4 text-[34px] font-medium leading-none tracking-[-0.02em] lg:text-[44px]">
            The OSD, in full.
          </h1>
          <p className="mt-4 max-w-2xl text-[15px] leading-7 text-muted-foreground">
            Every control the core exposes — cartridge, video, audio, BIOS, input,
            emulation, cheats and diagnostics — running against a simulated video
            output. Load any game from any region; choices persist to a local
            profile exactly as the core persists them to the SD card.
          </p>
        </div>

        <div className="mt-10 grid gap-10 lg:grid-cols-[minmax(0,1fr)_300px] lg:gap-12">
          <section className="mx-auto w-full max-w-[560px]">
            <div className="relative">
              <DsScreen
                values={values}
                rom={rom}
                booting={booting}
                osdOpen={osdOpen}
                fps={fps}
                frameMs={frameMs}
                frameTimes={frameTimes}
              />

              {osdOpen && (
                <div className="absolute inset-0 z-20 flex items-center justify-center p-4">
                  <OsdPanel
                    className="pointer-events-auto w-full max-w-[380px]"
                    title={frame.node.label}
                    rows={rows}
                    activeIndex={frame.index}
                    statusLine={status}
                    onRowClick={handleRowClick}
                  />
                </div>
              )}
            </div>

            <div className="mt-4 flex flex-wrap items-center justify-between gap-4">
              <p className="label-mono text-muted-foreground">
                ↑↓ rows · ←→ values · Enter OK · Esc back · F12 toggle
              </p>
              <button
                type="button"
                onClick={() => setOsdOpen((open) => !open)}
                className="border border-foreground bg-foreground px-4 py-2 font-mono text-[11px] uppercase tracking-[0.16em] text-background transition-opacity hover:opacity-80"
              >
                {osdOpen ? "Close OSD (Esc)" : "Open OSD (F12)"}
              </button>
            </div>
          </section>

          <aside className="flex flex-col gap-8">
            <section>
              <h2 className="label-mono border-b border-border pb-2.5 text-muted-foreground">
                Menu path
              </h2>
              <p className="mt-3 font-mono text-[12px] leading-6 text-foreground break-words">
                {breadcrumb}
              </p>
            </section>

            <section>
              <h2 className="label-mono border-b border-border pb-2.5 text-muted-foreground">
                Core state
              </h2>
              <dl className="mt-1">
                {[
                  ["Cartridge", rom ? rom.title : "— empty —"],
                  ["Save type", values["cart.savetype"] ?? "Auto"],
                  ["Output", `${values["video.layout"] ?? "Vertical"} · ${values["video.rotation"] ?? "0°"}`],
                  ["Region lock", values["bios.region"] === "Auto" ? "none — auto" : `${values["bios.region"]} locked`],
                  ["Core speed", speed],
                  ["Cheats", cheatsOn > 0 ? `${cheatsOn} active` : "none"],
                  ["Measured", `${fps.toFixed(2)} fps`],
                  ["Profile", rom ? `saved · ${rom.title}` : "saved · console"],
                ].map(([key, val]) => (
                  <div
                    key={key}
                    className="flex items-baseline justify-between gap-3 border-b border-border/60 py-2.5"
                  >
                    <dt className="font-mono text-[11px] uppercase tracking-[0.12em] text-muted-foreground">
                      {key}
                    </dt>
                    <dd className="truncate font-mono text-[12px] tabular-nums text-foreground">
                      {val}
                    </dd>
                  </div>
                ))}
              </dl>
            </section>

            <section>
              <h2 className="label-mono border-b border-border pb-2.5 text-muted-foreground">
                Status log
              </h2>
              <ul className="mt-3 flex flex-col gap-2">
                {log.length === 0 && (
                  <li className="font-mono text-[11px] text-muted-foreground/70">
                    No events yet — open a menu group to begin.
                  </li>
                )}
                {log.map((entry, i) => (
                  <li key={`${entry.time}-${i}`} className="flex gap-3 font-mono text-[11px] leading-5">
                    <span className="shrink-0 tabular-nums text-muted-foreground/60">
                      {entry.time}
                    </span>
                    <span className="text-foreground/80">{entry.text}</span>
                  </li>
                ))}
              </ul>
            </section>

            <section className="border border-border p-5">
              <h2 className="label-mono text-muted-foreground">About this lab</h2>
              <p className="mt-3 text-[13px] leading-6 text-muted-foreground">
                A faithful simulation of the shipping core: the same row order,
                value cycles and status line it draws over HDMI. Cartridges here
                span NTSC-U, NTSC-J and PAL — every one boots without a region
                lock. No ROM images are executed; video output is an abstract
                stand-in.
              </p>
            </section>
          </aside>
        </div>
      </main>
    </div>
  );
}
