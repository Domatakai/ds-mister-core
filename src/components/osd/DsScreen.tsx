import type { OsdValues, RomEntry } from "@/lib/osd-tree";
import type { ReactNode } from "react";

const SCANLINE_OVERLAY: Record<string, string> = {
  Off: "",
  Soft: "repeating-linear-gradient(to bottom, rgba(0,0,0,0.16) 0 1px, transparent 1px 3px)",
  Hard: "repeating-linear-gradient(to bottom, rgba(0,0,0,0.34) 0 2px, transparent 2px 4px)",
};

const OUTPUT_SIZE: Record<string, string> = {
  "Integer ×4": "1024 × 768",
  "Integer ×5": "1280 × 960",
  Fit: "1920 × 1080",
  Stretch: "1920 × 1080",
};

/**
 * Visual stand-in for the core's video output: two 256×192 screens whose
 * layout, rotation, brightness, scanlines and swap state are driven by the
 * same OSD values the real core consumes. Output is intentionally abstract —
 * a wireframe horizon and hairline grid rather than a fake game.
 */
export function DsScreen({
  values,
  rom,
  booting,
  osdOpen,
  fps,
  frameMs,
  frameTimes,
}: {
  values: OsdValues;
  rom: RomEntry | null;
  booting: boolean;
  osdOpen: boolean;
  fps: number;
  frameMs: number;
  frameTimes: number[];
}) {
  const layout = values["video.layout"] ?? "Auto";
  const rotation = values["video.rotation"] ?? "0°";
  const swap = values["video.swap"] === "On";
  const brightness = Number(values["video.brightness"] ?? "3");
  const scanlines = values["video.scanlines"] ?? "Off";
  const showHud = values["diag.fps"] === "On";
  const showGraph = values["diag.graph"] === "On";
  const showLeds = values["diag.leds"] === "On";

  const showTop = layout !== "Bottom only";
  const showBottom = layout !== "Top only";
  const vertical = layout === "Horizontal" ? "row" : "col";
  const turn = rotation === "90°" || rotation === "270°";

  const topScreen = (
    <ScreenFrame
      label="Top · 256×192"
      turn={turn}
      rotation={rotation}
      brightness={brightness}
      scanlines={scanlines}
      dimmed={osdOpen}
    >
      <div className="absolute inset-0 bg-[linear-gradient(to_bottom,#101010,#0a0a0a)]" />
      <div className="absolute inset-x-0 bottom-0 h-[46%] overflow-hidden">
        <div className="dualis-floor absolute inset-x-[-60%] bottom-0 h-[300%] motion-safe:dualis-floor-anim" />
      </div>
      <div className="absolute inset-x-0 top-[22%] flex flex-col items-center gap-1.5 px-4 text-center">
        {rom ? (
          <>
            <span className="text-[9px] tracking-[0.3em] text-white/30">NOW RUNNING</span>
            <span className="text-[12px] leading-tight tracking-[0.12em] text-white/75">
              {rom.title}
            </span>
            <span className="text-[9px] tracking-[0.2em] text-white/30">
              {rom.code} · {rom.region}
            </span>
          </>
        ) : (
          <>
            <span className="text-[12px] tracking-[0.24em] text-white/40">NO CARTRIDGE</span>
            <span className="text-[9px] tracking-[0.22em] text-white/25">SLOT-1 EMPTY</span>
          </>
        )}
      </div>
      {showHud && (
        <div className="absolute left-2 top-2 font-mono text-[9px] tabular-nums leading-relaxed text-white/55">
          <div>{fps.toFixed(2)} FPS</div>
          <div>{frameMs.toFixed(2)} MS</div>
        </div>
      )}
      {showGraph && <FrameGraph times={frameTimes} />}
    </ScreenFrame>
  );

  const bottomScreen = (
    <ScreenFrame
      label="Bottom · 256×192"
      turn={turn}
      rotation={rotation}
      brightness={brightness}
      scanlines={scanlines}
      dimmed={osdOpen}
    >
      <div className="dualis-dots absolute inset-0 bg-[#0b0b0a]" />
      <div className="absolute inset-0 flex flex-col items-center justify-center gap-4">
        <span className="text-[9px] tracking-[0.28em] text-white/25">TOUCH INPUT</span>
        <div className="flex gap-2 font-mono text-[9px] tracking-[0.14em] text-white/35">
          {["SAVE", "LOAD", "MAP"].map((t) => (
            <span key={t} className="border border-white/15 px-2 py-1">
              {t}
            </span>
          ))}
        </div>
      </div>
    </ScreenFrame>
  );

  const stack = swap ? [bottomScreen, topScreen] : [topScreen, bottomScreen];

  return (
    <div className="border border-border bg-[#141413] p-3 sm:p-4">
      <div
        className={[
          "relative flex gap-3 sm:gap-4",
          vertical === "row" ? "flex-row" : "flex-col",
        ].join(" ")}
      >
        {showTop && stack[0]}
        {showBottom && stack[1]}

        {booting && (
          <div className="absolute inset-0 z-10 flex flex-col items-center justify-center gap-2 bg-black/85 font-mono text-white/70">
            <span className="text-[10px] tracking-[0.26em]">ARM9 · ARM7 BOOT</span>
            <span className="text-[9px] tracking-[0.2em] text-white/40">
              HLE FIRMWARE · WRAM INIT
            </span>
          </div>
        )}

        {osdOpen && !booting && (
          <div className="absolute inset-0 z-10 bg-black/45" aria-hidden />
        )}

        {showLeds && (
          <div className="pointer-events-none absolute right-2 top-2 z-20 flex flex-col gap-1.5">
            {["MAIN", "VRAM", "AXI"].map((led, i) => (
              <span
                key={led}
                className="flex items-center justify-end gap-1.5 font-mono text-[8px] tracking-[0.18em] text-white/30"
              >
                {led}
                <span
                  className="size-1.5 rounded-full bg-white/70 motion-safe:animate-pulse"
                  style={{ animationDelay: `${i * 240}ms`, animationDuration: "900ms" }}
                />
              </span>
            ))}
          </div>
        )}
      </div>

      <div className="mt-3 flex items-center justify-between font-mono text-[10px] tracking-[0.16em] text-[#8b8b84] uppercase">
        <span>
          OUT {OUTPUT_SIZE[values["video.scale"] ?? "Integer ×4"] ?? "1024 × 768"} ·{" "}
          {values["video.aspect"] ?? "4:3"} · ROT {rotation}
        </span>
        <span className="tabular-nums">{showHud ? "HUD ON" : "HUD OFF"}</span>
      </div>
    </div>
  );
}

