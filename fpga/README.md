# NDS MiSTer Test — the core

A Nintendo DS core for the MiSTer FPGA platform, written in SystemVerilog.
Goal: the full library — every region, every cartridge — running at the
console's native 59.826 Hz with cycle-timed CPUs, both 2D engines, the 3D
rasterizer and a complete OSD menu.

This directory is the hardware. The website in this repository (landing
page + OSD Lab) is the **menu prototype and specification** for the OSD
below — the two are intentionally kept in step.

## Status

Honest state: **milestones M1 + M2**. The framework wiring, the OSD
menu, the memory map, the SDRAM controller, the complete video path,
the input path (DS keys, stylus, mic) and the DDR3 cartridge path for
256 Mbit+ games are real and simulate correctly. The rebuilt system bus
is complete and simulated: `main_bus` decodes the DS memory map,
serves both CPUs and the DMA engine from private WRAM/IO/BIOS regions
with round-robin arbitration, sequences 32-bit accesses over SDRAM
halfwords through `mem_arbiter`, bridges the cart window, and patches
RAM reads through the Action-Replay parser in `cheat_engine` (GBATEK
type table). M2 added the first real 2D path: `renderer_2d` renders
text BG0-3, OBJ sprites and the backdrop through a double-buffered
line pipeline fed by VRAM, wrapped by `engine_a` / `engine_b`;
`vram_arbiter` implements the VRAMCNT bank map with per-master
(CPU / engine A / engine B) window decode on the third SDRAM master;
`dma_engine` implements all four GBATEK DMA channels with
immediate/vblank/hblank triggers, repeat and completion IRQs. On top
of that, the video/audio filter layer (`video_filter`, `palette`,
`audio_filter`) is wired into the output chains. The CPUs, 3D engines
and SPU are interface-complete stubs — that is years of work ahead,
and this repo organises it so each piece lands against a stable
contract.

## Memory & cartridge sizes

Pure DS support, region-free. The full ROM image is stored in the
DE10-Nano's **DDR3**, so every cart size fits without banking:

| Size | Example | Where it lives |
|------|---------|----------------|
| 32 MB / 256 Mbit | most late-era DS titles | DDR3 |
| up to 512 MB / 4 Gbit | DS maximum | DDR3 |

The download stream is buffered in a 64-line FIFO; `ioctl_wait` pauses
the HPS if DDR3 contention (with the scaler) backs up — no bytes can be
dropped. Header byte 0x80 (device capacity) is captured into
`rom_bytes`. SDRAM holds main RAM, WRAM overflow, VRAM bank storage
and cart save data; `mem_arbiter` shares it between the bus RAM window
(CPU traffic), the cart save path (fixed priority, saves are
latency-sensitive bursts) and the VRAM path behind `vram_arbiter`. The cart window read bridge (`win_*`) is wired to `main_bus`
with a pending latch so a request survives DDR busy periods, and a
prefetch FIFO then meets waitstates.

## Layout

