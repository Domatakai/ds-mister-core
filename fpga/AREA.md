# Area budget: fitting the NDS core on the DE10-Nano's A6

Measured from a full compile of the tree as it stood on 2026-10-31
(`quartus_sh --flow compile NDS`, Quartus 17.0.0, device `5CSEBA6U23I7`, run
from `/tmp/ndsfull` because the fitter needs a path outside OneDrive), from
the `quartus_map` pass that precedes it, and from standalone `quartus_map`
probes of the candidate rewrites. Device capacities were read from a trivial
fit on the same part, not from a datasheet.

## The budgets at the 2026-10-31 baseline

| resource | used | device | headroom |
|---|---|---|---|
| ALMs needed (mapper) | 57,207 | 41,910 | **−15,297 (137%)** |
| ALMs used (fitter, last fit) | 58,065 | 41,910 | **−16,155 (139%)** |
| combinational nodes (ALUTs) | 82,280 | 83,820 | 1,540 (98.2%) |
| registers | 53,431 | 83,820 | 30,389 (64%) |
| DSP blocks | 96 | 112 | 16 (86%) |
| M10K bits | 1,877,683 | 5,662,720 | 3,785,037 (33%) |
| I/O pins | 143 | 314 | 171 (46%) |

These rows are the baseline this file was started from, when the design did
not fit; they are not the current state. The area fits now -- 38,881 ALMs and
4,157 of 4,191 LABs in the 2026-11-09 rebuild the last section records -- so
read the table above as where the cut ladder began and the rungs below as how
far it has come.

41,910 ALMs each give two combinational nodes and two registers, so the LUT and
register limits are the same 83,820. The node count is now *under* that limit —
82,280, 1,540 spare — so the mapper's `170011` check passes and the fitter
reaches placement. What it runs out of there is LABs: 57,207 ALMs is 5,721
LABs' worth against the device's 4,191, and the last full compile of this
configuration, made before the ARM9 read-port and decode changes, had its
fitter count 5,883 after placement. A LAB holds ten ALMs, so those are the same
statement, and the gap at the mapper's count is 15,297 ALMs — 27% of the
design.

Those mapper rows were re-measured on 2026-11-07 with no macros: 57,207 ALMs,
82,280 ALUTs, 53,431 registers, 1,877,683 memory bits and 143 pins. The numbers
they replace -- 58,325 / 83,296 / 53,805 / 1,873,331 / 145 -- predate the ARM9
read-port and decode changes, and the fitter row above is the last full fit of
the default configuration, which was made before either change.

That last compile stops at the fitter, in its own words:

```
Error (170012): Fitter requires 5883 LABs to implement the design, but the device contains only 4191 LABs
Error (11802): Can't fit design in device.
```

That is 26:26 into the flow and it comes after placement, so the number in it
is the fitter's own post-placement count, not a pre-flight estimate. The timing
analyzer still never runs: there is no Fmax for this build, only the mapper's
numbers above.

Nothing else is close to its budget. Pins are *not* a constraint and never
were: 143 of the 314 I/O the part exposes, 46%, so the periphery has 171 spare
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

Two further levers were measured and rejected.
`ALLOW_ANY_RAM_SIZE_FOR_RECOGNITION` and `ALLOW_ANY_ROM_SIZE_FOR_RECOGNITION`
both on map to **83,608 nodes and 58,539 ALMs** — worse than the area build by
363 nodes and 155 ALMs — so no small memory is hiding in this design. Switching
off the other two speed-only features,
`PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION` and
`ROUTER_LCELL_INSERTION_AND_LOGIC_DUPLICATION`, changes nothing that matters:
fitted on its own the design still needs **5,883 LABs**, exactly the count it
needs with them on, and placement preparation stretches from under 18 minutes
to 21:51. Neither setting is in the qsf.

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
SWI bank out (every BIOS call then vectors to the absent BIOS, so that rung is
a measurement only, never a product). Each row is one clean `quartus_map` on
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
own latency -- 5 clocks for the shadowmask, 3 for the scanline filter, 4 for
the VGA OSD -- so the picture keeps its alignment instead of shifting by a few
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
0, `scanlines:VGA_scanlines` from 21 to 0 and `osd:vga_osd` from 179 to 0,
while `osd:hdmi_osd` stays at 159 and `ascal` keeps every one of its logic
blocks, with only its mention count in the report moving (800 to 863) as the
hierarchy around it shifts. The warning count is 126 against t6's 124, and not
because anything was suppressed: `Warning (10036)` appears three times for
`io_osd_vga`, `shadowmask_data` and `shadowmask_wr` (assigned, never read, now
that their consumers are gone), and one `Warning (276027)` inferred-RAM notice
drops out.

At default settings the fitter places but does not route: peak interconnect
93.1% overall and 99.0% on the horizontal channels, `Warning (16684)` then
`Warning (16618)` with the routing phase terminated and `Critical Warning
(188026)` after 3h13m, and no bitstream. Eighteen free LABs were enough to
place and not enough to route.

The fitter's own remedy fixes it. With
`FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION Always` and `SEED 2`, placement
still clears the gate at 4,173 LABs, routing then completes in 01:20:34 and the
fit succeeds in 01:50:47 at **4,177 of 4,191 LABs** with peak interconnect
88.8% overall / 87.6% horizontal / 93.1% vertical -- `Quartus Prime Fitter was
successful. 0 errors, 20 warnings`. The assembler produces a 3,813,556-byte
`NDS.rbf` with 0 errors and 0 warnings: the first bitstream this ladder has
produced.

It does not close timing at these constraints, and that is the honest state of
that build; the section below measures what fixing the clock groups does to
those numbers. Setup is short in five domains, worst the `emu` clock (67.03
MHz) at **-19.413 ns** with -96.4 us of TNS; `FPGA_CLK1_50` is -14.203,
`FPGA_CLK2_50` -11.573, `h2f_user0_clk` (100 MHz) -8.310 and the 148.54 MHz
HDMI clock -7.973, all short as well. Hold is reported at -53.667 ns on the
24.58 MHz audio clock, which is too large to be a real hold violation at that
period: that number means unrelated clocks are being analysed together, and it
needs its own investigation before it is trusted in either direction. Recovery
is -1.700 on `emu`; removal and minimum pulse width are clean.

No earlier rung produced a timing report, so none of this is a known regression
-- it is simply the first measurement of the design's timing at all, and it
says the next problem is closing timing on a 99.7%-full device, not finding
more LABs.

The guards are also inert where it counts. Mapped with no macro defined, the
design produces 83,296 ALUTs, 58,325 ALMs, 53,805 registers, 96 DSP blocks and
53 warnings -- identical to the baseline recorded before these switches
existed, so the three guards change nothing about the shipped build.

