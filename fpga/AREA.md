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
not fit; they are not the current state. The area fits now -- the slot-2 pak
build at the end of this file reports 39,119 ALMs and 4,157 of 4,191 LABs at
`SEED 2`, stamp 261115 -- so read the table above as where the cut ladder
began and the rungs below as how far it has come. The 38,881 ALMs and 4,157
LABs quoted here earlier were the 2026-11-09 rebuild, three features back;
they are the figure that section records for that date, not for this tree.

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
| before† | -19.413 (emu) | -96,426.996 | -53.667 (audio) | 4,177 | 88.8/87.6/93.1 | 01:50:47 |
| after (t11) | -8.339 (emu) | -45,936.820 | +0.203 (hdmi) | 4,160 | 84.2/83.1/91.3 | 00:45:25 |
| 2026-11-08 | -8.325 (emu) | -53,336.764 | +0.238 (hdmi) | 4,138 | 83.0/82.3/89.7 | 00:53:59 |

Routing fell from 01:20:34 to 00:21:25 because the router no longer tries to
make unrelated clocks meet, the assembler still reports 0 errors and 0 warnings
and wrote a 3,718,564-byte `NDS.rbf`, and the fitter's warning count drops from
20 to 18. The 2026-11-08 row is that build plus two measured changes: the save
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
| pak tree† | 39,729 | 31,179 | 4,181 | 86.8/85.9/91.6 | -8.354 | -44,563.505 | 3,730,440 | 00:50:53 |
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
| 2026-11-06, effort 4.0 (the 2026-11-08 row above) | 4,143 | 48 | -8.313 | -47,647.790 | +0.250 | 3,718,564 |
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

### Timing-driven synthesis scoped to the ARM9 core (2026-11-11)

The area profile switches timing-driven synthesis off for the whole
design: `NDS.qsf` line 29 has carried
`set_global_assignment -name SYNTH_TIMING_DRIVEN_SYNTHESIS OFF` since
`469b4ae` (2026-10-31), and this file prices that area profile as
deliberate. The one untried fitter lever was to turn it back on for the
single entity that owns the worst cone:

```
set_instance_assignment -name SYNTH_TIMING_DRIVEN_SYNTHESIS ON \
    -to "emu:emu|arm9_core:arm9"
```

Mapping the committed tree with and without that line moves the estimate
by six ALMs and 125 combinational ALUTs out of about 38,700 and 56,000:
38,732 ALMs, 56,043 combinational ALUTs and 28,151 registers without it,
38,726, 56,168 and 28,151 with. The setting reaches the netlist, which
`PHYSICAL_SYNTHESIS_EFFORT EXTRA` did not.

Two full flows of one tree -- `d720637`, stamp 261108, the ten macros,
`PLACEMENT_EFFORT_MULTIPLIER 8.0`, nothing else differing -- price it:

| scoped timing-driven synthesis | LABs | fitted regs | setup (`emu`) | setup TNS | hold | rbf |
|---|---|---|---|---|---|---|
| off, the committed setting | 4,157 | 34,107 | -8.210 | -49,244.967 | +0.250 | 3,764,100 |
| on for `arm9_core` | 4,138 | 32,612 | -8.325 | -53,336.764 | +0.238 | 3,783,032 |

It saves 19 LABs and 1,495 fitted registers, and lowers peak
interconnect from 87.2/85.9/91.1 to 83.0/82.3/89.7. It costs 0.115 ns of
worst setup slack, 4,091.797 of TNS, 0.012 ns of hold and 18,932 bytes
of bitstream, and does not shorten the cone: the path this file traced,
`insn[1]` through the read port, shifter and ALU into `regs[11][11]`,
moves the wrong way. Scoped to `arm9_core` the setting is a loss, so
`NDS.qsf` is unchanged and still maps the design with timing-driven
synthesis off.

The off row is the committed design figure for figure: 4,157 LABs,
-8.210, -49,244.967 and a 3,764,100-byte `NDS.rbf` with sha256
`a4adcf37...`, as the 261108 rebuild recorded above.

The on row lands on the 2026-11-08 microphone row's 4,138 LABs, -8.325,
-53,336.764 and 3,783,032 bytes, at stamp 261108 -- which that row did
not carry -- and with 32,612 fitted registers against the row's 32,510.
Two different inputs reaching the same four figures is not explained
here. Nor does this pair show what the row held: its tree was never
committed, and the stamp attribution above is an inference from a
difference, not a controlled pair. What the pair does show is that 19
LABs, 0.115 ns and 4,091.797 of TNS can move at a fixed stamp from a
synthesis setting, so a fitted figure alone does not identify its cause.

### A three-bit shift-amount class in the ARM9 shifter (2026-11-11)

The traced cone runs through the shifter's amount comparison: `rp_c` (Rs)
reaches `rs_amt`, then the 8-bit tests that pick the shift case, then
`op2`, `dp_b`, the ALU and the write mux. Each case branches on only three
classes of that amount, and the classes are the bits above the barrel
shifter's select, so the tests were rewritten as such -- `sh_in` and
`sh_amt` became continuous wires, and

```
sh_zero = !(|sh_amt);                    // amount == 0
sh_hi   = |sh_amt[7:5];                  // amount >= 32
sh_32   = (sh_amt[7:5] == 3'd1) && !(|sh_amt[4:0]);
```

replace the comparisons against 0, 32 and 32-or-more. The rewrite is
bit-exact -- for an 8-bit amount `< 32` is `sh_amt[7:5] == 0`, and `== 32`
is the three-bit class with a zero low half -- but no simulator is
installed on this host (`run_benches.py` shells out to `iverilog`), so it
was not simulated, only elaborated and fitted.

Mapping shows Quartus had already shared those comparisons: 38,760 ALMs
and 56,187 combinational ALUTs against the committed 38,732 and 56,043,
so naming the classes cost 28 ALMs rather than saving any.

| shifter amount tests | LABs | fitted regs | setup (`emu`) | setup TNS | hold (worst) | rbf |
|---|---|---|---|---|---|---|
| as committed | 4,157 | 34,107 | -8.210 | -49,244.967 | +0.250 | 3,764,100 |
| three-bit classes | 4,120 | 32,807 | -9.091 | -56,345.624 | +0.192 | 3,725,640 |

The fit got worse on both headline numbers, by 0.881 ns of worst setup
slack and 7,100.657 of TNS, while using 37 fewer LABs and 1,300 fewer
fitted registers and writing a 38,460-byte smaller bitstream. A logic
edit that small moving retiming by 1,300 registers is the finding: at
98% LAB occupancy, with retiming and physical synthesis on, the fit is
the dominant term, and a single pair cannot attribute the difference to
the three-bit tests. The change is reverted; this record is the only
thing kept.

### Fitter sensitivity, and one shared barrel shifter (2026-11-12)

The pairs above are single flows, so the first question is what the fitter
itself contributes. The committed tree at stamp 261108 was fitted at three
seeds with no other input changed:

| SEED | bitstream | LABs | setup (`emu`) | TNS | fit time |
|---|---|---|---|---|---|
| 1 | none: "Fitter failed to successfully route the design", 188026/11802 | - | - | - | 00:43:27 |
| 2 | yes | 4,157 | -8.210 | -49,244.967 | 00:45 |
| 3 | none, the same 188026/11802 | - | - | - | 00:42:26 |

Two of the three seeds produce no bitstream at all. The design uses 4,157
of 4,191 LABs, so this is not a placement preference but the edge of
fittability: the same netlist either fits exactly or does not fit. Every
slack difference measured on this tree is a difference between fits that
are themselves marginal, and any change that alters the netlist size also
alters whether the part fits.

That makes area the one lever with a predictable direction, and the ARM9
core carried two 32-bit barrel shifters: the data-processing one behind
`op2`, and `sdt_sh` for a single data transfer's register offset. Both are
selected by `insn[6:5]`, so they were merged into one shifter whose input
and amount are muxed by `sdt_reg` (`insn[27:26] == 2'b01 && insn[25]`, and
not Thumb). The merge is bit-exact: `sdt_sh` is the same shifter with
`rm_val` as input and `insn[11:7]` as amount, and a model of both forms
agrees on 384,896 cases -- all 32 amounts, all four shift types, 3,007
register values. The one special case, ROR by zero being RRX for data
processing but a plain ROR for a transfer, is taken from `sdt_reg`.

It maps 217 ALMs and 252 combinational ALUTs smaller: 38,515 ALMs, 55,791
combinational ALUTs and 28,152 registers against 38,732, 56,043 and
28,151, which is the direction the fitting margin needs.

| build | LABs | regs | setup (`emu`) | TNS | hold (worst) | rbf | fit time |
|---|---|---|---|---|---|---|---|
| committed | 4,157 | 34,107 | -8.210 | -49,244.967 | +0.250 | 3,764,100 | 00:45 |
| shared shifter | 4,138 | 32,805 | -14.165 | -52,338.245 | +0.158 | 3,748,048 | 03:06 |

The fit is far worse, not better: 5.955 ns on the worst path, 3,093.278 of
TNS, 0.092 ns of hold, `pll_hdmi` from -0.515 to -1.121, peak interconnect
from 87.2/85.9/91.1 to 90.5/90.0/94.4, and a fit that takes four times as
long. Removing the second shifter lowered the mapped area and left the
fitted design worse on every timing figure. The change is reverted.

On the rumble tree the same merge does not fit at all. `17492a1` with the
ten macros, the later pin and 261108 fits at 4,118 of 4,191 LABs with setup
-8.752, TNS -58,562.464 and a 3,735,040-byte bitstream. Mapped with the
merge it is 267 ALMs smaller -- 38,426 ALMs and 55,731 combinational ALUTs
against 38,693 and 56,108 -- and the fit ends after 02:06 with 188026 and
11802, "Fitter failed to successfully route the design", and no bitstream.

| rumble tree | map ALMs | LABs | setup (`emu`) | TNS | bitstream | fit |
|---|---|---|---|---|---|---|
| committed† | 38,693 | 4,118 | -8.752 | -58,562.464 | 3,735,040 | 01:25:59 |
| shared shifter | 38,426 | none | - | - | none | 02:06, failed |

So the one change that reduced mapped area helped neither tree: it cost
5.955 ns of worst setup slack on the committed tree and made the rumble
tree unfittable. Area is not what this cone needs, and on this design the
fit does not follow the map.



The TNS this row reports measures something the worst slack cannot.
All of it sits in the emu domain: -58,562.464, against -1.239 for
pll_hdmi and 0 for every other clock. TNS sums the failing endpoints;
-8.752 is one endpoint's minimum. Enumerating the 43,897 register nodes
that carry a setup path and taking each one's worst path counts 14,214
failing endpoints -- one endpoint in three -- whose slacks sum to
-58,564.977, the summary's -58,563.703 to within 1.274 ns, the
three-decimal rounding of the individual values. The rebuild's 10,000
worst paths, all between -8.752 and -7.935, end at only 56 of those
endpoints and contribute 0.8% of the sum, so the deepest failures are a
sliver. Setup slack can improve 0.254 ns while TNS grows 6,490.070 more
negative because the two numbers read different populations: one
minimum against fourteen thousand accumulated deficits. The row's own
report is gone, so how its population of endpoints compared cannot be
recovered; only its TNS total survives. TimeQuest 17.0 has no
unique-per-endpoint path option, so the count came from one worst-path
query per register node.

The endpoints that fail fall into two populations. By count the
renderer leads: 5,120 of the 14,214 failing endpoints sit in its
write bank, -21,601.065 ns in total, an average of -4.2 ns each.
The ARM9 register file holds the deepest: 6,017 arm9_core
endpoints carry -26,745.280 ns, with regs[11][11] at -8.752,
regs[9][11] at -8.694 and regs[3][20] at -8.448; arm7 adds 609
register and 388 r13/r14 endpoints. The spread is a bulge, not a
spike: 1,223 endpoints fail by under a nanosecond, 1,997 by one
to three, 8,555 by three to six, and 2,439 by six or more. The
worst path runs insn[1] through rp_ic, rs_amt and LessThan1 into
dp_b, two adders and Mux56, then Selector637 into regs[11][11]:
16 logic levels, 22.841 ns of data delay against a 14.917 ns
period, 62% of it interconnect with one 3.234 ns hop, behind
8.550 ns of clock network. At 67 MHz no such cone closes, and the
renderer write bank supplies the bulk of the rest at 4.2 ns over
budget on average.

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