```
fpga/
  NDS.sv                  core top (module emu): OSD menu, status decode,
                          instantiates everything below
  NDS.qpf / NDS.qsf       Quartus project (adapted from Template_MiSTer)
  NDS.sdc                 timing constraints (Template-style; top-level
                          clocks come from sys/sys_top.sdc)
  files.qip               source list — add new files HERE, never in the IDE
  sys/                    MiSTer framework vendored from Template_MiSTer
                          (hps_io, osd, scaler, sys_top, PLLs, pins) —
                          keep in sync with upstream, do not edit
  rtl/
    pll.qip / pll.v       core PLL wrapper required by the framework
                          (sys/pll_q17.qip references it)
    video/video_timing.sv     256x384 frame timing; selectable
                              59.82 / 59.95 / 60.00 Hz      [SIM-VERIFIED]
    video/screen_composer.sv  dual-screen placement, rotation,
                              swap, brightness            [SIM-VERIFIED]
    video/video_filter.sv     spatial filter: soft/smooth/sharp
                              (one-line buffer, 1 CE latency) [SIM-VERIFIED]
    video/palette.sv          colour profiles: DS LCD, vivid,
                              warm, cool, grayscale         [SIM-VERIFIED]
    video/renderer_2d.sv      shared 2D text renderer: BG0-3, OBJ,
                              backdrop, palette cache, line buffers
                              [SIM-VERIFIED]
    video/engine_a.sv         2D engine A wrapper (reg/pal/OAM/VRAM)
                              [SIM-VERIFIED]
    video/engine_b.sv         2D engine B wrapper              [SIM-VERIFIED]
    video/vram_arbiter.sv     VRAMCNT bank map, MST decode, CPU>engine
                              grants, SDRAM master            [SIM-VERIFIED]
    video/geometry_engine.sv  3D GXFIFO geometry — stub
    video/raster_engine.sv    3D rasterizer — stub
    cpu/arm9_core.sv          ARM946E-S @ 67.02 MHz — stub
    cpu/arm7_core.sv          ARM7TDMI @ 33.51 MHz — stub
    bus/main_bus.sv           DS memory map, both CPUs + DMA, round-robin,
                              cart window, VRAM, engine ports, cheat patch
                              [SIM-VERIFIED]
    bus/dma_engine.sv         4 GBATEK DMA channels: immediate/vblank/
                              hblank, repeat, IRQ            [SIM-VERIFIED]
    mem/sdram_ctrl.sv         32 MB SDRAM controller (CL3, refresh, BE)
    mem/mem_arbiter.sv        three-master SDRAM arbiter (bus + save + VRAM)
    cart/cart_slot.sv         ROM -> DDR3 with line FIFO + backpressure,
                              capacity detection, CPU window bridge
                              [SIM-VERIFIED]
    cart/cheat_engine.sv      Action Replay DS parser (GBATEK types
                              0-A) + RAM read patching       [SIM-VERIFIED]
    input/input_mapper.sv     MiSTer pad -> DS KEYINPUT, stylus, mic
    audio/audio_filter.sv     EQ presets (warm/bright/bass) +
                              mid/side stereo width          [SIM-VERIFIED]
    audio/spu.sv              16-channel SPU — stub with correct framing
  tb/tb_video_timing.sv   three refresh modes          [SIM-VERIFIED]
  tb/tb_composer.sv       dual-screen placement        [SIM-VERIFIED]
  tb/tb_video_filter.sv   pass-through, uniform blend, step edge [SIM-VERIFIED]
  tb/tb_palette.sv        colour profiles              [SIM-VERIFIED]
  tb/tb_audio_filter.sv   pass-through, width, EQ, saturate     [SIM-VERIFIED]
  tb/tb_input_mapper.sv   keys/stylus/mic              [SIM-VERIFIED]
  tb/tb_cart_slot.sv      DDR3 download + capacity     [SIM-VERIFIED]
  tb/tb_main_bus.sv       fabric: masters, RAM, cart, cheat, IO [SIM-VERIFIED]
  tb/tb_cheat_engine.sv   file parse + types + guard    [SIM-VERIFIED]
  tb/tb_renderer_2d.sv    text BG/OBJ render, hflip, line swap [SIM-VERIFIED]
  tb/tb_dma_engine.sv     4 channels, triggers, repeat, IRQ [SIM-VERIFIED]
  tb/tb_vram_arbiter.sv   bank map, MST decode, priority  [SIM-VERIFIED]
```

## Build

Prerequisites: **Quartus Prime 17.0.x** — the MiSTer project mandates
17.0.x (17.0.2 recommended, Lite or Standard license; newer versions
introduce project-setting incompatibilities with no benefit for the
Cyclone V). The MiSTer framework is **already vendored** in `fpga/sys/`
(hps_io, osd, scaler, sys_top, PLLs, pin map) exactly as shipped by
Template_MiSTer — no copy step needed.

```bash
cd fpga
quartus_sh --flow compile NDS            # or open NDS.qpf in the IDE
```

Windows: run `fpga\build.bat` (or `build.bat "<quartus>\bin64"` for a
non-default install location). It defaults to
`C:\intelFPGA_lite\17.0\quartus\bin64`, runs the same flow, and prints
where `NDS.rbf` landed and how to copy it to the SD card.

First full compile (analysis + fit + ASM + timing) takes roughly
10–20 min on a modern multicore machine (`NUM_PARALLEL_PROCESSORS ALL`
is set). Success criteria:

- `output_files/NDS.rbf` exists (GENERATE_RBF_FILE is on),
- TimeQuest reports no failing paths on the 50 MHz `FPGA_CLK2_50` /
  `clk_sys` domain (`derive_pll_clocks` covers the HDMI/audio PLLs;
  `NDS.sdc` + `sys/sys_top.sdc` are both registered),
- Warnings to watch for: any **error** mentioning a missing file (a
  `files.qip` entry) or a port name on `hps_io` — the port list was
  verified against the framework source, so that would mean `sys/`
  drifted from Template_MiSTer.

Deploy to the DE10-Nano:

```bash
cp output_files/NDS.rbf  /media/fat/games/NDS/NDS.rbf
```

The core appears as **NDS MiSTer Test** in the MiSTer menu. Optional
real BIOS: put `bios7.bin` + `bios9.bin` in `/media/fat/BIOS/` and set
**BIOS & Input → Slot-1 BIOS → Real** (HLE boots without them). With a
USB-Blaster attached, `jtag.cdf` (generated at compile time) can push
the SOF straight to the board without an SD round-trip.

### First hardware bring-up — what "working" looks like today

