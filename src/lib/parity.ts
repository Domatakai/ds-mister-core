/**
 * Parity and roadmap data for the landing page.
 *
 * The roadmap's states are not typed here: they come from
 * `parity.generated.json`, which `tools/gen-parity.mjs` writes by reading the
 * milestone table in `fpga/README.md`. The core's own document is the source,
 * so the site cannot drift from it -- run `npm run gen:parity` after editing
 * a milestone, and `npm run gen:parity -- --check` to see whether it has.
 *
 * The subsystem rows carry `evidence`: the module or bench in `fpga/` that
 * justifies the badge. `tools/gen-parity.mjs` also checks that every row has
 * one and that every milestone it names exists.
 */

import states from "./parity.generated.json";

export type Mark = "●" | "◐" | "○" | "—";
export type Status = "Complete" | "In progress" | "Next" | "Planned";

export interface ParityRow {
  name: string;
  melonDS: Mark;
  DeSmuME: Mark;
  status: Status;
  /** What in the core backs this badge. */
  evidence: string;
  /** Milestone this subsystem belongs to, if it maps to one. */
  milestone?: string;
}

export interface ParityGroup {
  group: string;
  rows: ParityRow[];
}

export interface Milestone {
  id: string;
  scope: string;
  /** The core's own word: complete, working or partial. */
  state: string;
  /** What the milestone table says is still out. */
  left: string;
}

export const MILESTONES: Record<string, Milestone> = states;