### Decoupling the core's clock, measured (2026-11-01)

The framework SDC already decouples each PLL's `divclk` from the 50/100 MHz
clocks with `set_clock_groups -exclusive`, but its glob expected an instance
named `pll`; this core's is `emu|u_pll`, so its 67.03 MHz clock was left out
and TimeQuest timed about 120k HPS-bridge paths as synchronous -- 101,956
emu-to-`FPGA_CLK1_50` paths alone, while the other PLLs sat on "false path"
rows. `hps_io` runs on `clk_sys` and the bridge it talks to runs on
`FPGA_CLK2_50`, so the crossing is asynchronous by construction, which is why
the framework cuts it on its own side. Widening the glob to `*|*pll|pll_inst|`
makes the existing intent cover this core. Nothing else changed: same macros,
same seed 2, same aggressive routability.

| build | setup worst | setup TNS | hold worst | LABs | interconnect | fit |
|---|---|---|---|---|---|---|
| before | -19.413 (emu) | -96,426.996 | -53.667 (audio) | 4,177 | 88.8/87.6/93.1 | 01:50:47 |
| after (t11) | -8.339 (emu) | -45,936.820 | +0.203 (hdmi) | 4,160 | 84.2/83.1/91.3 | 00:45:25 |
| current | -8.325 (emu) | -53,336.764 | +0.238 (hdmi) | 4,138 | 83.0/82.3/89.7 | 00:53:59 |

Routing fell from 01:20:34 to 00:21:25 because the router no longer tries to
make unrelated clocks meet, the assembler still reports 0 errors and 0 warnings
and wrote a 3,718,564-byte `NDS.rbf`, and the fitter's warning count drops from
20 to 18. The `current` row is that build plus two measured changes: the save
file's load path, which costs 8 LABs and 0.816 ns on its own, and
`PLACEMENT_EFFORT_MULTIPLIER 4.0`, which gives back 9 LABs and 0.680 ns. That
build fitted at 4,159 of 4,191 LABs. The CRT video modes then cost 27 LABs and
0.039 ns -- four output timings in `video_timing` plus the 240p placements in
`screen_composer` -- so the tree now fits at **4,186 of 4,191 LABs**, 5 spare.
The Slot-2 RAM expansion pak built at **4,181 of 4,191 LABs**, 10 spare — five
fewer than the CRT tree, which is placement luck rather than a saving — with
setup at -8.354 ns (0.160 ns better), TNS -44,563.505, hold +0.226, peak
interconnect 86.8/85.9/91.6 and a 3,730,440-byte `NDS.rbf`.

Removing the adder from the pak address does not pay. The pak sits at
0xA00000, one 25-bit add above `{3'd0, a[22:1]}`; since 8 MB is exactly a
quarter of the chip's 16 MB, a base of 0xC00000 turns the address into the
concatenation `{1'b0, 2'b11, a[22:1]}`, ends the pak on the chip's last
halfword, 0xFFFFFF, and lets both SDRAM sequences share one high-halfword
mux. Three fitter seeds were tried against it and none placed tighter than
the adder. Seed 2 put it in 4,183 of 4,191 LABs and then abandoned routing on
congestion (`Error (16618)`, 02:22:07 of fitting, no successful final
attempt); seed 3 used 4,188 LABs and 31,789 registers, placed in 8:44 and
gave up routing in 8:28 (`Error (170143)`, 00:47:53 in total); seed 4 placed
in 17:24 and was still routing after 3 h 00, 928 CPU-minutes in, when the
sweep was stopped. At 99% LAB occupancy the adder costs less than the
placement noise -- the adder build was 4,181 -- so the adder stays and this
build is the one above.

### The firmware shadow's written flag fits in its own RAM (2026-11-06)

The SPI firmware shadow at 3FE00h/3FF00h kept the 512 bytes in one block RAM
and a separate `fw_written[511:0]` bitmap saying which of them had been
written since reset: 502 flip-flops in the netlist, plus the 512-way read mux
that selecting one bit of it needs. The flag is worth one bit -- the array is
9 bits wide, `{written, byte}`, so the bitmap rides in the block RAM the bytes
already occupy, and the mux goes with it.

| build | ALMs | registers | LABs | peak interconnect | setup worst | setup TNS | rbf | fit |
|---|---|---|---|---|---|---|---|---|
| pak tree | 39,729 | 31,179 | 4,181 | 86.8/85.9/91.6 | -8.354 | -44,563.505 | 3,730,440 | 00:50:53 |
| flag in the shadow RAM | 39,083 | 30,691 | **4,154** | 79.8/78.8/83.8 | -8.376 | -41,728.820 | 3,764,604 | 00:46:36 |

The map says the flag landed where it was meant to: registers fall 502 while
block memory bits rise by exactly 512, so the bit went into the block instead
of being rebuilt in logic. The saving is larger than 502 flops are worth on
their own, because the array's read mux goes with them, and it is real: 27
LABs is three times the +-9 LAB spread placement alone produces here. That is
the difference from the register-duplication experiment above, where 1,637
registers vanished and no LAB did: those duplicates shared ALMs the logic
already occupied, while these sat in register-only ALMs and dragged a 512-way
mux behind them.

Setup is 0.022 ns worse and TNS 2,835 better, hold improves to +0.251 and peak
interconnect falls from 86.8% to 79.8%: the tree now has 37 spare LABs where it
had 10. `tb_spi` and `tb_main_bus` pass unchanged. The first attempt failed the
bench for a reason worth keeping: with the flag in the array, an unwritten
entry's flag is whatever the RAM holds, and being initialised in hardware is
not being initialised in simulation, so the bench read X where the device reads
0. The array is now explicitly initialised to zero.

### Spending the spare LABs on the emu path did nothing measurable (2026-11-06)

The LABs the flag change freed invited an attempt at the domain that still
misses: emu setup is -8.376 ns against a 14.917 ns period. The worst twenty
setup paths in the fresh report are all one shape -- they start at a bit of
`arm9_core|regs` and end at the operand mux, 13 logic levels and 22.420 ns of
data delay, of which 11.846 ns (53%) is interconnect and 10.574 ns is cell
delay. It is the register file's read, not the 64-bit multiply the section
above blames.

`PHYSICAL_SYNTHESIS_EFFORT EXTRA` is the assignment that spends area to
shorten exactly such a path, and it was the one physical-synthesis knob not
already in `NDS.qsf` (retiming, combinational logic and asynchronous
pipelining are all on). Measured against the shipping build it changes
nothing: the same LAB count, the same slack and TNS, and a bitstream of the
same size -- the signature of an inert setting rather than a small win. It is
reverted.