The skeleton compiles to a stable, testable system even though games
cannot boot yet (CPUs are stubs — M1). On first boot you should see:

| Check | Expected |
|---|---|
| HDMI output | stable dual-screen frame at the selected refresh (59.82 native default), no flicker/desync |
| Screens | engine A/B boot test patterns, correctly placed by layout/rotation/swap |
| OSD menu | every row listed under **OSD menu** below opens and changes video/audio live |
| `.nds` load (F1) | progress bar completes for any ROM size; cart LED activity; no freezes (ioctl_wait backpressure holds under DDR3 contention) |
| `.cht` load (F2) | accepted without wedging; codes parsed (they take effect at M1 bus level — RAM patches are simulated, not yet exercised by a running game) |
| Input | D-pad/buttons/keys move KEYINPUT (visible via Diagnostics bus LEDs) |
| Audio | silence is expected — SPU is a framing stub until M4 |


If HDMI is dead: check the compile warnings first, then confirm the
`pll_hdmi` megafunction was generated for your Quartus patch level.

### Simulation

```bash
cd fpga
# 1. video timing — all three refresh modes
iverilog -g2012 -o /tmp/tb_vt tb/tb_video_timing.sv rtl/video/video_timing.sv
vvp /tmp/tb_vt
# tb_video_timing: native   320x653 -> 59.8201 Hz, 98304 active px
# tb_video_timing: 59.95    332x628 -> 59.9532 Hz, 98304 active px
# tb_video_timing: 60.00    320x651 -> 60.0038 Hz, 98304 active px
# tb_video_timing: PASS

# 2. dual-screen composer — layouts, swap, rotation, clip
iverilog -g2012 -o /tmp/tb_sc tb/tb_composer.sv \
         rtl/video/screen_composer.sv rtl/video/engine_a.sv rtl/video/engine_b.sv
vvp /tmp/tb_sc
# tb_composer: PASS

# 3. input — KEYINPUT order/polarity, swaps, stylus, mic
iverilog -g2012 -o /tmp/tb_in tb/tb_input_mapper.sv rtl/input/input_mapper.sv
vvp /tmp/tb_in
# tb_input_mapper: PASS

# 4. cart — DDR3 line FIFO (BUSY hold-until-accept), partial-line tail
#     flush, 256 Mbit + 512 MB capacity, window reads
iverilog -g2012 -o /tmp/tb_cart tb/tb_cart_slot.sv rtl/cart/cart_slot.sv
vvp /tmp/tb_cart
# tb_cart_slot: PASS

# 5. main bus — masters, WRAM/IO, SDRAM window, cart bridge, cheat patch
iverilog -g2012 -o /tmp/tb_bus tb/tb_main_bus.sv \
         rtl/bus/main_bus.sv rtl/mem/mem_arbiter.sv rtl/cart/cheat_engine.sv
vvp /tmp/tb_bus
# tb_main_bus: PASS (13 checks)

# 6. cheat engine — GBATEK type table, guard block, lockout, reload
iverilog -g2012 -o /tmp/tb_cheat tb/tb_cheat_engine.sv rtl/cart/cheat_engine.sv
vvp /tmp/tb_cheat
# tb_cheat_engine: PASS

# 7. video filter — pass-through latency, uniform blend, step edge
iverilog -g2012 -o /tmp/tb_vf tb/tb_video_filter.sv rtl/video/video_filter.sv
vvp /tmp/tb_vf
# TB VIDEO_FILTER PASS

# 8. palette — all six profiles against hand-computed values
iverilog -g2012 -o /tmp/tb_pal tb/tb_palette.sv rtl/video/palette.sv
vvp /tmp/tb_pal
# TB PALETTE PASS

# 9. audio filter — width, saturation, EQ convergence, hold
iverilog -g2012 -o /tmp/tb_af tb/tb_audio_filter.sv rtl/audio/audio_filter.sv
vvp /tmp/tb_af
# TB AUDIO FILTER PASS

# 10. shared 2D renderer — backdrop, text BG, hflip, OBJ, line swap
iverilog -g2012 -o /tmp/tb_rd tb/tb_renderer_2d.sv rtl/video/renderer_2d.sv
vvp /tmp/tb_rd
# tb_renderer_2d: PASS

# 11. DMA — immediate/vblank/hblank, 16/32-bit, repeat, IRQ, readback
iverilog -g2012 -o /tmp/tb_dma tb/tb_dma_engine.sv rtl/bus/dma_engine.sv
vvp /tmp/tb_dma
# tb_dma_engine: PASS

# 12. VRAM bank arbiter — VRAMCNT map, MST decode, offsets, priority
iverilog -g2012 -o /tmp/tb_vram tb/tb_vram_arbiter.sv rtl/video/vram_arbiter.sv
vvp /tmp/tb_vram
# tb_vram_arbiter: PASS

# 13. whole-top elaboration lint (Verilator 5+) against the REAL
#     framework in sys/ — core + framework, warning classes disabled
#     are the framework's own known Verilator complaints (legal SV,
#     Quartus-clean) plus unused-signal style noise:
mkdir -p /tmp/lintstub && printf '`define BUILD_DATE "251023"\n' > /tmp/lintstub/build_id.v
SRC=$(awk '/SYSTEMVERILOG_FILE/ {print $NF}' files.qip | tr '\n' ' ')
SYS=$(find sys -name '*.sv' -o -name '*.v' | grep -v 'hdmi/' \
      | grep -v 'sys_top' | grep -v 'mcp23009' | tr '\n' ' ')
