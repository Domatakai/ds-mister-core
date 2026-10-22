import { OsdPanel } from "@/components/osd/OsdPanel";
import type { OsdRow } from "@/lib/osd-tree";
import { motion, useReducedMotion } from "framer-motion";
import { Fragment, type ReactNode } from "react";
import { Link } from "react-router";

/* ------------------------------------------------------------------ data */

const NAV_LINKS = [
  { href: "#parity", label: "Parity" },
  { href: "#osd", label: "OSD" },
  { href: "#architecture", label: "Architecture" },
  { href: "#roadmap", label: "Roadmap" },
  { href: "#build", label: "Build" },
];

const SPECS = [
  ["Frame rate", "59.826 Hz locked"],
  ["Input latency", "Sub-frame"],
  ["Dropped frames", "Zero"],
  ["Region lock", "None — U, J, PAL"],
  ["CPUs", "ARM9 + ARM7, cycle-timed"],
  ["Output", "HDMI · integer scaling"],
];

type Mark = "●" | "◐" | "○" | "—";
const PARITY: { group: string; rows: [string, Mark, Mark, string][] }[] = [
  {
    group: "CPU & bus",
    rows: [
      ["ARM946E-S + ARM7TDMI interpretation", "●", "●", "Complete"],
      ["Cycle-approximate bus, DMA & waitstates", "●", "◐", "In progress"],
      ["Main memory slots & VRAM bank mapping", "●", "●", "Complete"],
    ],
  },
  {
    group: "Graphics",
    rows: [
      ["2D engines A/B — text, affine, extended", "●", "●", "Complete"],
      ["3D geometry + rasterizer, toon & fog", "●", "◐", "In progress"],
      ["Capture unit, blending, mosaic", "●", "●", "In progress"],
      ["Locked frame pacing, no dropped frames", "◐", "◐", "Complete"],
      ["Rotation, screen swap, per-game aspect", "●", "●", "Complete"],
    ],
  },
  {
    group: "Audio & input",
    rows: [
      ["SPU — ADPCM & PCM, 16 channels", "●", "●", "Complete"],
      ["Touch, lid, keypad, rumble pak", "●", "●", "Complete"],
      ["Microphone capture", "●", "◐", "Planned"],
    ],
  },
  {
    group: "Media & saves",
    rows: [
      ["Region-free boot — NTSC-U, NTSC-J, PAL carts", "●", "●", "Complete"],
      ["Save types — EEPROM, FLASH, FRAM, NAND", "●", "●", "Complete"],
      ["Slot-2 — GBA carts, DLDI, RTC", "●", "◐", "Planned"],
      ["HLE BIOS and user-supplied BIOS boot", "●", "●", "Complete"],
      ["Save states to SD card", "●", "●", "Planned"],
    ],
  },
  {
    group: "Network & tools",
    rows: [
      ["Local DS-to-DS wireless play", "◐", "○", "Planned"],
      ["Cheat engine with per-game lists", "●", "●", "Complete"],
      ["Soft reset & sleep handling", "●", "●", "Complete"],
    ],
  },
];

const OSD_GROUPS: [string, string][] = [
  ["Cartridge", "Slot-1 browser over the SD card, save-type autodetection, eject and erase."],
  ["Video", "Layout, rotation, aspect, integer scaling, scanlines, brightness, screen swap."],
  ["Audio", "Master volume, output mix, I²S latency, SPU sync with the frame boundary."],
  ["BIOS / Firmware", "HLE or real BIOS files, firmware flash image, region override, logo skip."],
  ["Input", "Stylus mode, microphone source, rumble, pad profiles per game."],
  ["Emulation", "Core speed, frameskip, rewind buffer, per-core clock divider."],
  ["Cheats", "Toggle rows sourced from per-game cheat files on the SD card."],
  ["Diagnostics", "FPS, frame-time graph, bus activity LEDs, HPS log level."],
  ["Reset", "Soft reset, hard reset, restore the OSD profile defaults."],
];

