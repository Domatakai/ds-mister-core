/**
 * Menu model for the NDS MiSTer Test OSD.
 *
 * Mirrors the structure the core exposes on real hardware: a numbered root
 * menu of groups, each group holding cyclical value rows, on/off toggles,
 * one-shot actions and nested submenus. The landing page renders a static
 * snapshot of it; the OSD Lab walks it live and persists the chosen values.
 */

export type OsdNode =
  | { id: string; kind: "submenu"; label: string; children: OsdNode[] }
  | { id: string; kind: "choice"; label: string; options: string[] }
  | { id: string; kind: "toggle"; label: string }
  | { id: string; kind: "action"; label: string };

export interface RomEntry {
  title: string;
  region: string;
  code: string;
}

/** Demo slot contents for the simulator's cartridge folder. */
export const ROMS: RomEntry[] = [
  { title: "MARIO KART DS", region: "NTSC-U", code: "NTR-AMCE-USA" },
  { title: "CHRONO TRIGGER", region: "NTSC-U", code: "NTR-ACTE-USA" },
  { title: "METROID PRIME HUNTERS", region: "NTSC-U", code: "NTR-PAMT-USA" },
  { title: "NEW SUPER MARIO BROS.", region: "NTSC-U", code: "NTR-AMCE-USA" },
  { title: "PROFESSOR LAYTON", region: "PAL", code: "NTR-ALTP-EUR" },
  { title: "SUPER MARIO 64 DS", region: "NTSC-J", code: "NTR-AMGJ-JPN" },
];

const ROM_OPTIONS = ["— EMPTY —", ...ROMS.map((r) => r.title)];

export type OsdSubmenu = Extract<OsdNode, { kind: "submenu" }>;