The reason no setting helps is in the source: `rread()` is a function over a
plain 16x32 flop array and the core calls it at 47 sites, so every `regs` bit
fans out into 47 separate 16-way mux trees. Only a structural change -- one
shared read port, or a copy of the array per port -- reduces that; the first
is a large refactor of the state machine and the second costs far more than
the 37 spare LABs. Neither is a knob.

### The register-file read ports (2026-11-06)

The obvious repair was one shared read port. The core has none to share:
three sites read two different registers in the same cycle -- the Thumb
load/store register offset, the long multiply-accumulate pair and MUL's two
operands -- and LDRD/STRD (`Rd`, `Rd+1`), SMLALxy and the long multiply each
need four distinct registers in one cycle, so the smallest set that keeps one
instruction per cycle is four ports, not one.

All 47 read sites now go through four ports (`rp_a`..`rp_d`) and `rread` is
gone. Each port's index is decoded from `state` and `insn` alone, which is the
part that makes it work: the machine assigns its temporaries with blocking
assignments inside the clocked block, so an index written there would be read
a delta too late. The ARM side needed almost no branch tests -- Rn 19:16, Rm
3:0, Rs 11:8 and Rd 15:12 are every field an ARM read comes from, so those are
the defaults and only the halfword group's Rd+1 is an override. Thumb reads
three-bit fields and does need a table.

Measured against the same ten-macro map: `arm9_core` falls from 18,126 to
17,522 ALUTs and the design from 56,441 to 55,403, with the register count
unchanged at 2,471 -- nothing went dead, which a pinned-index experiment
would have hidden. That is 604 ALUTs of the 3,875 a pinned index releases:
the four 32-bit 16:1 muxes and their decode cost 3,271, so most of the
theoretical prize is the price of having ports at all rather than of having
eleven mux trees.

`tb_arm9` (109 checks), `tb_main_bus` and `tb_spi` pass, but they do not
cover every branch: checking the 48 sites against the decode caught a Thumb
format-4 ALU operand that had been left reading `Rd` twice, which `tb_arm9`
passes because its Thumb program never uses that form with two different
registers. That gap wants a directed test before the next change here.

Fitted for real, the tree lands at **4,143 of 4,191 LABs**, 48 spare: setup
-8.313 ns on `emu` (0.063 ns better than before the change), hold +0.250, a
3,718,564-byte `NDS.rbf`, and the same 18 fitter warnings with 0 errors from
both the fitter and the assembler. The LAB count moves less than the ALUT count
suggests, and the reports say why: total registers rise from 30,691 to 31,996,
because the fitter duplicates register bits to keep the four shared muxes'
fanout down, and peak interconnect rises from 79.8/78.8/83.8 to 87.9/86.7/91.5.
So the ports do take the reads from eleven mux trees to four, but synthesis
spends most of the saved logic on that duplication and the router, and the net
is 11 LABs, 0.063 ns and a 46 KB smaller bitstream for a fit that takes 18
minutes longer.

Every domain passed except setup, and the failing set had shrunk to the core
itself: `pll_hdmi` was -0.061 ns with -0.061 of TNS and the emu domain at
-8.313 with -41,728.820, while `h2f_user0_clk` was +3.793, `FPGA_CLK1_50` at
+7.062, `FPGA_CLK2_50` at +9.728, `pll_audio` at +14.082 and `FPGA_CLK3_50` at
+18.801. Hold was positive in every domain (worst +0.251), recovery at +3.439,
removal at +0.917 and minimum pulse width at +1.065.

So the remaining deficit is inside the 67.03 MHz domain, which no constraint
can fix: it is design work in the core, and the -53.667 ns hold figure that
looked impossible was the same constraint mistake seen from the other side.

### The operand-form bench's decoder fixes (2026-11-07, rebuilt 2026-11-09)

`tb_arm9`'s program E drives every Thumb and ARM operand-encoding form with a
different register in every field, so a read port that decodes the wrong field
stores a value the bench can see. It failed five real decode gaps, fixed in the
RTL rather than worked around in the bench:

- the register-shift data-processing forms (`dp_rshift`, and the multiply group
  that shared its predicate) no longer take `UND`;
- the halfword/media gate is `insn[24] && !insn[23] && !insn[20]`, so the forms
  that had been falling into the single-transfer decode reach their own one;
- Thumb format 8 (immediate offset) scales imm5 by a word, not a byte;
- Thumb LDMIA decodes at `insn[15:12] == 4'b1100`, with bit 11 choosing load or
  store;
- single data transfer gained `sdt_sh`, so a shifted register offset
  (`ldr r12,[r8,r9,lsl #1]`) is no longer treated as an immediate offset.

The committed design makes this reproducible: the after row is `HEAD`, the
before row is `HEAD` with the same hunk from `arm9_core.sv` applied in
reverse (`git show 291b41f -- rtl/cpu/arm9_core.sv | git apply -R -p2`),
and both ran `quartus_map` with the pinned stamp 261108:

| build | ALMs needed | ALUTs | registers | DSP | M10K bits | warnings |
|---|---|---|---|---|---|---|
| before the fixes | 38,439 | 55,624 | 28,156 | 63 | 1,800,523 | 127 |
| after the fixes | 38,732 | 56,043 | 28,155 | 63 | 1,800,523 | 127 |
| delta | +293 | +419 | -1 | 0 | 0 | none new |

The `arm9_core` entity carries 18,001 ALUTs against 17,594, so the decoder
costs 407 of the 419 ALUTs the fixes add design-wide. The register count does
not move: 2,471 in the entity and 28,155 in the design against 28,156, which
is what a decode fix should look like -- no state was added, so the extra
logic is the terms the old predicates had folded away. The 127 mapper
warnings are 17 distinct message ids in the same counts on both sides, and
the map has 0 errors.

The surrounding sections still quote the working tree the fixes were first
measured on -- 56,002 ALUTs and 28,049 registers after them -- so their
deltas compare among themselves; the committed design measures 221 ALUTs
higher before the fixes and 41 higher after.

Fitted at `PLACEMENT_EFFORT_MULTIPLIER 4.0`, the same ten macros no longer
close. Two runs of `quartus_fit` on the same mapped database (38:47 and 46:19)
both place the design -- 4,040 of 4,191 LABs, 38,707 ALMs, 30,581 registers,
peak interconnect 80.1/82.5/89.2 -- and then abandon routing: `16684` reports
an exceedingly large amount of congestion, `16618` terminates the routing
phase, critical warning `188026` says the design did not route, and `11802`
ends the fit with 2 errors and 22 warnings. No `NDS.rbf` and no timing report
come out of that configuration.

