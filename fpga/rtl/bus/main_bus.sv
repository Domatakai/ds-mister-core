//============================================================================
// NDS MiSTer Test — main bus interconnect
//
// Single-server round-robin fabric serving both CPU masters against the
// DS address map. Private regions (BIOS, WRAM, IO, palette, OAM) answer
// in one cycle; shared regions (main RAM via SDRAM, the cart window via
// DDR3) run a two-phase micro-sequence so every 32-bit access assembles
// both 16-bit halves — the DS bus is 16-bit wide.
//
// Map (physical, as seen by either CPU):
//   0x00000000..0x00003FFF  ARM7 BIOS (HLE: NOPs, dispatch in M1)
//   0x02000000..0x02FFFFFF  Main RAM 4 MB              -> SDRAM via arbiter
//   0x03000000..0x03007FFF  Shared WRAM 32 KB          -> BRAM
//   0x03800000..0x0380FFFF  ARM7 WRAM 64 KB            -> BRAM
//   0x04000000..0x040003FF  I/O registers              -> IO block below
//   0x05000000..0x050007FF  Palette 2 KB               -> BRAM
//   0x06000000..0x06FFFFF7  VRAM                       -> vram_arbiter (M2)
//   0x07000000..0x070007FF  OAM 2 KB                   -> BRAM
//   0x08000000..0x0FFFFFFF  Cart window                -> cart_slot (DDR3)
//   0x09000000..0x097FFFFF  Slot-2 RAM expansion 8 MB  -> SDRAM (OSD row)
//   0xFFFF0000..0xFFFF3FFF  ARM9 BIOS mirror           -> HLE
//
// IO registers (GBATEK has the full list; M1 grows it):
//   0x000 DISPCNT_A  RW     0x1000 DISPCNT_B  RW
//   0x130 KEYINPUT    R  {4'hF, ~keys} (0 = Pressed, active low)
//   0x132 KEYCNT      RW     0x136 EXTKEYIN R (NDS7: X/Y, pen, hinge)
//   0x204 EXMEMCNT    RW     0x208 IME RW  0x210 IE RW  0x214 IF W1C
//   0x008..0x00E      BG0-3CNT_A -> engine A      (0x1008.. B)
//   0x048..0x056      BGxHOFS/VOFS_A -> engine A   (0x1048.. B)
//   0x0B0..0x0DF      DMA0-3 -> dma_engine (M2)
//   0x150..0x15A      AUX SPI / MIDI -> midi_port (MT-32-pi)
//   0x240..0x248      VRAMCNT A..I -> vram_arbiter
//   0x100..0x10F      timers 0-3 (one set per CPU)      -> sys_io
//   0x180..0x188      IPCSYNC / IPCFIFOCNT / SEND     -> sys_io
//   0x280..0x2BF      ARM9 DIV / SQRT                 -> sys_io
//   0x208/0x210..0x217 IME / IE / IF (one bank per CPU) -> sys_io
//   0x300/0x301       POSTFLG / HALTCNT               -> sys_io
//   0x138             RTC port (S-35180, bit-banged)   -> sys_io/nds_rtc
//   0x1C0/0x1C2       SPI bus (firmware/TSC/powerman) -> sys_io/nds_spi
//   0x04100000        IPCFIFORECV (own 64 KB page)    -> sys_io
//   0x400..0x4FF      SOUND0-15 (ARM7; from the ARM9 these are the 3D
//                     window)                        -> spu
//   0x500/0x504       SOUNDCNT / SOUNDBIAS (ARM7)    -> spu
//   0x300 POWCNT1     RW
//
// The 0x400..0x5FF window belongs to the ARM7 for sound registers and to
// the ARM9 for the geometry engine, exactly as on hardware: the decode is
// qualified by the granted master, not by the address alone.
////
// VRAM (0x06xxxxxx) is served as 16-bit beats through vram_arbiter
// (M2); palette/OAM expose second read ports for the engines.
//
// Cheat hook: every completed main-RAM read is offered to cheat_engine,
// which may substitute the value (GameShark codes loaded via F2).
//============================================================================
module main_bus (
	input            clk,
	input            reset,
	input            ce7,          // ARM7 clock enable (cpu_ce): the timers
	                               // count it, not clk_sys
	input            ram_exp,      // Slot-2 RAM expansion pak, from the OSD
	input            rumble_pak,   // Slot-2 rumble pak, from the OSD
	output reg       rumble_lvl,   // its actuator state, for the pad motors

	// input state from input_mapper
	input     [11:0] ds_keys,
	input      [2:0] lang,           // OSD language -> firmware user settings
	input      [8:0] touch_x,
	input      [7:0] touch_y,
	input            touch_down,
	input            mic_in,
	input            hinge_closed,   // EXTKEYIN bit 7

	// ---- ARM9 master ----
	input     [31:0] m9_addr,
	input     [31:0] m9_wdata,
	input      [3:0] m9_be,
	input            m9_rd,
	input            m9_wr,
	output reg       m9_ready,
	output reg [31:0] m9_rdata,

	// ---- ARM7 master ----
	input     [31:0] m7_addr,
	input     [31:0] m7_wdata,
	input      [3:0] m7_be,
	input            m7_rd,
	input            m7_wr,
	output reg       m7_ready,
	output reg [31:0] m7_rdata,

	// ---- cart window (cart_slot read bridge) ----
	output reg       cart_req,
	output reg [25:0] cart_addr,
	input            cart_valid,
	input     [15:0] cart_rdata,

	// ---- shared SDRAM (mem_arbiter) ----
	output reg       ram_req,
	output reg       ram_wr,
	output reg [24:0] ram_addr,
	output reg [15:0] ram_wdata,
	output reg [1:0] ram_be,
	input            ram_done,
	input     [15:0] ram_rdata,

	// ---- VRAMCNT writes -> vram_arbiter ----
	output           vramcnt_we,
	output     [3:0] vramcnt_addr,
	output     [7:0] vramcnt_data,

	// ---- VRAM window (0x06000000..) -> vram_arbiter (M2) ----
	output reg       vram_req,
	output reg       vram_wr,
	output    [19:0] vram_addr,
	output    [15:0] vram_wdata,
	input            vram_valid,
	input     [15:0] vram_rdata,

	// ---- DMA register file + bus master (M2) ----
	output reg       dma_reg_we,
	output     [7:0] dma_reg_addr,
	output    [15:0] dma_reg_data,
	output     [7:0] dma_reg_rd_addr,
	input     [15:0] dma_reg_rdata,
	input     [31:0] d_addr,
	input     [31:0] d_wdata,
	input      [3:0] d_be,
	input            d_rd,
	input            d_wr,
	output reg       d_ready,
	output reg [31:0] d_rdata,
	input      [3:0] dma_irq,   // completion pulses -> IRQ8+n

	// ---- engine register writes (M2) ----
	output reg       ea_we,
	output     [6:0] ea_addr,
	output    [15:0] ea_data,
	output reg       eb_we,

	// ---- 3D command / status window (M3) ----
	output reg       gx_we,
	output     [9:0] gx_addr,
	output    [31:0] gx_data,
	input     [31:0] gx_rdata,

	// ---- palette / OAM engine read ports (M2) ----
	input      [9:0] pal_ra_a,
	output reg [15:0] pal_rd_a,
	input      [9:0] pal_ra_b,
	output reg [15:0] pal_rd_b,
	input      [9:0] oam_ra_a,
	output reg [15:0] oam_rd_a,
	input      [9:0] oam_ra_b,
	output reg [15:0] oam_rd_b,

	// ---- cheat hook ----
	output reg       cheat_chk_en,
	output reg [31:0] cheat_chk_addr,
	output reg [31:0] cheat_chk_word,
	input     [15:0] cheat_patch,
	input            cheat_patch_hi_en,
	input     [15:0] cheat_patch_hi,
	input            cheat_hit,
	input            cheat_ready,  // the cheat walk for this read is finished

	// ---- MIDI / AUX SPI port (0x04000150..0x0400015A) ----
	output reg       midi_wr,
	output reg       midi_rd,
	output    [15:0] midi_addr,
	output    [15:0] midi_wdata,
	input     [15:0] midi_rdata,

	// ---- SPU register window (0x04000400..0x0400051F, ARM7 only) ----
	output           spu_acc,
	output           spu_we,
	output    [15:0] spu_addr,
	output    [15:0] spu_wdata,
	input     [15:0] spu_rdata,

	// ---- engine / system observations (M2 consumers) ----
	output reg [15:0] dispcnt_a,
	output reg [15:0] dispcnt_b,

	// ---- interrupt and halt observations ----
	// the flat trio below is the ARM9 bank, kept for the M1 consumers; the
	// per-CPU lines are what the cores will take (there are two banks on a DS)
	output            irq_master_enable,
	output     [31:0] irq_enable,
	output     [31:0] irq_flags,
	output            irq9_cpu,
	output            irq7_cpu,
	output            arm7_halt
);