`tools/area_audit.py` is how a row gets re-checked rather than believed: it
takes each finished fit's LAB, ALM and register counts, `emu` setup, TNS,
hold, worst hold, `pll_hdmi` slack and bitstream size from the directories
under `--builds` and from the ledger in `reports/fits.csv`, and matches every
table row in this file to one. `--record` appends a finished fit to that
ledger, and `build.bat` calls it after a successful flow, so a figure
survives the report directory being reused by the next fit. Against this
host it checks 54 rows, matches 38 and contradicts none. Ten rows carry a
dagger: those ran before the ledger existed, in directories a later fit
reused, so their figures survive only in this document and the pre-stamp
ones would not rebuild to them anyway. The dagger is the document saying a
row cannot be checked, as against one nobody has checked -- an unmarked
row with no report is still counted as a gap.

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
| t11† | 39,685 | 63 | 4,160 | 84.2/83.1/91.3 | -8.339 | -45,936.820 | 3,749,124 |
| t12, `t64` on DSP† | 39,884 | 67 | 4,186 | 87.7/85.8/93.8 | -8.618 | -39,865.075 | 3,780,460 |

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
| shipping† | 39,254 | 31,129 | 4,168 | 89.3% | -9.155 | 00:56:15 |
| register + router duplication off† | 39,254 | 29,492 | 4,168 | 84.8% | not run | 00:49:29 |
| `PLACEMENT_EFFORT_MULTIPLIER 4.0` | 39,254 | 31,394 | **4,159** | 90.0% | **-8.475** | 00:45:00 |
| that setting + the CRT video modes + the RAM expansion pak (the pak tree)† | 39,729 | 31,179 | 4,181 | 91.6% | -8.354 | 00:50:53 |
| that + the firmware shadow's flag in its block RAM (today's tree)† | 39,083 | 30,691 | 4,154 | 79.8% | -8.376 | 00:46:36 |

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

## The motion pak, measured (2026-11-14)

The slot-2 motion pak in `main_bus` (OSD bit 96) is a five-bit counter, a
17-step byte sequence, a 64 KB window decode, a byte-enable test and
three 8-bit axis values from the pad's sticks with a deadzone. Measured
on the same tree, macros and `SEED 2` as the fitter-noise section (stamp
261108), against that section's 4,157-LAB baseline:

| | baseline | with the pak |
|---|---|---|
| LABs | 4,157 / 4,191 | 4,142 / 4,191 |
| registers | 32,805 | 32,792 |
| `emu` setup slack | -8.210 | -8.417 |
| `emu` TNS | -49,244.967 | -56,615.113 |
| worst hold | +0.158 | +0.216 |
| peak interconnect | 90.5 / 90.0 / 94.4 % | 86.2 / 85.8 / 90.6 % |
| rbf | 3,748,048 | 3,765,048 bytes |

The design fits at this seed with 49 LABs spare instead of 34, and the LAB
and register counts moved down slightly.

### Across seeds

Seeds 4 and 5 on the same tree, one full compile each, to see how much of
the difference above belongs to the seed rather than the logic:

| seed | result | LABs | `emu` setup | `emu` TNS | worst hold |
|---|---|---|---|---|---|
| 2† | fits | 4,142 | -8.417 | -56,615.113 | +0.216 |
| 4 | failed to route (188026 / 11802) | -- | -- | -- | -- |
| 5 | fits | 4,132 | -10.975 | -56,916.851 | +0.256 |

The seed moves the setup slack by 2.558 ns between the two that route,
which is far more than the 0.207 ns the pak costs at a fixed seed, so
setup slack here is the seed's number before it is the design's. The
`emu` TNS is the opposite: -56,615 and -56,917 are 0.302 ns apart, and
both sit about 7.4 ns below the -49,245 the baseline tree measured at
`SEED 2`, so that change is the pak rather than the seed and is the one
number in this section worth acting on.

Seed 4 joining seeds 1 and 3 in failing to route is the other result:
three of five seeds fit. Seed 4 also reports a peak virtual memory of
9,365 MB on an 8 GB machine, so a failing seed is slow as well as
useless. One intermediate build in this directory produced a
3,679,032-byte rbf while the assembler still reported a compression ratio
of 1; that does not fit the reading and was not investigated.

## Slot-2 RAM expansion sizes (2026-11-15)

The row now picks Off / 8 MB / 16 MB, and the sizes are real: the pak
window at 0x09000000 grows from 0x09000000..0x097FFFFF to
0x09000000..0x09FFFFFF, and the SDRAM behind it moved down to make room.
What the 32 MB module actually holds, from the RTL rather than a datasheet:

| region | SDRAM halfwords | size |
|---|---|---|
| cart save data | 0x000000..0x0FFFFF | 2 MB reserved (M4) |
| main RAM | 0x200000..0x3FFFFF | 4 MB |
| palette/OAM overflow | 0x400000..0x4FFFFF | 2 MB reserved |
| VRAM banks | 0x600000..0x6B0000 | about 0.7 MB of an 8 MB reservation |
| expansion pak | 0x700000..0xFFFFFF | 18 MB |

The VRAM banks are what made this possible: `vram_arbiter` places them
from 0x600000 and `pbase` reaches only 0x90000 + 128 KB, so the 8 MB once
reserved for them was 7 MB of empty space. Moving the pak base from
0xA00000 to 0x700000 turns the old 8 MB region plus the 4 MB above it
into 18 MB, which is what a 16 MB pak needs.

That base now depends on a number in another module, so it is guarded:
`vram_arbiter` names the bank map's ceiling (`VRAM_SDRAM_TOP`, 0x6B0000)
and `tools/check_memmap.py` reads both it and `EXP_SDRAM_BASE` from the
RTL, failing if the pak base ever drops to or below the banks, or if less
than 64 KB separates them. Today the headroom is 0x50000 halfwords
(640 KB).

32 MB cannot come from that module at all: the pak alone is 16M
halfwords, the whole chip, and its window runs from 0x09000000 to
0x0AFFFFFF. So the 32 MB size is backed by DDR3 instead. The cart ROM
already lives there, and `ddr_bus_bridge` carries one 64-bit line per
transaction, so `exp_ddr` turns one halfword access into one line request
at line 0x200_0000 (256 MB in, past anything a cart slot can address) and
`ddr_arb` lets the pak and the cart take turns on that port. main_bus
keeps driving its usual held halfword request, and NDS.sv routes it to
`exp_ddr` instead of `mem_arbiter` when the size is 32 MB, so the bus
state machine never learns which memory answered.

The bus holds `req` across both halves of a 32-bit access, so `exp_ddr`
treats "the offset changed while `req` was still high" as the next beat
rather than waiting for `req` to drop; without that the second half would
stall forever.

What it costs, measured in `tb_exp_ddr` rather than estimated: one
halfword takes 6 clk_sys from `req` to `done` against a bridge that acks
in 2, and 12 against one that acks in 8, so the shim's own share is 4
clk_sys and does not follow the bridge. On top of that sits the DDR3 line
time, which these benches do not model.

The shim keeps two lines: the one the last access used, and the line
after it once the bus has been quiet for 8 cycles. A line is four
halfwords and `main_bus` asks for two per 32-bit access, so the second
half is a hit -- the bench counts one transaction for one `ldr` where it
counted two -- and a prefetched line answers in 2 clk_sys against 6 for
the fetch it replaces. The prefetch waits for that quiet period on
purpose. Firing at the first free cycle would put a fetch in front of
the next real access, and take a line from the cart, to gain nothing
while the port is already busy: `tb_pak_worst`, whose cart re-requests
every free cycle, never leaves an 8-cycle gap, so the cache leaves what
that bench measures alone bar one warm hit.

Stores are collected rather than sent one halfword at a time. `main_bus`
presents a 32-bit store as two halfword beats, so the shim holds the first
and merges the second into it, and the bench counts one line for the pair
where it counted two, with the merged enables reading 0x0F. A write is
answered in 2 clk_sys at either bridge latency, because nothing about it
waits for the port. The collected bytes go out before anything that would
read the line, before a write to a different line, and on their own when
the bus has been quiet for 8 cycles -- a lone halfword store that nothing
follows still reaches DDR3, which the bench checks by reading it back
after an idle gap. Writes also land in the cached copy of that line, so a
read that follows a store sees it without a fetch.

What contention adds is measured too, in `tb_pak_worst`, which runs the
real shim and arbiter against a 7-cycle line and a cart that re-requests
every free cycle: 12 clk_sys for a lone access, 19 worst and 16 mean
under that load, with the cart completing 14 lines across 8 pak accesses.
The mean is the one number the cache moves there, and it moves it by one
warm hit: the lone access fetches line 0, and the first streamed access
is then served from it. Nothing else in that bench is touched, because a
cart asking on every free cycle never lets the bus go quiet.
So the pak waits for about one cart line, not for a burst, which is what
the alternation is for. Both numbers scale with the line latency the
model is given; the 7 is `tb_ddr_bridge`'s model, not the DDR3 controller.

The DDR3 split has a guard as well: `check_memmap` now reads the pak's
line base and the cart's own line mapping (`{boot_slot, win_addr[25:3]}`)
and fails if the base ever drops inside the cart's range, and
`tools/test_check_memmap.py` breaks each split in turn to prove the guard
refuses it.

Lane arithmetic keeps a halfword inside one line (an
even offset never straddles two), so a partial write needs no
read-modify-write: the byte enables go to the DDR controller and it masks
the line write.

The pak's twelve window checks run twice: once against a mock that answers
the bus directly, and once -- compiled with `-DPAK_REAL` -- against this
shim, where the same words have to come back through the line cache, the
write buffer and the port handshake. That second run is what ties the
window tests to the hardware path; the mock alone would pass with a shim
that never issued a DDR3 access at all.

At 0x0A000000 the 32 MB pak covers the page this core gives the motion
pak, so that size shadows it -- a slot cannot hold both devices at once.
MiSTer's dual-SDRAM mode does not help here and is not used: it
repurposes the DDR3 pins, which this core drives as DDR3 for the cart.

Fit of the tree with the 32 MB pak, its line cache and its write buffer,
`SEED 2`, stamp 261115: 4,157 / 4,191 LABs (34 spare) and 39,119 / 41,910
ALMs, 33,283 registers, `emu` setup -8.751, TNS -54,941.052, worst hold
+0.259, rbf 3,738,524 bytes, 01:06:02 wall clock, no fitter or assembler
error.

Narrowing the shim's datapath -- a halfword out of a cached line and a
beat out of the store buffer as four-way 16-bit muxes instead of 64-bit
barrel shifters, and the flushed store merged into a cached copy by mask
instead of an eight-way byte loop -- is what moved the row above off the
one before it: 4,170 to 4,157 LABs, 39,214 to 39,119 ALMs, 33,358 to
33,283 registers. It buys 95 ALMs and 75 registers and gives back setup
slack, -8.266 to -8.751, with TNS 1,124 deeper and the bitstream 1,888
bytes larger. The trade was made for routing headroom, not for area: on
the same settings the seed that used to run out of routing now fits (see
the sweep below).

The write buffer was tried in a compact form too, and put back: two
halfword slots -- lane, data and byte enables each -- instead of a 64-bit
word with a byte mask, which is 29 fewer flops on paper. Built at `SEED 2`
it measured 4,174 / 4,191 LABs, 39,194 ALMs and 33,356 registers, against
4,157 / 39,119 / 33,283 for the form in the tree. Fewer flops, more
fabric: the fitter spent the difference duplicating the buffer for
routability, which is what it was already doing to the wide one. It also
moved setup the other way -- -7.917 and TNS -46,129.179 against -8.751
and -54,941.052 -- and took `pll_hdmi` from +0.157 to -0.470, so it is
not a change this tree can afford for 17 LABs of margin. The wide form
stays.

Moving the two cached lines into M10K was considered against that and not
taken. It would pull 128 registers out of the fitter's way, but a block
RAM read is registered: a hit would answer in 3 `clk_sys` instead of 2,
and the shim's own cost would go from 4 to 5, which is the property the
cache exists to protect. Trading a cycle on every hit for 128 of 4,157
LABs is the wrong side of that trade on a part that is 99 % full of
routing, not of registers.

The same tree before the write buffer, and before that narrowing, fitted
at 4,172 / 4,191 LABs, 32,642 registers, -8.248 / -48,507.556, hold
+0.248 and 3,733,660 bytes, so the buffer and the narrowing together cost
641 registers, give back 15 LABs, and move TNS 6,433 deeper -- at this
fill, inside what the sweep below shows seeds doing to each other. The 8/16
MB-only tree before the DDR3 path fitted at 4,122 LABs, -9.575 /
-54,038.768 with 32,605 registers -- recorded when that tree was built
at `3f91bda`, not rebuilt for this comparison -- so everything behind
the pak, cache and write buffer included costs 35 LABs, and setup is
0.824 worse than that baseline (-8.751 against -9.575).

The motion pak section above was measured before any of this, so its LAB
count is not comparable with these.

### Across seeds

Every `hold` column below is the `emu` domain's hold slack; above, a table
whose hold is the worst across every clock says `hold (worst)` in its
header.

Four seeds, each a full compile of the tree before the two bank writes were
captured:

| seed | LABs / 4,191 | ALMs | registers | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 4,146 | 38,376 | 32,757 | -7.777 | -45,942.094 | +0.251 | -0.370 | 3,679,600 | 52:13 |
| 2 | 4,152 | 38,243 | 32,551 | -8.639 | -43,118.502 | +0.254 | +0.016 | 3,707,912 | 52:01 |
| 4 | 4,151 | 38,301 | 32,590 | -8.034 | -49,973.143 | +0.250 | -0.061 | 3,754,852 | 1:09:44 |
| 5 | 4,150 | 38,303 | 32,693 | -8.295 | -48,901.867 | +0.242 | -0.033 | 3,743,120 | 59:47 |

