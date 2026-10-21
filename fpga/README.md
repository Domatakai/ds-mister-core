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
menu, the memory map, the SDRAM controller and the complete video path are
real and simulate correctly. The CPUs, 2D/3D engines and SPU are
interface-complete stubs — that is years of work ahead, and this repo
organises it so each piece lands against a stable contract.

## Layout

```
fpga/
  NDS.sv                  core top (module emu): OSD menu, status decode,
                          instantiates everything below
  NDS.qpf / NDS.qsf       Quartus project (adapted from Template_MiSTer)
  NDS.sdc                 timing constraints
  files.qip               source list — add new files HERE, never in the IDE
  rtl/
    video/video_timing.sv     256x384 frame timing, 59.8201 Hz  [SIM-VERIFIED]
    video/screen_composer.sv  dual-screen placement, rotation,
                              swap, brightness                   [FUNCTIONAL]
    video/engine_a.sv         2D engine A (top screen) — stub, boot pattern
    video/engine_b.sv         2D engine B (touch screen) — stub
    video/vram_arbiter.sv     VRAMCNT bank map + grant scheduler — stub
    video/geometry_engine.sv  3D GXFIFO geometry — stub
    video/raster_engine.sv    3D rasterizer — stub
    cpu/arm9_core.sv          ARM946E-S @ 67.02 MHz — stub
    cpu/arm7_core.sv          ARM7TDMI @ 33.51 MHz — stub
    bus/main_bus.sv           DS memory map + arbitration — skeleton
    mem/sdram_ctrl.sv         32 MB SDRAM controller (CL3, refresh)
    cart/cart_slot.sv         .nds download, header capture, save control
    audio/spu.sv              16-channel SPU — stub with correct framing
  tb/tb_video_timing.sv   self-checking testbench (Icarus Verilog)
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
iverilog -g2012 -o /tmp/tb_vt tb/tb_video_timing.sv rtl/video/video_timing.sv
vvp /tmp/tb_vt
# tb_video_timing: refresh = 59.8201 Hz
# tb_video_timing: active pixels/frame = 98304 (expect 98304)
# tb_video_timing: PASS
```

## OSD menu

Drawn by the framework from `CONF_STR` in `NDS.sv`; values arrive in the
128-bit `status` word. Groups: **Cartridge** (load `.nds`, save type,
erase), **Video** (layout, rotation, aspect, scanlines, swap, brightness),
**Audio** (volume, mix, I2S latency, SPU sync), **BIOS & Input** (HLE vs
real BIOS, firmware, region, stylus, mic, rumble, pad profile),
**Emulation** (speed, frameskip, rewind), **Diagnostics** (FPS, frame
graph, bus LEDs, log level), cheat file load (`F2,.CHT`), soft reset and
reset. The full status-bit map is documented at the top of `NDS.sv`.

Region policy: **none**. The header's game code is captured for the
diagnostics overlay only — NTSC-U, NTSC-J and PAL carts all boot.

## Milestones

| # | Scope | State |
|---|-------|-------|
| M1 | Skeleton, boot, HLE BIOS, main RAM, ROM download | in progress |
| M2 | 2D engines A/B, VRAM banking, DMA | next |
| M3 | PLL (67.02/33.51 MHz domains), 3D geometry + rasterizer | planned |
| M4 | SPU channels, save types + `.sav`, Slot-2, cart banking | planned |
| M5 | Microphone, rumble, local DS-to-DS wireless | planned |
| M6 | Save states via DDR3, cheat engine, replay, OSD polish | planned |

The video timing (59.8201 Hz measured, native 59.8261 Hz) and the OSD
menu are already final; everything else fills in behind them.
