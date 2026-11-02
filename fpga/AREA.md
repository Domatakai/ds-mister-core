# Area budget: fitting the NDS core on the DE10-Nano's A6

Measured from a full compile of the current tree (`quartus_sh --flow compile
NDS`, Quartus 17.0.0, device `5CSEBA6U23I7`, 2026-10-31, run from `/tmp/ndsfull`
because the fitter needs a path outside OneDrive), from the `quartus_map` pass
that precedes it, and from standalone `quartus_map` probes of the candidate
rewrites. Device capacities were read from a trivial fit on the same part, not
from a datasheet.

## The budgets, as the design stands

| resource | used | device | headroom |
|---|---|---|---|
| ALMs needed (mapper) | 58,325 | 41,910 | **−16,415 (139%)** |
| ALMs used (fitter) | 58,065 | 41,910 | **−16,155 (139%)** |
| combinational nodes (ALUTs) | 83,296 | 83,820 | 524 (99.4%) |
| registers | 53,805 | 83,820 | 30,015 (64%) |
| DSP blocks | 96 | 112 | 16 (86%) |
| M10K bits | 1,873,331 | 5,662,720 | 3,789,389 (33%) |
| I/O pins | 145 | 314 | 169 (46%) |

41,910 ALMs each give two combinational nodes and two registers, so the LUT and
register limits are the same 83,820. The node count is now *under* that limit —
83,296, 524 spare — so the mapper's `170011` check passes and the fitter reaches
placement. What it runs out of there is LABs: 5,883 required against 4,191, 140%.
A LAB holds ten ALMs, so 5,883 LABs is the same statement as 58,830 ALMs, and
the gap is 16,474 ALMs at the mapper's count — 28% of the design.

The full compile stops at the fitter, in its own words:

```
Error (170012): Fitter requires 5883 LABs to implement the design, but the device contains only 4191 LABs
Error (11802): Can't fit design in device.
```

That is 26:26 into the flow and it comes after placement, so the number in it is
the fitter's own post-placement count, not a pre-flight estimate. The timing
analyzer still never runs: there is no Fmax for this build, only the mapper's
numbers above.

Nothing else is close to its budget. Pins are *not* a constraint and never
were: 145 of the 314 I/O the part exposes, 46%, so the periphery has 169 spare
pins. PLLs are 3 of 6. DSPs are 96 of 112 — they were over at 124 until item 1
serialised the geometry engine's matrix multiply. The 33% memory figure is the
mapper's bit count against 5.66 Mbit; a failed fit allocates no blocks, so the
`0 / 553` in its summary is not a usage number. What does not fit is logic.

This file started from a pre-item baseline of 141,879 combinational ALUTs,
68,515 registers and 124 DSP blocks — 169% of the device's logic and 111% of
its DSPs. Every figure below is measured against that start, and the rows above
are where the items left it.

## The project was mapping itself for speed

`NDS.qsf` asked for `OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"` and
`OPTIMIZATION_TECHNIQUE SPEED` while also setting
`PHYSICAL_SYNTHESIS_COMBO_LOGIC_FOR_AREA`. The design is area-starved, so those
worked against the third. Mapping the *same sources* twice, changing only the
optimisation assignments, measures what they were costing:

| | speed | area | change |
|---|---|---|---|
| combinational ALUTs | 84,130 | **83,245** | −885 |
| ALMs needed | 59,346 | **58,384** | −962 |
| registers | 54,092 | 53,704 | −388 |
| DSP blocks | 96 | 96 | — |
| block memory bits | 1,873,204 | 1,873,331 | +127 |

Those figures are the measurement that setting produced, not the design
today: the cart read cache since added +84 ALUTs, +90 registers and +5 ALMs.


The qsf now asks for area — `OPTIMIZATION_MODE "BALANCED"`,
`OPTIMIZATION_TECHNIQUE AREA`, `ALM_REGISTER_PACKING_EFFORT HIGH`,
`SYNTH_TIMING_DRIVEN_SYNTHESIS OFF` — with no RTL change, and
`tools/run_benches.py` is 33/33 either way. Those 885 nodes are what turns the
`170011` check from a wall into a pass: the fit now fails one stage later, on
LABs, which is the wall this file has been describing all along.

`QII_AUTO_PACKED_REGISTERS MINIMAL_AREA` is rejected as an illegal value by
Quartus 17.0, which is why the register packing comes from
`ALM_REGISTER_PACKING_EFFORT` alone.

Two further levers were measured and rejected. `ALLOW_ANY_RAM_SIZE_FOR_RECOGNITION`
and `ALLOW_ANY_ROM_SIZE_FOR_RECOGNITION` both on map to **83,608 nodes and
58,539 ALMs** — worse than the area build by 363 nodes and 155 ALMs — so no
small memory is hiding in this design. Switching off the other two speed-only
features, `PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION` and
`ROUTER_LCELL_INSERTION_AND_LOGIC_DUPLICATION`, changes nothing that matters:
fitted on its own the design still needs **5,883 LABs**, exactly the count it
needs with them on, and placement preparation stretches from under 18 minutes to
21:51. Neither setting is in the qsf.

A third lever was measured and rejected. The two engine-facing palette copies
are 16 bits wide, but an engine reads BGR555 and never looks at bit 15, so the
fitter was already deleting that bit from both RAMs (`14320` on `ram_block1a15`
of each). Declaring the copies 15 bits wide says the same thing in the source
and does clear those two notes plus the `14284` header that carried them,
taking the log from 53 warnings to 49 -- with registers (53,805) and block
memory (1,873,331 bits) exactly where they were. It also maps to **83,409
combinational ALUTs against 83,296**, +113, so the explicit width costs logic
that the optimiser's version did not. The palette stays 16 bits.

## What it would take to fit (measured)

The device needs 16,474 ALMs back. Rather than projecting the cuts, the design
now has switches for them: `NDS_NO_3D`, `NDS_NO_CHEAT` and `NDS_NO_SPU` compile
the 3D pipeline, the cheat engine and the SPU out of `NDS.sv` and tie their
ports off. Each row below is a real `quartus_map` on `5CSEBA6U23I7` with the
committed area settings, the macro passed on the command line:

| build | ALMs | ALUTs | registers | DSP | vs A6 |
|---|---|---|---|---|---|
| full (the committed default) | 58,325 | 83,296 | 53,805 | 96 | 139% |
| `NDS_NO_3D` | 54,220 | 78,095 | 46,448 | 74 | 129% |
| `NDS_NO_3D` + `NDS_NO_CHEAT` + `NDS_NO_SPU` | **48,427** | **70,198** | **38,751** | **66** | **116%** |

Those two reduced rows predate the cart read cache and the per-game overclock
lookup; the default row above is the current measurement of all of it.