All four fit, with 45, 39, 40 and 41 LABs to spare. Nothing fails that
did not fail before: seed 2 closed the video path, and seeds 5, 4 and 1
missed it by 0.033, 0.061 and 0.370.

The same four seeds on the tree before the deferred link-register write,
kept because the paragraphs below quote it:

| seed | LABs / 4,191 | ALMs | registers | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 4,152 | 39,169 | 33,318 | -8.559 | -53,402.246 | +0.249 | -0.418 | 3,794,856 | 51:12 |
| 2 | 4,157 | 39,119 | 33,283 | -8.751 | -54,941.052 | +0.259 | +0.157 | 3,738,524 | 01:06:02 |
| 4 | 4,169 | 39,093 | 33,207 | -8.409 | -51,033.563 | +0.075 | -0.188 | 3,731,896 | 59:30 |
| 5 | 4,159 | 39,241 | 33,355 | -7.526 | -47,247.484 | +0.253 | -0.360 | 3,764,240 | 48:44 |

All four fitted there too, with 39, 34, 32 and 22 LABs to spare. They
differed by 17 LABs, 1.225 ns on setup, 7,694 on TNS and 0.184 ns on
hold, and the spread did not follow the order of the seeds: seed 5
closed highest at -7.526, seed 2 lowest at -8.751, seed 4 tightest on
hold at +0.075. Comparing the two tables is the point of keeping both:
the `emu` column reordered -- seed 1 best at -7.777 where it was -8.559,
seed 5 third where it was best -- so setup at this fill follows the seed
and a change to the tree reshuffles the rows instead of shifting them
together.

`pll_hdmi` is the one path that does not clear on most of them: +0.157 on
seed 2, then -0.188, -0.360 and -0.418 on seeds 4, 5 and 1. That is the
closest thing to a failure in the table, and on that tree the seed the
`.qsf` names was the one where it closed.

Where the path is: the worst of them is `ascal|o_vcpt_pre3[3]` to
`ascal|o_fload[1]`, both on the 148.54 MHz video clock -- 6.203 ns of data
delay and -0.517 of skew against a 6.732 ns period. That is the
framework's scaler (`sys/ascal.vhd`), not this core's logic, and the delay
is nearly all routing, which is what 99 % fill leaves the fitter to work
with.

`SYNTH_TIMING_DRIVEN_SYNTHESIS`, which the `.qsf` had off, was tried
against it and does not fix it: at seed 1 it takes `pll_hdmi` from -0.418
to -0.228 and `emu` setup from -8.559 to -8.254, and at seed 2 it takes
`pll_hdmi` from +0.157 to -0.259, so it moves the path both ways and the
sign of the answer depends on the seed. It costs LABs (4,152 to
4,164 at seed 1, 4,157 to 4,167 at seed 2) and about 200 registers, while
`emu` setup improves on both (-8.559 to -8.254, -8.751 to -7.774) and
TNS improves by 12,245 at seed 2. The setting stays off because, on that
tree, the path it was reached for is the one it makes worse.

Timing-driven synthesis on the tree with the deferred link-register write
was measured at seeds 3 and 6, both with it on:

| seed | LABs / 4,191 | ALMs | registers | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| 3 | 4,118 | 38,203 | 32,140 | -9.381 | -44,749.704 | +0.250 | +0.150 | 3,755,072 | 55:14 |
| 6 | 4,143 | 38,159 | 32,193 | -8.212 | -42,160.637 | +0.235 | +0.047 | 3,719,736 | 44:54 |

Both fit, with 73 and 48 LABs to spare, and both close the video path.
That is the seed and not the switch, and seed 2 built both ways on this
tree is what says so:

| seed 2 | LABs | ALMs | registers | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| switch off | 4,152 | 38,243 | 32,551 | -8.639 | -43,118.502 | +0.254 | +0.016 | 3,707,912 | 52:01 |
| switch on | 4,153 | 38,195 | 32,234 | -8.115 | -41,635.751 | +0.251 | -0.186 | 3,724,716 | 45:53 |

One setting between them: the switch buys 0.524 ns of `emu` setup, 317
registers, 48 ALMs and 1,483 of TNS, and spends 0.202 ns of the video
path paying for it -- the endpoint it was reached for. So the runs at
seeds 3 and 6 close because those seeds place the path, not because the
switch helps it, and the direction matches the old tree: at seed 2 the
switch moved `pll_hdmi` from +0.157 to -0.259 there and from +0.016 to
-0.186 here. The setting stayed off.

The same two seeds were fitted again after both bank writes were captured,
with timing-driven synthesis still on:

| seed | LABs / 4,191 | ALMs | registers | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| 3 | 4,096 | 37,552 | 32,042 | -8.329 | -40,481.898 | +0.248 | +0.013 | 3,702,672 | 48:51 |
| 6 | 4,092 | 37,463 | 32,005 | -7.858 | -42,407.109 | +0.252 | +0.138 | 3,686,540 | 1:01:56 |

Both fit with more room than any row above -- 95 and 99 LABs spare, where
the four-seed sweep's best was 45 -- and 116 and 205 fewer ALMs than the
shipped seed. Both close the video path, seed 6 by 0.138 ns against seed
3's 0.013, where the shipped seed 2 with the switch off misses it at
-0.064. On `emu` setup the two seeds land 0.471 apart (-8.329 and -7.858)
and 1,925.211 apart on TNS, and both are shallower than seed 2's -8.907;
both also carry about a thousand fewer registers, 32,042 and 32,005
against 33,043.

That is a seed comparison as much as a switch comparison, so seed 2 was
built both ways on this tree:

| seed 2 | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| switch off (shipped) | 4,125 | 37,668 | 33,043 | -8.907 | -44,808.642 | +0.254 | -0.064 | 3,695,232 | 1:03:38 |
| switch on | 4,092 | 37,559 | 31,959 | -7.940 | -45,601.081 | +0.252 | -0.207 | 3,726,460 | 47:42 |

One setting between them, and it is the trade the old tree showed: 0.967 ns
of `emu` setup, 33 LABs, 109 ALMs, 1,084 registers and 15:56 of wall, paid
for with 0.143 ns of the video path (-0.064 to -0.207), 792.439 of TNS and
31,228 bytes of bitstream. The switch is not a way to close the video path
on this tree either -- it spends the endpoint it was reached for, as it did
at +0.016 to -0.186 before the deferred link register.

What closes it is the seed: seed 6 reaches the same 4,092 LABs with the
switch on and lands the video path at +0.138, and its `emu` setup is 0.082
better than seed 2's with the switch on (-7.858 against -7.940). So on this
tree seed 6 dominates seed 2 in both configurations -- fewer LABs than the
shipped seed, a shallower `emu` path than either seed-2 build, and the only
one of the three that closes the video path.

The configuration was left as it stood, and `NDS.qsf` named seed 2 with the
switch off until the RTC row at the end of this file moved it to seed 4.
Moving to seed 6 would have needed a recorded bitstream and the board -- the
seed does not change the benches, and this fit changed nothing but the two
settings.

That a path at 99 % fill can be moved half a nanosecond by a synthesis
switch, in either direction, is the honest reading: this one is not a
constraint mistake that a knob corrects. Closing it on every seed means
pipelining inside `ascal` or running the scaler on the 1x pixel clock
instead of the 2x it uses; both change video timing, and neither can be
checked without the board. Nor is gate-level timing simulation an
alternative on this install: `quartus_eda NDS --simulation --tool=modelsim
--format=verilog` writes `simulation/modelsim/NDS.vo` in 22 seconds, but the
writer reports `Warning (10905)` that the functional netlist is the only type
this device supports, so there is no `.sdo` to back-annotate. Static timing
analysis and the bench suite are what this machine can check; the board is
the rest.

The store buffer was tried as the same kind of lever and also refused.
Dropping the cached copy of a line instead of merging the store into it
takes a 64-bit mask and two 64-bit merges out of the shim, and the bench
still passes with the read after a store refetching the line. At seed 4 it
came out worse on every axis: 4,169 to 4,172 LABs, 39,093 to 39,221 ALMs,
33,207 to 33,341 registers, `emu` setup -8.409 to -9.672, TNS
-51,033.563 to -58,463.849, `pll_hdmi` -0.188 to -0.299. The muxes it
removed were shared with the read path, so the fitter had been paying for
them once; the refetch cost is real and the saving was not. Reverted.

For `emu` setup the same holds. Its worst path at seed 4 ran from
`arm9|insn[12]` to `arm9|r14_b[1][18]`, -8.409: an instruction bit reaching
the link register's write enable and the bank behind it, inside one 14.9 ns
cycle at 67.0274 MHz. Nothing settable from the `.qsf` shortens that --
timing-driven synthesis gets -7.774 at seed 2 and -8.254 at seed 1 and
takes the video path with it.

The register itself was worth attacking, and it worked. `insn[12]` is Rd[0]
deciding whether a write lands in the banked link register, and it reached
85 cells before touching `r14_b[1][18]`; the fitter was duplicating decode
to meet a cone that starts at the instruction word. `insn` is only valid
for the execute cycle, so there is no spare state to move the write into
without putting a bubble in front of every instruction. Instead the select
is captured in a register (`lr_v`, `lr_m`, `lr_val`) and committed on the
next edge, with the four readers of the bank taking the pending value
through `lr_rd` -- so the compare starts at a flip-flop instead of the
instruction word and the architecture sees exactly what it saw before.

At seed 4 that is 4,169 to 4,151 LABs, 39,093 to 38,301 ALMs, 33,207 to
32,590 registers, `emu` setup -8.409 to -8.034, TNS -51,033.563 to
-49,973.143 and `pll_hdmi` -0.188 to -0.061, for a bitstream 22,956 bytes
larger and a flow of 1:09:44 against 59:30. The four-seed table above was
measured before this change and is left standing as it was; seed 4 is the
row that shows what it did.

Seed 2, the shipped one, was rebuilt on this tree afterwards: 4,152
LABs / 4,191, 38,243 ALMs, 32,551 registers, `emu` setup -8.639, TNS
-43,118.502, hold +0.254, `pll_hdmi` +0.016, 3,707,912 bytes, 52:01. The
video path still closes, by 0.016 ns where the old row had 0.157, and
`emu` setup and TNS both move the good way against that row (-8.751 to
-8.639, 11,823 shallower), so the deferred write did not cost the shipped
seed the one domain it was closing.

Which path is next was measured on that same seed-2 fit. The worst `emu`
setup path is no longer the link register: it runs from
`arm9|regs[4][29]` to `r8u_b[2][10]`, -8.639, through 25 cells and 25
hops, 22.733 ns of data path against a 14.917 ns relationship. 17.174 of
those nanoseconds are routing, 0.69 a hop, and the hops walk from X29 to
X27 to X19 and back to X29; the remainder is 25 cells, mostly the
register-file read mux (`rp_c[29]`) and the `t32b` decode, with the
fitter's own LUT (`OTERM1910`) in front of the banked write. So this one
is both deep and spread: the same shape as the video path, one level
further in, and `r8u_b` is the user-mode r8..r12 bank taking the same
instruction-driven write select that `r14_b` took.

Whether that select is worth attacking was measured on the same fit, not
assumed. Of the 200 worst `emu` setup paths, 200 start at `regs[...]` and
none at `insn[...]`, and the worst path that does start at the
instruction word is `arm7|insn[0]` to `arm7|r13_b~154` at -7.728 -- 0.911
ns clear of the worst path and better than every one of the 200. So the
select cone is not on the failing list: the 25 cells of the worst path
carry value from the register file into the bank, and deferring a write
select there -- the change that took `r14_b` from -8.409 to -8.034 --
would shorten a path that already clears the failure by 0.9 ns. The next
lever for `emu` setup is placement or a stage in the read path, not
another deferred select.

A LogicLock region around the ARM9, the obvious next try for those 17 ns
of routing, cannot be measured here. This install is Quartus Prime Lite
17.0, and the mapper reports Critical Warning (140003) twice -- once per
stage -- that the licence does not support LogicLock regions and that
the software removes them automatically. The assignment syntax itself is
accepted, which is what made the first attempt look possible: region
properties take `-section_id` (`LL_ENABLED`, `LL_AUTO_SIZE`, `LL_STATE`,
`LL_CORE_ONLY`) and membership takes both `-to` and `-section_id`, so the
project parses and fits with the block in the `.qsf`. It is deleted
before placement, which means the build is seed 2 again and says nothing
about the routing. A floorplan needs a subscription licence; on this
machine the placement half of the `emu` question is out of reach, and
only the stage in the read path is left measurable.