//------------------------------------------------------------------
// Memories
//------------------------------------------------------------------
// The two WRAM banks are held as four byte lanes each, not as one 32-bit
// array with byte enables inside the write. A masked write that reads the
// array for the lanes it is not writing (`{be[3] ? wdata[31:24] :
// wram[idx][31:24], ...}`) is a read-modify-write of the same memory, which
// no block RAM can do — Quartus therefore built both banks out of flip-flops:
// 786,432 registers, which consumed 33 GB while elaborating and never fit.
// With the lanes separate each one is a plain 8-bit wide RAM with a single
// write enable (its own byte select) and a registered read, so they infer as
// M10K blocks and the four read bytes are concatenated. Read-during-write
// behaviour is unchanged: old data, as before.
reg [7:0] wram_s0 [0:8191];        // 32 KB  @0x03000000, byte 0
reg [7:0] wram_s1 [0:8191];        //                     byte 1
reg [7:0] wram_s2 [0:8191];        //                     byte 2
reg [7:0] wram_s3 [0:8191];        //                     byte 3
reg [7:0] wram_70 [0:16383];       // 64 KB  @0x03800000, byte 0
reg [7:0] wram_71 [0:16383];       //                     byte 1
reg [7:0] wram_72 [0:16383];       //                     byte 2
reg [7:0] wram_73 [0:16383];       //                     byte 3
// Palette and OAM, 2 KB each: one BRAM copy per reader.
//
// A 10 Kb block has two ports, and this memory has three readers that all
// run in the same cycle - the CPU (both halfwords of a word read) and the
// two 2D engines - plus the CPU's writes, so each reader gets its own copy
// and every copy is written in the same cycle as the others. Left as arrays
// read and written from one always block they were flip-flops: 32,768 of
// them, plus a 1024:1 mux on each read.
//
// Each copy has a single write address, so a 32-bit write (two adjacent
// halfwords) is split over two cycles: the addressed halfword in S_PRIV, its
// neighbour in S_RESP. Software sees nothing but the response arriving a
// cycle later, which the bus handshake already allows.
reg [15:0] pal_cpu_lo [0:1023];   // 2 KB   @0x05000000, CPU read low half
reg [15:0] pal_cpu_hi [0:1023];   //                     CPU read high half
reg [15:0] pal_eng_a  [0:1023];   //                     engine A read port
reg [15:0] pal_eng_b  [0:1023];   //                     engine B read port
reg [15:0] oam_cpu_lo [0:1023];   // 2 KB   @0x07000000, CPU read low half
reg [15:0] oam_cpu_hi [0:1023];   //                     CPU read high half
reg [15:0] oam_eng_a  [0:1023];   //                     engine A read port
reg [15:0] oam_eng_b  [0:1023];   //                     engine B read port