### The cut ladder, measured (2026-11-01)

Two more switches price the coarse cuts the ranked list could not deliver:
`NDS_ONE_SCREEN` compiles engine B out (one renderer answers both screens, the
bottom pixel coming back blank) and `NDS_NO_SWI_HLE` compiles the shared BIOS
SWI bank out (every BIOS call then vectors to the absent BIOS, so that rung is a
measurement only, never a product). Each row is one clean `quartus_map` on
`5CSEBA6U23I7` with the committed area settings and the macros in a scratch
`.qsf`; the first two rows re-measure the older table above on today's tree.

| build | ALMs | ALUTs | registers | vs A6 (41,910 ALMs) |
|---|---|---|---|---|
| full (committed default) | 58,325 | 83,296 | 53,805 | 139% |
| + `NDS_NO_3D` | 54,170 | 78,143 | 46,549 | 129% |
| + `NDS_NO_CHEAT` `NDS_NO_SPU` | 48,545 | 70,479 | 38,852 | 116% |
| + `NDS_ONE_SCREEN` | 42,061 | 60,838 | 31,058 | 100.4% |
| + `NDS_NO_SWI_HLE` | **40,905** | **58,975** | **30,248** | **97.6%** |

The second 2D engine is the largest single item left once the 3D pipeline is
gone: 6,484 ALMs and 9,641 ALUTs, an eighth of the design, which is why the
shared-renderer item was worth chasing. Taking it brings the mapper to 100.4%
and the last rung to 97.6% -- but the mapper's percentage is not the verdict.
Fitted for real, that deepest rung still does not go on the device:

```
Error (170012): Fitter requires 4245 LABs to implement the design, but the
                device contains only 4191 LABs
```

**4,245 LABs against 4,191: 54 over, 1.3%.** So no combination of the five
switches fits, and the configuration that comes closest is already a 2D,
single-screen, silent core without cheats or BIOS calls -- a different product,
not a trimmed one. The remaining 54 LABs (~540 ALMs of LAB capacity) would have
to come out of the framework -- one OSD, the scanline filter, the shadowmask,
the MIDI link -- rather than out of the core.

### The framework rung, measured (2026-11-01)

So the last 54 LABs were sought in the framework, using switches the framework
already carries in `sys/sys_top.v` rather than editing RTL: `MISTER_DISABLE_YC`
removes the YC/S-Video output path and `MISTER_DISABLE_ALSA` removes ALSA
audio. Neither is defined in the default build, so the default numbers in this
file are untouched. Stacked on the deepest core rung:

| rung | switches | ALMs | ALUTs | regs | DSP | of device |
|---|---|---|---|---|---|---|
| core deepest | five core switches | 40,905 | 58,975 | 30,248 | 65 | 97.6% |
| t5 | + `MISTER_DISABLE_YC` | 40,780 | 58,580 | 29,976 | 63 | 97.3% |
| t6 | + `MISTER_DISABLE_ALSA` | 40,500 | 58,146 | 29,287 | 63 | 96.6% |

Both cuts are real in the netlist and not just in the settings: `yc_out`
references in the map report fall from 154 to 2, `alsa` from 18 to 4, and the
register count drops 268 then 689. The extra `Warning (14320)` lines are the
synthesized-away nodes of the disabled paths, which is also why these rungs
report 124 warnings instead of the default 53 -- nothing was filtered to get
there.

Fitted for real, t6 still does not go on the device:

```
Error (170012): Fitter requires 4216 LABs to implement the design, but the
                device contains only 4191 LABs
```

**4,216 against 4,191: 25 over, down from 54.** So the two framework switches
are worth 405 ALMs and 29 LABs -- 29 of the 54 the core was short, and the
remaining 25 would have to come from removing an OSD, the scanline filter or
the shadowmask outright. The framework is not spare capacity: it is already
mostly floorplan and PLL, and the parts that do compress are the ones the
picture depends on. A bitstream for the A6 remains out of reach at this feature
set; a larger device or a cut in the core is the decision.

### The framework video rung, measured (2026-11-01)

Three more switches, all in `sys/sys_top.v` and all default-off, put the
framework's cosmetic and overlay blocks behind bypasses that carry the module's
own latency -- 5 clocks for the shadowmask, 3 for the scanline filter, 4 for the
VGA OSD -- so the picture keeps its alignment instead of shifting by a few
pixels:

| switch | what stops being built | entity cost in the t6 report (ALUTs / regs) |
|---|---|---|
| `MISTER_DISABLE_SHADOWMASK` | the mask multiply on the HDMI path | 254 / 248 |
| `MISTER_DISABLE_SCANLINES` | the scanline filter on the analog path | 39 / 6 |
| `MISTER_DISABLE_OSD_VGA` | the menu overlay on the analog output | 859 / 540 |

Those entity figures are in context, from the `sys_top` hierarchy of the t6 map
report. The same table says where the rest of the framework sits: `ascal` 2,826
ALUTs and 4,451 registers, the HDMI OSD 849 and 540, `audio_out` 1,599,
`pll_hdmi_adj` 732, `pll_cfg_hdmi` 284, `vga_out` plus `vga_scaler_out` 520.
Which is why the numbers below are 815 ALMs and not the ~1,000 the earlier
projection guessed: the two OSDs and the scaler are the only framework blocks
that are large, and two of the three cuts here are small blocks the picture
barely notices.

All three switches on top of t6:

| build | ALMs | ALUTs | regs | warnings | of device |
|---|---|---|---|---|---|
| t6 | 40,500 | 58,146 | 29,287 | 124 | 96.6% |
| t9, t6 plus the three bypasses | 39,685 | 56,717 | 28,422 | 126 | 94.7% |

The netlist says the 815 ALMs came from exactly those three modules and nothing
else: in the t9 report `shadowmask:HDMI_shadowmask` falls from 77 references to
0, `scanlines:VGA_scanlines` from 21 to 0 and `osd:vga_osd` from 179 to 0, while
`osd:hdmi_osd` stays at 159 and `ascal` keeps every one of its logic blocks, with
only its mention count in the report moving (800 to 863) as the hierarchy around
it shifts. The warning count is 126 against t6's 124, and not because anything
was suppressed: `Warning (10036)` appears three times for `io_osd_vga`,
`shadowmask_data` and `shadowmask_wr` (assigned, never read, now that their
consumers are gone), and one `Warning (276027)` inferred-RAM notice drops out.

At default settings the fitter places but does not route: peak interconnect 93.1%
overall and 99.0% on the horizontal channels, `Warning (16684)` then
`Warning (16618)` with the routing phase terminated and `Critical Warning (188026)`
after 3h13m, and no bitstream. Eighteen free LABs were enough to place and not
enough to route.