Seed 5 is the one that changed sides. On the tree before the shim's
datapath was narrowed it packed 4,129 LABs and then ran out of routing,
43:53 in, reporting 188005 (excessive demand for the available routing)
and 11802 (cannot fit). It now routes. What the shim gave up to get there
is the two 64-bit barrel shifters that pulled a halfword out of a cached
line and a beat out of the store buffer, each now a four-way 16-bit mux,
and the eight-way byte loop that folded a flushed store into a cached
copy, now a mask and a merge.

The LAB count alone does not show the edge: the rows above read 98 or
99 % either side of the narrowing, and the two seeds fitted before it did
so by 21 and 28 LABs. That is why the sweep is worth running after every
change to the tree.

A seed's outcome is not a property of the seed -- seed 4 failed to route
on the tree before the expansion work and fits here -- so a sweep says
what this tree does at the edge, not what a seed will always do. It is
also not stable to the run: seed 5 was built twice here, and the second
build repeated its counts to the register (4,159 LABs, 33,355 registers,
-7.526) while its wall time moved from 01:21:54 to 48:44 under a
different load. Counts and slacks are reproducible; minutes are not.

### Staging the bank writes, measured (2026-11-18)

The two failing bank writes took the link register's treatment: the select
and the value are captured and committed on the next edge, and the readers
take the pending entry. On the ARM9 that is `r8u_v`, `r8u_i` and `r8u_val`,
read back through `r8u_rd` by the user-bank read port and by the FIQ
swap's entry branch; the bulk `SWAP8` still writes the bank directly,
because it replaces all five entries at once and its path carries no read
mux. On the ARM7 it is `lr_v`, `lr_m` and `lr_val`, read back through
`lr_rd` by the four readers of `r14_b`, and BL's link write fills the same
registers instead of the bank. The link-register commits sit at the top of
their clocked block, so an exception entry -- which writes its own bank
later in the same block -- still wins the edge. The user-bank commit is
deliberately the last statement in its block instead: it belongs to the
instruction before the current one and has to outrank the FIQ entry swap,
which copies the `regs` shadow in and never saw an LDM or STM with S=1.

| seed 2, TDS off | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| link register captured | 4,152 | 38,243 | 32,551 | -8.639 | -43,118.502 | +0.254 | +0.016 | 3,707,912 | 52:01 |
| both bank writes captured, immediate port | 4,125 | 37,668 | 33,043 | -8.907 | -44,808.642 | +0.254 | -0.064 | 3,695,232 | 1:03:38 |

Both paths the change was reached for are gone: of the 30 worst `emu` setup
paths on the new fit, none ends at `r8u_b` or `r14_b`, where the previous
fit's worst path was `arm9|regs[4][29]` to `r8u_b[2][10]` at -8.639. What
replaced it is the write into `regs` itself -- `arm9|rp_ic[2]~3` to
`arm9|regs[13][7]`, -8.907 -- which is the register file's one write port
and cannot be deferred without putting a cycle in front of every
instruction.

Seed 6 places that wall from a different start and keeps it: its worst `emu`
path is `arm9|insn[26]` to `arm9|regs[1][20]` at -7.858, 21.956 ns of data
delay against the same 14.917 ns relationship, and all 30 of its worst paths
end at a `regs` write. None ends at `r8u_b` or `r14_b`, so the captures hold
at that seed too; only the margin moves. That is why the seed is a decision
about where the wall sits, not a fix for it.

The fitter also warns once per build that `r8u_b` is assigned but never read.
It is read: the bank appears in the map report as 32-bit `r8u_b[n][m]` cells,
and `tb_arm9`'s STMIA^ and LDMIA^ cases write it and read it back. The front
end does not follow the read through `r8u_rd`, so the warning is a tool
artefact rather than a bank that optimised away.

So the fit moves the wrong way by 0.268 ns of `emu` setup and 1,690.140 of
TNS while using 27 fewer LABs (66 spare instead of 39), 575 fewer ALMs, 492
more registers and a 12,680-byte smaller bitstream. The video path moved
from +0.016 to -0.064 on the same `ascal|o_vcpt_pre3` endpoints, so seed 2
no longer closes it on this tree. Neither number is attributable to the
captures at this fill -- the netlist changed and the seed places it again --
but both are what that build does, and the LAB margin is the one
that decides whether the next change fits at all. The bench suite is 47
step(s), 47 passed, 0 failed with both captures in.

### Seeds on the bank-write tree (2026-11-18)

Four seeds fitted from the tree that carries both bank writes, at the
shipped timing switch and placement effort, so the rows differ in
nothing but the seed:

| seed | LABs / 4,191 | ALMs | registers | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 4,123 | 37,711 | 32,966 | -8.694 | -45,129.477 | +0.239 | -0.313 | 3,714,024 | 47:39 |
| 2 (shipped) | 4,125 | 37,668 | 33,043 | -8.907 | -44,808.642 | +0.254 | -0.064 | 3,695,232 | 1:03:38 |
| 4 | 4,140 | 37,657 | 33,002 | -8.167 | -48,683.455 | +0.248 | +0.075 | 3,719,728 | 55:54 |
| 5 | 4,129 | 37,731 | 33,036 | -8.426 | -47,619.350 | +0.252 | -0.182 | 3,695,044 | 1:02:26 |

All four route. The `emu` domain fails at every seed, between -8.167 and
-8.907; what its worst path is was measured at seeds 2 and 6 above, and
nothing here moves it, because the seed cannot move a wall that the
netlist built. The seed does move the number by 0.740 ns, which is the
size of the effect a single fit would otherwise attribute to the change
that shares its tree.

Area moves by 17 LABs across the four (4,123 to 4,140), less than the 66
LABs of headroom the seed-2 fit leaves. The seed that uses the most of
it -- 4 -- is also the only one that closes the video path, at +0.075
where seed 2 on that tree sits at -0.064: 15 LABs and 0.740 ns of `emu`
setup for a path that clears instead of missing. That is not a free
switch of the shipped seed, because the release was measured at seed 2
and a shipped-seed change has to be run through the release path, not
read off this table.

The wall times spread from 47:39 to 1:03:38 for the same work, so they
are machine load rather than the seed; the counts and the slacks are the
seed's.

### Driving the write port from flops (2026-11-18)

The `emu` domain failed on paths into the register file's write port, so
the single-register decode sites now capture their value and the port is
committed from flops on the next edge. Every converted site ends in
`S_FETCH`, which reads no general register, so the value is in `regs`
before the next instruction decodes. Both fits are seed 2, timing-driven
synthesis off, placement effort 8.0:

| seed 2, TDS off | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| both bank writes captured, immediate port | 4,125 | 37,668 | 33,043 | -8.907 | -44,808.642 | +0.254 | -0.064 | 3,695,232 | 1:03:38 |
| both bank writes captured, ARM7 port immediate | 4,126 | 38,603 | 31,618 | -6.715 | -25,738.048 | +0.245 | -0.042 | 3,749,628 | 1:12:46 |

`emu` setup moves 2.192 ns and TNS 19,070.594 in the fit's favour with
the seed, the switch and the effort unchanged. The seed alone moved setup
by 0.740 ns on the tree before this one, so 2.192 ns is more than a
placement roll. A standalone `quartus_sta` probe of the fit says where it
went: all 30 of the worst `emu` setup paths end at `arm7|regs`, led by
`arm7|insn[3]` and `arm7|insn_thumb` into `arm7|regs[6][20]` at -6.715,
20.789 ns of data delay against the 14.917 ns relationship. None of the
30 touches the ARM9's register file or `r8u_b`, where the previous fit's
worst path ended, so the ARM9 write port left the wall -- and the same
wall now sits on the ARM7, which still writes its register file
immediately.

Area is close to a wash: one LAB more, 65 spare instead of 66, 935 more
ALMs and 1,425 fewer registers. The deferred port is 41 flops --
`pw_en`, `pw_sel`, `pw_val` and `pw_mode` -- so the rest of the design
lost 1,466 registers as the decode left the bank. The bitstream is
54,396 bytes larger, hold is 0.009 ns tighter, the video path improves
0.022 ns and still misses at -0.042, and the fit took 9:08 longer.

Seed 4 was fitted on this tree as well, because it was the one seed that
closed the video path on the tree before it. It does not repeat that here:

| seed 4, TDS off | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| seed 4 on this tree | 4,144 | 38,678 | 31,642 | -7.127 | -31,937.036 | +0.245 | -0.337 | 3,732,324 | 53:46 |

Eighteen more LABs, 47 spare instead of 65, and worse on both slacks:
0.412 ns of `emu` setup and 0.295 ns of the video path. The seed that
closed the video path on the tree before this one does not close it here,
which is the sweep's point seen from the other side: a seed's outcome
belongs to the tree it places, not to the seed. The shipped seed stays 2.

The bench suite was run against this tree before the fit: 47 step(s), 47
passed, 0 failed.

That was the tree the core shipped from for one fit. The `(shipped)` tags
in the tables above name the settings -- seed 2, timing-driven synthesis
off, effort 8.0 -- which have not changed; the figures beside them are the
tree before this change. The ARM7's port came next, below.

### Driving the ARM7 write port from flops (2026-11-20)

The probe above left the wall on the ARM7: all 30 of that fit's worst
`emu` paths ended at `arm7|regs`, led by `arm7|insn[3]` into
`arm7|regs[6][20]` at -6.715, while the ARM9's port -- already moved
behind flops -- had left the list. The same treatment goes to the other
core now: 15 single-register decode sites capture their select and value
into `pw_en`/`pw_sel`/`pw_val`/`pw_mode`, and the port is committed on
the next edge. Each of them ends in `S_FETCH`, which reads no general
register, so the value is in `regs` before the next instruction decodes.
The four sites that write two registers from one instruction -- a long
multiply's pair, a load with its writeback -- keep the immediate port,
because one pending write cannot carry both. Both fits are seed 2,
timing-driven synthesis off, placement effort 8.0:

| seed 2, TDS off | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| ARM9 port from flops, ARM7 immediate | 4,126 | 38,603 | 31,618 | -6.715 | -25,738.048 | +0.245 | -0.042 | 3,749,628 | 1:12:46 |
| both bank writes captured, ARM7 port from flops | 4,105 | 37,529 | 31,713 | -5.207 | -18,145.820 | +0.255 | +0.109 | 3,726,228 | 49:07 |

Every column moves the right way this time: 1.508 ns of `emu` setup,
7,592.228 of TNS, 21 LABs (86 spare of 4,191 instead of 65), 1,074 ALMs,
23,400 bytes off the bitstream and 23:39 off the flow, for 95 more
registers. The video path clears at this seed for the first time, -0.042
to +0.109, and its worst path is a different one: `ascal|o_vcpt_pre3`
is out of the top five, which `ascal|o_v_hmin_adj[11]` into
`ascal|o_radl3[11]` now leads at +0.109.

A `quartus_sta` probe of the new fit says where the wall went, and it is
not the same wall. All 30 of the worst `emu` paths now *start* at the
ARM9's register file -- `arm9|regs[4][15]`, `arm9|regs[1][8]`,
`arm9|regs[6][8]~DUPLICATE` -- and end in the operand mux behind it,
`arm9|rm_val[30]~60_OTERM5278` and `arm9|rp_c[30]~130_OTERM5246`, led by
-5.207 with 19.324 ns of data delay against the 14.917 ns relationship.
None of them touches the ARM7's register file any more. That is a read
path, not a write port: the array drives the mux that feeds the shifter,
and no capture in front of a write address changes it.

One fit at one seed, so 1.508 ns is this build's number rather than a
repeatable effect: the seed spread measured two trees back was 0.740 ns
at a fixed tree, and this is twice that, but that spread belongs to
another netlist. What the fit does say without a sweep is that the ARM7
write port is nowhere in the worst 30.

The bench suite was run against this tree before the fit: 47 step(s), 47
passed, 0 failed.

That tree shipped for one fit; the ARM9's long multiply came next.


### The ARM9's long multiply, split across two states (2026-11-20)

The probe on the ARM7-port tree left its worst `emu` path on the ARM9's
long multiply: `regs[4][15]` through the `rp_c` read port into
`Mult1|ay[15]`, out through a DSP carry chain and the 64-bit `Add45`
chain into two write muxes, and on into the read-through mux of the
register it had just written -- 19.324 ns of data delay against a
14.917 ns relationship, 47 cells in 10 levels. Three quarters of that
is one cycle doing four things: read, a 32x32 product, a 64-bit
accumulate and two writes.

Both long-multiply groups -- UMULL/UMLAL/SMULL/SMLAL under `insn[23]`,
and SMLALxy -- now capture their operands where the instruction
decodes, `S_ML1` latches the product into `ml_p`, and `S_ML2` adds the
accumulator, sets N and Z and writes both halves. Real ARM9 silicon
takes five to six cycles for these; this takes three, and no longer
tries to take one. Both fits are seed 2, timing-driven synthesis off,
placement effort 8.0:

