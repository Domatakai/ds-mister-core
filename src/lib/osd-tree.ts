/**
 * Menu model for the Dualis OSD.
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
  label: "Dualis NDS",
  children: [
    {
      id: "cart",
      kind: "submenu",
      label: "Cartridge",
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
        { id: "cart.erase", kind: "action", label: "Erase save data" },
        { id: "cart.eject", kind: "action", label: "Eject cartridge" },
      ],
    },
    {
      id: "video",
      kind: "submenu",
      label: "Video",
      children: [
        {
          id: "video.layout",
          kind: "choice",
          label: "Screen layout",
          options: ["Auto", "Horizontal", "Vertical", "Top only", "Bottom only"],
        },
        { id: "video.rotation", kind: "choice", label: "Rotation", options: ["0°", "90°", "180°", "270°"] },
        {
          id: "video.aspect",
          kind: "choice",
          label: "Aspect ratio",
          options: ["4:3", "14:9", "1:1", "Pixel-perfect"],
        },
        {
          id: "video.scale",
          kind: "choice",
          label: "Scaling",
          options: ["Integer ×4", "Integer ×5", "Fit", "Stretch"],
        },
        {
          id: "video.scanlines",
          kind: "choice",
          label: "Scanlines",
          options: ["Off", "Soft", "Hard"],
        },
        { id: "video.swap", kind: "toggle", label: "Swap screens" },
        {
          id: "video.brightness",
          kind: "choice",
          label: "Brightness",
          options: ["1", "2", "3", "4", "5"],
        },
      ],
    },
    {
      id: "audio",
      kind: "submenu",
      label: "Audio",
      children: [
        {
          id: "audio.volume",
          kind: "choice",
          label: "Master volume",
          options: ["0%", "10%", "20%", "30%", "40%", "50%", "60%", "70%", "80%", "90%", "100%"],
        },
        { id: "audio.mix", kind: "choice", label: "Output mix", options: ["Stereo", "Mono", "Headphones"] },
        {
          id: "audio.latency",
          kind: "choice",
          label: "I²S latency",
          options: ["1 frame", "2 frames", "4 frames"],
        },
        { id: "audio.spusync", kind: "toggle", label: "SPU sync" },
      ],
    },
    {
      id: "bios",
      kind: "submenu",
      label: "BIOS / Firmware",
      children: [
        {
          id: "bios.slot1",
          kind: "choice",
          label: "Slot-1 BIOS",
          options: ["HLE", "bios7.bin + bios9.bin"],
        },
        { id: "bios.slot2", kind: "choice", label: "Slot-2 BIOS", options: ["None", "GBA BIOS"] },
        { id: "bios.firmware", kind: "choice", label: "Firmware", options: ["HLE", "Flash dump"] },
        { id: "bios.logo", kind: "toggle", label: "Skip intro logo" },
        {
          id: "bios.region",
          kind: "choice",
          label: "Console region",
          options: ["Auto", "NTSC-U", "NTSC-J", "PAL"],
        },
      ],
    },
    {
      id: "input",
      kind: "submenu",
      label: "Input",
      children: [
        {
          id: "input.stylus",
          kind: "choice",
          label: "Stylus mode",
          options: ["D-pad", "Touch pad", "Off"],
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
      label: "Emulation",
      children: [
        {
          id: "emu.speed",
          kind: "choice",
          label: "Core speed",
          options: ["50%", "100%", "150%", "200%", "Max"],
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
