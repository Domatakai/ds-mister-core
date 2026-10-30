# Area budget: fitting the NDS core on the DE10-Nano's A6

Measured from the last full compile (`NDS.map.rpt`, Quartus 17.0.0, device
`5CSEBA6U23I7`) and from standalone `quartus_map` probes of the candidate
rewrites. Device capacities were read from a trivial fit on the same part, not
from a datasheet.

## The four budgets

| resource | used | device | headroom |
|---|---|---|---|
| combinational nodes (ALUTs) | 141,879 | 83,820 | **−58,059 (169%)** |
| registers | 68,515 | 83,820 | 15,305 (82%) |
| DSP blocks | 124 | 112 | **−12 (111%)** |
| M10K bits | 1,849,281 | 5,662,720 | 3,813,439 (33%) |

41,910 ALMs each give two combinational nodes and two registers, so the LUT and
register limits are the same 83,820 — registers are *not* comfortable, they are
at 82%, and any fix that adds pipeline stages spends the same budget.

Two blocks are over: logic by 58k and DSP by 12. The DSP overrun is why the
geometry engine's multipliers spill into LUTs — Quartus ran out of DSPs and
fell back, which is the single largest LUT cost in the design.

## Where the 141,879 ALUTs are

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
to 56%. As built the word is 34 bits rather than 42 (the display only reads
`{opaque, rgb}` of each pixel), so the pair RAM is 8,704 bits; the working bank
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

**7. One 2D renderer shared by both engines — ~5,500 ALUTs** (estimate).
After (3) the two instances hold 10,146 and 6,703 ALUTs of logic that would be
one copy. *Accuracy: none in pixels*; the cost is line budget and VRAM
arbitration — two lines per period instead of one, ~644 clocks against the
1,280 measured for a single 4bpp+sprites line, so it fits but the margin is
gone. Highest risk item of the seven.

**8. Single-pass scaler in the framework — ~4,000 ALUTs** (estimate).
`ascal` is 8,344 with 4,864 in scaler leaves. Nearest/integer scaling instead of
the polyphase path is a visible quality loss on HDMI. *Accuracy: softens or
blocks the upscale.*

**9. CPU datapath sharing — ~2,000 ALUTs** (estimate, high risk).
18,012 + 10,192 ALUTs of decode, shifter and ALU. Sharing the barrel shifter and
address adder across states is the only real saving and it must keep `tb_arm7`
and `tb_arm9` green. Not worth doing before the items above.

**10. Registers → BRAM in cart_slot and the save path — ~1,500 ALUTs** (estimate).
7,640 registers hold line buffers that are read sequentially.

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

That is: a DS core with the two ARM cores, both 2D engines, sound, cart and
save support fits the A6 once the four lossless items are taken *and* the two
renderers are merged *and* the 3D pipeline is gone. Keeping 3D needs either a
bigger device (the DE10-Nano's A6 is the top of that part) or a much slower 3D
implementation that shares the rasteriser's datapath with the 2D engine.

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
renderer, which is one M10K each (8,704 of 10,240 bits) — two of the 553. The
`Total RAM Blocks 0 / 553` row in `NDS.fit.summary` is an artefact of the
aborted placement, not a memory total; the bit count above is the reliable
figure (33%, ~183 block-equivalents of the 553). The two `Critical Warning
(127005)` lines are the pre-existing SPU MIF depth notes.

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
| `renderer_2d` block memory bits | 0 | **8,704** (256 × 34) |
| `tb_renderer_2d` | PASS | PASS (line fetch 1,196 clocks) |
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
  is 34 bits wide, not 42: only `{opaque, rgb}` of each pixel is ever read back,
  so the kind/priority bits are dropped rather than stored.

The working bank (`wbank`) stays in registers: its read-modify-write must land
in the same cycle as the write, which a simple dual-port cannot do. That is the
5,376 registers still there.