| seed 2, TDS off | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| ARM7 port from flops, one-cycle multiply | 4,105 | 37,529 | 31,713 | -5.207 | -18,145.820 | +0.255 | +0.109 | 3,726,228 | 49:07 |
| both bank writes captured, pad stylus only | 4,029 | 34,353 | 31,675 | -4.375 | -12,115.231 | +0.250 | +0.316 | 3,650,576 | 40:56 |

Everything moves the right way, and the area is the surprise: 76 LABs
and 3,176 ALMs come back, 38 registers with them, the bitstream shrinks
75,652 bytes and the flow 8:11. The registered multiplier is what the
fitter wanted -- the LUT partial-product tree it had built around the
DSP block goes away. `emu` setup gains 0.832 ns and TNS 6,030.589,
the video path 0.207 (to +0.316), and hold gives back 0.005.

`emu` still fails, and a probe of the new fit says why: the wall is no
longer the multiply. It starts at the flags -- `arm9|n` into `n~5`,
then `Selector995~6`, `cond_hold~0`, `Mux35` and `f~1` -- and runs
through `regs~194` into the read muxes (`regs[12][8]`,
`regs[12][21]`, `rm_val[21]`) for 18.493 ns in 10 levels. Three of
those hops are a single interconnect each, 2.169, 2.681 and 2.171 ns,
so the condition is being evaluated in the cycle the read happens and
the two sides of its mux sit far apart.

The label `both bank writes captured` is the one `area_audit.py
--check-shipped` looks for, so it stays on the shipped row; the name is
history, not this change. When the shipped tree moves again, the row it
leaves behind takes a qualifier and the new tree's row takes the name.

The bench suite was run against this tree before the fit: 47 step(s),
47 passed, 0 failed.

This was the tree the core shipped from until the pointer mode.

### Seeds on the split-multiply tree (2026-11-20)

Four seeds fitted from the tree that carries the two-state long
multiply, at the shipped timing switch and placement effort, so the
rows differ in nothing but the seed:

| seed | LABs / 4,191 | ALMs | registers | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 4,021 | 34,353 | 31,652 | -3.665 | -11,552.085 | +0.255 | +0.043 | 3,660,444 | 41:30 |
| 2 (shipped) | 4,029 | 34,353 | 31,675 | -4.375 | -12,115.231 | +0.250 | +0.316 | 3,650,576 | 40:56 |
| 4 | 4,049 | 34,329 | 31,684 | -4.140 | -14,485.416 | +0.240 | +0.331 | 3,631,904 | 42:16 |
| 5 | 4,050 | 34,360 | 31,694 | -3.560 | -11,760.407 | +0.249 | -0.082 | 3,591,320 | 42:06 |

All four route. `emu` fails at every seed, between -3.560 and -4.375,
and the 0.815 ns between the best and the worst is the size of the
effect a single fit would otherwise credit to the change sharing its
tree; the previous sweep measured 0.740 on its own tree. No seed closes
the domain, and the shipped seed is not the best one at it: 5 is
0.815 ns ahead and 1 is 0.710.

The seed moves the video path as well, and not in the order the `emu`
ranking would predict: 5 leads on setup and is the only seed that
fails the video path (-0.082), while 2 and 4 clear it at +0.316 and
+0.331 and 1 by 0.043. Three seeds of four close a path the bank-write
tree closed at one in four, and seed 2 keeps the widest margin of the
three that do.

The shipped seed stays 2. Seed 1 would buy 0.710 ns of `emu` and still
clear the video path, but `emu` fails at both, so that gain is a number
and not a fix, and it costs 0.273 ns of the video margin -- the path
that actually limits the release. A shipped-seed change also has to go
through the release path rather than be read off a table.

Area moves by 29 LABs across the four, against 162 spare. The wall
times spread from 40:56 to 42:16 for the same work, so they are machine
load rather than the seed; the counts and the slacks are the seed's.

### MUL, MLA and the Thumb MUL, split across two states (2026-11-20)

The long forms' two states were extended to the rest of the multiply
space: MUL and MLA in the ARM encodings, and the Thumb ALU's MUL, which
still computed their product in the cycle that decoded and wrote it. The
same states carry them now -- `ml_single` selects a 32-bit result from
`ml_a * ml_b`, `ml_rd` names the one destination, and the flags come from
the low word. The bench suite ran first: 47 step(s), 47 passed.

| seed 2, TDS off, effort 8.0 | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| both bank writes captured, pad stylus only | 4,029 | 34,353 | 31,675 | -4.375 | -12,115.231 | +0.250 | +0.316 | 3,650,576 | 40:56 |
| 32-bit multiplies split | 4,036 | 34,171 | 31,454 | -4.656 | -17,557.912 | +0.249 | +0.079 | 3,664,300 | 49:02 |

`emu` gains 0.281 ns, and the ARM9 stops limiting the domain at all:
the probe's worst paths now start at `cart_slot|hdr[45][6]` and run into
`arm7_core|Mux3~2`, and no multiply is among the four it reports. Area
comes back as well, 182 ALMs and 221 registers of it, for 7 LABs.

The video path gives back 0.237 ns (to +0.079), TNS 5,442 and the
bitstream 13,724 bytes, and `emu` still fails. That is the seed-1 trade
and the condition latch's trade a third time: margin on the path the
release is timed on is not spent on a gain that is not a fix. It was
reverted; the split belongs with whatever next frees the video path
rather than ahead of it.

### Latching the condition (2026-11-20)

The probe on the split-multiply tree named the condition check as the
worst `emu` path: `n` into the condition function, its mux, and then the
whole decode cone it gates. Latching the answer where the instruction is
fetched -- `cond_r`, taken from the same word the instruction comes from,
and tested by the decode instead of computed in it -- removes that path
outright. It is also the change that does not pay:

| seed 2, TDS off, effort 8.0 | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| both bank writes captured, pad stylus only | 4,029 | 34,353 | 31,675 | -4.375 | -12,115.231 | +0.250 | +0.316 | 3,650,576 | 40:56 |
| condition latched at fetch | 4,036 | 34,425 | 31,982 | -4.323 | -13,890.762 | +0.247 | +0.276 | 3,655,488 | 52:32 |

0.052 ns of `emu` setup, for 1,775.531 of TNS, 0.040 ns of video margin,
7 LABs, 72 ALMs, 307 registers and 4,912 bytes. `emu` fails either way
and `pll_hdmi` is the path the release is timed on, so this is the seed-1
trade again: a number that is not a fix, paid for on the limit. It was
reverted.

The probe on that fit also says the flagged path was not the wall by
itself. The new worst four are all between -4.16 and -4.32 and all start
at `blk_list`: bit 0 into the encoder that produces `blk_idx` (fanout 110
and 129 on its two cells), out through the register read mux into `dp_a`,
and into a register at the core's edge -- 18.396 ns of data delay in 10
levels for the first, and -4.211, -4.184 and -4.161 for the next three
from `blk_list[4]` and `blk_list[1]`. So the domain is limited by a
cluster that one deep path used to hide, and the list walk is where the
cluster sits: a 16-bit register into a lowest-set-bit encoder that drives
a read-port index.

### Placement effort above 8.0 (2026-11-18)

`PLACEMENT_EFFORT_MULTIPLIER` was swept up from the shipped 8.0 at seed 2,
on the tree with the deferred link register only, so the rows differ in
nothing but the multiplier:

| effort | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| 8.0 (shipped) | 4,152 | 38,243 | 32,551 | -8.639 | -43,118.502 | +0.254 | +0.016 | 3,707,912 | 52:01 |
| 10.0 | 4,147 | 38,243 | 32,677 | -7.557 | -42,383.255 | +0.253 | -0.208 | 3,707,004 | 1:04:18 |
| 12.0 | 4,147 | 38,243 | 32,677 | -7.557 | -42,383.255 | +0.253 | -0.208 | 3,707,004 | 55:30 |

The 12.0 row is not a rounding: the fitter says so itself -- `Warning
(170136): Design uses Placement Effort Multiplier = 12.0` -- and its
`NDS.rbf` is bit-identical to the 10.0 one, the same md5 over 3,707,004
bytes. Effort above 10.0 reaches nothing this design has, so 10.0 is the
top of the lever. It buys 1.082 ns of `emu` setup and 735.247 of TNS, and
costs 0.224 ns of the video path (+0.016 to -0.208), 5 LABs, 126 registers
and 12:17 of wall time. The video path is the one that fails first here,
so the shipped setting stays at 8.0.

The same lever measured on the tree with both captures does not pay. At
seed 2 with the switch off, effort 10.0 gives:

| effort, both captures | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| 8.0 (shipped) | 4,125 | 37,668 | 33,043 | -8.907 | -44,808.642 | +0.254 | -0.064 | 3,695,232 | 1:03:38 |
| 10.0 | 4,119 | 37,668 | 32,988 | -8.206 | -49,184.182 | +0.254 | -0.980 | 3,779,332 | 54:44 |

Every timing number moves the wrong way: 0.701 ns of `emu` setup, 4,375.540
of TNS, and the video path from -0.064 to -0.980 with 6.461 of TNS of its
own. That is the opposite of what the lever did before the captures (+1.082
on setup, +735.247 on TNS), so the effort multiplier is one more knob whose
sign belongs to the tree rather than to the setting. Six LABs come back and
the flow is 8:54 shorter; the shipped setting stays at 8.0.




### Placement effort on the split-multiply tree (2026-11-20)

The lever was last read on the tree with both captures, 4,890 ALMs larger
than this one; read again at seed 2 with nothing else changed:

| effort, seed 2, TDS off | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| 8.0 (shipped) | 4,029 | 34,353 | 31,675 | -4.375 | -12,115.231 | +0.250 | +0.316 | 3,650,576 | 40:56 |
| 10.0 | 4,026 | 34,353 | 31,617 | -4.253 | -13,873.489 | +0.248 | +0.198 | 3,633,520 | 42:25 |

The sign has not changed with the tree: `emu` gains 0.122 ns and the video
path gives back 0.118, TNS 1,758, the hold rows 0.002 and 0.051 (to
+0.199, still passing); 3 LABs, 58 registers and 17,056 bytes come off
and the flow runs 1:29 longer. What has changed is the size of the buy:
1.082 ns on the old tree, 0.122 here. Effort is no longer a lever on the
`emu` path at all -- the probe's worst four now start at
`arm7_core|pc[1]` and sit within 0.052 ns of each other -- so the shipped
setting stays at 8.0.

### The split multiplies at seed 4 (2026-11-21)

The split was read at seed 2, where it lost 0.237 ns of the video margin.
A seed-2 loss can be the seed rather than the change, so the same tree
was fitted again at seed 4 and read against the shipped tree's own
seed-4 row, which the seed sweep already holds:

| seed 4, TDS off, effort 8.0 | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf |
|---|---|---|---|---|---|---|---|---|
| both bank writes captured, seed 4 | 4,049 | 34,329 | 31,684 | -4.140 | -14,485.416 | +0.240 | +0.331 | 3,631,904 |
| 32-bit multiplies split | 4,021 | 34,172 | 31,540 | -4.079 | -14,479.457 | +0.253 | +0.276 | 3,694,880 |

Two of the three numbers that made it a loss at seed 2 do not survive
the second seed. `emu` gains 0.061 ns here against 0.281 there, and the
video path gives back 0.055 against 0.237, so most of that video cost
was where the fitter put the logic and not what the change built. The
sign does not move: the split still spends margin on `pll_hdmi`, the
path the release is timed on, to move a domain that fails either way.
TNS is 5.959 better and hold 0.013 better, 28 LABs, 157 ALMs and 144
registers come off the fit, and the bitstream gains 62,976 bytes for the
two states. 40:13 of wall against 40:56 on the shipped tree at seed 2 is
machine load and not the setting.

The rule that retired seed 1 and the condition latch is the rule here.
The split stays out until something frees the video path; after that all
three changes want reading together at one seed.

### Moving the block-transfer index into a register (2026-11-21)

After the condition latch went out, the probe's worst four `emu` paths
were within 0.16 ns of each other and all started at `blk_list`: bit 0
and bit 4 of the list walking sixteen terms into `blk_idx`, then through
a register read-port index into `dp_a` and a register at the core's
edge. The list is written in S_EXEC and first read in S_BLK, and the
beat that clears a bit is the beat that has to produce the next index,
so the walk can end in a flop. `blk_first` does that, and the two Thumb
stack forms now name their lists so the list and the index come from one
expression:

| seed 2, TDS off, effort 8.0 | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| both bank writes captured, pad stylus only | 4,029 | 34,353 | 31,675 | -4.375 | -12,115.231 | +0.250 | +0.316 | 3,650,576 | 40:56 |
| block index in a register | 4,024 | 34,007 | 31,772 | -4.024 | -17,931.123 | +0.254 | +0.167 | 3,615,508 | 39:07 |

The cluster is gone from the domain. The probe's worst six on the new
fit are all inside `engine_a|renderer_2d` -- `s_bpp8` and `shw[0]` into
`wbank` -- and sit within 0.019 ns of each other, with no path naming
`blk_list`. So 0.351 ns of `emu` setup is that walk's whole share of the
domain, and what is left under it is the read-port mux in front of
`dp_a`, which the probe does not name in its first six.