// the registered write side (one address per cycle, fanned out to all copies)
reg        pal_we  = 1'b0, oam_we  = 1'b0;
reg [9:0]  pal_wa  = 10'd0, oam_wa  = 10'd0;
reg [15:0] pal_wd  = 16'd0, oam_wd  = 16'd0;
reg        pal2_we = 1'b0, oam2_we = 1'b0;   // the neighbour halfword
reg [9:0]  pal2_wa = 10'd0, oam2_wa = 10'd0;
reg [15:0] pal2_wd = 16'd0, oam2_wd = 16'd0;

//------------------------------------------------------------------
// IO registers
//------------------------------------------------------------------
reg [15:0] keycnt   = 0;
reg [15:0] exmemcnt = 0;
reg [15:0] powcnt1  = 0;
reg        vramcnt_we_r = 0;
reg        dma_reg_we_r = 0;

//------------------------------------------------------------------
// Arbitration view of the granted master
//------------------------------------------------------------------
// FSM state and the master mux live here, ahead of every helper that
// indexes them: iverilog 14 rejects a forward reference to a wire or
// reg from a continuous assign (Quartus tolerates it).
localparam S_IDLE  = 3'd0,
           S_PRIV  = 3'd1,
           S_REQ_A = 3'd2,
           S_WAIT_A= 3'd3,
           S_REQ_B = 3'd4,
           S_WAIT_B= 3'd5,
           S_RESP  = 3'd6,
           S_CPATCH= 3'd7;

reg [2:0]  state = S_IDLE;
reg [1:0]  rr = 0;         // fairness: rotates among the three masters
reg        m9_active = 0;
reg        m7_active = 0;
reg        d_active = 0;
reg        m9_block = 0;  // served until the master drops its strobe
reg        m7_block = 0;
reg        d_block = 0;
reg        is_read = 0;
reg        need_b = 0;
reg [15:0] lo_half = 0;
reg [15:0] hi_half = 0;

wire m9_req = m9_rd | m9_wr;
wire m7_req = m7_rd | m7_wr;
wire d_req  = d_rd  | d_wr;

wire        m_rd  = m9_active ? m9_rd  : m7_active ? m7_rd  : d_rd;
wire        m_wr  = m9_active ? m9_wr  : m7_active ? m7_wr  : d_wr;
wire [31:0] a     = m9_active ? m9_addr : m7_active ? m7_addr : d_addr;
wire [31:0] wdata = m9_active ? m9_wdata: m7_active ? m7_wdata: d_wdata;
wire  [3:0] be    = m9_active ? m9_be   : m7_active ? m7_be   : d_be;

//------------------------------------------------------------------
// Address / word helpers
//------------------------------------------------------------------
wire [15:0] io_addr  = a[15:0];
wire [15:0] keyinput = {4'hF, ~ds_keys}; // GBATEK: 0 = Pressed

// EXTKEYIN (NDS7 only, GBATEK *DS Keypad*): bit0 X, bit1 Y, bit2 set,
// bit3 DEBUG (1 = none), bit4-5 set, bit6 pen-down (0 = pressed, the TSC's
// /PENIRQ), bit7 hinge (1 = closed), bits 8-15 zero. X/Y are mirrored from
// KEYINPUT, which carries the same two buttons. Hinge transitions raise IRQ 22
// (see irq_src7 below), which is the game's cue to sleep the shell.
wire [15:0] extkeyin = {8'h00, hinge_closed, ~touch_down, 4'b1111,
                        ds_keys[11], ds_keys[10]};
wire [15:0] w_lane_lo = wdata[15:0];
wire [15:0] w_lane_hi = wdata[31:16];
// 16-bit accesses carry their lanes in [31:16] when the halfword at
// `a` is odd (be == 1100); that beat must use the high lane
wire        beat_hi = (be[1:0] == 2'b00) && (be[3:2] != 2'b00);
wire [12:0] shared_idx = a[14:2];
wire [13:0] a7_idx     = a[15:2];
wire [9:0]  pal_idx    = a[10:1];
// main RAM: byte 0x02xxxxxx -> SDRAM halfword 0x2xxxxx + byte/2, so a
// 32-bit word spans halves {k, k+1} (never overlapping its neighbour).
wire [24:0] ram_word_lo = {3'd0, 1'b1, a[21:1]};
wire [24:0] ram_word_hi = ram_word_lo + 25'd1;
// The pak's 8 MB goes in SDRAM at 0xA00000 + a[22:1]: main RAM owns
// 0x200000, palette/OAM 0x400000 and the VRAM banks 0x600000..0x9FFFFF
// (vram_arbiter's VRAM_SDRAM_BASE), while the cart ROM is in DDR3, so
// 0xA00000..0xDFFFFF is free (the chip's 16M halfwords end at 0xFFFFFF).
wire [24:0] exp_word_lo = 25'hA00000 + {3'd0, a[22:1]};
wire [24:0] exp_word_hi = exp_word_lo + 25'd1;

// VRAM window port (byte address within the 1MB window; offset register
// allows the second beat of a 32-bit access at +2)
reg [19:0] vram_off;
reg        vram_hi_beat = 0;