The fitter's own remedy fixes it. With `FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION
Always` and `SEED 2`, placement still clears the gate at 4,173 LABs, routing then
completes in 01:20:34 and the fit succeeds in 01:50:47 at **4,177 of 4,191 LABs** with
peak interconnect 88.8% overall / 87.6% horizontal / 93.1% vertical --
`Quartus Prime Fitter was successful. 0 errors, 20 warnings`.
The assembler produces a 3,813,556-byte `NDS.rbf` with 0 errors and 0 warnings: the
first bitstream this ladder has produced.

It does not close timing, and that is the honest state of this rung. Setup is
short in five domains, worst the `emu` clock (67.03 MHz) at **-19.413 ns** with
-96.4 us of TNS; `FPGA_CLK1_50` is -14.203, `FPGA_CLK2_50` -11.573, `h2f_user0_clk`
(100 MHz) -8.310 and the 148.54 MHz HDMI clock -7.973, all short as well. Hold is
reported at -53.667 ns on the 24.58 MHz audio clock, which is too large to be a
real hold violation at that period: that number means unrelated clocks are being
analysed together, and it needs its own investigation before it is trusted in
either direction. Recovery is -1.700 on `emu`; removal and minimum pulse width
are clean.

No earlier rung produced a timing report, so none of this is a known regression
-- it is simply the first measurement of the design's timing at all, and it says
the next problem is closing timing on a 99.7%-full device, not finding more LABs.

The guards are also inert where it counts. Mapped with no macro defined, the
design produces 83,296 ALUTs, 58,325 ALMs, 53,805 registers, 96 DSP blocks and
53 warnings -- identical to the baseline recorded before these switches existed,
so the three guards change nothing about the shipped build.

One trap, because it cost two runs here: several macros in a single
`--verilog_macro` value, or in one `set_global_assignment -name VERILOG_MACRO`
line, apply only the **first** one and silently drop the rest. The build then
looks untouched and the rung measures nothing. One assignment per macro.

So the 3D pipeline is worth **4,164 ALMs, 5,150 ALUTs, 7,256 registers and 22
DSP blocks**, and the cheat engine plus the SPU together are worth **5,793 ALMs,
7,897 ALUTs and 7,697 registers**. Both are less than the standalone-ALUT projections this file
carried before, because mapping the whole design shares logic that mapping a
block alone counts twice: the real conversion is 1.24 nodes per ALM for the 3D
cut and 1.36 for cheat plus SPU, not the 1.42 the renderer probe suggested.
Item-level numbers in the ranked list are therefore upper bounds, useful for
ordering work and not for promising savings.

That leaves the merged renderer as the last lossless lever, ~8,550 ALUTs (~6,030
ALMs by the probe's ratio). On top of the lean build that is **~42,400 ALMs,
101%** — about 500 ALMs over. Measured, no combination of the four cuts fits: a
fit also needs one more item of roughly 1,000 ALMs (an OSD, the scanline filter
or the shadowmask) *and* the merged renderer, which is the one item that
currently fails the line budget at 109%.

So a fit remains a scope decision, not a setting. 3D, cheats and sound are each
worth having, and all three together are still not enough on their own.

## Where the 141,879 ALUTs were

Core (`emu`, 124,519) and framework (17,360):

| block | ALUTs | of which / notes | DSP |
|---|---|---|---|
| geometry_engine | 22,433 | 15,577 in 92 LUT multiplier leaves, 6,856 in logic | 106 |
| arm9_core | 20,154 | 18,012 self | 3 |
| main_bus | 16,167 | sys_io 14,862 → math_unit 12,257, spi 1,215, rtc 482, timers 553 | — |
| engine_a (renderer_2d) | 13,520 | 3,342 is the line-buffer read mux | — |
| arm7_core | 11,307 | 10,192 self | 3 |
| engine_b (renderer_2d) | 10,076 | 3,342 is the line-buffer read mux | — |
| cheat_engine | 8,721 | 4,813 is the 32-entry walk | — |
| screen_composer | 5,309 | | — |
| spu | 5,157 | ~1.1k in LUT multiplier leaves | 8 |
| cart_slot | 3,605 | save_spi 296, save_probe 183 | — |
| raster_engine | 3,021 | | 8 |
| dma / hps_io / rest | ~4,700 | 32 blocks under 400 each | — |
| *framework* ascal | 8,344 | 4,864 in scaler leaves (16 lpm_mult) | — |
| *framework* audio_out + alsa | 2,855 | | — |
| *framework* osd ×2, yc, vga, pll, shadowmask, misc | ~6,160 | | — |

Two thirds of the core is five blocks: geometry, the two CPUs, the bus/IO and
the two renderers.

## Measured cost of each candidate rewrite

Each number comes from mapping the primitive alone as the top level on the same
device, so it is an ALUT count, not an estimate:

| probe | ALUTs | regs | BRAM | DSP |
|---|---|---|---|---|
| 64-bit iterative divider (one 65-bit subtractor) | **149** | 328 | 0 | 0 |
| one 32×32→64 multiply, DSPs available | **46** | 0 | 0 | 3 |
| the same multiply in LUTs (as built, DSPs exhausted) | 271 | 0 | 0 | 0 |
| renderer line buffer as built (2×128×42 flops + bank mux) | **3,342** | 10,752 | 0 | 0 |
| the same buffer as one 256×42 dual-port M10K | **0** | 0 | 10,752 | 0 |
| cheat walk, 32 entries in one cycle | **4,813** | — | — | — |
| cheat walk, 8 entries per cycle | **1,188** | — | — | — |
| `geometry_engine` before item 1 (whole module) | 22,433 | — | 0 | 106 |
| `geometry_engine` after item 1 (whole module) | **4,319** | 6,980 | 1,024 | 6 |
| the same module with its MTX_SCALE/MTX_TRANS adds widened | 5,732 | 6,590 | 1,024 | 6 |

## Ranked trims

**1. Serialise the geometry engine's composite matrix — done: 18,114 ALUTs, 100 DSP measured.**
(15,577 sat in the multiplier leaves; the replacement multiplier and its FSM take
about 180 back.)
`comp[0:15]` is 16 outputs × 4 products, evaluated combinationally, and the
viewport transform adds 8 more: 72 multiplies of 32×32 in one clock. Each costs
3 DSPs (216 for all of them) against 112 available, so 37 of them landed in LUTs
at 271 ALUTs each. One time-multiplexed multiplier is 46 ALUTs and 3 DSPs, and
the 16 accumulators go to a 16×64-bit BRAM. *Accuracy: none lost* — same integer
widths, same 4.12 truncation, same results. Throughput falls from 1
vertex/clock to 10 clocks: 6.7 M vertices/s against the 369 k/s that 6144
vertices at 60 Hz needs.

Measured after the rewrite, mapped alone on the same device: `geometry_engine`
**22,433 → 4,319 ALUTs and 106 → 6 DSP**. The 24 combinational 32×32 multiplies
of MTX_SCALE and MTX_TRANS were another 48 DSPs — they were only free in ALUTs
because the DSPs they sat in were already spoken for — so they went through the
same multiplier too rather than being left as the last over-budget block. The
units are now: one 64×32 multiplier (6 DSP blocks, wide enough to keep the
composite's 64-bit 4.12 values exact), a 64-clock composite rebuild, 10 clocks
per vertex, 12 for MTX_SCALE and 9 for MTX_TRANS. The matrix registers are
written in exactly one place, which is why the two matrix commands stage their
results in `mres[]` and the command FSM commits them.

At design level that is **126,275 → 110,011 combinational ALUTs (−16,264) and
124 → 96 DSP blocks** — the first build where the DSP budget is met, with 16
blocks spare.

**2. One iterative divider in the maths unit — ≈11,200 ALUTs.**
`math_unit` relies on `/` and `%` over 64-bit and 32-bit signed operands, which
infers four combinational dividers: Div0 4,485, Mod0 4,570, Div1 1,220,
Mod1 1,257. A single restoring divider of 64 steps costs 149 ALUTs (the
unsigned core; the sign handling the unit needs adds roughly 150 more) and
produces both quotient and remainder from the same loop, so the modulo
instances are not needed at all. *Accuracy: none lost*, and the visible timing
does not change —
the module already gates the result behind a 34/66-cycle busy window, which a
32/64-step divider fits inside.

**3. Line buffers into block RAM — done: 3,218 ALUTs and 8,738 registers per
renderer, measured.**
Both renderers used to hold `buf_a`/`buf_b` as 2×128×42 flops with a bank mux on
the read path: 3,342 ALUTs each, measured. A 256×42 dual-port M10K is 0 ALUTs and 0
registers, and only ~4 of the 372 spare M10Ks. *Accuracy: none lost*; the read
becomes registered, which costs one pixel-CE of latency on the composer
contract. This also matters because registers are at 82%: it takes the design
to 56%. As built the word is 68 bits rather than 84 (the display only reads
`{opaque, rgb}` of each pixel), so the array is 128 x 68 = 8,704 bits -- exactly
what the pair form held as 256 x 34; the working bank
stays in registers because its read-modify-write must land in the write cycle.

**4. Cheat walk, 32 entries → 8 per cycle — 3,625 ALUTs.**
The walk is a 32-deep combinational chain (entry j's guard update feeds entry
j+1), which is 4,813 ALUTs and probably also the worst timing path in the
design. Walking 8 entries per clock over four clocks is 1,188. *Accuracy:
capacity unchanged* — still 32 codes, still evaluated in list order, guards
still persist. Cost: the check must start ~3 cycles before `S_CPATCH`; the bus
already knows the address at `S_REQ`, so this is a scheduling change, not a
protocol change.

Subtotal of the four above: **≈36,900 ALUTs measured, no accuracy loss.**
141,879 → 105,000. Still 21,180 over the limit.

**5. Serialise the SPU mixer — done: 90 ALUTs measured, and the 1,176 the earlier
estimate rested on was an artefact.**
The mixer summed sixteen channels in one tree, costed at "1,176 ALUTs (4,188 →
3,012 with the tree stubbed out)". Stubbing the sum to zero constant-folds
everything downstream of it — master volume, OSD volume, the clamp — so that
1,176 measured the whole mix path, not the tree. Mapping the same source twice,
once with the tree and once with one channel per clock, gives **4,188 → 4,098
ALUTs and 4,717 → 4,767 registers, 8 DSP either way**: the tree's fifteen 22-bit
adds are worth ~90, because the serial version pays most of it back in the 16:1
mux on `c_l`/`c_r`.

The pass is still the right shape: sixteen of the ~1,396 clocks between two
48 kHz samples, and it takes the sixteen-way fanout off the master-volume
multiply's input. *Accuracy: none* — same accumulation order (channel 0 first),
same 22-bit width, same sign extension, so `tb_spu` is bit-identical. The one
thing it needs is the service engine holding a channel's new sample while
`mx_st == MX_SCAN`, or a value written mid-pass would be summed at a different
instant from its neighbours.

*Lesson, same as item 6:* a "stub it out" measurement includes everything the
stub lets the tools constant-fold away.

**6. Per-row rotation/layout remap in the composer — measured: nothing to gain.**
The estimate here said ~2,000 ALUTs. Mapping `screen_composer` alone on the same
device gives **73 ALUTs, 0 registers, 3 DSP** (97 ALUTs in context, the 3 DSP
being the brightness multiplies), so there is no 2,000 to find: the layout case
is one 8-bit subtract plus two range compares, `sy`/`box_hit`/the `use_top` base
are already shared by the whole pixel datapath, and the rotation remap is two
subtracts and two 4:1 byte muxes. Registering the row terms would also put the
first pixel of every line one cycle behind the engines, because the engines
sample `na_x`/`na_y` combinationally through their line-buffer RAM.

*Lesson for the rest of this list:* every remaining number in it is an estimate,
and this one was 25× high. Measure a block before planning work on it.

**7. One 2D renderer shared by both engines — measured: does not fit the line
budget, so not landed.** The saving is real: the two instances are 9,255 and
9,211 ALUTs, so one copy plus the second register bank and the port steering
(the palette, OAM and VRAM ports have to be pointed at the engine that owns
the renderer, and both front line-buffer banks must stay readable at once)
comes to ~9,900 — about **8,550 ALUTs, 6,030 ALMs**, taking the design to
~52,760 ALMs, still **126%** of the A6's 41,910. What rules it out is the
line budget, not the area.

The budget arithmetic, all measured rather than estimated:

| | clocks |
|---|---|
| line period, native refresh (330 x 5 pixel CEs, 679 lines, 67.0274 MHz) | **1,650** |
| engine A's line: BG 425 + OBJ 330 + 3D merge 284 (`tb_renderer_2d`) | **1,039** (63%) |
| engine B's line: the same minus the merge | **755** (46%) |
| both lines through one renderer | **1,794 = 109%** |

Serialising the two engines pools 1,794 clocks of work into a 1,650-clock
period, so the fetcher misses its swap on every line that has a sprite on it
and each screen keeps showing the previous line. The renderer's own design
budget is 1,280 (the figure its benches check against), which the pool
overruns by 140%. The old note here said "~644 clocks against 1,280 ... it
fits but the margin is gone": 644 was the pre-burst cost of a BG phase alone,
not a line, and it is 1,039 once the OBJ pass and the merge are counted.

Nothing cheap closes the 144-clock gap. The OAM walk is 258 of everything,
per engine: it is already one OAM address per clock over a two-clock
pipeline, and interleaving A and B entries through one walk still costs 512
for both (the ports are separate BRAMs but the walk is serial), so pooling
buys nothing there. The BG phase is 34 grants a line and is dominated by the
grant latency, not the beats. What would pay is fetching a tile row once per
8-line tile-row band and compositing 8 lines from a cache — a BG fetch
redesign, and 16 KB of tile cache per engine at 4 bpp — i.e. a project of its
own, and worth more to the *current* two-renderer design than to a merged one.

So item 7 stays unimplemented on purpose: it costs 109% line occupancy for
8,550 ALUTs that still do not produce a fit. `tb_renderer_2d` (1,039 clocks),
`tb_composer` and `tb_3d_path` are green on the two-renderer design as it
stands.

### The tile-row cache, built and measured (reverted)

The obvious way to buy the line budget back is to stop fetching a tile row per
column per line. A 4bpp tile is eight halfwords of contiguous VRAM (four tile
rows) and an 8bpp tile is 16 (two rows, and eight halfwords is half a tile), so
the fetch can ask for eight halfwords once and serve the next three lines
(4bpp) or the next line (8bpp) out of block RAM. That was built: a per-column
entry of eight halfwords keyed by tile-row group and band, refilled by the
existing per-column burst (widened to eight), read out one clock behind its
address so Quartus sees a block RAM, staged into the tile buffer beside the
composite, and dropped whenever a BGxCNT/HOFS/VOFS write moves the tiles.

It works, and it is not worth having. Measured in `tb_renderer_2d`, 4bpp with
one BG layer, two sprites and the 3D merge. The `before` rows are the design as it stands; the refill and cached rows were measured before the state fold and the quad fill landed, so they are a snapshot from that tree rather than a re-run against it:

| line | clocks | BG | grants | beats |
|---|---|---|---|---|
| before (a row burst per column) | 1,039 | 425 | 35 | 100 |
| band refill (first line of the group) | **1,388** | 759 | 35 | 292 |
| cached (rest of the group) | **1,191** | 562 | **3** | **36** |
| 8bpp 64-wide, before | 512 | 512 | 34 | 192 |
| 8bpp 64-wide, refill | 767 | 767 | 34 | 320 |
| 8bpp 64-wide, cached | 574 | 574 | 2 | 64 |

Grants fall by an order of magnitude and beats by two thirds, and the line is
still not faster: 1,191 against 1,039. The reason is that the fetch was never
the cost. A column's row burst is a grant latency plus two beats, about twelve
clocks, and it streams *while* the column's eight pixels composite — the
prefetch hides all of it. What bounds the BG phase is the composite itself
(eight clocks) plus roughly six clocks of per-column state overhead, so a
column costs 17 clocks whatever the data comes from. The cache cannot shorten
the composite, and its refill — 18 clocks a column, eight beats against eight
pixels — is the one thing that no longer fits behind it.

Averaged over a group the change is a small loss, and it puts the worst line
over the 1,280 budget rather than under it: 4bpp is (1,388 + 3 x 1,191) / 4 =
**1,240** against 1,039, 8bpp is (767 + 574) / 2 = **670** against 512. So it
was reverted; `renderer_2d` and `tb_renderer_2d` are back at the committed
state (1,039 clocks, 35 grants, 100 beats; 8bpp 512).

What the measurement changes: the fetch is not the lever, the composite and its
per-column overhead are. 33 columns x ~6 overhead clocks is ~200 clocks a line
of pure state transitions (S_PF_WAIT, S_COL_CHK, S_PXC_GO), which is worth more
than any fetch rework and is lossless. That is now done: `S_COL_CHK` and
`S_PXC_GO` are gone, both jobs riding on the cycle that already advances the
column -- the bank check there, and the next column's fetch too, a clock
earlier than the state it replaced -- and the wait is skipped when the burst
has landed. It measures one clock a column, not three: 63 clocks off the BG
walk (567 -> 504, the line 1,196 -> 1,133). The backdrop fill then went from a
pair a clock to a quad a clock, another 64: BG 504 -> 440, the line
1,133 -> 1,069. Both palette-bank fills then stopped paying a handshake per
entry -- one address a clock, data two clocks behind, 17 clocks a fill instead
of 32 -- for another 30: BG 440 -> 425, the OBJ pass 345 -> 330, the line
1,069 -> 1,039. And it sets the floor for item 7: even a
free BG fetch leaves ~375 clocks of BG phase, so two engines still need ~1,700
clocks of the 1,650-clock line.

**8. Single-pass scaler in the framework — ~4,000 ALUTs** (estimate).
`ascal` is 8,344 with 4,864 in scaler leaves. Nearest/integer scaling instead of
the polyphase path is a visible quality loss on HDMI. *Accuracy: softens or
blocks the upscale.*

**9. CPU datapath sharing — ~2,000 ALUTs** (estimate, high risk).
18,012 + 10,192 ALUTs of decode, shifter and ALU. Sharing the barrel shifter and
address adder across states is the only real saving and it must keep `tb_arm7`
and `tb_arm9` green. Not worth doing before the items above.

**10. Registers → BRAM in cart_slot — done: 2,452 ALUTs and 6,150 registers,\nmeasured.** (The estimate was ~1,500 ALUTs; it was low.)
`cart_slot`'s download FIFO was three register arrays — 64 x 64-bit data,
64 x 29-bit line, 64 x 8-bit byte enables, 6,464 flops — written once and read
once in order, which is exactly a simple dual-port RAM. They are now one
64 x 101-bit array (`{be, line, data}`) in one M10K, with the drain fetching the
head entry and issuing it on the next cycle to absorb the registered read.
Measured at design level: `cart_slot` **3,590 → 1,138 ALUTs, 7,640 → 1,490
registers**, block RAM +7,488 bits, and the design **85,696 → 83,303 ALUTs,
60,181 → 54,032 registers, 62,271 → 58,791 ALMs**. `tb_cart_slot` 62/62 (tail
flush, byte enables, hold-across-BUSY), `tb_ddr_bridge` and `tb_main_bus` green.

This is the first time the design has been *under* the 83,820-node limit at the
mapper (83,303), so the fitter got past the `170011` check that killed every
earlier build and ran placement for 26:46. It then failed on the wall that
matters, in its own words:

```
Error (170012): Fitter requires 5877 LABs to implement the design, but the
                device contains only 4191 LABs