export const OSD_ROOT: OsdSubmenu = {
  id: "root",
  kind: "submenu",
  label: "NDS MiSTer Test",
  children: [
    {
      id: "cart",
      kind: "submenu",
      label: "Slot-1 Card",
      children: [
        { id: "cart.rom", kind: "choice", label: "Slot-1 ROM", options: ROM_OPTIONS },
        {
          id: "cart.savetype",
          kind: "choice",
          label: "Save type",
          options: [
            "Auto",
            "EEPROM 512K",
            "EEPROM 8K",
            "FLASH 512K",
            "FLASH 1M",
            "FRAM",
            "NAND",
          ],
        },
        {
          id: "cart.ramexp",
          kind: "choice",
          label: "Slot-2 RAM expansion",
          options: ["Off", "8 MB"],
        },
        { id: "cart.erase", kind: "action", label: "Erase save data" },
        { id: "cart.bootmenu", kind: "action", label: "Boot menu" },
        { id: "cart.clearslots", kind: "action", label: "Clear game slots" },
        { id: "cart.eject", kind: "action", label: "Eject cartridge" },
      ],
    },
    {
      id: "video",
      kind: "submenu",
      label: "Screens",
      children: [
        {
          id: "video.layout",
          kind: "choice",
          label: "Screen layout",
          options: ["Vertical", "Horizontal", "Top only", "Bottom only"],
        },
        { id: "video.rotation", kind: "choice", label: "Rotation", options: ["0°", "90°", "180°", "270°"] },
        { id: "video.swap", kind: "toggle", label: "Swap screens" },
        {
          id: "video.output",
          kind: "choice",
          label: "Video output",
          options: ["HDMI 256x384", "CRT 240p side by side", "CRT 240p single", "CRT 31 kHz"],
        },
        {
          id: "video.aspect",
          kind: "choice",
          label: "Aspect ratio",
          options: ["Original", "Full Screen", "Arcade 1", "Arcade 2"],
        },
        {
          id: "video.scale",
          kind: "choice",
          label: "Scaling",
          options: ["Integer ×4", "Integer ×5", "Fit", "Stretch"],
        },
        {
          id: "video.brightness",
          kind: "choice",
          label: "Backlight",
          options: ["Dim", "Low", "Medium", "High", "Brightest"],
        },
        {
          id: "video.scanlines",
          kind: "choice",
          label: "Scanlines",
          options: ["Off", "Soft", "Medium", "Hard"],
        },
        {
          id: "video.refresh",
          kind: "choice",
          label: "Refresh rate",
          options: ["Native 59.82", "59.95", "60.00"],
        },
        {
          id: "video.filter",
          kind: "choice",
          label: "Video filter",
          options: ["Off", "Soft", "Smooth", "Sharp"],
        },
        {
          id: "video.palette",
          kind: "choice",
          label: "LCD colour",
          options: ["Original", "DS LCD", "Vivid", "Warm", "Cool", "Grayscale"],
        },
      ],
    },
    {
      id: "audio",
      kind: "submenu",
      label: "Sound",
      children: [
        {
          id: "audio.volume",
          kind: "choice",
          label: "Master volume",
          options: ["0%", "10%", "20%", "30%", "40%", "50%", "60%", "70%", "80%", "90%", "100%"],
        },
        { id: "audio.mix", kind: "choice", label: "Sound output", options: ["Stereo", "Mono", "Headphones"] },
        { id: "audio.spusync", kind: "toggle", label: "SPU sync" },
        {
          id: "audio.latency",
          kind: "choice",
          label: "I²S latency",
          options: ["1 frame", "2 frames", "4 frames"],
        },
        {
          id: "audio.filter",
          kind: "choice",
          label: "Audio filter",
          options: ["Off", "Warm", "Bright", "Bass"],
        },
        {
          id: "audio.width",
          kind: "choice",
          label: "Stereo width",
          options: ["Off", "Soft", "Strong"],
        },
      ],
    },
    {
      id: "midi",
      kind: "submenu",
      label: "MIDI",
      children: [
        { id: "midi.mt32", kind: "toggle", label: "MT-32-pi" },
        {
          id: "midi.volume",
          kind: "choice",
          label: "MIDI volume",
          options: ["0%", "14%", "29%", "43%", "57%", "71%", "86%", "100%"],
        },
        { id: "midi.demo", kind: "toggle", label: "Internal demo stream" },
        { id: "midi.lcd", kind: "toggle", label: "Pi LCD on screen" },
        {
          id: "midi.lcdsize",
          kind: "choice",
          label: "Pi LCD size",
          options: ["1x", "2x"],
        },
        {
          id: "midi.lcdcorner",
          kind: "choice",
          label: "Pi LCD corner",
          options: ["Top left", "Top right", "Bottom left", "Bottom right"],
        },
        {
          id: "midi.synth",
          kind: "choice",
          label: "MT-32-pi synth",
          options: ["MT-32", "SoundFont"],
        },
        {
          id: "midi.sfbank",
          kind: "choice",
          label: "SoundFont bank",
          options: ["0", "1", "2", "3", "4", "5", "6", "7"],
        },
      ],
    },
    {
      id: "bios",
      kind: "submenu",
      label: "Firmware",
      children: [
        { id: "bios.slot1", kind: "choice", label: "ARM7 BIOS", options: ["HLE", "bios7.bin"] },
        { id: "bios.slot9", kind: "choice", label: "ARM9 BIOS", options: ["HLE", "bios9.bin"] },
        { id: "bios.firmware", kind: "choice", label: "Firmware", options: ["HLE", "firmware.bin"] },
        {
          id: "bios.lang",
          kind: "choice",
          label: "Language",
          options: ["English", "Japanese", "French", "German", "Italian", "Spanish"],
        },
        { id: "bios.autostart", kind: "choice", label: "Auto-start", options: ["Manual", "Auto"] },
        {
          id: "bios.region",
          kind: "choice",
          label: "Region",
          options: ["Auto", "NTSC-U", "NTSC-J", "PAL"],
        },
      ],
    },
    {
      id: "input",
      kind: "submenu",
      label: "Touch & Pad",
      children: [
        {
          id: "input.stylus",
          kind: "choice",
          label: "Stylus cursor",
          options: ["Off", "D-pad", "Left stick"],
        },
        {
          id: "input.tap",
          kind: "choice",
          label: "Stylus tap",
          options: ["L2", "R2", "L3", "R3"],
        },
        {
          id: "input.lid",
          kind: "choice",
          label: "Lid close",
          options: ["Ignore", "L2+R2", "L3+R3"],
        },
        {
          id: "input.face",
          kind: "choice",
          label: "Face buttons",
          options: ["Standard", "Swapped"],
        },
        {
          id: "input.shoulders",
          kind: "choice",
          label: "Shoulders",
          options: ["Normal", "Swapped"],
        },
        { id: "input.mic", kind: "choice", label: "Microphone", options: ["Off", "Button", "Host device"] },
        { id: "input.rumble", kind: "toggle", label: "Rumble pak" },
        {
          id: "input.profile",
          kind: "choice",
          label: "Pad profile",
          options: ["Default", "Left-hand", "Arcade stick"],
        },
      ],
    },
    {
      id: "emu",
      kind: "submenu",
      label: "System",
      children: [
        {
          id: "emu.speed",
          kind: "choice",
          label: "Core speed",
          options: ["100%", "150%", "200%", "Max"],
        },
        {
          id: "emu.overclock",
          kind: "choice",
          label: "CPU overclock",
          options: ["Normal", "ARM7 ×2", "ARM7 ×4"],
        },
        { id: "emu.frameskip", kind: "choice", label: "Frameskip", options: ["Off", "1", "2", "3"] },
        { id: "emu.autoskip", kind: "toggle", label: "Auto frameskip" },
        { id: "emu.rewind", kind: "choice", label: "Rewind buffer", options: ["Off", "5 s", "15 s", "30 s"] },
      ],
    },
    {
      id: "cheats",
      kind: "submenu",
      label: "Cheats",
      children: [
        { id: "cheats.file", kind: "action", label: "Load .cht from SD card" },
        { id: "cheats.hearts", kind: "toggle", label: "Infinite hearts" },
        { id: "cheats.coins", kind: "toggle", label: "Max coins" },
        { id: "cheats.karts", kind: "toggle", label: "Unlock all karts" },
        { id: "cheats.clear", kind: "action", label: "Disable all cheats" },
      ],
    },
    {
      id: "diag",
      kind: "submenu",
      label: "Diagnostics",
      children: [
        { id: "diag.fps", kind: "toggle", label: "Show FPS" },
        { id: "diag.graph", kind: "toggle", label: "Frame graph" },
        { id: "diag.leds", kind: "toggle", label: "Bus activity LEDs" },
        { id: "diag.log", kind: "choice", label: "Log level", options: ["Off", "Errors", "Verbose"] },
      ],
    },
    {
      id: "reset",
      kind: "submenu",
      label: "Reset",
      children: [
        { id: "reset.soft", kind: "action", label: "Soft reset" },
        { id: "reset.hard", kind: "action", label: "Hard reset" },
        { id: "reset.profile", kind: "action", label: "Reset OSD profile" },
      ],
    },
  ],
};