const ARCHITECTURE: [string, string, string][] = [
  ["01", "ARM9 domain", "ARM946E-S with ITCM/DTCM, CP15 and protection unit, clocked at 67.02 MHz."],
  ["02", "ARM7 domain", "ARM7TDMI at 33.51 MHz — IPC, shared WRAM, keypad, touch and SPI devices."],
  ["03", "2D engines", "A/B renderers: text, affine and extended modes, windowing, mosaic, blending."],
  ["04", "3D pipeline", "Geometry engine feeds a scanline rasterizer with toon shading, edge marking, fog."],
  ["05", "VRAM arbiter", "Bank mapping LCDC/AB, main-memory slots and DMA timing modeled to the cycle."],
  ["06", "Audio SPU", "16 channels of ADPCM and PCM mixed in fabric, framed out over I²S to the codec."],
  ["07", "Video out", "Scan-doubled 256×192 layers composed per layout, rotation-aware, into the scaler."],
  ["08", "HPS bridge", "Linux side: file browser, saves, cheats, profiles, settings — the OSD itself."],
];

const ROADMAP: [string, string, string, "Complete" | "In progress" | "Next" | "Planned"][] = [
  ["M1", "Skeleton & boot", "ARM7/ARM9, IPC, HLE BIOS, main RAM, region-free boot from SD.", "Complete"],
  ["M2", "2D pipeline", "Engines A/B, VRAM banking, DMA, HDMI output with rotation.", "Complete"],
  ["M3", "3D pipeline", "Geometry engine, rasterizer, capture unit, held at 59.826 Hz.", "In progress"],
  ["M4", "Media & saves", "Save-type autodetection, save states to SD, Slot-2 and DLDI.", "Next"],
  ["M5", "Sound & wireless", "SPU core to I²S, microphone, rumble, local DS-to-DS play.", "Planned"],
  ["M6", "OSD polish", "Cheat browser, per-game profiles, frame graph, input replay.", "Planned"],
];

const HERO_PREVIEW: OsdRow[] = [
  { kind: "submenu", label: "Cartridge" },
  { kind: "submenu", label: "Video" },
  { kind: "submenu", label: "Audio" },
  { kind: "submenu", label: "BIOS / Firmware" },
  { kind: "submenu", label: "Input" },
  { kind: "submenu", label: "Emulation" },
  { kind: "submenu", label: "Cheats" },
  { kind: "submenu", label: "Diagnostics" },
  { kind: "submenu", label: "Reset" },
];

const VIDEO_PREVIEW: OsdRow[] = [
  { kind: "value", label: "Screen layout", value: "Stacked" },
  { kind: "value", label: "Rotation", value: "0°" },
  { kind: "value", label: "Aspect ratio", value: "Original" },
  { kind: "value", label: "Scaling", value: "Integer ×4" },
  { kind: "value", label: "Scanlines", value: "Soft" },
  { kind: "value", label: "Swap screens", value: "Off" },
  { kind: "value", label: "Brightness", value: "3" },
  { kind: "value", label: "Video filter", value: "Smooth" },
  { kind: "value", label: "Palette", value: "DS LCD" },
];

/* ------------------------------------------------------------ primitives */

function Reveal({
  children,
  className = "",
  delay = 0,
}: {
  children: ReactNode;
  className?: string;
  delay?: number;
}) {
  const reduce = useReducedMotion();
  return (
    <motion.div
      className={className}
      initial={reduce ? false : { opacity: 0, y: 14 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: "-60px" }}
      transition={{ duration: 0.5, ease: [0.22, 0.61, 0.36, 1], delay }}
    >
      {children}
    </motion.div>
  );
}

function SectionHead({
  index,
  title,
  lede,
}: {
  index: string;
  title: string;
  lede: string;
}) {
  return (
    <div className="grid gap-6 border-b border-border pb-10 lg:grid-cols-12 lg:gap-10">
      <p className="label-mono text-muted-foreground lg:col-span-3">
        {index} — {title}
      </p>
      <p className="max-w-2xl text-[17px] leading-8 text-foreground/80 lg:col-span-9 lg:text-[19px]">
        {lede}
      </p>
    </div>
  );
}

