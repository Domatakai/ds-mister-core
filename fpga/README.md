# NDS MiSTer Test — the core

A Nintendo DS core for the MiSTer FPGA platform, written in SystemVerilog.
Goal: the full library — every region, every cartridge — running at the
console's native 59.826 Hz with cycle-timed CPUs, both 2D engines, the 3D
rasterizer and a complete OSD menu.

This directory is the hardware. The website in this repository (landing
page + OSD Lab) is the **menu prototype and specification** for the OSD
below — the two are intentionally kept in step.

## Status

Honest state: **skeleton (milestone M1)**. The framework wiring, the OSD
menu, the memory map, the SDRAM controller, the complete video path,
the input path (DS keys, stylus, mic) and the DDR3 cartridge path for
256 Mbit+ games are real and simulate correctly. The CPUs, 2D/3D
engines and SPU are interface-complete stubs — that is years of work
ahead, and this repo organises it so each piece lands against a stable
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
`rom_bytes`. SDRAM keeps main RAM, save data and the palette/OAM
overflow. The cart window read bridge (`win_*`) is wired to `main_bus`
when the CPUs land in M1, with a prefetch FIFO then to meet waitstates.

## Layout

```
fpga/
  NDS.sv                  core top (module emu): OSD menu, status decode,
                          instantiates everything below
  NDS.qpf / NDS.qsf       Quartus project (adapted from Template_MiSTer)
  NDS.sdc                 timing constraints
  files.qip               source list — add new files HERE, never in the IDE
  rtl/
    video/video_timing.sv     256x384 frame timing; selectable
                              59.82 / 59.95 / 60.00 Hz      [SIM-VERIFIED]
    video/screen_composer.sv  dual-screen placement, rotation,
                              swap, brightness            [SIM-VERIFIED]
    video/engine_a.sv         2D engine A (top screen) — stub, boot pattern
    video/engine_b.sv         2D engine B (touch screen) — stub
    video/vram_arbiter.sv     VRAMCNT bank map + grant scheduler — stub
    video/geometry_engine.sv  3D GXFIFO geometry — stub
    video/raster_engine.sv    3D rasterizer — stub
    cpu/arm9_core.sv          ARM946E-S @ 67.02 MHz — stub
    cpu/arm7_core.sv          ARM7TDMI @ 33.51 MHz — stub
    bus/main_bus.sv           DS memory map + arbitration — skeleton
    mem/sdram_ctrl.sv         32 MB SDRAM controller (CL3, refresh)
    cart/cart_slot.sv         ROM -> DDR3 with line FIFO + backpressure,
                              capacity detection, CPU window bridge
    input/input_mapper.sv     MiSTer pad -> DS KEYINPUT, stylus, mic
    audio/spu.sv              16-channel SPU — stub with correct framing
  tb/tb_video_timing.sv   three refresh modes          [SIM-VERIFIED]
  tb/tb_composer.sv       dual-screen placement        [SIM-VERIFIED]
  tb/tb_input_mapper.sv   keys/stylus/mic              [SIM-VERIFIED]
  tb/tb_cart_slot.sv      DDR3 download + capacity     [SIM-VERIFIED]
  tb/tb_composer.sv        composer placement testbench
```

## Build

Prerequisites: **Quartus Prime 17.0.2 or 23.1 Standard Edition**, and the
MiSTer framework:

```bash
git clone --depth 1 https://github.com/MiSTer-devel/Template_MiSTer.git
cp -r Template_MiSTer/sys  fpga/sys      # framework (hps_io, osd, scaler…)
cd fpga
quartus_sh --flow compile NDS            # or open NDS.qpf in the IDE
cp output_files/NDS.rbf  /media/fat/games/NDS/
```

The `.rbf` appears on the MiSTer's Games/NDS folder. Optional real BIOS:
put `bios7.bin` + `bios9.bin` in `/media/fat/BIOS/` and set
**BIOS & Input → Slot-1 BIOS → Real** (HLE boots without them).

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

# 4. cart — DDR3 line FIFO, 256 Mbit capacity, window reads
iverilog -g2012 -o /tmp/tb_cart tb/tb_cart_slot.sv rtl/cart/cart_slot.sv
vvp /tmp/tb_cart
# tb_cart_slot: PASS

# 5. whole-top elaboration lint (Verilator 5+)
verilator --lint-only -sv --top-module emu -I<framework-stub> \
  NDS.sv <hps_io-stub> rtl/**/*.sv     # clean
```

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
refresh rate: Native 59.82 / 59.95 / 60.00), **Audio** (volume, mix,
I2S latency, SPU sync), **BIOS & Input** (HLE vs
real BIOS, firmware, region, stylus cursor + tap button, face/shoulder
swaps, mic, rumble, pad profile), **Emulation** (speed, CPU overclock:
Normal / ARM7 ×2 / ARM7 ×4, frameskip, rewind), **Diagnostics** (FPS,
frame graph, bus LEDs, log level), cheat file load (`F2,.CHT`), soft
reset and reset. The full status-bit map is documented at the top of
`NDS.sv`.

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
| M6 | Save states via DDR3, cheat engine, replay, OSD polish | planned |

The OSD menu and all three refresh modes (59.82 / 59.95 / 60.00 Hz,
simulation-verified) are already final; everything else fills in
behind them.