The effort changes no mapped logic: `quartus_map` puts this database at
38,726 ALMs and 28,155 registers. At `PLACEMENT_EFFORT_MULTIPLIER 8.0` --
seed 2, the same ten macros and the same aggressive routability -- it fits.
Placement takes 13:54 and routing 08:33, the fit ends at 00:53:59 with 0
errors and 18 warnings, the assembler adds 0 errors and 0 warnings, TimeQuest
0 errors, and the build uses 4,138 of 4,191 LABs (53 spare), 38,654 ALMs,
32,510 registers, peak interconnect 83.0/82.3/89.7,
and writes a 3,783,032-byte `NDS.rbf`.

| ten-macro build | LABs | spare | setup (`emu`) | setup TNS | hold | rbf |
|---|---|---|---|---|---|---|
| 2026-11-06, effort 4.0 (the `current` row above) | 4,143 | 48 | -8.313 | -47,647.790 | +0.250 | 3,718,564 |
| 2026-11-07, effort 8.0 | 4,126 | 65 | -8.403 | -46,613.591 | +0.256 | 3,761,748 |
| 2026-11-08, effort 8.0, rumble pak | 4,122 | 69 | -9.006 | -52,072.394 | +0.245 | 3,745,296 |
| 2026-11-08 later, effort 8.0, microphone ADC | 4,138 | 53 | -8.325 | -53,336.764 | +0.238 | 3,783,032 |

None of these four rows can be rebuilt to the numbers shown from the
committed tree: they all ran before the stamp was pinned (2026-11-09),
so the `BUILD_DATE` each carried is not in the repository -- and that
constant moves the fit, as the 261031-against-261108 difference above
shows. The 2026-11-06 row also needs `PLACEMENT_EFFORT_MULTIPLIER 4.0`,
which `NDS.qsf` no longer sets (`2f75cc4` moved it to 8.0). The two
2026-11-08 rows' features are still in the tree (`rumble` in
`main_bus.sv`, `mic_adc` in `rtl/input/`), so their logic rebuilds; only
their fit figures do not.

The microphone row was rebuilt to check that reading: `6f925da`'s tree,
the same RTL with the ten macros committed, staged with the later pin
mechanism and 261108 substituted for its clock date, fits at 4,157 of
4,191 LABs with setup -8.210 and TNS -49,244.967, hold +0.250, and
writes a 3,764,100-byte `NDS.rbf` with sha256 `a4adcf37...`. Every
figure is the committed design's and none is the row's -- 19 more LABs
than the 4,138 recorded, 1,597 more fitted registers (34,107 against
32,510), 0.115 ns better setup, 4,091.797 of TNS, and 18,932 bytes
smaller -- the same 19 LABs and 1,597 registers this file prices as the
cost of one build stamp, measured here on a tree that predates the pin.

The rumble row was rebuilt the same way: `17492a1` with the ten macros
appended as `6f925da` commits them, the later pin mechanism and 261108.
It fits at 4,118 of 4,191 LABs (73 spare) with setup -8.752, TNS
-58,562.464, hold +0.250, and a 3,735,040-byte `NDS.rbf` (sha256
`f747b986...`). The row's 4,122 LABs, -9.006, -52,072.394, +0.245 and
3,745,296 bytes are not reproduced: 4 LABs fewer, 0.254 ns better setup,
6,490.070 more TNS, 0.005 better hold and 10,256 bytes smaller. This
tree is not the committed design -- 143 pins against 144, the microphone
ADC's line absent -- so unlike the microphone row it lands somewhere of
its own, and its fit takes 01:25:59.

That is 0.090 ns of setup for a build that exists, and it is the only change:
`NDS.qsf` asks for 8.0 with the reason beside it. The margin it buys is 65
LABs, the same order as the 48 the previous build had, so the next feature
still has to find its own area. A different seed was not tried -- the fitter
suggests one, but the effort alone was enough.

The rumble pak lands without growing the netlist: `quartus_map` gives 55,919
ALUTs against 56,002 and 28,056 registers against 28,049. The fit still pays
0.603 ns of setup and 5,459 of TNS for it, at 94.2 against 89.9 on the H
channel, and it uses 4 LABs fewer: at 98% full it is repacking, not size, that
moves the margin.

The microphone ADC trades the other way: 16 more LABs (4,138, 53 spare) and
44 more ALMs, 82 fewer registers, setup better by 0.681 ns, and routing down
from 41:21 to 08:33 with interconnect 89.7 against 94.2 on the H channel. TNS
is 1,264 worse, so the domain that already failed still does; nothing new
fails, and `pll_hdmi` now closes at 0.022 ns.

### Reproducing these figures (2026-11-09, rehearsed 2026-11-10)

The configuration is in the project: seed 2,
`PLACEMENT_EFFORT_MULTIPLIER 8.0` and the ten macros, so a clean checkout
builds the design this document describes. It reproduces the mapped design --
28,155 registers and the mapper's own `0 errors, 127 warnings`, as
above -- and the fit too, once the build stamp is pinned. `git archive
HEAD` into an empty directory followed by
`quartus_sh --flow compile NDS` fits at 4,157 of 4,191 LABs with setup -8.210
ns and TNS -49,244.967, leaves `pll_hdmi` short by 0.515 ns and writes a
3,764,100-byte `NDS.rbf`. A second flow on that same tree reproduced every
figure: 4,157 LABs, 38,881 ALMs, 34,107 fitted registers, interconnect
87.2/85.9/91.1, 18 warnings, the same bitstream size and the same setup, TNS
and hold slacks. The fitter is deterministic given the same inputs.

The inputs used to differ. `sys/build_id.tcl` wrote `BUILD_DATE` from the
clock, so each day's build carried a different constant into the netlist: the
2026-11-08 run held `"261031"`, this one `"261108"`. Mapped registers, settings
and duplication are the same either way -- both runs log `Created 222 register
duplicates`, not the thousand that comparing fitted register counts suggests.
What changes is the fit: 4,138 LABs and 32,510 fitted registers in the older
run, 4,157 and 34,107 here, setup -8.325 against -8.210 and TNS -53,336.764
against -49,244.967. The extra registers are retiming done differently on a
different netlist, priced by the logs at 2,859 ps there against 1,770 ps here:
one constant is worth 19 LABs and 1,597 fitted registers.