export const PARITY: ParityGroup[] = [
  {
    group: "CPU & bus",
    rows: [
      {
        name: "ARM946E-S + ARM7TDMI interpretation",
        melonDS: "●",
        DeSmuME: "●",
        status: "Complete",
        evidence: "rtl/cpu/arm9_core.sv, arm7_core.sv; tb_arm9, tb_arm7",
        milestone: "M1",
      },
      {
        name: "Cycle-approximate bus, DMA & waitstates",
        melonDS: "●",
        DeSmuME: "◐",
        status: "In progress",
        evidence: "main_bus/mem_arbiter/sdram_ctrl benched; no ARM9 caches or TCM yet",
      },
      {
        name: "Main memory slots & VRAM bank mapping",
        melonDS: "●",
        DeSmuME: "●",
        status: "Complete",
        evidence: "cart_slot.sv, vram_arbiter.sv; tb_cart_slot, tb_vram_arbiter",
        milestone: "M2",
      },
    ],
  },
  {
    group: "Graphics",
    rows: [
      {
        name: "2D engines A/B — text, affine, extended",
        melonDS: "●",
        DeSmuME: "●",
        status: "In progress",
        evidence: "renderer_2d.sv draws text BGs and regular OBJ; affine BGs, affine/bitmap OBJ and mosaic are M3",
      },
      {
        name: "3D geometry + rasterizer, toon & fog",
        melonDS: "●",
        DeSmuME: "◐",
        status: "In progress",
        evidence: "raster_engine.sv header lists depth, fog, edge marking, toon and alpha as not modelled",
        milestone: "M3",
      },
      {
        name: "Capture unit, blending, mosaic",
        melonDS: "●",
        DeSmuME: "●",
        status: "In progress",
        evidence: "engine_a.sv: affine BGs, OBJ windows, mosaic and blending are M3; SPU capture reads zero",
      },
      {
        name: "Locked frame pacing, no dropped frames",
        melonDS: "◐",
        DeSmuME: "◐",
        status: "Complete",
        evidence: "tb_video_timing; the frameskip rows exist but are not wired (NDS.sv `_unused`)",
      },
      {
        name: "Rotation, screen swap, per-game aspect",
        melonDS: "●",
        DeSmuME: "●",
        status: "Complete",
        evidence: "screen_composer.sv; tb_composer, and the four OSD rows",
      },
    ],
  },
  {
    group: "Audio & input",
    rows: [
      {
        name: "SPU — ADPCM & PCM, 16 channels",
        melonDS: "●",
        DeSmuME: "●",
        status: "In progress",
        evidence: "spu.sv, tb_spu (49 checks); capture units at 0x4000508 not modelled",
        milestone: "M4",
      },
      {
        name: "Touch, lid, keypad, rumble pak",
        melonDS: "●",
        DeSmuME: "●",
        status: "Complete",
        evidence: "input_mapper.sv, tb_input_mapper, tb_main_bus (rumble latch, lid chord)",
        milestone: "M5",
      },
      {
        name: "Microphone capture",
        melonDS: "●",
        DeSmuME: "◐",
        status: "In progress",
        evidence: "Off / R3 / board LTC2308; tb_mic_adc. No HPS audio capture on the platform",
        milestone: "M5",
      },
    ],
  },
  {
    group: "Media & saves",
    rows: [
      {
        name: "Region-free boot — NTSC-U, NTSC-J, PAL carts",
        melonDS: "●",
        DeSmuME: "●",
        status: "Complete",
        evidence: "cart_slot.sv is region-free; tb_cart_slot, tb_boot_menu",
        milestone: "M1",
      },
      {
        name: "Save types — EEPROM, FLASH, FRAM, NAND",
        melonDS: "●",
        DeSmuME: "●",
        status: "In progress",
        evidence: "tb_save_probe classifies all four, tb_flash_save covers the 64 KB window; .sav write-back and FLASH above it are M4",
        milestone: "M4",
      },
      {
        name: "Slot-2 — GBA carts, DLDI, RTC",
        melonDS: "●",
        DeSmuME: "◐",
        status: "Planned",
        evidence: "Only RAM paks, rumble and the motion pak decode; no GBA cart path",
      },
      {
        name: "HLE BIOS and user-supplied BIOS boot",
        melonDS: "●",
        DeSmuME: "●",
        status: "In progress",
        evidence: "swi_hle.sv is nine calls; no BIOS image path exists (NDS.sv rows [28]/[29] are unwired)",
        milestone: "M1",
      },
      {
        name: "Save states to SD card",
        melonDS: "●",
        DeSmuME: "●",
        status: "Planned",
        evidence: "OSD rows only; the hardware behind them does not exist",
        milestone: "M6",
      },
    ],
  },
  {
    group: "Network & tools",
    rows: [
      {
        name: "Local DS-to-DS wireless play",
        melonDS: "◐",
        DeSmuME: "○",
        status: "Planned",
        evidence: "Nothing in rtl/ touches RF",
        milestone: "M5",
      },
      {
        name: "Cheat engine with per-game lists",
        melonDS: "●",
        DeSmuME: "●",
        status: "Complete",
        evidence: "cheat_engine.sv (GBATEK table, 8 entries/clock); tb_cheat_engine, F2 .CHT load",
        milestone: "M6",
      },
      {
        name: "Soft reset & sleep handling",
        melonDS: "●",
        DeSmuME: "●",
        status: "Complete",
        evidence: "HALTCNT halt/sleep in both cores; lid chord on EXTKEYIN",
      },
    ],
  },
];

/** The core's word for a milestone, as the site shows it. */
export function statusOf(id: string): Status {
  const m = MILESTONES[id];
  if (!m) return "Planned";
  if (m.state === "complete") return "Complete";
  return "In progress";
}

const ROADMAP_COPY: [string, string, string][] = [
  ["M1", "Skeleton & boot", "ARM7/ARM9, IPC, HLE BIOS, main RAM, region-free boot from SD."],
  ["M2", "2D pipeline", "Engines A/B, VRAM banking, DMA, HDMI output with rotation."],
  [
    "M3",
    "3D pipeline",
    "GXFIFO, serialised multiplier, flat rasterizer, VRAM write-back, 3D layer over engine A.",
  ],
  ["M4", "Sound, saves & cartridge", "Sixteen SPU channels, AUXSPI save probe, MT-32-pi MIDI, timers, IPC, RTC, SPI."],
  [
    "M5",
    "Sensors",
    "Microphone Off / R3 / board ADC at 48 kHz, SPI touchscreen, slot-2 rumble pak and the lid chord; wireless still out.",
  ],
  [
    "M6",
    "Front end",
    "Cheat engine and the DS-native menu, profiles and filter rows; save states, rewind, replay still out.",
  ],
];

export const ROADMAP: [string, string, string, Status][] = ROADMAP_COPY.map(
  ([id, title, copy]) => [id, title, copy, statusOf(id)],
);