Error (11802):  Can't fit design in device.
```

A LAB is ten ALMs, so that is 58,770 against 41,910 (140%), matching the
mapper. The gap is **1,686 LABs**, about **24,000 combinational ALUTs** — not
the 2,002 nodes the node check used to complain about. Placement cannot close
it, which is why the error now names the LAB count instead.

### Where items 5-10 actually stand (measured, not estimated)

| item | state | measured effect |
|---|---|---|
| 5. serialise the SPU mixer | **in** | 4,188 → 4,098 ALUTs, `tb_spu` bit-identical |
| 6. per-row composer remap | **measured: nothing to gain** | the module is 73 ALUTs standalone |
| 7. one 2D renderer for both engines | **rejected on measurement** | worth ~8,550 ALUTs (~6,030 ALMs), but the two lines need 1,794 clocks in a 1,650-clock period (109%) — the picture, not the area, is what fails |
| 8. single-pass framework scaler | **not done** | `ascal` is **2,883** ALUTs in context (the 8,344 in the old estimate is stale), so the ceiling is ~2,800 and it costs upscale quality |
| 9. CPU datapath sharing | **not done** | arm9 18,732 + arm7 10,448 ALUTs; only the shifter/adder can be shared, ~2,000 at high risk to two green benches |
| 10. cart FIFO into block RAM | **in** | 2,452 ALUTs and 6,150 registers |

The arithmetic after 5, 6 and 10: at 57,993 ALMs the design needs **16,083
ALMs (about 23,000 ALUTs) removed** to fit. Items 7, 8 and 9 together are worth
at most ~14,000 ALUTs (~9,700 ALMs) on these measured numbers, and 8 and 9 buy
that with visible quality loss and heavy surgery. Even all three leave the
design around 48,000 ALMs — 115% — so **items 5-10 cannot deliver a fit**. What
can is dropping the 3D pipeline (geometry 4,147 + rasteriser + the merge pass)
together with item 7, or a larger device.

## What the arithmetic says

| set | saving | ALUTs | vs limit |
|---|---|---|---|
| original | — | 141,879 | 1.69× |
| after 2 and 4 (measured) | 14,825 | 127,000 | 1.51× |
| after 1 too (measured: 126,275 → 110,011) | 31,900 | 110,011 | 1.31× |
| 1–4 (measured, no accuracy loss) | 36,900 | 105,000 | 1.25× |
| + 5–7 | 45,400 | 96,500 | 1.15× |
| + 8–10 | 52,900 | 89,000 | 1.06× |
| + capability cuts (~4,850: 3D merge pass, one OSD, scanlines,
shadowmask, cheat entries 32→8) | 57,750 | 84,120 | 1.004× |

So taking *every* item, including the ones that cost accuracy, still leaves the
design about 300 ALUTs over. That is not a fit: the fitter duplicates logic,
inserts buffers and needs room to route, and every later fix spends pipeline
registers out of the same 83,820. A build with a sane 10% margin has a ceiling
of ~75,000, and table stakes for the lossless items alone is ~105,000.

The honest conclusion: **the A6 cannot host this core at full feature set.**
The gap is structural, not a matter of tightening a few blocks. After item 1 the
3D path is no longer the largest thing in the design — 4,025 ALUTs of geometry
(4,319 standalone) plus 948 of rasteriser — and what remains around it, the two
CPUs, the bus and the two renderers, is still over the limit on its own.

The "what does fit" rows below are from the pre-item-1 baseline; item 1 moved
every one of them down by about 18,000.

What does fit, with margin:

| build | how | ALUTs | margin |
|---|---|---|---|
| 2D DS core | drop geometry + raster, then items 2,3,4,5,6,9,10 and 7 | 82,900 | 1.1% |
| 2D DS core, lean | the same without the shared renderer | 88,400 | does not fit |

Item 7 is out (see above: the shared renderer needs 128% of the line period), so
the *only* projected build that fit — the 2D core with the merge — is not
buildable. The same build with two renderers is the 88,400 row: no fit, and the
measured design is **83,296 ALUTs / 58,325 ALMs** today (the table at the top),
so what the A6 actually
needs before any of this is about 24,000 ALUTs of things this list does not
contain.

That is: a DS core with the two ARM cores, both 2D engines, sound, cart and
save support would fit the A6 once the four lossless items are taken *and* the
3D pipeline is gone *and* the renderers could be merged — and the last of those
is measurably not possible at 59.83 Hz. Keeping 3D needs either a bigger device
(the DE10-Nano's A6 is the top of that part) or a much slower 3D implementation
that shares the rasteriser's datapath with the 2D engine.

Items 1–4 are worth doing regardless of that decision: 36.9k of measured,
lossless saving, and item 1 clears the DSP overrun that makes the fit fail a
second time — measured, that overrun is gone (96 of 112 blocks used), because
the engine's last 24 combinational multiplies went through the same unit.

Reproduce the probes with `quartus_map` on `5CSEBA6U23I7`, one module as top
level at a time; the design itself must be mapped from a path outside OneDrive
(`/tmp/ndsfull`) because the fitter cannot create `incremental_db` there.

## What is actually in the tree

| item | state | measured |
|---|---|---|
| 2. iterative divider | **in**, `tb_sys_io` 53/53 and `tb_main_bus` green | `math_unit` 12,257 → 1,388 ALUTs standalone |
| 4. cheat walk 32 → 8 per clock | **in**, `tb_cheat_engine` and `tb_main_bus` green | `cheat_engine` 8,721 → 2,098 ALUTs standalone |
| 3. line buffers into block RAM | **in**, `tb_renderer_2d`, `tb_composer` and `tb_3d_path` green | `renderer_2d` 3,218 ALUTs and 8,738 registers less than the same source with the array in logic, 8,704 BRAM bits |
| 1. serialised matrix multiply | **in**, `tb_geometry_engine` and `tb_3d_path` green | `geometry_engine` 22,433 → 4,319 ALUTs (4,025 in context), 106 → 6 DSP |
| 5. SPU mixer serialised | **in**, `tb_spu` green, bit-identical samples | `spu` 4,188 → 4,098 ALUTs standalone (90, not the ~1,000 estimated); 16 of ~1,396 clocks per 48 kHz sample |
| 10. cart FIFO into block RAM | **in**, `tb_cart_slot` 62/62, `tb_ddr_bridge` and `tb_main_bus` green | `cart_slot` 3,590 → 1,138 ALUTs and 7,640 → 1,490 registers; design −2,393 ALUTs, −6,149 registers |

## Measured on a full compile

`quartus_sh --flow compile NDS` on `5CSEBA6U23I7`, after the divider and cheat
walk landed (`output_files/NDS.map.rpt`, `NDS.fit.rpt`):

| | result | device | use |
|---|---|---|---|
| Analysis & synthesis | 0 errors, 80 warnings | | |
| Combinational ALUTs for logic | 126,448 | 83,820 | **151%** |
| ALMs needed | 88,973 | 41,910 | **212%** |
| Dedicated logic registers | 68,682 | 83,820 | 82% |
| Block memory bits (M10K) | 1,849,332 (246 of 553) | 5,662,720 | 33% |
| DSP blocks | 112 | 112 | **100%** |

The two trims that landed took combinational ALUTs from 141,879 to 126,448 —
15,431 saved, which matches the 11,200 + 3,625 the probes predicted. The fitter
then rejects the device outright:

```
Error (170011): Design contains 126448 blocks of type combinational node.
                However, the device contains only 83820 blocks.