`sys/build_id.txt` now pins the stamp the flow writes -- 261108, the build
recorded above -- so a rebuild of this tree reproduces its own fit;
`tools/bump_build_id.py` moves it for a release, and a clean checkout confirms
it: `git archive HEAD` into an empty directory wrote that stamp, fitted at
4,157 LABs with setup -8.210 ns, and produced a bitstream byte-identical to the
one above (sha256 `a4adcf373ee886867621bf9a...`).

The release run of 2026-11-09 came through `build.bat --record --verify
--strict --max-age 30` instead: the stamp and document self-tests
passed, and the flow took 01:14:57 (13:59 analysis, 58:39 fit, 1:18
assembly and 1:01 timing) with 03:52:27 of CPU on all processors. It
fitted at the same 4,157 LABs, 38,881 ALMs and 34,107 registers, with
setup -8.210 ns and TNS -49,244.967 on the core domain, 18 fitter
warnings and none from the assembler, and it recorded stamp 261108
against the bitstream and verified it. That bitstream is the same
3,764,100 bytes with the same sha256, so the gate costs its own run
time and changes nothing in the fit.
Rehearsed again on 2026-11-10 from a tree staged at `4c9e3eb`, the
checklist ran end to end: `bump_build_id.py` moved the pin 261108 to
261110, `build.bat --record` passed its 73 stamp cases and the document
check, and `--verify --max-age 30` matched the new record. The stamp
reached the design -- `build_id.v` holds `"261110"` -- and the
bitstream is 3,764,100 bytes with sha256 `e4508adc...f44b`, a different
hash from the 261108 build at the same size. The flow took 01:00:44,
and the fit still reports 38,881 ALMs, 34,107 registers and 127/18/0
warnings, so a stamp-only change moved the bitstream and left the
counts alone.

In that microphone build only the 67.03 MHz core fails: the emu domain -8.325
with -53,336.764, and every other domain closes. `pll_hdmi` is 0.022 ns with
0.000 of TNS. `h2f_user0_clk` is +3.400, `FPGA_CLK1_50` +7.205, `FPGA_CLK2_50`
+9.791, `pll_audio` +14.324 and `FPGA_CLK3_50` +18.641. Hold is positive in
every domain (worst +0.238), recovery +3.373, removal +1.019 and minimum pulse
width +1.065.

`tb_arm9` reports 161 checks with 0 failures and `tb_cpu_clk` 23 with 0. The
bench is directed, not merely passing: pointing Thumb format 4's `t32b` at
`rp_a` instead of `rp_b` fails 11 checks on the same build (AND, EOR, LSL, LSR,
ASR, ORR, MUL, BIC, TST, CMP and the ASR immediate).

The microphone ADC (`mic_adc`, one LTC2308 channel at 48 kHz) is in that
2026-11-08 later build: `tb_mic_adc` measures the sample path and the
conversion rate, and the fit puts it at 4,138 LABs with setup -8.325 ns.

### Sharing the ARM9 barrel shifter (2026-11-08)

The single-transfer fix added `sdt_sh`, a second 32-bit barrel shifter with all
four shift types, and by size it was the largest thing the fixes bought. It
does not have to exist. In mode 2 the shift field sits on Rm exactly where data
processing keeps it; only bit 25 (register offset rather than immediate
operand) and bit 4 (the low bit of the shift amount, not a shift-by-register
flag) mean something else. Steering the one shifter into its immediate form for
that case and reading `op2`, with `ROR #0` held at Rm -- which is how this core
has always read it, unlike the architectural RRX -- is behaviour-identical:
`tb_arm9` stays at 161 checks with 0 failures.

Measured, the sharing is real but small: `quartus_map` on the same ten macros
gives 38,416 ALMs and 55,637 ALUTs against 38,680 and 56,002, so 365 of the 599
come back, with 28,049 registers (still unchanged) and `arm9_core` at 17,795
against 18,012.

Fitted at seed 2 and effort 8.0 it routes with 0 errors, and against the
2026-11-07 build it was a worse one: 4,158 of 4,191 LABs (33 spare, against
65), 38,520 ALMs, 33,548 registers (up 1,258 from 32,290), peak interconnect
89.1/87.8/93.2 (against 81.7/79.1/89.9), and setup short by 8.574 ns with
-49,692.260 of TNS (against 8.403 and -46,613.591). Routing alone took 52:29 of
the 01:40:26 fit -- the router logged `16684` on the way -- and the fitter
ended with 19 warnings rather than 18.

Seed 3 was tried next, at the same effort, in case the spare LABs were the
seed's fault: it places in 13:17 and routes in 29:08, uses 4,144 of 4,191 LABs
(47 spare), 38,393 ALMs and 33,582 registers, and finishes with 0 errors and 18
warnings. The margin does not come back with it -- emu slack is short by 9.559
ns, TNS -56,577.958, and `pll_hdmi` misses by 0.224 ns (-0.443 of TNS), both
worse than seed 2.

So the 365 ALUTs of mapped logic do not survive packing at either seed: seed 2
spends 32 more LABs than the 2026-11-07 build and 3,079 ns of TNS, seed 3
spends 18 more LABs and 9,964 ns of TNS. The change is reverted and the
shipped build stays the one to quote; the measurement is kept because it says
where the decode cost lives.

Against the rumble build the comparison is no longer one-sided: 4,158 LABs
against 4,122 and 33,548 registers against 32,592, but setup -8.574 against
-9.006 and TNS -49,692.260 against -52,072.394. The revert rests on area.

### Why micro-optimising one path does not close it (2026-11-01)

The worst t11 path is the ARM9's 64-bit multiply-accumulate, built in LUTs
(`Mult3` -> `Add54`, 32.6 ns of logic against a 14.92 ns cycle). The device has
49 free DSP blocks, so the obvious repair is `(* multstyle = "dsp" *)` on the
result register `t64`. Measured, it is a loss:

| build | ALMs | DSP | LABs | interconnect | setup worst | setup TNS | rbf |
|---|---|---|---|---|---|---|---|
| t11 | 39,685 | 63 | 4,160 | 84.2/83.1/91.3 | -8.339 | -45,936.820 | 3,749,124 |
| t12, `t64` on DSP | 39,884 | 67 | 4,186 | 87.7/85.8/93.8 | -8.618 | -39,865.075 | 3,780,460 |

The attribute did what it advertises: `arm9_core` goes from 11 to 15 DSP blocks
and the multiply leaves the failing set -- the worst t12 path is no longer the
multiplier but `insn[10]` into the register-read mux. But the extra ALMs cost
23 of the 31 free LABs, interconnect rises to 87.7%, and the worst slack is
marginally worse. The change is reverted; t11 remains the build to quote.