assign vramcnt_we   = vramcnt_we_r;
assign vramcnt_addr = a[3:0];
assign vramcnt_data = wdata[7:0];

assign dma_reg_we   = dma_reg_we_r;
assign dma_reg_addr = io_addr[7:0];
// lane-aware: STRH to an odd-halfword register (SAD/DAD high at
// 0xB2/0xB6) carries its data in bits [31:16]
assign dma_reg_data = beat_hi ? w_lane_hi : w_lane_lo;
assign dma_reg_rd_addr = io_addr[7:0];

// engine register write forwarding (0x000..0x07F A, 0x1000..0x107F B)
assign ea_addr = io_addr[6:0];
assign ea_data = w_lane_lo;

assign vram_addr  = vram_off;
assign vram_wdata = vram_hi_beat ? w_lane_hi : w_lane_lo;

// MIDI / AUX SPI port: the byte sits in whichever lane this beat uses, so a
// STRH at 0x150 (the hardware access GBATEK documents) and a STR carrying
// the halfword high both land correctly. Strobes are issued from the FSM
// below, one cycle per transaction.
assign midi_addr  = io_addr;
assign midi_wdata = beat_hi ? w_lane_hi : w_lane_lo;

// 3D window: 0x04000400..0x040007FF -> geometry engine. The GXFIFO is a
// 32-bit port on real hardware, so the master word is forwarded as-is.
assign gx_addr = io_addr[9:0];
assign gx_data = wdata;