function ScreenFrame({
  label,
  turn,
  rotation,
  brightness,
  scanlines,
  dimmed,
  children,
}: {
  label: string;
  turn: boolean;
  rotation: string;
  brightness: number;
  scanlines: string;
  dimmed: boolean;
  children: ReactNode;
}) {
  return (
    <figure className="min-w-0 flex-1">
      <div
        className={[
          "relative overflow-hidden border border-white/10 bg-[#0b0b0a]",
          turn ? "aspect-[3/4]" : "aspect-[4/3]",
          dimmed ? "opacity-55" : "opacity-100",
          "transition-opacity duration-200",
        ].join(" ")}
      >
        <div
          className="absolute inset-0"
          style={{
            transform: `rotate(${rotation})`,
            filter: `brightness(${0.72 + brightness * 0.11})`,
          }}
        >
          {children}
        </div>
        {scanlines !== "Off" && (
          <div
            className="pointer-events-none absolute inset-0"
            style={{ backgroundImage: SCANLINE_OVERLAY[scanlines] }}
            aria-hidden
          />
        )}
      </div>
      <figcaption className="mt-1.5 font-mono text-[9px] uppercase tracking-[0.18em] text-muted-foreground/70">
        {label}
      </figcaption>
    </figure>
  );
}

function FrameGraph({ times }: { times: number[] }) {
  if (times.length < 2) return null;
  const max = Math.max(...times, 17.5);
  const points = times
    .map((t, i) => {
      const x = (i / (times.length - 1)) * 100;
      const y = 24 - (t / max) * 22;
      return `${x.toFixed(2)},${y.toFixed(2)}`;
    })
    .join(" ");
  return (
    <svg
      viewBox="0 0 100 24"
      preserveAspectRatio="none"
      className="absolute bottom-2 left-2 right-2 h-6 w-[calc(100%-1rem)] text-white/35"
      aria-hidden
    >
      <polyline points={points} fill="none" stroke="currentColor" strokeWidth="0.8" />
      <line x1="0" y1="24" x2="100" y2="24" stroke="currentColor" strokeWidth="0.4" />
    </svg>
  );
}