Error (11802):  Can't fit design in device.
```

The A6 has 41,910 ALMs (83,820 combinational nodes, not 83,820 ALMs — that is
where the "2.1x over" and "1.5x over" differ). DSPs are already saturated at
112/112, so item 1 is not just an area trim: every further multiply that lands
in LUTs costs 271 ALUTs. Timing analysis never runs, because placement aborts
before the timing analyzer, so there is no Fmax to report from this build.

## After item 1 (mapped, `quartus_map`, same device and settings)

| | before | after | device | use |
|---|---|---|---|---|
| Combinational ALUTs for logic | 126,275 | **110,011** | 83,820 | **131%** |
| DSP blocks | 124 | **96** | 112 | **86%** |
| Dedicated logic registers | 68,809 | 69,183 | 83,820 | 83% |
| Block memory bits (M10K) | 1,849,281 | 1,850,305 | 5,662,720 | 33% |
| Analysis & synthesis | 0 errors, 80 warnings | 0 errors, 81 design warnings | | |

The extra warning is the one the new inferred RAM earns: `comp[]` is now a
16×64 block RAM rather than 1,024 combinational nodes, so it carries the same
`WINFER_RAM_PASS_THROUGH_LOGIC_INSERTED` note as the other nine inferred RAMs.
No new width, index or multiple-driver warnings: the design maps clean.

The 3D engine's throughput after serialisation: a vertex is 10 clocks (6.7 M/s
against 369 k/s needed), a composite rebuild 64 clocks whenever a matrix
command changed either matrix (measured on the next vertex, not on the command),
MTX_SCALE 12 clocks and MTX_TRANS 9. All of that sits inside GXSTAT's busy
window, which now covers the pipeline, so a game polling `GXSTAT.27`/bit 0 sees
the engine busy exactly as long as it is.

## Full compile after item 3

`quartus_sh --flow compile NDS` on `5CSEBA6U23I7`, run from `/tmp/ndsfull` (the
fitter cannot create `incremental_db` under OneDrive), 43:30 wall time, peak
virtual memory 4.6 GB:

| | result | device | use |
|---|---|---|---|
| Analysis & synthesis | 0 errors, 100 warnings | | |
| Combinational ALUTs for logic | **83,997** | 83,820 | **100.2%** |
| Dedicated logic registers (synth) | 59,318 | 83,820 | 71% |
| Block memory bits (M10K) | 1,866,740 | 5,662,720 | 33% |
| DSP blocks | 96 | 112 | 86% |
| Fitter | failed: 84,123 combinational nodes | 83,820 | **100.4%** |
| Fitter ALM estimate | 58,131 | 41,910 | 139% |

That is **303 combinational nodes** from fitting, against 58,059 over for the
first full compile, 42,628 after items 2 and 4, and 26,191 after item 1 alone. The fitter still stops
before placement (`Error 170011`, then `11802`), and its own ALM count is the
pessimistic reading of the same design: an ALM holds two 4-input LUTs only when
they share inputs, so 84,123 nodes that pack badly look like 58,131 ALMs. No
placement means no routing, no timing analysis and no Fmax report from this
build.

### Why 303 nodes is not the gap

The node count and the ALM count are not the same wall, and the fitter quotes
both: `84,123` combinational nodes against `83,820`, and **58,131 ALMs against
41,910 (139%)**. The second number is the one that decides it.

An ALM holds two 4-input LUTs and reports two dedicated registers, so the
capacity is 41,910 ALMs = 83,820 nodes = 83,820 registers. The design uses
83,997 nodes and 59,318 registers. With *perfect* co-location — every register
in the same ALM as the LUT that drives it — that needs
`max(83,997/2, 59,318/2) = 41,999` ALMs, which is 89 ALMs (0.2%) over. So 303
nodes is the gap only in the best case, and the fitter's 139% says the placer is
not going to reach it: at the packing ratio it quotes (1.45 nodes/ALM against
1.5 for a perfectly packed ALM) the design needs roughly 60,000-65,000 nodes to
fit, i.e. **20,000 nodes / about a quarter of the logic**, not 0.4%.

That is the sum the ranked list below adds up to, and it is why the next step is
items 5-10 rather than another few hundred nodes: registers already occupy 71%
of the device on their own, so there is no LUT headroom left to spend.

Most of the 110,011 → 83,997 drop is not item 3: the line-buffer trim measures
6,436 ALUTs across the two renderers (3,218 each, A/B above). The rest came from
the burst-fetch and OAM-scan work that landed between the two builds. Registers
fell 69,183 → 59,318, of which 2 × 8,738 belongs to item 3.

There are no warnings on `lbuf`: the RAM infers cleanly, 8,704 bits per
renderer (128 words x 68 bits, four pixels of `{opaque, rgb}` each). Quartus
17.0 maps it as a Simple Dual Port RAM, 128 x 68, with no Info 276009, and the
fitter spends **two M10K blocks** on it (20,480 implementation bits). The pair
form of the same buffer (256 x 34) took **one** (10,240 bits), so the quad word
that halved the backdrop fill costs one extra M10K per renderer -- four of the
553 for both. The lane select on the read path is all the logic it adds. The
`Total RAM Blocks 0 / 553` row in `NDS.fit.summary` is an artefact of the
aborted placement, not a memory total; the bit count above is the reliable
figure (33%, ~183 block-equivalents of the 553). There are no critical warnings any
more: the two `Critical Warning (127005)` lines that used to appear here were the
SPU MIF depth notes, fixed by padding those tables to the depth the synthesiser
builds.

Item 3 first went in as a *single* write-through shadow and came back out: the
shadow only answers a completed line, while the composite pass for line y+1
runs across the whole of line y, so every line after the first came out as
backdrop. The fix is the second display bank the estimate above called for —
the display reads the finished line from one bank while the composite builds
the next in the other — and it is now in:

| | `ramstyle = "logic"` | in block RAM |
|---|---|---|
| `renderer_2d` combinational ALUTs | 12,820 | **9,602** |
| `renderer_2d` dedicated registers | 16,811 | **8,073** |
| `renderer_2d` block memory bits | 0 | **8,704** (128 × 68 = 256 × 34), 2 M10K |
| `tb_renderer_2d` | PASS | PASS (line fetch 1,039 clocks) |
| `tb_composer`, `tb_3d_path` | PASS | PASS |

Both columns are the same source mapped twice (the second with `ramstyle =
"logic"` on `lbuf`), so the difference is the trim itself: **3,218 ALUTs and
8,738 registers for one renderer**, against the 3,342 / 10,752 the probe
predicted for the buffer plus its bank mux. Two renderers is ~6,400 ALUTs.

Three things had to be got right beyond deciding where the array lives:

* The composite writes into `~front_is_a` and that alone — not into
  `~(front_is_a ^ swap)`. The swap pulse lasts the single cycle before the
  front flop moves, which is fine for the read address but pointed the *write*
  at the bank about to be displayed and split a fill across both banks.
* The mirror address is `{bank, x[7:1]}`, seven bits of pair. An eight-bit
  slice (`x[8:1]`) concatenates to 256 + pair, past the end of a 256-entry
  array; every back-bank write was dropped and only the front bank ever got
  pixels.
* Inference needs the whole memory in one process: the display read first and
  a *single* write statement last, fed by enable/address/data registers that
  the fill and the composite both set. Split across two processes, or with two
  write sites in one process, Quartus reports Info 276009 ("unsupported
read-during-write behavior") and builds 10,752 registers instead. The word
is 68 bits wide, not 84: only `{opaque, rgb}` of each pixel is ever read back,
so the kind/priority bits are dropped rather than stored.

The working bank (`wbank`) stays in registers: its read-modify-write must land
in the same cycle as the write, which a simple dual-port cannot do. That is the
5,376 registers still there.

## The BIOS SWI bank (`swi_hle`)

`swi_hle` is new logic, not a trim, so it is worth pricing: mapped alone as
top level (`quartus_map`, `5CSEBA6U23I7`, family defaults), it is **1,214
combinational ALUTs and 788 registers**, no memory bits and no DSP. In the
design there are two of them, one per core, and they cost more there than
alone because of the muxing onto each core's own master: **1,397 + 1,387 =
2,784 combinational ALUTs and 1,574 registers** (the per-entity table in
`NDS.map.rpt`). Neither instance raises a synthesis warning.

Where it goes: the byte-lane generator and the variable shift in BIT_UNPACK
and RL are one 32-bit shifter; Div/Sqrt share a 32-bit subtract-compare adder
and the 22-bit count; CpuSet/CpuFastSet reuse the same address incrementer as
the LZ77/RL copy loops. Nothing here is a table — the LZ77/RL windows live in
memory, not in flops — so there is no cheap second trim: the shifter is the
only candidate (it is the largest single piece, shared by three calls), and
removing it would cost bit-packed BIOS formats that games do use. If the fit margin disappears, this module is the first
thing to look at with `quartus_map` before touching the renderers again.

## Full compile with the BIOS SWI bank

`quartus_sh --flow compile NDS` on `5CSEBA6U23I7`, run from `/tmp/ndsfull` as
a clean build (no `db/`, no `incremental_db/`), 34:44 wall time, peak 3.3 GB
resident:

| | result | device | use |
|---|---|---|---|
| Analysis & synthesis | 0 errors, 150 warnings | | |
| Combinational ALUTs for logic | 87,111 | 83,820 | **104.0%** |
| ALMs needed (mapper) | 62,881 | 41,910 | **150%** |
| Dedicated logic registers (synth) | 60,816 | 83,820 | 73% |
| Block memory bits (M10K) | 1,865,716 | 5,662,720 | 33% |
| DSP blocks | 96 | 112 | 86% |
| Fitter | failed: **87,237** combinational nodes | 83,820 | **104.1%** |
| Fitter ALM count | 59,843 | 41,910 | **143%** |

The fitter stops at node-count legality, before placement:

```
Error (170011): Design contains 87237 blocks of type combinational node.
                However, the device contains only 83820 blocks.