//------------------------------------------------------------------
// Address decode
//------------------------------------------------------------------
wire is_bios   = (a[31:14] == 18'd0) ||                       // 0x00000000
                 (a[31:16] == 16'hFFFF && a[15:14] == 2'b00); // 0xFFFF0000
wire is_ram    = (a[31:24] == 8'h02);
wire is_shared = (a[31:24] == 8'h03 && a[23] == 1'b0);
wire is_a7wram = (a[31:24] == 8'h03 && a[23] == 1'b1);
wire is_io     = (a[31:24] == 8'h04);
// 0x04100000 is the IPC receive FIFO, on its own 64 KB page: it shares the
// low address with DISPCNT, so the page bit selects between them
wire is_ipc_pg = (a[31:16] == 16'h0410);
wire is_io_reg = is_io && !is_ipc_pg;
wire is_gx     = !m7_active &&                   // ARM9 only: from the ARM7
                 ((io_addr[15:9] == 7'd2) ||     // the same addresses are
                  (io_addr[15:9] == 7'd3));      // the sound registers
// 0x04000400..0x0400051F from the ARM7: SOUND0-15 at 0x400+x*0x10, then
// SOUNDCNT (0x500) and SOUNDBIAS (0x504). Bits 8:9 == 2 covers 0x400-0x5FF.
wire is_spu    = is_io_reg && m7_active && (io_addr[15:9] == 7'd2);
wire is_pal    = (a[31:24] == 8'h05);
wire is_vram   = (a[31:24] == 8'h06);
wire is_oam    = (a[31:24] == 8'h07);
wire is_cart   = (a[31:24] == 8'h08);
// Slot-2 rumble pak: a latch on the cart port's /WR and AD1 that takes the
// first 64 KB of the cart window away from the ROM and answers reads with the
// pak's own open-bus pattern (GBATEK: halfword[i] = i and FFFDh). With the OSD
// row off, 0x08000000 is cart space again, as on a DS with no pak fitted.
wire is_rumble  = rumble_pak && (a[31:16] == 16'h0800);
wire [11:0] rmb_i = a[12:1];                        // halfword index
wire [15:0] rmb_lo = {4'd0, rmb_i} & 16'hFFFD;
wire [15:0] rmb_hi = {4'd0, rmb_i + 12'd1} & 16'hFFFD;
wire [31:0] rumble_word = {rmb_hi, rmb_lo};
// Slot-2 RAM expansion pak: the 8 MB the DS maps at 0x09000000..0x097FFFFF
// when one is in the slot. With the OSD row off nothing decodes here, which
// is exactly what a DS with an empty slot does.
wire is_exp    = ram_exp && (a[31:23] == 9'd18);
wire is_private = is_bios | is_shared | is_a7wram | is_io | is_pal | is_oam;

//------------------------------------------------------------------
// system I/O block: timers, IPC, maths, IRQ banks, HALT
//------------------------------------------------------------------
wire [15:0] sio_rdata;
wire [31:0] sio_recv;
wire        sio_ie9_w, sio_if9_w, sio_ime9;
wire        sio_irq9, sio_irq7, sio_halt;
wire [31:0] sio_ie9, sio_if9, sio_ie7, sio_if7;
wire        sio_ime7;

wire sio_acc = (state == S_PRIV) && is_io_reg;
wire sio_we  = sio_acc && m_wr;

//------------------------------------------------------------------
// Timers: clocked by the ARM7
//------------------------------------------------------------------
// On the DS the four timers are a divider of the same 33.513982 MHz clock the
// ARM7 runs on -- GBATEK, *DS Timers*: "F = 33.513982 MHz (for both NDS9 and
// NDS7)" -- so a timer counts ARM7 cycles and nothing else. They are ticked
// from `ce7` for that reason, which keeps both ratios the hardware has (the
// ARM9 sees two timer ticks per own cycle, the ARM7 one) and makes the OSD's
// CPU overclock row scale the timers with the ARM7 it scales instead of
// leaving them behind on a clock of their own.
//
// The RTC is the exception, and it gets its own reference below.

//------------------------------------------------------------------
// Reference clock for the real-time clock
//------------------------------------------------------------------
// The RTC is an S-35180 with its own crystal: a second is a second whatever
// the CPU domain is doing, so its divider is fed from a free-running
// reference rather than from the ARM7's enable. clk_sys is the DS's
// 67.0274 MHz, so that reference is simply clk/2 = 33.5137 MHz — exactly the
// ARM7's nominal clock, independent of the OSD overclock row — and no
// fractional accumulator is needed any more.
reg ref_div = 1'b0;

wire ref_tick = ref_div;

always @(posedge clk) ref_div <= ~ref_div;

// DMA completions are IF.8..11; keypad (IF.12) and cartridge (IF.13) follow
// with their own blocks.
wire [31:0] irq_src9 = {20'd0, dma_irq, 8'd0} & 32'h0000_0F00;

// Hinge interrupt 22 (GBATEK *DS Keypad*). The lid is an edge source, not
// a level: a shell left shut must raise one interrupt, not one every cycle,
// so the hinge is held for a clock and the source takes the difference. IF
// is sticky and write-1-to-clear per CPU, so one cycle is enough to latch it.
reg  hinge_d = 1'b0;
always @(posedge clk) begin
	if (reset) hinge_d <= 1'b0;
	else       hinge_d <= hinge_closed;
end
wire hinge_edge = hinge_closed ^ hinge_d;

wire [31:0] irq_src7 = ({20'd0, dma_irq, 8'd0} & 32'h0000_0F00) |
                       (hinge_edge ? 32'h0040_0000 : 32'd0);

sys_io u_sys_io (
	.clk(clk), .reset(reset), .tick(ce7), .tick33(ref_tick),
	.cpu9(m9_active), .addr(io_addr), .acc(sio_acc), .we(sio_we),
	.wdata(beat_hi ? w_lane_hi : w_lane_lo),
	.wdata32(wdata),
	.rdata(sio_rdata),
	.recv_hit(is_ipc_pg && (io_addr == 16'h0000)),
	.recv_rdata(sio_recv),		.touch_x(touch_x), .touch_y(touch_y), .touch_down(touch_down),
		.mic_in(mic_in), .lang(lang),
		.irq_src9(irq_src9), .irq_src7(irq_src7),
	.ie9(sio_ie9), .if9(sio_if9), .ime9(sio_ime9), .irq9(sio_irq9),
	.ie7(sio_ie7), .if7(sio_if7), .ime7(sio_ime7), .irq7(sio_irq7),
	.arm7_halt(sio_halt)
);

assign irq_master_enable = sio_ime9;
assign irq_enable  = sio_ie9;
assign irq_flags   = sio_if9;
assign irq9_cpu    = sio_irq9;
assign irq7_cpu    = sio_irq7;
assign arm7_halt   = sio_halt;
// AUX SPI / MIDI block (0x04000150..0x0400015A)
wire is_midi   = is_io && (io_addr >= 16'h0150 && io_addr <= 16'h015A);

// SPU register window: one-cycle strobe in the private-access state, the
// same shape sys_io uses for its write ports
assign spu_acc   = (state == S_PRIV) && is_spu;
assign spu_we    = spu_acc && m_wr;
assign spu_addr  = io_addr;
assign spu_wdata = beat_hi ? w_lane_hi : w_lane_lo;

//------------------------------------------------------------------
// Read data for private regions
//------------------------------------------------------------------
reg [31:0] rd_word;
always @(*) begin
	rd_word = 32'h0000_0000;
	if (is_ipc_pg && io_addr == 16'h0000) begin
		// IPCFIFORECV is a 32-bit port of its own (0x04100000), which is why
		// the page bit is decoded rather than the low half only
		rd_word = sio_recv;
	end else if (is_io_reg) begin
		case (io_addr)
		16'h0130: rd_word = {16'h0000, keyinput};
		16'h0132: rd_word = {16'h0000, keycnt};
		// the extended keypad is ARM7-only: from the ARM9 this address is
		// not a register, so it keeps the reset value
		16'h0136: rd_word = m7_active ? {16'h0000, extkeyin} : 32'h0000_0000;
		16'h0204: rd_word = {16'h0000, exmemcnt};
		16'h0304: rd_word = {16'h0000, powcnt1};
		16'h0000: rd_word = {16'h0000, dispcnt_a};
		16'h1000: rd_word = {16'h0000, dispcnt_b};
		default:  rd_word = {16'h0000, sio_rdata};
		endcase
		// DMA channel registers (0xB0..0xDF)
		if (io_addr >= 16'h00B0 && io_addr <= 16'h00DF)
			rd_word = {16'h0000, dma_reg_rdata};
		// AUX SPI / MIDI: CNT at 0x150 (busy in bit 0), received byte at 0x15A
		if (is_midi)
			rd_word = {16'h0000, midi_rdata};
		// sound registers (ARM7): the SPU returns one halfword per beat,
		// so a 32-bit read assembles SOUNDxCNT/SAD/LEN from two of them
		if (is_spu)
			rd_word = {16'h0000, spu_rdata};
		// GXSTAT, RAM_COUNT and the matrix registers reflect the 3D block
		if (is_gx)
			rd_word = gx_rdata;
	end else if (is_bios) begin
		rd_word = 32'hE1A0_0000; // MOV r0,r0 (NOP) — HLE dispatch in M1
	end
	// palette and OAM come from their registered read ports (priv_data below)
	// VRAM reads 0 until bank storage lands (M2)
end

// WRAM BRAMs answer with a registered read (one cycle, captured before
// S_CPATCH consumes it); the shared index/idx are stable per transaction.
reg [31:0] wram_q, wram7_q, pal_q, oam_q;
always @(posedge clk) begin
	wram_q  <= {wram_s3[shared_idx], wram_s2[shared_idx],
	            wram_s1[shared_idx], wram_s0[shared_idx]};
	wram7_q <= {wram_73[a7_idx], wram_72[a7_idx],
	            wram_71[a7_idx], wram_70[a7_idx]};
	// The CPU's palette/OAM pair, registered the same way as the WRAM read:
	// the address is held for the whole transaction, so the pair is waiting
	// when S_CPATCH consumes it (two copies, one per halfword)
	pal_q <= {pal_cpu_hi[pal_idx + 10'd1], pal_cpu_lo[pal_idx]};
	oam_q <= {oam_cpu_hi[pal_idx + 10'd1], oam_cpu_lo[pal_idx]};
	// engine-facing palette/OAM read ports, one copy each
	pal_rd_a <= pal_eng_a[pal_ra_a];
	pal_rd_b <= pal_eng_b[pal_ra_b];
	oam_rd_a <= oam_eng_a[oam_ra_a];
	oam_rd_b <= oam_eng_b[oam_ra_b];
end

// the write side: all four copies of each memory are written together
always @(posedge clk) begin
	if (pal_we) begin
		pal_cpu_lo[pal_wa] <= pal_wd;
		pal_cpu_hi[pal_wa] <= pal_wd;
		pal_eng_a [pal_wa] <= pal_wd;
		pal_eng_b [pal_wa] <= pal_wd;
	end
	if (oam_we) begin
		oam_cpu_lo[oam_wa] <= oam_wd;
		oam_cpu_hi[oam_wa] <= oam_wd;
		oam_eng_a [oam_wa] <= oam_wd;
		oam_eng_b [oam_wa] <= oam_wd;
	end
end

wire [31:0] priv_data = is_shared ? wram_q :
                        is_a7wram ? wram7_q :
                        is_pal    ? pal_q  :
                        is_oam    ? oam_q  : rd_word;

// final response word (VRAM is a halfword-pair path, not a private BRAM)
wire [31:0] resp_word = is_vram    ? {hi_half, lo_half} :
                        is_private ? priv_data :
                        is_ram     ? {cheat_hit && cheat_patch_hi_en ? cheat_patch_hi : hi_half,
                                      cheat_hit ? cheat_patch : lo_half} :
                        is_exp     ? {hi_half, lo_half} :
                        is_rumble  ? rumble_word :
                        is_cart    ? {hi_half, lo_half} : 32'h0;

//------------------------------------------------------------------
// FSM
//------------------------------------------------------------------
always @(posedge clk) begin
	m9_ready <= 0;
	m7_ready <= 0;
	d_ready  <= 0;
	vramcnt_we_r <= 0;
	dma_reg_we_r <= 0;
	midi_wr <= 0;
	midi_rd <= 0;
	pal_we  <= 0;
	oam_we  <= 0;
	ea_we <= 0;
	eb_we <= 0;
	gx_we <= 0;
	cheat_chk_en <= 0;
	cart_req <= 0;
	ram_req  <= 0;
	vram_req <= 0;
	// DMA completion pulses are IRQ8..11; sys_io latches them into both banks

	// A master is blocked from the moment it is answered until its strobe
	// actually drops, so one access cannot be served twice. That clear is
	// deliberately unconditional rather than done in S_IDLE: these strobes are
	// levels, and a CPU that re-asserts its next request in the very cycle after
	// it takes a response never leaves the bus an idle cycle to notice in. Seen
	// from S_IDLE alone, it would stay blocked for good — tb_cpu_clk, which is
	// the first bench to put two continuously-fetching cores on this bus, hung
	// on exactly that (the other master's transaction swallowed the one-cycle
	// gap).
	if (!m9_req) m9_block <= 0;
	if (!m7_req) m7_block <= 0;
	if (!d_req)  d_block  <= 0;

	case (state)

	S_IDLE: begin
		cheat_chk_en <= 0;
		// round-robin over the three masters starting at rr
		if (((m9_req && !m9_block) + (m7_req && !m7_block) + (d_req && !d_block)) > 1) begin
			case (rr)
			2'd0: if (m9_req && !m9_block) begin m9_active<=1; m7_active<=0; d_active<=0; rr<=2'd1; state<=S_PRIV; end
			      else if (m7_req && !m7_block) begin m7_active<=1; m9_active<=0; d_active<=0; rr<=2'd2; state<=S_PRIV; end
			      else begin d_active<=1; m9_active<=0; m7_active<=0; rr<=2'd0; state<=S_PRIV; end
			2'd1: if (m7_req && !m7_block) begin m7_active<=1; m9_active<=0; d_active<=0; rr<=2'd2; state<=S_PRIV; end
			      else if (d_req && !d_block) begin d_active<=1; m9_active<=0; m7_active<=0; rr<=2'd0; state<=S_PRIV; end
			      else begin m9_active<=1; m7_active<=0; d_active<=0; rr<=2'd1; state<=S_PRIV; end
			2'd2: if (d_req && !d_block) begin d_active<=1; m9_active<=0; m7_active<=0; rr<=2'd0; state<=S_PRIV; end
			      else if (m9_req && !m9_block) begin m9_active<=1; m7_active<=0; d_active<=0; rr<=2'd1; state<=S_PRIV; end
			      else begin m7_active<=1; m9_active<=0; d_active<=0; rr<=2'd2; state<=S_PRIV; end
			default: ;
			endcase
		end else if (m9_req && !m9_block) begin
			m9_active <= 1; m7_active <= 0; d_active <= 0; state <= S_PRIV;
		end else if (m7_req && !m7_block) begin
			m7_active <= 1; m9_active <= 0; d_active <= 0; state <= S_PRIV;
		end else if (d_req && !d_block) begin
			d_active <= 1; m9_active <= 0; m7_active <= 0; state <= S_PRIV;
		end
	end

	S_PRIV: begin
		is_read  <= m_rd;
		need_b   <= (m_wr ? (be[3:2] != 2'b00 && be[1:0] != 2'b00)
		                   : (be[3:2] != 2'b00)) &&
		             (is_ram || is_exp || (is_cart && !is_rumble) ||
			 is_shared || is_a7wram ||
		              is_pal || is_oam || is_io || is_vram);
		lo_half  <= 16'h0000;
		hi_half  <= 16'h0000;

		if (is_vram && (m_rd || m_wr)) begin
			// 16-bit beats through the vram_arbiter (held until valid)
			vram_req  <= 1;
			vram_wr   <= m_wr;
			vram_off  <= a[19:0];
			vram_hi_beat <= beat_hi;   // odd halfword: lanes in [31:16]
			state     <= S_WAIT_A;
		end else if ((is_ram || is_exp) && (m_rd || m_wr)) begin
			ram_req   <= 1;
			ram_wr    <= m_wr;
			ram_addr  <= is_exp ? exp_word_lo : ram_word_lo;
			ram_wdata <= beat_hi ? w_lane_hi : w_lane_lo;
			ram_be    <= beat_hi ? be[3:2]   : be[1:0];
			state     <= S_WAIT_A;
		end else if (is_rumble) begin
			// the whole device: one latch bit, taken from the written halfword
			if (m_wr) rumble_lvl <= w_lane_lo[1];
			state <= S_RESP;
		end else if (is_cart && m_rd) begin
			cart_req  <= 1;
			cart_addr <= {a[25:2], 2'b00};
			state     <= S_WAIT_A;
		end else if (is_cart && m_wr) begin
			// ROM command writes (unlock sequence) — M4
			state <= S_RESP;
		end else begin
			// private region: perform in this cycle, respond in S_RESP
			if (m_wr) begin
				if (is_shared) begin
					// one lane per byte enable: the untouched lanes keep their
					// contents in the RAM itself, with no read-back needed
					if (be[0]) wram_s0[shared_idx] <= wdata[7:0];
					if (be[1]) wram_s1[shared_idx] <= wdata[15:8];
					if (be[2]) wram_s2[shared_idx] <= wdata[23:16];
					if (be[3]) wram_s3[shared_idx] <= wdata[31:24];
				end else if (is_a7wram) begin
					if (be[0]) wram_70[a7_idx] <= wdata[7:0];
					if (be[1]) wram_71[a7_idx] <= wdata[15:8];
					if (be[2]) wram_72[a7_idx] <= wdata[23:16];
					if (be[3]) wram_73[a7_idx] <= wdata[31:24];
				end
				else if (is_pal) begin
					// halfword granularity: the addressed halfword
					// takes its lane; pal_idx+1 only on 32-bit writes,
					// and that one goes out in S_RESP (one write address
					// per cycle, shared by all four copies)
					pal_we  <= 1'b1;
					pal_wa  <= pal_idx;
					pal_wd  <= (be[1:0] != 2'b00) ? wdata[15:0] : wdata[31:16];
					pal2_we <= (be[1:0] != 2'b00) && (be[3:2] != 2'b00);
					pal2_wa <= pal_idx + 10'd1;
					pal2_wd <= wdata[31:16];
				end else if (is_oam) begin
					oam_we  <= 1'b1;
					oam_wa  <= pal_idx;
					oam_wd  <= (be[1:0] != 2'b00) ? wdata[15:0] : wdata[31:16];
					oam2_we <= (be[1:0] != 2'b00) && (be[3:2] != 2'b00);
					oam2_wa <= pal_idx + 10'd1;
					oam2_wd <= wdata[31:16];
				end else if (is_io_reg) begin
					// timers, IPC, maths, the IRQ banks and HALT are written by
					// sys_io from this same access (sio_acc / sio_we above)
					case (io_addr)
					16'h0000: dispcnt_a <= w_lane_lo;
					16'h1000: dispcnt_b <= w_lane_lo;
					16'h0132: keycnt    <= w_lane_lo;
					16'h0204: exmemcnt  <= w_lane_lo;
					16'h0304: powcnt1 <= w_lane_lo;
					default: ;
					endcase
					if (io_addr >= 16'h0240 && io_addr <= 16'h0248)
						vramcnt_we_r <= 1;
					// MIDI byte write / read of the receive latch
					if (is_midi) midi_wr <= 1;
					if (io_addr >= 16'h00B0 && io_addr <= 16'h00DF)
						dma_reg_we_r <= 1;
					// 3D command / matrix window (0x0400..0x07FF)
					if (is_gx) gx_we <= 1;
					// engine register writes (A: 0x000..0x07F, B: 0x1000..0x107F)
					if (io_addr[15:7] == 9'd0) ea_we <= 1;
					else if (io_addr[15:7] == 9'h20) eb_we <= 1;
				end
			end
			state <= S_RESP;
		end
	end

	S_WAIT_A: begin
		// held requests: the SDRAM arbiter may be busy with the engines
		// or the save path; keep asserting until the transfer completes
		if ((is_ram || is_exp) && !ram_done)   ram_req  <= 1;
		if (is_vram && !vram_valid) vram_req <= 1;
		if ((is_ram || is_exp) && ram_done) begin
			lo_half <= ram_rdata;
			if (m_wr && !is_read) begin
				// write sequence: first half done
				if (need_b) state <= S_REQ_B;
				else        state <= S_RESP;
			end else if (need_b) begin
				ram_req   <= 1;
				ram_wr    <= 0;
				ram_addr  <= is_exp ? exp_word_hi : ram_word_hi;
				ram_be    <= 2'b11;
				state     <= S_WAIT_B;
			end else state <= S_RESP;
		end else if (is_vram && vram_valid) begin
			lo_half <= vram_rdata;
			if (m_wr && !is_read) begin
				if (need_b) begin
					vram_req <= 1;
					vram_wr  <= 1;
					vram_off <= vram_off + 20'd2;
					state    <= S_REQ_B;
				end else state <= S_RESP;
			end else if (need_b) begin
				vram_req <= 1;
				vram_wr  <= 0;
				vram_off <= vram_off + 20'd2;
				state    <= S_WAIT_B;
			end else state <= S_RESP;
		end else if (is_cart && cart_valid) begin
			lo_half <= cart_rdata;
			if (need_b) begin
				cart_req  <= 1;
				cart_addr <= {a[25:2], 2'b00} + 26'd2;
				state     <= S_WAIT_B;
			end else state <= S_RESP;
		end
	end

	S_REQ_B: begin
		// issue the high halfword of a split write
		if (is_vram) begin
			vram_req <= 1;
			vram_wr  <= 1;
			vram_hi_beat <= 1;
			state    <= S_WAIT_B;
		end else begin
			ram_req   <= 1;
			ram_wr    <= 1;
			ram_addr  <= is_exp ? exp_word_hi : ram_word_hi;
			ram_wdata <= w_lane_hi;
			ram_be    <= be[3:2];
			state     <= S_WAIT_B;
		end
	end

	S_WAIT_B: begin
		if ((is_ram || is_exp) && !ram_done)   ram_req  <= 1;
		if (is_vram && !vram_valid) vram_req <= 1;
		if ((is_ram || is_exp) && ram_done) begin
			hi_half <= ram_rdata;
			state   <= S_RESP;
		end else if (is_vram && vram_valid) begin
			hi_half <= vram_rdata;
			state   <= S_RESP;
		end else if (is_cart && cart_valid) begin
			hi_half <= cart_rdata;
			state   <= S_RESP;
		end
	end

	S_RESP: begin
		// Offer the read to the cheat engine; the patched value lands
		// one cycle later in S_CPATCH.
		cheat_chk_en   <= is_read && !m_wr && is_ram;
		cheat_chk_addr <= a;
		// a read of the AUX receive register pops the byte (0x15A only; the
		// CNT readback at 0x150 must not consume anything)
		if (is_read && !m_wr && is_midi && io_addr[7:1] == 7'h2D) midi_rd <= 1;
		cheat_chk_word <= {hi_half, lo_half};
		// the neighbour halfword of a 32-bit palette/OAM write, one cycle
		// after the first (both land before the next transaction reads)
		if (pal2_we) begin
			pal_we  <= 1'b1;
			pal_wa  <= pal2_wa;
			pal_wd  <= pal2_wd;
			pal2_we <= 1'b0;
		end
		if (oam2_we) begin
			oam_we  <= 1'b1;
			oam_wa  <= oam2_wa;
			oam_wd  <= oam2_wd;
			oam2_we <= 1'b0;
		end
		state          <= S_CPATCH;
	end

	S_CPATCH: begin
		// The cheat walk offers one cycle for the common case (no code, or one
		// code, on this address) and one clock per extra code when several sit
		// on the same address, so hold the response until it says it is done.
		// A completed walk is ready the cycle it is offered, so this costs
		// nothing on an ordinary read.
		if (is_ram && is_read && !m_wr && !cheat_ready) begin
			cheat_chk_en <= 1'b1;      // keep the walk offered while it runs
			state        <= S_CPATCH;
		end else begin
			// one response word for all masters (cheat patch included)
			if (m9_active) begin
				if (is_read && !m_wr) m9_rdata <= resp_word;
				m9_ready <= 1;
				m9_block <= 1;
			end else if (m7_active) begin
				if (is_read && !m_wr) m7_rdata <= resp_word;
				m7_ready <= 1;
				m7_block <= 1;
			end else if (d_active) begin
				if (is_read && !m_wr) d_rdata <= resp_word;
				d_ready <= 1;
				d_block <= 1;
			end
			m9_active  <= 0;
			m7_active  <= 0;
			d_active   <= 0;
			state      <= S_IDLE;
		end
	end

	default: state <= S_IDLE;
	endcase

	if (reset) begin
		state <= S_IDLE;
		m9_active <= 0; m7_active <= 0; d_active <= 0;
		m9_block <= 0; m7_block <= 0; d_block <= 0;
		vram_req <= 0; vram_wr <= 0; vram_off <= 0; vram_hi_beat <= 0;
		dma_reg_we_r <= 0; ea_we <= 0; eb_we <= 0; gx_we <= 0;
		m9_ready  <= 0; m7_ready  <= 0;
		vramcnt_we_r <= 0; cheat_chk_en <= 0;
		cart_req <= 0; ram_req <= 0; ram_wr <= 0;
		midi_wr <= 0; midi_rd <= 0;
		pal_we <= 0; oam_we <= 0; pal2_we <= 0; oam2_we <= 0;
		dispcnt_a   <= 0;
		dispcnt_b   <= 0;
		rumble_lvl  <= 0;
	end
end

// cheat_patch is applied by the CPU read service in M1; touch/mic and
// observations are consumed as the engines land.
wire _unused = &{1'b0, touch_x, touch_y, touch_down, mic_in};
	// Read the sink so the analyser does not call it "assigned but never read"
	// (warning 10036). The branch cannot be taken and synthesises to nothing:
	// measured on a throwaway module, the warning goes from 1 to 0 with this
	// line and the netlist is unchanged.
	always @(*) if (_unused) begin end


endmodule