That is the useful measurement. Those paths spend 1-2 ns per hop in
interconnect, and at 99.3% LAB occupancy (99.8% in t12) the router has no room
to shorten them. The remaining gap is an occupancy problem: it needs more logic
gone, which from here means real features, or a slower core clock -- not
another micro-optimisation of a single path.

### Verified from the repository state (2026-11-01)

The fitter settings that make this build possible used to live only in a
scratch copy of the project. They are now in `NDS.qsf` -- `SEED 2` and
`FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION Always`, with the reason written
beside them -- and a build made from a **fresh copy of the repository**, with
no hand edits and only the ten macros added, reproduces the earlier result in
every figure:

| metric | fresh tree from the repo | earlier t11 build |
|---|---|---|
| ALMs / ALUTs / registers / DSP | 39,685 / 56,717 / 28,426 / 63 | same |
| LABs | 4,160 / 4,191 | same |
| peak interconnect | 84.2% / 83.1% / 91.3% | same |
| setup worst / hold worst | -8.339 ns / +0.203 ns | same |
| `NDS.rbf` | 3,749,124 bytes | same |

The two `.rbf` files are **bit-identical** (sha256 `fa4ee336f277009a...`), so
the written figures and the bitstream both come out of the committed tree
exactly.

One trap, because it cost two runs here: several macros in a single
`--verilog_macro` value, or in one `set_global_assignment -name VERILOG_MACRO`
line, apply only the **first** one and silently drop the rest. The build then
looks untouched and the rung measures nothing. One assignment per macro.

So the 3D pipeline is worth **4,164 ALMs, 5,150 ALUTs, 7,256 registers and 22
DSP blocks**, and the cheat engine plus the SPU together are worth **5,793
ALMs, 7,897 ALUTs and 7,697 registers**. Both are less than the standalone-ALUT
projections this file carried before, because mapping the whole design shares
logic that mapping a block alone counts twice: the real conversion is 1.24
nodes per ALM for the 3D cut and 1.36 for cheat plus SPU, not the 1.42 the
renderer probe suggested. Item-level numbers in the ranked list are therefore
upper bounds, useful for ordering work and not for promising savings.