Error (11802):  Can't fit design in device.
```

So the answer to "does the A6 still fit" is **no**, and it did not fit before
this change either — the previous recorded build was 84,123 nodes (303 over),
this one is 87,237 (3,417 over). The bank accounts for 2,784 of those nodes
(1,397 in `arm7_core`, 1,387 in `arm9_core`); the other ~630 come from the
muxes that put the engine's requests onto each core's bus master.

There is no timing report from this build, and no `NDS.rbf`: placement never
runs, so TimeQuest never runs. Any Fmax claim about this tree (including the
67.03 MHz core domain) is from an earlier, smaller design and does not cover
the added logic.

### Sharing the engine (landed)

`swi_share` now arbitrates one `swi_hle` between the two cores, and the two
per-core instances are gone. Mapped again with `quartus_map` (same device and
settings):

| | before | after | device | use |
|---|---|---|---|---|
| Combinational ALUTs for logic | 87,111 | **85,696** | 83,820 | **102.2%** |
| ALMs needed (mapper) | 62,881 | **62,271** | 41,910 | **149%** |
| Dedicated logic registers | 60,816 | **60,181** | 83,820 | 72% |
| Analysis & synthesis | 0 errors, 150 warnings | 0 errors, 86 warnings | | |
| Fitter (full `quartus_fit`, 21:40) | failed: 87,237 nodes | failed: **85,822** | 83,820 | **102.4%** |
| Fitter ALM count | 59,843 | **59,072** | 41,910 | **141%** |
| Fitter registers | 59,993 | **59,358** | 83,820 | 71% |

The two engines were 1,397 + 1,387 ALUTs and 1,574 registers; the shared bank
is 1,550 ALUTs (1,448 of them the engine, 102 the arbiter) and 793 registers.
Net: **1,415 ALUTs and 635 registers saved**, which is what the 2,784 → 1,550
per-entity diff predicts.

Still not a fit. The fitter reports **85,822 combinational nodes against
83,820 (102.4%)** and stops at node-count legality, so placement never starts,
TimeQuest never runs and there is no `NDS.rbf` — the same `170011` / `11802`
pair as before, only 2,002 nodes over instead of 3,417. Its own ALM count fell
59,843 → 59,072 (141%) and registers 59,993 → 59,358.

At 141% ALMs the honest gap is still the ~20,000 nodes the ranked list above
calls for: registers alone are 71% of the device, so node-count shaving does
not reach a fit until items 5-10 land. Nothing about a timing claim survives
this either — any Fmax figure for the 67.03 MHz core domain predates the HLE
work and does not cover it.

What the sharing cost, and why it is not free: the engine is started by a
pulse the arbiter generates, not by the caller's level, because two callers
can both be holding `go` when the engine changes hands and a muxed level would
never fall between them. `swi_hle` also dispatches on the rising edge of `go`
now, so a request that outlives its completion cannot re-run the call — the
per-core version relied on the core dropping `go` in the `done` cycle, which
is true but fragile. Both are covered by `tb_swi_share` (44 checks), and the
ARM7/ARM9 benches still pass unchanged (43 and 109 checks).