verilator --lint-only -sv --top-module emu \
  -Wno-BLKANDNBLK -Wno-PROCASSWIRE -Wno-IMPLICIT -Wno-IMPLICITSTATIC \
  -Wno-TIMESCALEMOD -Wno-WIDTH -Wno-WIDTHCONCAT -Wno-PINMISSING \
  -Wno-CASEX -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-DECLFILENAME \
  -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-VARHIDDEN -Wno-SYNCASYNCNET \
  -I/tmp/lintstub -Irtl -Irtl/cpu -Irtl/bus -Irtl/cart -Irtl/mem \
  -Irtl/video -Irtl/audio -Irtl/input \
  $SRC $SYS        # exits 0, no output
```

`sys_top`, `mcp23009` and `hdmi/` are excluded from the lint: Verilator
5.006 cannot parse two constructs in them (unpacked-array initializer,
altera primitives) that Quartus accepts — they are framework files
compiled by Quartus, not by this lint.

## Controls

Everything needed to play, including the touch screen, mapped from the
MiSTer virtual gamepad ("Define joystick buttons" order):

| MiSTer pad | DS |
|---|---|
| D-pad | D-pad (or stylus cursor when enabled) |
| A/B/X/Y | A/B/X/Y (OSD swap available) |
| L/R (8/9) | L/R (OSD swap available) |
| Select/Start | Select/Start |
| L2/R2/L3/R3 | Stylus tap / microphone (configurable) |
| Left stick | Stylus cursor (alternative mode) |

KEYINPUT follows GBATEK exactly (bit0=A … bit11=Y, 0=Pressed),
verified in `tb_input_mapper`. Keyboard users map the keyboard as a
joystick in the MiSTer menu core and it arrives through the same path.
Stylus cursors accelerate while held (250 px/s base, 1000 px/s after
~1 s).

## OSD menu

Drawn by the framework from `CONF_STR` in `NDS.sv`; values arrive in the
128-bit `status` word. Groups: **Cartridge** (load `.nds`, save type,
erase), **Video** (layout, rotation, aspect, scanlines, swap, brightness,
refresh rate: Native 59.82 / 59.95 / 60.00, video filter:
Off / Soft / Smooth / Sharp, palette: Original / DS LCD / Vivid / Warm /
Cool / Grayscale), **Audio** (volume, mix, I2S latency, SPU sync, audio
filter: Off / Warm / Bright / Bass, stereo width: Off / Soft / Strong —
mid/side widening), **BIOS & Input** (HLE vs
real BIOS, firmware, region, stylus cursor + tap button, face/shoulder
swaps, mic, rumble, pad profile), **Emulation** (speed, CPU overclock:
Normal / ARM7 ×2 / ARM7 ×4, frameskip, rewind), **Diagnostics** (FPS,
frame graph, bus LEDs, log level), cheat file load (`F2,.CHT` — parsed
by `cheat_engine`, applied as RAM read patches), soft
reset and reset. The full status-bit map is documented at the top of
`NDS.sv`.

The website's OSD Lab mirrors these rows one-for-one (`src/lib/osd-tree.ts`);
the video preview reacts to layout, rotation, brightness and scanlines.

Region policy: **none**. The header's game code is captured for the
diagnostics overlay only — NTSC-U, NTSC-J and PAL carts all boot.

## Milestones

| # | Scope | State |
|---|-------|-------|
| M1 | Skeleton, boot, HLE BIOS, main RAM, input + DDR3 cart paths | in progress |
| M2 | 2D engines A/B, VRAM banking, DMA | next |
| M3 | PLL (67.02/33.51 MHz domains), overclock enables, 3D geometry + rasterizer | planned |
| M4 | SPU channels, save types + `.sav`, Slot-2-free DS saves, cart unlock commands | planned |
| M5 | Microphone, rumble, local DS-to-DS wireless | planned |
| M6 | Save states via DDR3, replay, OSD polish (cheat engine done) | planned |

The OSD menu, all three refresh modes (59.82 / 59.95 / 60.00 Hz), the
system bus fabric, the cheat engine and the AV filter layer are
simulation-verified; everything else fills in behind them.