That leaves the merged renderer as the last lossless lever, ~8,550 ALUTs
(~6,030 ALMs by the probe's ratio). On top of the lean build that is **~42,400
ALMs, 101%** — about 500 ALMs over. Measured, no combination of the four cuts
fits: a fit also needs one more item of roughly 1,000 ALMs (an OSD, the
scanline filter or the shadowmask) *and* the merged renderer, which is the one
item that currently fails the line budget at 109%.

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
| *framework* ascal | 2,826 | in context, t6 report (8,344 was a standalone estimate) | — |
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

**1. Serialise the geometry engine's composite matrix — done: 18,114 ALUTs, 100
DSP measured.** (15,577 sat in the multiplier leaves; the replacement
multiplier and its FSM take about 180 back.) `comp[0:15]` is 16 outputs × 4
products, evaluated combinationally, and the viewport transform adds 8 more: 72
multiplies of 32×32 in one clock. Each costs 3 DSPs (216 for all of them)
against 112 available, so 37 of them landed in LUTs at 271 ALUTs each. One
time-multiplexed multiplier is 46 ALUTs and 3 DSPs, and the 16 accumulators go
to a 16×64-bit BRAM. *Accuracy: none lost* — same integer widths, same 4.12
truncation, same results. Throughput falls from 1 vertex/clock to 10 clocks:
6.7 M vertices/s against the 369 k/s that 6144 vertices at 60 Hz needs.

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
renderer, measured.** Both renderers used to hold `buf_a`/`buf_b` as 2×128×42
flops with a bank mux on the read path: 3,342 ALUTs each, measured. A 256×42
dual-port M10K is 0 ALUTs and 0 registers, and only ~4 of the 372 spare M10Ks.
*Accuracy: none lost*; the read becomes registered, which costs one pixel-CE of
latency on the composer contract. This also matters because registers are at
82%: it takes the design to 56%. As built the word is 68 bits rather than 84
(the display only reads `{opaque, rgb}` of each pixel), so the array is 128 x
68 = 8,704 bits -- exactly what the pair form held as 256 x 34; the working
bank stays in registers because its read-modify-write must land in the write
cycle.

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

**5. Serialise the SPU mixer — done: 90 ALUTs measured, and the 1,176 the
earlier estimate rested on was an artefact.** The mixer summed sixteen channels
in one tree, costed at "1,176 ALUTs (4,188 → 3,012 with the tree stubbed out)".
Stubbing the sum to zero constant-folds everything downstream of it — master
volume, OSD volume, the clamp — so that 1,176 measured the whole mix path, not
the tree. Mapping the same source twice, once with the tree and once with one
channel per clock, gives **4,188 → 4,098 ALUTs and 4,717 → 4,767 registers, 8
DSP either way**: the tree's fifteen 22-bit adds are worth ~90, because the
serial version pays most of it back in the 16:1 mux on `c_l`/`c_r`.

The pass is still the right shape: sixteen of the ~1,396 clocks between two
48 kHz samples, and it takes the sixteen-way fanout off the master-volume
multiply's input. *Accuracy: none* — same accumulation order (channel 0 first),
same 22-bit width, same sign extension, so `tb_spu` is bit-identical. The one
thing it needs is the service engine holding a channel's new sample while
`mx_st == MX_SCAN`, or a value written mid-pass would be summed at a different
instant from its neighbours.

*Lesson, same as item 6:* a "stub it out" measurement includes everything the
stub lets the tools constant-fold away.

**6. Per-row rotation/layout remap in the composer — measured: nothing to
gain.** The estimate here said ~2,000 ALUTs. Mapping `screen_composer` alone on
the same device gives **73 ALUTs, 0 registers, 3 DSP** (97 ALUTs in context,
the 3 DSP being the brightness multiplies), so there is no 2,000 to find: the
layout case is one 8-bit subtract plus two range compares, `sy`/`box_hit`/the
`use_top` base are already shared by the whole pixel datapath, and the rotation
remap is two subtracts and two 4:1 byte muxes. Registering the row terms would
also put the first pixel of every line one cycle behind the engines, because
the engines sample `na_x`/`na_y` combinationally through their line-buffer RAM.

*Lesson for the rest of this list:* every remaining number in it is an
estimate, and this one was 25× high. Measure a block before planning work on
it.

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
one BG layer, two sprites and the 3D merge. The `before` rows are the design as
it stands; the refill and cached rows were measured before the state fold and
the quad fill landed, so they are a snapshot from that tree rather than a
re-run against it:

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
`ascal` is 2,826 in context, from the t6 report; the 8,344 standalone
estimate is stale. Nearest/integer scaling instead of the polyphase path is
a visible quality loss on HDMI. *Accuracy: softens or blocks the upscale.*

**9. CPU datapath sharing — ~2,000 ALUTs** (estimate, high risk). 18,012 +
10,192 ALUTs of decode, shifter and ALU. Sharing the barrel shifter and address
adder across states is the only real saving and it must keep `tb_arm7` and
`tb_arm9` green. Not worth doing before the items above.

**10. Registers → BRAM in cart_slot — done: 2,452 ALUTs and 6,150
registers,\nmeasured.** (The estimate was ~1,500 ALUTs; it was low.)
`cart_slot`'s download FIFO was three register arrays — 64 x 64-bit data, 64 x
29-bit line, 64 x 8-bit byte enables, 6,464 flops — written once and read once
in order, which is exactly a simple dual-port RAM. They are now one 64 x
101-bit array (`{be, line, data}`) in one M10K, with the drain fetching the
head entry and issuing it on the next cycle to absorb the registered read.
Measured at design level: `cart_slot` **3,590 → 1,138 ALUTs, 7,640 → 1,490
registers**, block RAM +7,488 bits, and the design **85,696 → 83,303 ALUTs,
60,181 → 54,032 registers, 62,271 → 58,791 ALMs**. `tb_cart_slot` 62/62 (tail
flush, byte enables, hold-across-BUSY), `tb_ddr_bridge` and `tb_main_bus`
green.

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

### The save file's second read port does not fit (2026-11-02)

Loading a `.sav` needs only a write port on the cart's save memory, and that
fits. Writing the save back out needs to read it as well, and the second read
port is what the device cannot pay for. Measured, in this order:

| build | block memory bits | registers | result |
|---|---|---|---|
| save chip as committed | 1,873,204 | 53,269 | fits at 4,160 LABs |
| load + upload read port | 2,397,619 | 54,093 | `170011`: 83,984 combinational nodes against 83,820 — 164 over |
| read port shared, address muxed | — | — | `276007` / `276003`: the RAM is uninferred, map fails |
| reads and writes in separate clocked blocks | 2,397,619 | 54,093 | identical: `276020` pass-through on both nodes |
| `(* no_rw_check *)`, then `ramstyle = "no_rw_check"` | 2,397,619 | 54,093 | attribute ignored; pass-through stays |

The extra 524,415 block-memory bits are the duplicated 64 KB array a second
read port infers, and the pass-through logic Quartus adds to each copy is what
puts the design 164 nodes over. Sharing the one port instead makes the mapper
treat the read address as asynchronous and leave part of the array in
registers, which fails the map outright. So the build loads saves and does not
write them back: `rtl/cart/save_file.sv` says so in its own header, and
`tb_save_file` covers what is built.

### Where items 5-10 actually stand (measured, not estimated)

| item | state | measured effect |
|---|---|---|
| 5. serialise the SPU mixer | **in** | 4,188 → 4,098 ALUTs, `tb_spu` bit-identical |
| 6. per-row composer remap | **measured: nothing to gain** | the module is 73 ALUTs standalone |
| 7. one 2D renderer for both engines | **rejected on measurement** | worth ~8,550 ALUTs (~6,030 ALMs), but the two lines need 1,794 clocks in a 1,650-clock period (109%) — the picture, not the area, is what fails |
| 8. single-pass framework scaler | **not done** | `ascal` is **2,826** ALUTs in context (the 8,344 standalone estimate is stale), so the ceiling is ~2,800 and it costs upscale quality |
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
| + capability cuts (~4,850: 3D merge pass, one OSD, scanlines, shadowmask, cheat entries 32→8) | 57,750 | 84,120 | 1.004× |

So taking *every* item, including the ones that cost accuracy, still leaves the
design about 300 ALUTs over. That is not a fit: the fitter duplicates logic,
inserts buffers and needs room to route, and every later fix spends pipeline
registers out of the same 83,820. A build with a sane 10% margin has a ceiling
of ~75,000, and table stakes for the lossless items alone is ~105,000.

The honest conclusion: **the A6 cannot host this core at full feature set.**
The gap is structural, not a matter of tightening a few blocks. After item 1
the 3D path is no longer the largest thing in the design — 4,025 ALUTs of
geometry (4,319 standalone) plus 948 of rasteriser — and what remains around
it, the two CPUs, the bus and the two renderers, is still over the limit on its
own.

The "what does fit" rows below are from the pre-item-1 baseline; item 1 moved
every one of them down by about 18,000.

What does fit, with margin:

| build | how | ALUTs | margin |
|---|---|---|---|
| 2D DS core | drop geometry + raster, then items 2,3,4,5,6,9,10 and 7 | 82,900 | 1.1% |
| 2D DS core, lean | the same without the shared renderer | 88,400 | does not fit |

Item 7 is out (see above: the shared renderer needs 128% of the line period),
so the *only* projected build that fit — the 2D core with the merge — is not
buildable. The same build with two renderers is the 88,400 row: no fit, and the
measured design is **82,280 ALUTs / 57,207 ALMs** today (the table at the top),
so what the A6 actually needs before any of this is about 24,000 ALUTs of
things this list does not contain.

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
command changed either matrix (measured on the next vertex, not on the
command), MTX_SCALE 12 clocks and MTX_TRANS 9. All of that sits inside GXSTAT's
busy window, which now covers the pipeline, so a game polling `GXSTAT.27`/bit 0
sees the engine busy exactly as long as it is.

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
first full compile, 42,628 after items 2 and 4, and 26,191 after item 1 alone.
The fitter still stops before placement (`Error 170011`, then `11802`), and its
own ALM count is the pessimistic reading of the same design: an ALM holds two
4-input LUTs only when they share inputs, so 84,123 nodes that pack badly look
like 58,131 ALMs. No placement means no routing, no timing analysis and no Fmax
report from this build.

### Why 303 nodes is not the gap

The node count and the ALM count are not the same wall, and the fitter quotes
both: `84,123` combinational nodes against `83,820`, and **58,131 ALMs against
41,910 (139%)**. The second number is the one that decides it.

An ALM holds two 4-input LUTs and reports two dedicated registers, so the
capacity is 41,910 ALMs = 83,820 nodes = 83,820 registers. The design uses
83,997 nodes and 59,318 registers. With *perfect* co-location — every register
in the same ALM as the LUT that drives it — that needs `max(83,997/2, 59,318/2)
= 41,999` ALMs, which is 89 ALMs (0.2%) over. So 303 nodes is the gap only in
the best case, and the fitter's 139% says the placer is not going to reach it:
at the packing ratio it quotes (1.45 nodes/ALM against 1.5 for a perfectly
packed ALM) the design needs roughly 60,000-65,000 nodes to fit, i.e. **20,000
nodes / about a quarter of the logic**, not 0.4%.

That is the sum the ranked list below adds up to, and it is why the next step
is items 5-10 rather than another few hundred nodes: registers already occupy
71% of the device on their own, so there is no LUT headroom left to spend.

Most of the 110,011 → 83,997 drop is not item 3: the line-buffer trim measures
6,436 ALUTs across the two renderers (3,218 each, A/B above). The rest came
from the burst-fetch and OAM-scan work that landed between the two builds.
Registers fell 69,183 → 59,318, of which 2 × 8,738 belongs to item 3.

There are no warnings on `lbuf`: the RAM infers cleanly, 8,704 bits per
renderer (128 words x 68 bits, four pixels of `{opaque, rgb}` each). Quartus
17.0 maps it as a Simple Dual Port RAM, 128 x 68, with no Info 276009, and the
fitter spends **two M10K blocks** on it (20,480 implementation bits). The pair
form of the same buffer (256 x 34) took **one** (10,240 bits), so the quad word
that halved the backdrop fill costs one extra M10K per renderer -- four of the
553 for both. The lane select on the read path is all the logic it adds. The
`Total RAM Blocks 0 / 553` row in `NDS.fit.summary` is an artefact of the
aborted placement, not a memory total; the bit count above is the reliable
figure (33%, ~183 block-equivalents of the 553). There are no critical warnings
any more: the two `Critical Warning (127005)` lines that used to appear here
were the SPU MIF depth notes, fixed by padding those tables to the depth the
synthesiser builds.

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

Where it goes: the byte-lane generator and the variable shift in BIT_UNPACK and
RL are one 32-bit shifter; Div/Sqrt share a 32-bit subtract-compare adder and
the 22-bit count; CpuSet/CpuFastSet reuse the same address incrementer as the
LZ77/RL copy loops. Nothing here is a table — the LZ77/RL windows live in
memory, not in flops — so there is no cheap second trim: the shifter is the
only candidate (it is the largest single piece, shared by three calls), and
removing it would cost bit-packed BIOS formats that games do use. If the fit
margin disappears, this module is the first thing to look at with `quartus_map`
before touching the renderers again.

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

## The capacity settings, measured (2026-11-03)

The shipping build at the time was 4,168 of 4,191 LABs (99%) while the same fit
used 39,254 of 41,910 ALMs (94%), and that gap is the question: ten ALMs to a
LAB means 4,168 LABs *are* 41,680 ALM slots, and 2,426 of them sat empty. Three
settings were tried against it. Two move nothing, and the third is worth 9
LABs.

| build | ALMs | registers | LABs | peak interconnect | setup worst | fit |
|---|---|---|---|---|---|---|
| shipping | 39,254 | 31,129 | 4,168 | 89.3% | -9.155 | 00:56:15 |
| register + router duplication off | 39,254 | 29,492 | 4,168 | 84.8% | not run | 00:49:29 |
| `PLACEMENT_EFFORT_MULTIPLIER 4.0` | 39,254 | 31,394 | **4,159** | 90.0% | **-8.475** | 00:45:00 |
| that setting + the CRT video modes + the RAM expansion pak (the pak tree) | 39,729 | 31,179 | 4,181 | 91.6% | -8.354 | 00:50:53 |
| that + the firmware shadow's flag in its block RAM (today's tree) | 39,083 | 30,691 | 4,154 | 79.8% | -8.376 | 00:46:36 |