It is still the same trade. The video path gives back 0.149 ns -- less
than the split's 0.237 and more than the latch's 0.040, but the same
direction -- TNS is 5,816 the wrong way, and `emu` fails either way. 5
LABs, 346 ALMs and 35,068 bytes come off the fit and 97 registers go on.
It was reverted. What it proves is worth keeping: the new `emu` limit is
the renderer's write bank, not a CPU path, so the next ARM9 change of
this kind buys less than this one did.

### Reading R15 from a flop (2026-11-21)

The worst `emu` path at placement effort 10 did not end at pc, it left
from it: `pc[1]` into `Add45` (pc+4), into the shifter amount, through
the barrel shifter's `ShiftLeft1` and `rotr`, `Mux52` and the ALU's
`Add7` into `pc[31]` -- 18.706 ns of data delay in 11 levels at -4.253.
The value an instruction reads from R15 cannot change between its fetch
and its execution, so the fetch can latch it and every R15 read
(`dp_a`, `rm_val`, `rs_amt`) starts at a flop instead:

| seed 2, TDS off, effort 8.0 | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| both bank writes captured, pad stylus only | 4,029 | 34,353 | 31,675 | -4.375 | -12,115.231 | +0.250 | +0.316 | 3,650,576 | 40:56 |
| R15 read from a flop | 4,016 | 33,996 | 32,110 | -3.893 | -8,423.520 | +0.249 | -0.333 | 3,558,740 | 40:26 |

This is the best `emu` result of the three changes read this week: 0.482
ns of setup and 3,691.711 of TNS, and the probe's worst six have moved
off pc -- they start at `sh_amt[4]`, `Equal81` and `insn[2]` and end in
`arm7_core|rread`. The video path goes from +0.316 to -0.333, though:
0.649 ns, and it fails. That is not a trade to weigh, it is the release's
timing path lost, so it was reverted. 13 LABs, 357 ALMs and 91,836 bytes
come off and 435 registers go on for the 32-bit latch.

### Where the three probes leave the tree (2026-11-21)

The week's three changes each removed a real path and each cost margin
on `pll_hdmi`: the split multiplies 0.237 at seed 2 and 0.055 at seed 4,
the condition latch 0.040, the block index 0.149, the R15 flop 0.649.
Only the first shrank with the seed, so most of its cost was placement;
the R15 flop's fail is the setting's and not the seed's until a second
seed says otherwise.

What the fits leave as targets, in the order the probes name them:

- `emu` is now limited inside `engine_a|renderer_2d` -- `s_bpp8` and
  `shw[0]` into `wbank`, six paths within 0.019 ns. That is the renderer
  and not a CPU path; it wants its own probe before any more core work.
- The ARM7's shift-amount mux into `rread` is the next CPU cluster, and
  it is what the R15 flop left behind.
- The shipped tree's own seed-4 fit is better than its seed-2 fit on
  both numbers at once (`emu` -4.140 against -4.375, video +0.331
  against +0.316). A shipped-seed change still has to go through the
  release path rather than be read off the ledger.
- The four retired changes -- seed 1, the condition latch, the split
  multiplies, the block index, the R15 flop -- all spend video margin.
  Once something buys video margin instead, they are worth re-reading
  together on one tree.

### A pointer mode for USB and Bluetooth devices (2026-11-21)

hps_io's `ps2_mouse` is the only pointing device a core is ever given:
one packet per toggle of bit 24, X and Y as a sign plus a magnitude, and
three buttons. This core had its two PS/2 mouse pins tied high and
ignored it. "Stylus cursor: Pointer" now moves the same absolute stylus
the d-pad and the stick move, with the left button as the pen tip, so a
USB or Bluetooth mouse, a laptop touchpad or a pen tablet in mouse mode
hovers and taps. The motion is relative because that is what the HPS
sends: there is no absolute position in the protocol and no pressure
channel at all, so the cursor starts at the centre of the screen and a
pen's pressure and tilt have nowhere to go.

| seed 2, TDS off, effort 8.0 | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf | wall |
|---|---|---|---|---|---|---|---|---|---|
| both bank writes captured, pad stylus only | 4,029 | 34,353 | 31,675 | -4.375 | -12,115.231 | +0.250 | +0.316 | 3,650,576 | 40:56 |
| both bank writes captured, seed 2 | 4,014 | 34,497 | 31,723 | -3.838 | -12,941.207 | +0.247 | +0.328 | 3,588,036 | 39:56 |

This is the first change this week that does not spend video margin:
0.012 ns the right way, which is placement noise rather than a result,
and 0.537 ns of `emu` setup, which is the best this domain has read.
TNS gives back 825.976 and hold 0.003, 15 LABs come off the fit while
144 ALMs and 48 registers go on, and the bitstream loses 62,540 bytes.

The gain is larger than 60 lines of pointer logic can buy, and the probe
says where it came from: the worst six paths are still `s_bpp8` into
`wbank` inside `engine_a|renderer_2d`, at -3.838 against the
block-index fit's -4.024 -- the same cluster, 0.186 ns shallower. So the
row is a placement the extra input logic moved rather than a shortened
path, and the number should not be quoted as a property of the mode.
The mode itself is benches: 47 step(s), 47 passed, with nine new checks
in `tb_input_mapper` for the packets, the toggle, the button, the edge
clamp and the two cases where the pointer must be ignored.

This was the tree the core shipped from until the RTC row.

### Seeding the clock from the HPS calendar (2026-11-21)

hps_io hands a core the host's calendar as one 65-bit packet: BCD seconds,
minutes, hours, day, month and year in the first six bytes, the weekday in
the seventh as a binary `tm_wday` where 0 is Sunday, `0x40` in the eighth,
and a toggle above it that says a new packet has arrived. This core's RTC
counted from its own reset date until now -- right for a DS, wrong on a
board whose menu already knows the date. **Firmware → RTC source** picks
between the two: `Internal` leaves the counter alone and `Host` latches the
packet's 56 bits and loads them into `nds_rtc` in one write.

The load is not on the packet's edge. `NDS.sv` holds the payload and pulses
`rtc_load` when a packet arrives while the row says Host, after a core
reset -- with the last packet it saw, so a core that starts on Host still
comes up on the calendar -- and on the switch from Internal to Host. A
packet that arrives while the row says Internal is ignored rather than
queued, and a host load wins over a seconds tick on the same cycle, so the
load cannot be counted twice. The weekday needed no conversion: the
packet's `tm_wday` is the same 0 = Sunday that the chip counts.

The benches run against this tree: 47 step(s), 47 passed, with checks in
`tb_rtc` for a host load of 2024-02-29 23:58:07, weekday 4, and the 113
seconds that carry it to 2024-03-01 00:00:00, weekday 5.

At seed 2 the row costs the release's path more margin than the tree has:
`pll_hdmi` goes from +0.328 to -0.115 and the fit fails. A probe on that
fit puts the worst paths in `ascal|o_hcpt[*]` into `ascal|o_radl2[*]` --
the HDMI scaler, which this change does not touch -- so the 0.443 ns is
where the fitter put the logic and not a path the row built. Seed 2 is then
not a seed this tree can ship on, and both trees were fitted at seed 4 to
read the row against a like-for-like baseline:

| seed 4, TDS off, effort 8.0 | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf |
|---|---|---|---|---|---|---|---|---|
| both bank writes captured, pointer mode, seed 4 | 4,035 | 34,428 | 31,782 | -4.215 | -11,371.210 | +0.194 | +0.384 | 3,674,156 |
| both bank writes captured, seed 4 | 4,043 | 34,237 | 31,503 | -4.474 | -9,255.070 | +0.243 | +0.239 | 3,671,232 |

At seed 4 the row costs 0.145 ns of the video path rather than 0.443, which
is the same placement sensitivity the probe describes, and 8 LABs. It
reports 191 fewer ALMs and 279 fewer registers than the tree without it --
the fitter's packing and retiming rather than the row's own logic -- and the
bitstream is 2,924 bytes smaller. `emu` gives back 0.259 ns, and the domain
is 2,116.140 of TNS better and 0.049 of hold better.

So the tree ships at seed 4, and `NDS.qsf` moves from `SEED 2` to `SEED 4`
for the first time since `SEED 1` became `SEED 2`. What that costs on its own
is the same pair read the other way: at seed 4 the pointer tree is 21 LABs
more, 69 ALMs fewer, 0.377 ns better on `emu` setup, 1,569.997 better on
TNS, 0.056 ns better on the video path, 0.053 ns worse on hold and 86,120
bytes larger than its own seed-2 row. Both trees were built with
`quartus_sh --flow compile`, which is the flow `build.bat` runs, so these
are release builds and not ledger readings.

The label `both bank writes captured` moved to this row and the pointer
tree's row took a qualifier, as it did when the pointer mode took it from
the block index; the touchpad row below takes it next. Nothing here has run
on a board: the bench checks cover the load, and the row itself is a menu
item waiting for a game that shows its date.

### A controller's touchpad as an absolute stylus (2026-11-21)

The DS's touch screen is an absolute device: a game asks where the pen is,
not how far it moved. Every stylus mode this core had was relative -- the
d-pad and the left stick walk a cursor, and hps_io's `ps2_mouse` is delta
packets -- so a controller with a touchpad could only nudge the pen across
the screen. MiSTer does send one absolute pointing device to a core: Light
Gun mode. Hold a finger on a DualShock 4's or a DualSense's touchpad, press
that pad's OSD button once, and Main maps a fixed window of the pad --
200..1720 across and 300..850 down, of the 1920x943 surface -- onto
-127..+127 and writes it to `joystick_l_analog_0` -- the port the left
stick uses, which this core gives to no game input. **Touchpad stylus:
Absolute** reads it as the pen's position, with the window's ends on the
screen's edges, so the outer margin of the physical pad does nothing.

Two mappings matter and both are arithmetic the bench can own. Adding 127
to the signed extremes gives 0..254, not 255 and 191, so x gains its top
bit and y is scaled by 191/254 in shifts: the pen reaches column 255 and
row 191 instead of stopping a pixel short of the corner. And the value is
signed, so a stick can also send -128, one count below Main's window, which
is clamped rather than wrapped onto the far edge. The pen is the tap button
and not the touchpad's click, because Light Gun mode drops the touchpad's
own mouse buttons and Main never tells a core whether a finger is down; the
d-pad keeps its game meaning in this mode, which takes the pen outright.
With the row Off nothing changes, and the same touchpad still drives
Pointer as a mouse, because MiSTer presents it as one whenever Light Gun
mode is off.

At seed 4 against the previous tree at the same seed -- one row of logic
between the two -- the row costs `emu` setup, TNS and ALMs, and gives back
LABs, video margin and bitstream:

| seed 4, TDS off, effort 8.0 | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf |
|---|---|---|---|---|---|---|---|---|
| both bank writes captured, seed 4 | 4,043 | 34,237 | 31,503 | -4.474 | -9,255.070 | +0.243 | +0.239 | 3,671,232 |
| both bank writes captured, no TCM | 4,021 | 34,638 | 31,783 | -4.662 | -13,964.027 | +0.250 | +0.261 | 3,611,128 |

0.188 ns of `emu` setup and 4,708.957 of TNS are the row's, and the domain
fails either way. The 401 ALMs are more than the handful of adders it adds,
and the 280 registers cannot be the row's at all because it holds no new
state: the count has moved that far between two fits of one design at this
seed before, 31,503 here against 31,782 on the fit before it, so the figure
is the fitter's packing rather than the change. What is not ambiguous is
the other side: 22 LABs come off the fit, 60,104 bytes off the bitstream,
hold gains 0.007 and the video path 0.022 ns. The release is timed on
`pll_hdmi`, the row is worth having, and it closes.

The benches run against this tree: 47 step(s), 47 passed, with nine checks
in `tb_input_mapper` for the mode -- both corners, the centre, the -128
clamp, the row winning over the stick cursor row, the tap pressing and
lifting, the d-pad still reaching KEYINPUT, and the pen holding still with
the row off. Nothing here has run on a board: whether a DualSense's
normalised touchpad lands corner to corner on a DS screen is the one thing
only hardware can answer, and the mapping is what the bench pins down.

The label `both bank writes captured` moves to this row, as it did twice
before it.

### The ARM9's tightly-coupled memory (2026-11-22)

The ARM946E-S has 32 KB of instruction TCM and 16 KB of data TCM, and the
DS's own libraries run from them: the crt0 of a libnds or blocksds build
points the ITCM's region register at 0x01000000 and runs from there before
it touches main RAM. The core had neither, so those addresses went to the
bus, nothing decoded them, and code that expected to be on chip went to the
fabric instead. `arm9_tcm` sits between `arm9_core` and `cpu_ce_bridge` on
the core's own handshake: a hit answers in one clock, a miss passes the
request through with its strobes intact, and the core does not know the
stage is there.