export type OsdValues = Record<string, string>;

/** Find a submenu by id anywhere in the tree (root included). */
export function findSubmenu(id: string, node: OsdSubmenu = OSD_ROOT): OsdSubmenu | null {
  if (node.id === id) return node;
  for (const child of node.children) {
    if (child.kind !== "submenu") continue;
    const hit = findSubmenu(id, child);
    if (hit) return hit;
  }
  return null;
}

/**
 * The rows a submenu draws, in menu order, with their current values.
 * Shared by the OSD Lab and the landing-page panels so the two can never
 * disagree about which rows exist.
 */
export function rowsFor(node: OsdSubmenu, values: OsdValues): OsdRow[] {
  return node.children.map((child) => {
    if (child.kind === "submenu") return { kind: "submenu", label: child.label };
    if (child.kind === "choice")
      return { kind: "value", label: child.label, value: values[child.id] ?? child.options[0] };
    if (child.kind === "toggle")
      return { kind: "value", label: child.label, value: values[child.id] ?? "Off" };
    return { kind: "action", label: child.label };
  });
}

/** Walk the tree and give every value row its default selection. */
export function defaultValues(node: OsdNode = OSD_ROOT, out: OsdValues = {}): OsdValues {
  if (node.kind === "choice") out[node.id] = node.options[0];
  if (node.kind === "toggle") out[node.id] = "Off";
  if (node.kind === "submenu") for (const child of node.children) defaultValues(child, out);
  return out;
}

/** Index of the currently loaded ROM in ROMS, or null when the slot is empty. */
export function loadedRom(values: OsdValues): RomEntry | null {
  const selected = values["cart.rom"] ?? "— EMPTY —";
  const index = ROMS.findIndex((r) => r.title === selected);
  return index === -1 ? null : ROMS[index];
}

/** Count of enabled cheat rows. */
export function activeCheats(values: OsdValues): number {
  return ["cheats.hearts", "cheats.coins", "cheats.karts"].filter((id) => values[id] === "On").length;
}

/** Row shape handed to the presentational panel. */
export interface OsdRow {
  kind: "submenu" | "value" | "action";
  label: string;
  value?: string;
}