**Duplication off.** `PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION OFF` removed
1,637 duplicate registers -- 31,129 to 29,492 -- and changed the ALM count by
zero and the LAB count by zero. The fitter's own breakdown says why: `[c] ALMs
used for registers` is 3,452 of the 40,132 placed, so the duplicates were
sharing ALMs the logic had already paid for. Registers were never the wall
(29,492 of 83,820 is 35%); the LAB is. Both switches, this one and
`ROUTER_LCELL_INSERTION_AND_LOGIC_DUPLICATION`, are reverted. They are
fitter-stage, so the map before them is byte-identical either way and only a
fit can price them -- which is why that row cost 49 minutes rather than 12.

**`OPTIMIZATION_MODE`.** It is still `BALANCED` in `NDS.qsf` while
`OPTIMIZATION_TECHNIQUE` is `AREA`, so it looked like a lever that had never
been pulled. Mapped with `AGGRESSIVE AREA` it produces **39,896 ALMs, 57,080
ALUTs and 28,538 registers -- every digit identical to the balanced map**, with
the same 46 warnings: the technique assignment wins and the mode has nothing
left to decide.

**Placement effort.** `PLACEMENT_EFFORT_MULTIPLIER 4.0` is the one that pays:
**4,159 LABs, 32 spare**, and setup 0.680 ns better at -8.475. It also costs
265 registers, raises the interconnect peak from 89.3% to 90.0%, and gives up
0.118 ns of hold -- still +0.130, positive in every domain -- and it shortens
the fit from 00:56:15 to 00:44:53, the placer spending its time once instead of
the router paying for a placement it did not like. The setting is in `NDS.qsf`
and is part of the shipping build.

Rebuilt from the committed tree, with nothing but the ten macros added and no
hand edits, the build reproduces every figure above and writes a
**bit-identical `NDS.rbf`** (sha256 `f227095515d0b4df...`). Only the wall-clock
minutes move between runs -- 45:00 here, 6:32 of it routing -- so the figures
quoted in this file are from that clean run.

The rest of the gap is packing, and the fitter prices its own shortfall:

```
[A] ALMs used in final placement                    40,132 / 41,910 (96%)
[B] estimate of ALMs recoverable by dense packing    1,716 (4%)
[C] ALMs unavailable                                   838 (2%)
      LAB-wide signal conflicts                           96
      LAB input limits                                   742
```

Nine LABs is 90 ALMs, about 5% of what that hint holds, so effort recovers a
real but small slice of it. There is no dense-packing assignment in 17.0 to ask
for the rest (`FITTER_EFFORT` is `Standard Fit` and
`ALM_REGISTER_PACKING_EFFORT` is already `HIGH`). The 838 is structural: 742
ALMs are lost to how many distinct inputs a LAB can take, which follows the
shape of the logic rather than the effort the placer spends.

So the LAB count still follows the LUT volume -- 25,803 of the 40,132 placed
ALMs hold LUT logic alone -- and a setting can recover the packing slack around
it, not the logic itself.