The area comes out of registers the core already had: CP15 c9 opcode_2 0
and 1 carry the base and the size, four kilobytes doubled by size[5:1]
minus three, c1 bit 16 and bit 18 the enables, and (addr - base) < size is
the whole test, which wraps right at 4 GB. The DS firmware programs the
ITCM area as 32 MB, so the 32 KB of storage answers at every 32 KB of it
and the mirror falls out of the index wrap rather than a wider compare.
Both TCMs are dormant at reset: the region registers are zero and a zero
size is no area, which is the state the core's post-BIOS control register
leaves them in. This core has no BIOS to fill them, and starting them
enabled would shadow the low vector page with zeros.

The memory is one byte-wide block RAM per lane, four per word. That is not
the obvious form. A single 32-bit array with byte-select writes into its
word is what the change was written as first, and Quartus 17.0's Verific
front end does not recognize it: all 12,288 words became registers, and
that fit reports 318,777 ALMs against 41,910, 761% of the device, 421,680
registers and 0 of 553 M10K blocks. Eight plain 8-bit arrays with one write
enable each ask nothing of the front end, so every lane is inferred as an
altsyncram: the fit below uses 289 M10K against 241 before it, and its
block memory is 393,216 bits larger, which is the 48 KB exactly.

At seed 4 against the tree before it:

| seed 4, TDS off, effort 8.0 | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf |
|---|---|---|---|---|---|---|---|---|
| both bank writes captured, no cache state | 4,016 | 34,663 | 31,830 | -4.205 | -14,778.535 | +0.250 | +0.136 | 3,775,172 |
| both bank writes captured, no TCM | 4,021 | 34,638 | 31,783 | -4.662 | -13,964.027 | +0.250 | +0.261 | 3,611,128 |

Five LABs and 0.457 ns of `emu` setup come off, and 25 ALMs, 47 registers,
814.508 of TNS and 0.125 ns of `pll_hdmi` go on. None of that is the TCM's
own arithmetic, two levels of register feeding a block RAM compared against
a bus decode: the ALM and register counts have moved further than this
between two fits of one design at one seed, and TNS follows the endpoints
the fitter picks. The bitstream is 164,044 bytes larger because every one
of those M10K blocks carries its initial contents. `emu` fails either way,
as it has since the ARM7 work; the release is timed on `pll_hdmi`, which
was 0.261 and is 0.136, so it stays positive. Hold does not move.

The benches run against this tree: 48 step(s), 48 passed, with sixteen
checks in `tb_tcm` -- the DTCM write and read with no fabric traffic either
way, the byte and halfword lanes, a miss keeping its strobes, the c1 and c9
gates for both TCMs, the ITCM's 32 MB mirror at 0x01000000, a 64 KB area
answering where the storage wraps, and `c_ready` as a pulse. Nothing here
has run on a board: that a game which relocates itself into the ITCM runs
from it is the thing only hardware can show, and both TCMs start empty, so
a tree that never programs them behaves as it did.

The label `both bank writes captured` moved to this row when it landed; the
section below moves it on. The touchpad's row takes a qualifier.

### The ARM9's cache state, before the caches (2026-11-22)

The cache step starts with the state software programs before it turns a
cache on, because nothing downstream can be enabled or maintained until it
is there. `arm9_core` now keeps c2's two cachability maps (opcode_2 0 for
data, 1 for instruction), c3's write-bufferability map, c5's four
permission halves, c6's eight region words and c9's lockdown registers.
The reserved bits are masked the way the part does: c2 and c3 keep eight,
the normal c5 halves sixteen, c6 keeps base [31:12], size [5:1] and
enable [0], and a lockdown word keeps its L bit and two-bit way index.

Two splits were wrong before. c9 was keyed by opcode_2 alone, so an
`MCR p15,0,Rd,c9,c0,0` -- data cache lockdown -- landed in the data TCM
region, which lives at CRm 1. The TCM bench never saw it because crt0
writes c9,c1,x. Lockdown and TCM are now four registers, and
`tb_arm9_cp15` writes both pairs and reads all four back. And c2 had been
called a translation table base, which this part does not have: it is the
per-region cachability map, eight bits wide. The ARM9 program in
`tb_arm9` had been checking a 0x1234 round trip through it, so it now
writes 0xA5A5 and expects 0xA5.

c7 decodes into a one-cycle strobe (`cp15_c7`: bit 7, CRm in 6:3 and
opcode_2 in 2:0, with Rd in `cp15_c7_arg`) instead of being dropped. The
ARM946E-S's set is nine commands: whole-cache invalidate for each cache,
single-line invalidate by address, single-line clean and
clean-and-invalidate by address or index, and prefetch. There is no
clean-all and no invalidate-by-index on this part, so those encodings
raise no strobe; the bench checks that, and all nine in order with their
Rd. An instruction-side invalidate drops the fetch buffer. The two
test-and-clean reads report the cache already clean, and a WFI (c7,c0,4,
plus the c8,2 alias GBATEK lists) stops the core until an interrupt, the
same stop HALTCNT uses.

The interesting part is the fit, because the change is 585 new flops and
65 ALMs -- 680 to 715 more device registers depending on the seed -- on a
device already at 96% LABs. At seed 4 the release path
`pll_hdmi` goes negative for the first time in this run of work, so that
fit cannot ship. At seed 2 it closes with 10 ps to spare:

| seed 2, TDS off, effort 8.0 | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf |
|---|---|---|---|---|---|---|---|---|
| both bank writes captured, cache state | 4,046 | 34,809 | 32,510 | -4.758 | -16,699.057 | +0.250 | +0.010 | 3,760,180 |
| ..., no cache state, seed 4 | 4,016 | 34,663 | 31,830 | -4.205 | -14,778.535 | +0.250 | +0.136 | 3,775,172 |
| ..., cache state, seed 4, does not ship | 4,035 | 34,728 | 32,545 | -4.880 | -14,215.390 | +0.244 | -0.257 | 3,780,436 |

Read the seed-2 row against the other seed-4 row, not the first one: seed 2
and seed 4 of this same tree differ by 11 LABs, 81 ALMs, 35 registers and
0.388 ns of `emu` setup with no RTL difference at all. That is the size of
the placement noise, and it is larger than the effect being measured. What
is clear is the register count -- 585 new flops plus retiming -- and a few
more LABs; the 0.257 ns the release lost at seed 4 is where those flops
pushed the fitter, not a path through the new state, which lives in the
`emu` domain. Seed 2 buys the margin back at +0.010, the thinnest this
tree has shipped on, so `NDS.qsf` now says SEED 2 and the next RTL change
should be fitted before anything else is built on it.

The label `both bank writes captured` moved to this row when it landed; the
section below moves it on. The benches: 50 steps, 50 passed.
`tb_arm9_cp15` contributes 43 checks --
the two c2 maps and their masking, c3, four c5 halves, eight c6 regions
with the DS's opcode_2 1 mirror, both c9 pairs, the c7 reads, the ten
strobe values including the WFI, the two encodings that must not strobe,
and the interrupt wake. `tb_arm9` and `tb_arm9_tcm` still pass. Nothing
here has run on a board.

What is left of the cache step is the caches: c1 bit 12 and bit 2, the
4 KB data and 8 KB instruction arrays, the line reload and the coherence
hook. The strobe and the state are the pieces they hang off.

### An input log instead of a savestate (2026-11-22)

M6 is the last open milestone, and the two rows still open in it, save states
and a true per-frame rewind, want the same improbable thing: the whole
machine -- both CPUs, both buses, the 2D engines, the audio channels, the
caches, the firmware's own state -- captured and put back inside one frame on
a device at 96% of its LABs. That is not a fit that gets better with effort.
It is megabytes of state behind a 16-bit DDR path whose `emu` domain already
misses timing, and a savestate that takes two frames to load is not one.

What a run actually needs from a savestate, for the things people use one
for -- practise a section again, hand a run to someone else, record a TAS --
is the frame-by-frame input, because from the same boot the rest of the
machine is a function of it. So that is what this step stores.
`rtl/input/input_replay.sv` keeps the mapper's whole output as one word per
frame:

    {5'd0, hinge, mic_lvl[11:0], touch_down, touch_y[7:0], touch_x[8:0],
     keys[11:0]}

the buttons, the touch panel's pressed flag and both coordinates, the
microphone level and the hinge, with five zero bits on top to make the word
48 wide in the source. Quartus sees the zeros and infers the array as
8192x43: 43 M10K blocks and 352,256 bits, against 289 M10K blocks in the
tree before it. 8192 frames is 2 minutes 17 seconds at the DS's 59.83 Hz,
one simple dual-port block RAM, port A writing the live word and port B
reading the next one back, both at `clk_sys` on the frame tick.

The log is session state and not saved state: power takes it, and `reset`
deliberately does not, because a log is worth nothing unless it can be
replayed from boot. Selecting Play and then resetting the core replays a run
from its first frame. Record stops at the depth instead of wrapping, so a
run that fills the log replays whole, and the frames nobody can replay are
the ones after the end rather than the ones where the log ate its own start.

The row is on the System page, `Input replay` with Off, Record and Play, on
P6O[98:97]. Those two bits were free, so `Rewind buffer` at P6O[46:45] and
everything else in the map keep their meanings. A mode change takes effect
on the next frame tick, never in the middle of a word, and Play primes its
read on the frame it is selected, so the first frame played is the first
frame recorded rather than the second. Off passes the mapper's outputs
straight through.

The cost, the two seed-2 rows compared against each other and the shipped
row at seed 1:

| seed 1, TDS off, effort 8.0 | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf |
|---|---|---|---|---|---|---|---|---|
| both bank writes captured, replay log | 4,038 | 35,143 | 32,736 | -4.004 | -11,854.877 | +0.257 | +0.241 | 3,871,272 |
| ..., input log, seed 2, does not ship | 4,018 | 35,192 | 32,793 | -4.091 | -12,661.459 | +0.249 | -0.087 | 3,886,764 |
| ..., cache state, seed 2 | 4,046 | 34,809 | 32,510 | -4.758 | -16,699.057 | +0.250 | +0.010 | 3,760,180 |

At one seed the log is 383 ALMs, 283 registers, 43 M10K blocks and 126,584
bitstream bytes, and it takes 0.097 ns off `pll_hdmi`, +0.010 to -0.087, so
seed 2 of this tree misses the release -- the second time in this work that
it has gone negative, after the cache tree at seed 4. The same tree at seed
1 closes at +0.241, and the 0.328 ns between two seeds of one unchanged
tree is larger than the effect being measured; the cache tree moved 0.267 ns
between seeds 2 and 4 for the same reason. What is not noise is the shape of
the cost: 283 flops, less than half the 680 device registers the cache state
added, but 43 block RAMs that no placement removes and 383 ALMs, which is
more than those flops alone account for because the ring's address compare
and the read-back mux do not fold into the memory. Seed 1 pays it out of
placement and 0.231 ns of margin over what had shipped, so `NDS.qsf` now
says SEED 1. `emu` setup is still negative and still not the release path;
the worst hold falls from +0.208 to +0.131, the lowest this tree has shown
and still positive.

The benches: 51 steps, 51 passed, `tb_input_replay` contributing 30 checks
-- Off as a wire, Record storing one word per frame and counting them, Play
returning them first one first and stopping at the end of the log, the log
surviving a core reset and replaying again after it, Record starting a fresh
log at index 0, and a log filled to its depth that stops recording and still
replays whole.

None of this has run on a board. A log also reproduces inputs and not a
machine: anything a game reads from outside the mapped inputs -- the RTC,
microphone noise, the wireless unit -- diverges on replay, and save states
and a true rewind remain M6 rows.
### Cache line state, and a readout for the log (2026-11-22)

Two of the rows the log left behind, in one tree: the state a cache
maintenance command acts on, and something on screen that says what the
input log is doing.

`rtl/cpu/arm9_cache_tag.sv` is that state and nothing else. Four tag arrays
per cache at the geometry CP15_CACHETYPE already declares -- 32-byte lines,
four ways, 32 sets over 4 KB of data cache and 64 sets over 8 KB of
instruction cache -- plus a valid bit per set and way and a dirty bit for
each of the data cache's 128 lines. Nothing is filled from memory, nothing
is served out of the arrays, and every access still reaches the bus, so no
timing changed; what changed is that the nine c7 commands CP15 already
decoded now do something. Before this, test-and-clean answered "clean" by
construction because there was no line state to test.

Two decisions came out of making the commands mean what they say.

Whole-cache invalidate clears a bitmap. A generation bit is smaller, but it
flips back: invalidate twice with a fill in between and the second one
revalidates the line the first threw away. A walk over the sets is exact
but lets an allocation land in a set that has been cleared or is about to
be. One cycle and a bitmap is both.

The compare is combinational and the state moves on the access's own cycle.
Software writes a line and then cleans it -- a DMA writeback does exactly
that -- so the clean has to see the store that came before it. A registered
array read put the dirty bit a cycle behind the store and the clean found
nothing to do; `tb_arm9_cp15` caught it in the core, as a test-and-clean
reading 1 where it should read 0, before a fit was spent on it.