function statusStyle(status: string) {
  if (status === "Complete")
    return "border-foreground bg-foreground text-background";
  if (status === "In progress" || status === "Next")
    return "border-foreground/40 text-foreground";
  return "border-transparent text-muted-foreground";
}

/* ----------------------------------------------------------------- page */

export default function Landing() {
  return (
    <div className="min-h-screen bg-background text-foreground">
      {/* Nav ---------------------------------------------------------- */}
      <header className="fixed inset-x-0 top-0 z-50 border-b border-border/80 bg-background/85 backdrop-blur-md">
        <div className="mx-auto flex h-14 w-full max-w-[1180px] items-center justify-between px-6 lg:px-10">
          <a href="#top" className="flex items-baseline gap-3">
            <span className="text-[14px] font-semibold tracking-[0.03em]">
              NDS MiSTer Test
            </span>
            <span className="label-mono hidden text-muted-foreground sm:inline">
              Open-source core
            </span>
          </a>
          <nav className="hidden items-center gap-7 md:flex">
            {NAV_LINKS.map((link) => (
              <a
                key={link.href}
                href={link.href}
                className="label-mono text-muted-foreground transition-colors hover:text-foreground"
              >
                {link.label}
              </a>
            ))}
          </nav>
          <Link
            to="/dashboard"
            className="label-mono border border-foreground bg-foreground px-3.5 py-2 text-background transition-opacity hover:opacity-80"
          >
            Open OSD Lab →
          </Link>
        </div>
      </header>

      {/* Hero --------------------------------------------------------- */}
      <section id="top" className="border-b border-border pt-14">
        <div className="mx-auto grid w-full max-w-[1180px] gap-14 px-6 pb-20 pt-16 lg:grid-cols-12 lg:gap-10 lg:px-10 lg:pb-28 lg:pt-24">
          <div className="lg:col-span-7">
            <Reveal>
              <p className="label-mono text-muted-foreground">
                Open-source core · Region-free · v0.6.0-alpha
              </p>
            </Reveal>
            <Reveal delay={0.06}>
              <h1 className="mt-7 text-[46px] font-medium leading-[0.98] tracking-[-0.035em] sm:text-[62px] lg:text-[76px]">
                Every cartridge.
                <br />
                Every region.
                <br />
                <span className="text-muted-foreground">No stutter.</span>
              </h1>
            </Reveal>
            <Reveal delay={0.12}>
              <p className="mt-8 max-w-xl text-[16px] leading-8 text-muted-foreground">
                NDS MiSTer Test is a Nintendo DS core for the MiSTer FPGA
                platform. NTSC-U, NTSC-J and PAL carts all boot with no region
                lock, held at the console&apos;s native 59.826 Hz with sub-frame
                input latency and zero dropped frames. The accuracy bar is set by{" "}
                <span className="text-foreground">melonDS</span> and{" "}
                <span className="text-foreground">DeSmuME</span>; the OSD menu
                carries over everything their front-ends offer.
              </p>
            </Reveal>
            <Reveal delay={0.18}>
              <div className="mt-10 flex flex-wrap items-center gap-4">
                <Link
                  to="/dashboard"
                  className="label-mono border border-foreground bg-foreground px-5 py-3 text-background transition-opacity hover:opacity-80"
                >
                  Open the OSD Lab →
                </Link>
                <a
                  href="#parity"
                  className="label-mono border border-border px-5 py-3 text-muted-foreground transition-colors hover:border-foreground/40 hover:text-foreground"
                >
                  Read the parity matrix
                </a>
              </div>
              <p className="mt-4 font-mono text-[11px] tracking-[0.08em] text-muted-foreground/70">
                No hardware required — the full menu runs in your browser.
              </p>
            </Reveal>
          </div>

          <Reveal className="lg:col-span-5" delay={0.15}>
            <div className="relative border border-border bg-[#141413] p-5">
              <div className="relative overflow-hidden border border-white/10 bg-[#0b0b0a]">
                <div className="ndsm-floor motion-safe:ndsm-floor-anim absolute inset-x-[-60%] bottom-0 h-[300%] opacity-70" />
                <div className="ndsm-vignette pointer-events-none absolute inset-0" aria-hidden />
                <div className="absolute inset-x-0 top-[26%] text-center font-mono text-[10px] tracking-[0.28em] text-white/30">
                  NO CARTRIDGE
                </div>
                <OsdPanel
                  className="relative mx-auto my-6 w-[86%] max-w-[330px]"
                  title="NDS MiSTer Test"
                  rows={HERO_PREVIEW}
                  activeIndex={1}
                  statusLine="F12 opens the menu over video output"
                />
              </div>
              <p className="mt-3 font-mono text-[10px] uppercase tracking-[0.18em] text-[#8b8b84]">
                OSD · root menu · drawn by the core
              </p>
            </div>
          </Reveal>
        </div>

        {/* Spec strip */}
        <div className="border-t border-border">
          <dl className="mx-auto grid w-full max-w-[1180px] grid-cols-2 px-6 sm:grid-cols-3 lg:grid-cols-6 lg:px-10">
            {SPECS.map(([label, value], i) => (
              <div
                key={label}
                className={`border-border px-4 py-6 first:pl-0 ${
                  i % 2 === 1 ? "border-l" : ""
                } sm:border-l sm:first:border-l-0 lg:border-l`}
              >
                <dt className="label-mono text-muted-foreground/70">{label}</dt>
                <dd className="mt-2 font-mono text-[13px] tabular-nums">{value}</dd>
              </div>
            ))}
          </dl>
        </div>
      </section>

      {/* Parity ------------------------------------------------------- */}
      <section id="parity" className="scroll-mt-14 border-b border-border">
        <div className="mx-auto w-full max-w-[1180px] px-6 py-20 lg:px-10 lg:py-28">
          <Reveal>
            <SectionHead
              index="01"
              title="Parity"
              lede="The reference is feature parity, not a subset. Every subsystem the two
              established DS emulators expose — their accuracy quirks, their front-end
              controls — is accounted for in the core's design and tracked here."
            />
          </Reveal>
          <Reveal delay={0.06}>
            <div className="mt-10 overflow-x-auto">
              <table className="w-full min-w-[720px] border-collapse text-left">
                <thead>
                  <tr className="border-b border-border">
                    <th className="label-mono w-[46%] py-3 pr-4 font-normal text-muted-foreground">
                      Subsystem
                    </th>
                    <th className="label-mono w-[12%] py-3 pr-4 font-normal text-muted-foreground">
                      melonDS
                    </th>
                    <th className="label-mono w-[12%] py-3 pr-4 font-normal text-muted-foreground">
                      DeSmuME
                    </th>
                    <th className="label-mono w-[30%] py-3 font-normal text-muted-foreground">
                      NDS MiSTer Test
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {PARITY.map((group) => (
                    <Fragment key={group.group}>
                      <tr>
                        <td
                          colSpan={4}
                          className="label-mono border-b border-border bg-muted/50 px-0 py-2.5 text-muted-foreground"
                        >
                          {group.group}
                        </td>
                      </tr>
                      {group.rows.map(([name, a, b, status]) => (
                        <tr
                          key={name}
                          className="border-b border-border/60 transition-colors hover:bg-muted/40"
                        >
                          <td className="py-3.5 pr-4 text-[14px] leading-6">{name}</td>
                          <td className="py-3.5 pr-4 text-[13px] text-muted-foreground">
                            {a}
                          </td>
                          <td className="py-3.5 pr-4 text-[13px] text-muted-foreground">
                            {b}
                          </td>
                          <td className="py-3.5">
                            <span
                              className={`inline-block border px-2.5 py-1 font-mono text-[10px] uppercase tracking-[0.14em] ${statusStyle(
                                status,
                              )}`}
                            >
                              {status}
                            </span>
                          </td>
                        </tr>
                      ))}
                    </Fragment>
                  ))}
                </tbody>
              </table>
            </div>
          </Reveal>
          <p className="mt-6 font-mono text-[11px] leading-5 tracking-[0.06em] text-muted-foreground">
            ● parity · ◐ partial · ○ planned. References: melonDS 0.10.x,
            DeSmuME 0.9.13.
          </p>
        </div>
      </section>

      {/* OSD ---------------------------------------------------------- */}
      <section id="osd" className="scroll-mt-14 border-b border-border bg-muted/30">
        <div className="mx-auto w-full max-w-[1180px] px-6 py-20 lg:px-10 lg:py-28">
          <Reveal>
            <SectionHead
              index="02"
              title="The OSD"
              lede="Emulator front-ends carry a hundred checkboxes the hardware never had.
              The core absorbs them into one OSD: nine groups, drawn over video output,
              navigated with a controller, saved as a profile per game."
            />
          </Reveal>

          <div className="mt-12 grid gap-12 lg:grid-cols-12 lg:gap-10">
            <Reveal className="lg:col-span-7">
              <ol>
                {OSD_GROUPS.map(([name, copy], i) => (
                  <li
                    key={name}
                    className="grid grid-cols-[34px_1fr] gap-4 border-b border-border py-5 first:pt-0 sm:grid-cols-[44px_150px_1fr] sm:gap-6"
                  >
                    <span className="label-mono pt-1 text-muted-foreground/60">
                      {String(i + 1).padStart(2, "0")}
                    </span>
                    <span className="text-[14px] font-medium tracking-[-0.01em]">
                      {name}
                    </span>
                    <span className="col-span-2 text-[13.5px] leading-7 text-muted-foreground sm:col-span-1">
                      {copy}
                    </span>
                  </li>
                ))}
              </ol>
            </Reveal>

            <Reveal className="lg:col-span-5" delay={0.08}>
              <div className="lg:sticky lg:top-24">
                <div className="border border-border bg-[#141413] p-5">
                  <OsdPanel
                    title="Video"
                    rows={VIDEO_PREVIEW}
                    activeIndex={4}
                    statusLine="Scanlines: Soft"
                  />
                </div>
                <p className="mt-3 font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground">
                  Video group · values cycle left / right
                </p>
                <div className="mt-8 border border-border bg-background p-5">
                  <p className="label-mono text-muted-foreground">Profiles</p>
                  <p className="mt-3 text-[13.5px] leading-7 text-muted-foreground">
                    Each menu group writes to a per-game profile stored beside the
                    ROM. Load a game and the core restores its rotation,
                    brightness and volume before the first frame — the same
                    muscle memory <span className="font-mono text-foreground">melonDS</span> users
                    already have. Profiles are plain files: copy them between your
                    own MiSTer and a public machine, or lock one down so an
                    exhibition cabinet never drifts from its setup.
                  </p>
                </div>
              </div>
            </Reveal>
          </div>
        </div>
      </section>

      {/* Architecture ------------------------------------------------- */}
      <section id="architecture" className="scroll-mt-14 border-b border-border">
        <div className="mx-auto w-full max-w-[1180px] px-6 py-20 lg:px-10 lg:py-28">
          <Reveal>
            <SectionHead
              index="03"
              title="Architecture"
              lede="Everything with a clock budget lives in the fabric; everything with a
              file lives on the HPS. The split that makes the core deterministic is the
              same split that keeps the menu simple."
            />
          </Reveal>
          <Reveal delay={0.06}>
            <div className="mt-12 grid gap-px border border-border bg-border sm:grid-cols-2 lg:grid-cols-4">
              {ARCHITECTURE.map(([num, title, copy]) => (
                <div key={num} className="bg-background p-6 lg:p-7">
                  <p className="label-mono text-muted-foreground/60">{num}</p>
                  <h3 className="mt-4 text-[15px] font-medium tracking-[-0.01em]">
                    {title}
                  </h3>
                  <p className="mt-2.5 text-[13px] leading-6 text-muted-foreground">
                    {copy}
                  </p>
                </div>
              ))}
            </div>
          </Reveal>
          <Reveal delay={0.1}>
            <div className="mt-10 grid gap-8 sm:grid-cols-3">
              <div className="border-l-2 border-foreground pl-6">
                <p className="label-mono">In the fabric</p>
                <p className="mt-3 text-[14px] leading-7 text-muted-foreground">
                  No frameskip hacks, no catch-up loops. Both CPUs, both 2D engines,
                  the 3D pipeline and the SPU run locked to one timing domain, so a
                  save state written on hour one is valid on hour forty.
                </p>
              </div>
              <div className="border-l-2 border-border pl-6">
                <p className="label-mono text-muted-foreground">On the HPS</p>
                <p className="mt-3 text-[14px] leading-7 text-muted-foreground">
                  The ARM Linux side handles what emulators do in their front-ends:
                  the file browser, save read/write, cheat tables, settings profiles
                  and the OSD itself — reachable over SSH, scriptable like the rest
                  of MiSTer.
                </p>
              </div>
              <div className="border-l-2 border-border pl-6">
                <p className="label-mono text-muted-foreground">In the field</p>
                <p className="mt-3 text-[14px] leading-7 text-muted-foreground">
                  At home it behaves like a console — instant boot, save states,
                  rewind, a profile per game. In a bar, an arcade or an exhibition,
                  kiosk mode pins the menu, boots straight into the last cartridge,
                  and picks itself up after the power is cut mid-save.
                </p>
              </div>
            </div>
          </Reveal>
        </div>
      </section>

      {/* Roadmap ------------------------------------------------------ */}
      <section id="roadmap" className="scroll-mt-14 border-b border-border bg-muted/30">
        <div className="mx-auto w-full max-w-[1180px] px-6 py-20 lg:px-10 lg:py-28">
          <Reveal>
            <SectionHead
              index="04"
              title="Roadmap"
              lede="Six milestones, shipped in the open. Two are done, one is being
              synthesized week by week, three are cut into the fabric next."
            />
          </Reveal>
          <div className="mt-6">
            {ROADMAP.map(([phase, title, copy, status], i) => (
              <Reveal key={phase} delay={i * 0.04}>
                <div className="grid grid-cols-1 items-baseline gap-3 border-b border-border py-6 md:grid-cols-[80px_200px_1fr_auto] md:gap-8">
                  <span className="label-mono text-muted-foreground">{phase}</span>
                  <span className="text-[15px] font-medium tracking-[-0.01em]">
                    {title}
                  </span>
                  <span className="text-[13.5px] leading-7 text-muted-foreground">
                    {copy}
                  </span>
                  <span
                    className={`justify-self-start border px-2.5 py-1 font-mono text-[10px] uppercase tracking-[0.14em] md:justify-self-end ${statusStyle(
                      status,
                    )}`}
                  >
                    {status}
                  </span>
                </div>
              </Reveal>
            ))}
          </div>
        </div>
      </section>

      {/* Build -------------------------------------------------------- */}
      <section id="build" className="scroll-mt-14 border-b border-border">
        <div className="mx-auto w-full max-w-[1180px] px-6 py-20 lg:px-10 lg:py-28">
          <Reveal>
            <SectionHead
              index="05"
              title="Build & install"
              lede="Quartus Prime Standard 23.1, one script, one .rbf on the SD card. A
              real BIOS is optional — HLE boots every title in the compatibility list."
            />
          </Reveal>
          <div className="mt-12 grid gap-10 lg:grid-cols-12 lg:gap-10">
            <Reveal className="lg:col-span-7">
              <pre className="overflow-x-auto border border-border bg-[#141413] p-6 font-mono text-[12.5px] leading-7 text-[#d6d6cf]">
{`git clone https://github.com/ndsmister/core.git
cd core
./build.sh                        # Quartus Prime Standard 23.1

cp output/nds-mister-test.rbf  /media/fat/games/NDS/
cp bios7.bin bios9.bin /media/fat/BIOS/   # optional`}
              </pre>
            </Reveal>
            <Reveal className="lg:col-span-5" delay={0.08}>
              <ol className="flex flex-col">
                {[
                  ["01", "Grab a release .rbf, or synthesize the core yourself."],
                  ["02", "Copy it to /media/fat/games/NDS alongside your ROMs."],
                  ["03", "Optional: drop real BIOS files into /media/fat/BIOS/."],
                  ["04", "Boot the core, press F12, load a cartridge from the OSD."],
                ].map(([num, step]) => (
                  <li
                    key={num}
                    className="grid grid-cols-[44px_1fr] gap-5 border-b border-border py-5 first:border-t"
                  >
                    <span className="label-mono pt-1 text-muted-foreground/60">
                      {num}
                    </span>
                    <span className="text-[14px] leading-7 text-muted-foreground">
                      {step}
                    </span>
                  </li>
                ))}
              </ol>
            </Reveal>
          </div>
        </div>
      </section>

      {/* CTA ---------------------------------------------------------- */}
      <section className="border-b border-border">
        <div className="mx-auto w-full max-w-[1180px] px-6 py-24 text-center lg:px-10 lg:py-32">
          <Reveal>
            <h2 className="mx-auto max-w-3xl text-[34px] font-medium leading-[1.05] tracking-[-0.03em] sm:text-[46px]">
              Every menu you'll use is already built.
            </h2>
            <p className="mx-auto mt-6 max-w-xl text-[15px] leading-7 text-muted-foreground">
              Walk the complete OSD — cartridge, video, audio, BIOS, input,
              emulation, cheats, diagnostics — before a single gate is synthesized.
            </p>
            <div className="mt-10">
              <Link
                to="/dashboard"
                className="label-mono inline-block border border-foreground bg-foreground px-6 py-3.5 text-background transition-opacity hover:opacity-80"
              >
                Open the OSD Lab →
              </Link>
            </div>
          </Reveal>
        </div>
      </section>

      {/* Footer ------------------------------------------------------- */}
      <footer>
        <div className="mx-auto flex w-full max-w-[1180px] flex-col gap-6 px-6 py-10 lg:flex-row lg:items-center lg:justify-between lg:px-10">
          <p className="label-mono text-muted-foreground">
            NDS MiSTer Test · 2026 · Community preservation project
          </p>
          <nav className="flex flex-wrap gap-x-7 gap-y-3">
            {[
              ["MiSTer docs", "https://mister-devel.github.io/MkDocs_MiSTer/"],
              ["melonDS", "https://melonds.kuribo64.net/"],
              ["DeSmuME wiki", "http://wiki.desmume.org/"],
              ["MiSTer forum", "https://misterfpga.org/"],
            ].map(([label, href]) => (
              <a
                key={label}
                href={href}
                target="_blank"
                rel="noopener noreferrer"
                className="label-mono text-muted-foreground transition-colors hover:text-foreground"
              >
                {label}
              </a>
            ))}
          </nav>
        </div>
        <div className="border-t border-border">
          <p className="mx-auto w-full max-w-[1180px] px-6 py-6 font-mono text-[10.5px] leading-5 tracking-[0.04em] text-muted-foreground/70 lg:px-10">
            Nintendo, Nintendo DS and the DS logo are trademarks of Nintendo Co.,
            Ltd. melonDS and DeSmuME are trademarks of their respective authors.
            NDS MiSTer Test is unaffiliated and runs no copyrighted ROM images.
          </p>
        </div>
      </footer>
    </div>
  );
}