The strip is the other half. `rtl/video/replay_status.sv` draws the log's
state along the bottom row of the picture while the row is not Off: `REC
0123`, `FULL8192`, `PLAY0123/8192`, `END 0123/8192` or `EMPTY`, in a bar
from column 8 to 23 with the text from column 9. The digits are BCD
counters inside the recorder, incremented on the same frame tick as `count`
and `pos`, so the readout cannot disagree with what is stored and there is
no divider in the video path. One pixel clock enable, gated off while the
boot menu is open, so the two overlays never share the row.

The README also stops implying things the menu cannot do. `Show FPS`,
`Frame graph`, `Bus activity LEDs` and `Rewind buffer` are rows with
nothing behind them, and it now says so where those rows are described.

The cost, the row that shipped and the fits behind it:

| seed 1, TDS off, effort 8.0 | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf |
|---|---|---|---|---|---|---|---|---|
| ..., replay log, seed 1 | 4,038 | 35,143 | 32,736 | -4.004 | -11,854.877 | +0.257 | +0.241 | 3,871,272 |
| both bank writes captured, seed 1, retired | 4,105 | 37,556 | 35,893 | -5.378 | -16,596.011 | +0.248 | +0.128 | 3,915,836 |
| ..., staging copy, seed 2, does not ship | 4,108 | 37,512 | 36,011 | -5.202 | -18,941.233 | +0.245 | -0.010 | 3,990,212 |

The cache state is not cheap, and it is not cheap where it was designed to
be. Both caches' tags come to 2,816 bits, which is nothing, but Quartus put
them in registers rather than RAM: 3,157 flops and 2,413 ALMs, which takes
the design from 84% to 90% of its ALMs. The strip is inside that figure and
the fit does not separate it out, but its counters and font cells are a
handful next to 3,157. The 44 ALMs between the two seeds say this is not a
placement accident; it is what an associative tag compare costs when it
cannot be read a cycle late. The next step, 12 KB of data arrays and the
line reload, therefore has to go to block RAM: 45% of the block memory is
spent and the 10% of ALMs left is not another set of arrays this size.

Seed 1 was measured twice. The first fit was of the staged copy; `rr_way`
then moved up the file so iverilog would accept it, and a comment changed,
and fitting the tree as committed reproduced that row figure for figure --
4,105 LABs, 37,556 ALMs, the same +0.128. The fingerprint is what noticed
the difference at all: it refused the first fit as evidence for a tree it
was not built from, which is the check doing its job on an edit that
turned out not to matter. The seed-2 row is the staged copy, one
declaration away from what ships.

Seed 2 misses the release by 10 ps -- `pll_hdmi` at -0.010 against +0.128
at seed 1 -- so `NDS.qsf` still says SEED 1 and all three rows are in the
ledger. The margin is thinner than the log alone left it, +0.241 to +0.128,
against the 0.328 ns that two seeds of one unchanged tree have moved. This
is the second tree in a row where seed 1 is the one that closes.

The benches: 53 steps, 53 passed. `tb_arm9_cache_tag` is 58 checks over
both geometries -- fill, hit, the dirty bit, every c7 form, lockdown, and
the whole-cache invalidate that a walk would get wrong. `tb_arm9_cp15`
grew to 45 with a store, a clean and two test-and-cleans run through the
core, and `tb_input_replay` is 37 with the tens carry at depth 16 as well
as at 8192. The strip has its own bench, 75 checks over its five states,
the digits and the bar's edges.

None of it has run on a board. The tags and the strip are simulation and
Quartus claims only, and the state without the data arrays is correct and
useless: a cache that allocates is still the missing half, and until it
lands the strip reports on a log that no game can see.
### The lines themselves, and the tags in MLAB (2026-11-22)

Two more of the rows after the cache state: the storage a cache needs, and
whether the tags can be moved out of the registers they landed in.

`rtl/cpu/arm9_cache_data.sv` is the storage: four ways of eight words per
set behind one byte-enabled write port and one registered read port, sized
for both geometries by the same parameters -- 1,024 words for the data
cache's 4 KB, 2,048 for the instruction cache's 8 KB. Byte lanes are four
byte-wide arrays rather than one word-wide array with a byte enable,
because a store has to write the lane it addresses without reading the word
first. The module holds no idea of what it holds: validity and dirtiness
stay in `arm9_cache_tag.sv`, and this is indexed by what that one says.

The read port is registered on purpose. An asynchronous read of a
1,024-word array is not a memory to Quartus, it is registers -- the same
finding that cost the tags 3,157 flops. A registered read is what makes
this a memory: by arithmetic, a lane of 1,024 bytes is one M10K block, so
four blocks for the data cache's 4 KB and eight for the instruction cache's
8 KB, against the 45% of the device's block memory the design already
spends. No fit holds this module yet, so that is arithmetic and not a
measurement.

What is not here is the path that uses it. Today the core reads memory
through the bus and updates the tags as a side effect; serving a load out
of these arrays needs a probe cycle, a fill on a miss and -- because the
DS's data cache is write-back -- eviction that writes a dirty line back and
a c7 clean that copies the line to memory instead of clearing a bit. A fill
with nothing serving it is eight bus reads for no return, and serving
without write-back hands back stale lines as soon as a game's working set
outgrows the cache. So the array is built and benched and not yet in the
datapath, and the next step is all of that rather than a shortcut through
it.

The tags, part two: the register bill. Both caches' tags are marked
`ramstyle = "MLAB"` -- a LUT RAM in the LAB can serve an asynchronous read,
where a block RAM cannot -- and the fit came back byte for byte identical
to the register one: 4,105 LABs, 37,556 ALMs, 35,893 registers, 3,915,836
bytes, -5.378 setup, +0.128 on `pll_hdmi`, and "Total MLAB memory bits: 0"
in the report. The attribute is inert. Quartus 17.0 will not put an array
with an asynchronous read in MLAB either, and it says so nowhere except by
doing exactly what it did before; the ledger row is `nds-mlab-s1`, and the
figures are the ones the shipped row already carries because the build is
the same build.

The way to get those 2,413 ALMs back is to register the tag read and
forward the store -- the fix the module header already names as the price
of the asynchronous compare. That costs a probe cycle, which is the cycle
the data array's registered read needs anyway, so it belongs with the
serving path rather than before it.

The bench: `tb_arm9_cache_data` is 31 checks -- a word read back where it
was written, the four ways of a set kept apart, the eight words of a line
kept apart, each byte lane written alone with the other three untouched, a
write with no lanes enabled changing nothing, the deepest address of each
geometry not wrapping onto set 0, the two geometries not sharing cells, and
the enable holding the read port still. Two of them failed on the first
run and both were the bench's own mistakes: a byte lane written with its
data in the wrong bits, and a read of a word nothing had ever written.

The suite is 55 steps, all passing.

### The cache serves a load (2026-11-22)

The arrays are wired in. A load from main RAM with c1 bit 2 set looks in
the tags in the cycle the decode produces its address, and if the line is
there the word comes back out of `rtl/cpu/arm9_cache_data.sv` with no bus
access at all; if it is not, the line is filled behind the load with eight
bus reads. The probe is in that cycle because the decision to ask the bus
or not has to be made before the bus is asked, and a registered tag read
would arrive a cycle too late. The array's read is registered, so the word
lands at the end of that cycle and is waiting in the one that used to be
the bus wait.

Stores stay write-through, and that is a choice about what can go wrong.
The ARM946E-S in a DS is write-back; a write-back cache writes a dirty
line out when it evicts it and copies it to memory on a c7 clean, which is
two more bus paths and two ways to lose data if either is wrong.
Write-through keeps memory authoritative: a store reaches memory and, if
the line is here, the array as well, so nothing is written back, nothing
is lost, and a c7 clean is a bit. The price is bus traffic on stores a
write-back cache would absorb, and it is worth paying before the fetch
path and the coherence hook exist.

Allocation follows from that. Only a load the core is going to fill may
take a line, so a valid line always has its eight words; a store to a line
the cache does not hold writes memory and allocates nothing, which is why
`tb_arm9_cp15` now loads its line before it stores into it. Block
transfers, LDRD/STRD and SWP bypass the cache -- they are not filled, so
they must not allocate -- and a block store into a line the cache does
hold does update it.

Three real defects turned up between the first compile and this row, and
none of them was in the part of the design that was being thought about:

* with every way of a set locked, a miss could not take a line but the
  fill ran anyway and wrote its eight words into the way the tags still
  called valid, corrupting a locked line. The tags now report whether a
  line can be taken at all (`alloc_ok`), and the core only fills when they
  say yes.
* the array's read address was a register set in the decode cycle, so the
  array registered the previous access's address and every hit returned
  the word before the one asked for. The bench saw it as a hit whose value
  was right for the wrong word; the address is combinational now.
* the hand-assembled program in the new bench put its register number in
  the CRn field of three CP15 encodings, so it wrote c9 instead of c1 and
  the cache never came on -- which the bus counts showed at once, because
  every load still cost a read.

And the one the fit found, which no bench could have: `NDS.qsf` switches
RAM recognition off for `arm9_core`, because Quartus 17.0's Verific front
end aborts on the core's register arrays; the comment there has
the failure and the KB number. The data array
lives inside that entity, so it was built out of registers -- 21,824 logic
elements, and the design needed 5,606 LABs against a 4,191-LAB device.
Quartus does not honour `ramstyle` against that switch, and says nothing.
Recognition is now turned back on for `arm9_cache_data` alone; measured in
a project of the core by itself, the array is 32,768 block bits and 6,340
registers for the whole core with the switch on, and 32,800 flops and no
block bits with it off.

The other thing no bench caught: moving the cache's declarations above the
machine's states, where iverilog can see them before the lines that read
them, left `tb_arm9` uncompilable for a while with `d_probe` used 239
lines before it was declared. Quartus never complained, which is exactly
why the suite has to be run on the tree and not on memory of it.

The cost, and the two seeds it took to ship:

| seed 1 and seed 2, TDS off, effort 8.0 | LABs | ALMs | regs | `emu` setup | TNS | hold | `pll_hdmi` | rbf |
|---|---|---|---|---|---|---|---|---|
| both bank writes captured, seed 1, tags only | 4,105 | 37,556 | 35,893 | -5.378 | -16,596.011 | +0.248 | +0.128 | 3,915,836 |
| the arrays wired in, seed 1, does not ship | 4,107 | 37,465 | 35,904 | -4.512 | -16,603.387 | +0.201 | -0.064 | 3,998,024 |
| both bank writes captured | 4,130 | 37,518 | 36,019 | -4.972 | -24,042.628 | +0.244 | +0.081 | 4,005,936 |

The array costs two LABs at seed 1 and the fit comes in ninety-one ALMs
lighter, because 32,768 bits that were never in the logic budget now sit
in four M10K blocks: block memory goes from 2,545,995 to 2,579,787 bits.
What it costs is on the release path, and at seed 1 it costs too much:
`pll_hdmi` was +0.128 on the tags-only tree and is -0.064 here, which by
this project's rule does not ship. The seed-2 fit of the same tree, same
settings, is +0.081 with TNS 0.000, so `NDS.qsf` now says SEED 2 and the
seed-2 row is the shipped one. The tags-only row it replaces was a seed-1
build, which is why the table above names both seeds: that row is evidence
about the tree before this change, not about the configuration that now
ships.

Seed 2 is 25 LABs over that tree's seed-1 fit -- 4,130 against 4,105, 61
spare of 4,191 instead of 84 -- and 53 more ALMs. Against the tags-only
row it is 38 fewer ALMs and 126 more registers. The `emu` figure moved the
other way at both seeds, from -5.378 to -4.972 at seed 2, and its TNS is
the worse one, -24,042.628 against -16,596.011, so what bought the video
path is where one path landed and not a shallower machine.

+0.081 ns is thin, and this file has measured thin before: two seeds of
one unchanged tree have moved `pll_hdmi` by 0.328 ns. The rule is a
measured non-negative slack and +0.081 is one, but another tree's placement
can put the video path back under zero without touching the cache at all.

The bench measures the bus, not the registers, because a hit is a claim
about the bus: `tb_arm9_cache_path` counts the reads of one line's 32 bytes
and stops the program at ten points to record the count. A miss and its
fill are nine reads; four different loads of the line are nine; a store
and a reload are nine, because the store updated the array; a byte and a
halfword out of the cached word are nine; a second line in the same set
fills into the next way and leaves the first at nine; an invalidate makes
the next load pay nine again; and with the cache off one more read takes
it to nineteen. Twenty-two checks, with the values beside them.

What is still not there: the instruction cache's arrays (its tags are
recorded, but nothing is served and allocation is off, since a valid line
with no data in it is worse than no line); coherence, so a DMA write into
main RAM leaves a cached line stale until software invalidates it, which
the hardware requires of software too; and a fill is nine separate bus
reads with no window protection, so another master writing the line while
it is being filled leaves a mixed line behind. That last one belongs with
the coherence hook rather than with a wider state machine.
