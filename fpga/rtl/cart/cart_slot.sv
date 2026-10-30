//============================================================================
// NDS MiSTer Test — Slot-1 cartridge
//
// Pure DS support, region-free: any .nds boots regardless of header
// region, and the whole ROM lives in the DE10-Nano's DDR3 so 256 Mbit
// (32 MB) carts — and anything up to the DS's 4 Gbit maximum — fit
// without banking tricks:
//
//   DDR3:  cart ROM (full image, up to 512 MB)
//   SDRAM: main RAM, save data, palette/OAM/VRAM overflow
//
// The download stream is decoupled from DDR3 by a 64-line FIFO; when the
// FIFO fills, ioctl_wait asks the HPS to pause the transfer — no bytes
// can be lost regardless of DDR3 contention with the scaler.
//
// DDR3 protocol: the framework DDRAM interface is Avalon waitrequest —
// RD/WE are asserted only while BUSY is low and held until the
// controller takes them (BUSY pulses for refresh and other masters).
// The write drain and the CPU window bridge arbitrate so RD and WE are
// never asserted in the same cycle: the read path wins when it wants the
// bus, the drain waits while a read is in flight.
//
// A download whose size is not a multiple of 8 bytes ends mid-line; the
// trailing words are flushed as one partial line with the matching byte
// enables so the tail of the image is never lost (byte slots beyond the
// image stay unwritten — CPU fetches stop at rom_bytes).
//
// TODO(M1): prefetch FIFO on the read side to satisfy cart waitstates.
// TODO(M4): save sector path via sd_* into SDRAM, save erase, and the
//           cart unlock command sequence (0x00000555/0x00000AAA) that
//           some 256 Mbit+ carts issue before large reads.
//============================================================================
module cart_slot (
	input            clk,
	input            reset,

	// HPS download stream (F1 -> .nds, index 1). WIDE=1: one 16-bit word
	// per write; ioctl_addr counts bytes, steps by 2, and presents the
	// current word's byte address while ioctl_wr is high.
	input            ioctl_download,
	input     [26:0] ioctl_addr,
	input     [15:0] ioctl_dout,
	input            ioctl_wr,
	input     [15:0] ioctl_index,
	output           ioctl_wait,  // -> hps_io: pause the transfer

	// DE10-Nano DDR3 (framework DDRAM interface, hold-until-accept)
	output reg [7:0]  ddr_burstcnt = 8'd1,
	output     [28:0] ddr_addr,   // unit: 8-byte line (byte addr >> 3)
	output reg [63:0] ddr_din,
	output reg [7:0]  ddr_be,
	output reg        ddr_we = 0,
	output reg        ddr_rd = 0,
	input             ddr_busy,
	input             ddr_dout_ready,
	input      [63:0] ddr_dout,

	// CPU cart-window read port (byte offset into the ROM image)
	input             win_req,
	input      [25:0] win_addr,
	output reg        win_valid,
	output reg [15:0] win_data,

	// game slots — the boot menu switches which one the window reads.
	// Four fixed 64 MB regions (the window is 64 MB wide, so a slot holds
	// exactly what a game can see), each named by the title in the ROM's
	// own header, so no file names are needed.
	input      [1:0]  boot_slot,   // slot the CPU window reads
	output     [1:0]  load_slot,   // slot the next download goes into
	output     [3:0]  slot_valid,  // slots holding a game
	input             slot_clear,  // forget every slot
	input      [1:0]  hdr_slot,    // header read port: 16 bytes/slot
	input      [3:0]  hdr_char,
	output     [7:0]  hdr_data,
	output     [31:0] slot_caps,  // header byte 0x80 (capacity) per slot
	output     [31:0] slot9_entry, // header 0x24: ARM9 entry point, boot slot
	output     [31:0] slot7_entry, // header 0x34: ARM7 entry point, boot slot
	output     [15:0] slot_save,  // save type recorded per slot, 4 bits each
	output     [15:0] slot_save_det, // save type the probe found, 4 bits each

	// save control (M4 implements the sd_* sector path). save_type is the
	// OSD row: it records into the active slot, and the slot's own record is
	// what the core will use once the save path exists.
	input             erase_save,
	input       [2:0] save_type,

	// SDRAM master for save data (via mem_arbiter, M4 drives requests)
	output           save_req,
	output           save_wr,
	output    [24:0] save_addr,
	output    [15:0] save_din,
	input            save_done,

	output reg        cart_loaded = 0,
	output reg [31:0] rom_bytes = 0  // detected ROM size in bytes (up to 512 MB)
);

localparam SAVE_BASE = 25'h280000;
wire is_rom = ioctl_index[3:0] == 4'd1;
wire rom_dl = ioctl_download && is_rom;

//------------------------------------------------------------------
// game slots
//
// One slot is 2^23 DDR3 lines = 64 MB, which is exactly the reach of the
// cart window (win_addr is 26 bits), so four slots cost 256 MB and a game
// never straddles another. A download goes into the lowest empty slot, or
// over the oldest when they are all full. The ROM header's first 16 bytes
// are latched per slot -- 0x00..0x0B is the title and 0x0C..0x0F the game
// code, e.g. "AMCE" for Mario Kart DS (USA) -- so the boot menu can name a
// game without the HPS ever telling the core a file name. The game code is
// what separates regional variants: they share a title, not a code. Byte
// 0x80 of the same header is kept per slot too: it is the capacity the game
// declares, which is how the menu shows that a 128 MB game cannot fit a
// 64 MB slot before it is booted. A save type is kept per slot as well, but
// no header field carries one: see the record itself for where it comes from.
//------------------------------------------------------------------
localparam [22:0] SLOT_LINES = 23'h7FFFFF;

reg  [3:0]  valid = 4'd0;
reg  [1:0]  wr_slot = 2'd0;
reg  [7:0]  hdr [0:63];         // 4 slots x 16 header bytes (title + code)
reg  [7:0]  caps [0:3];         // 4 slots x header byte 0x80 (capacity)
// header 0x24 / 0x34: where the game's ARM9 and ARM7 code starts. The HLE
// boot jumps there instead of running a BIOS, so the CPU needs no image.
reg  [31:0] entry9 [0:3];
reg  [31:0] entry7 [0:3];
reg  [15:0] saves = 16'd0;      // 4 slots x 4 bits (0..6 = OSD save type)

assign slot_valid = valid;
assign load_slot  = wr_slot;

wire [1:0] free_slot = !valid[0] ? 2'd0 :
                       !valid[1] ? 2'd1 :
                       !valid[2] ? 2'd2 :
                       !valid[3] ? 2'd3 : (wr_slot + 2'd1);

// header read port for the boot menu (asynchronous: a 64-byte array)
wire [5:0] hdr_idx = {hdr_slot, hdr_char};   // 0..15 within the slot
assign hdr_data = hdr[hdr_idx];
assign slot_caps = {caps[3], caps[2], caps[1], caps[0]};   // byte i = slot i
assign slot9_entry = entry9[boot_slot];
assign slot7_entry = entry7[boot_slot];
assign slot_save = saves;                                  // bits 4i..4i+3 = slot i

//------------------------------------------------------------------
// Save chip and probe
//
// The cart contains the part the slot's record names, and the probe
// classifies what the bus answers -- so the type the core shows and uses
// is a measurement of the emulated cart, not a copy of the OSD row. It
// walks the four slots and stops when every record has been confirmed.
//------------------------------------------------------------------
wire        chip_cs, chip_slot, chip_resp;
wire  [7:0] chip_din, chip_dout;
wire  [2:0] det_type;
wire        det_valid, det_done;

reg  [1:0]  pslot = 2'd0;      // slot the probe is looking at
reg  [15:0] dets = 16'd0;      // per slot: {1'b1, type} once probed
reg  [15:0] pseed = 16'd0;     // per slot: the record the verdict was measured against
reg  [2:0]  probe_seed = 3'd0; // the record the running probe was launched on
reg  [2:0]  chip_cfg = 3'd0;   // which part the cart currently holds
reg         probe_go = 0;
reg         probing = 0;

wire [3:0]  seed_w = saves[{pslot, 2'b00} +: 4];
wire [2:0]  seed_i = seed_w[2:0];
wire [3:0]  det_w  = dets[{pslot, 2'b00} +: 4];
wire [3:0]  psd_w  = pseed[{pslot, 2'b00} +: 4];
// a slot is probed once per record it is given: a verdict that disagrees
// with the record is a measurement, not a reason to probe again forever
wire        need_probe = valid[pslot] && (!det_w[3] || psd_w[2:0] != seed_i);

// clearing the slots also abandons a probe in flight: the chip is taken back
// to its idle state instead of being left mid-transaction, which would block
// every later probe (the script only starts from its idle state)
wire chip_reset = reset || slot_clear;

save_spi u_chip (
	.clk(clk), .reset(chip_reset),
	.cfg(chip_cfg),
	.cs_n(chip_cs), .din(chip_din), .slot(chip_slot),
	.dout(chip_dout), .resp(chip_resp),
	.status_o(), .present()
);

save_probe u_probe (
	.clk(clk), .reset(chip_reset),
	.start(probe_go),
	.cs_n(chip_cs), .din(chip_din), .slot(chip_slot),
	.dout(chip_dout), .resp(chip_resp),
	.det_type(det_type), .valid(det_valid), .done(det_done),
	.seen_status(), .seen_id(), .seen_cap()
);

// the menu shows what was detected; a slot with no chip, or one not yet
// probed, shows nothing at all rather than a guess
wire [3:0] sd0 = dets[3]  ? {1'b0, dets[2:0]}  : 4'd0;
wire [3:0] sd1 = dets[7]  ? {1'b0, dets[6:4]}  : 4'd0;
wire [3:0] sd2 = dets[11] ? {1'b0, dets[10:8]} : 4'd0;
wire [3:0] sd3 = dets[15] ? {1'b0, dets[14:12]} : 4'd0;
assign slot_save_det = {sd3, sd2, sd1, sd0};

// The cart holds one part at a time -- the one the slot under the probe calls
// for -- so its type is latched at the start of each probe and held until the
// next one starts. Following the rotating pointer (or the record) would let
// the chip change identity between two bytes of a transaction, and the verdict
// would describe a part that never existed.
always @(posedge clk) begin
	if (reset || slot_clear) begin
		probe_seed <= 3'd0;
		chip_cfg   <= 3'd0;
	end else if (probe_go) begin
		probe_seed <= seed_i;
		chip_cfg   <= seed_i;
	end
end

// the probe owns `dets` and `pseed`, including the invalidation below, so
// the download start is detected here rather than driving the same regs from
// the download block (one variable, one always block)
reg dl_d2 = 1'b0;

always @(posedge clk) begin
	probe_go <= 1'b0;
	dl_d2    <= rom_dl;
	if (reset || slot_clear) begin
		pslot   <= 2'd0;
		probing <= 1'b0;
		dets    <= 16'd0;
		pseed   <= 16'd0;
	end else begin
		if (det_done) begin
			// a verdict for a slot that was just forgotten describes nothing
			if (valid[pslot]) begin
				dets[{pslot, 2'b00} +: 4]  <= {1'b1, det_type};
				pseed[{pslot, 2'b00} +: 4] <= {1'b0, probe_seed};
			end
			pslot   <= pslot + 2'd1;
			probing <= 1'b0;
		end else if (!probing && !rom_dl && need_probe) begin
			probe_go <= 1'b1;
			probing  <= 1'b1;
		end else if (!probing) begin
			// nothing to confirm here: look at the next slot
			pslot <= pslot + 2'd1;
		end

		// a download fills this slot with a new game, so whatever was
		// detected there described the previous one: drop it and re-probe
		if (rom_dl && !dl_d2) begin
			dets[{free_slot, 2'b00} +: 4]  <= 4'd0;
			pseed[{free_slot, 2'b00} +: 4] <= 4'd0;
		end
	end
end



//------------------------------------------------------------------
// line FIFO: 16-bit words -> 64-bit DDR3 lines
//------------------------------------------------------------------
localparam FIFO_DEPTH = 64;
reg [63:0] fifo_data [0:FIFO_DEPTH-1];
reg [28:0] fifo_line [0:FIFO_DEPTH-1];
reg  [7:0] fifo_be   [0:FIFO_DEPTH-1];
reg  [5:0] wr_ptr = 0;
reg  [5:0] rd_ptr = 0;

wire [5:0] fifo_used = wr_ptr - rd_ptr;
wire       fifo_empty = (wr_ptr == rd_ptr);
wire       fifo_full  = (fifo_used >= 6'd60); // pause download near full

assign ioctl_wait = fifo_full;

//------------------------------------------------------------------
// read-bridge state (declared before the drain, which arbitrates on it)
//------------------------------------------------------------------
localparam R_IDLE = 2'd0, R_WAIT = 2'd1, R_DONE = 2'd2;
reg  [1:0] rstate = R_IDLE;
reg        pending_req = 0; // win_req pulse arrived while DDR busy

//------------------------------------------------------------------
// Block A — download stream state. Single driver for pack, pack_idx,
// line_no, wr_ptr, fifo write side, cart_loaded and the tail flush:
// everything lives in one always block so no signal is multi-driven.
//------------------------------------------------------------------
reg [2:0]  save_type_d = 3'd0;
reg [15:0] pack [0:3];
reg  [1:0] pack_idx = 0;
reg [28:0] line_no = 0;
reg        dl_d = 0;
reg        tail_flush = 0;

// a full slot stops accepting new lines: the window could not read them
// anyway, and the next slot's game must not be overwritten
wire slot_full = (line_no[22:0] == SLOT_LINES);

always @(posedge clk) begin
	dl_d <= rom_dl;

	if (rom_dl && !dl_d) begin
		// start of a ROM download: reset the packer (a .cht load on
		// the shared pipe must never touch this state) and pick the slot
		cart_loaded <= 1'b0;
		wr_slot     <= free_slot;
		line_no     <= {free_slot, 23'd0};
		pack_idx    <= 2'd0;
		tail_flush  <= 1'b0;
		caps[free_slot] <= 8'hFF;   // unknown until 0x80 arrives
		entry9[free_slot] <= 32'h0000_0000;
		entry7[free_slot] <= 32'h0000_0000;
		saves[{free_slot, 2'b00} +: 4] <= {1'b0, save_type};   // the probe re-runs
	end else begin
		// ROM download finished: this slot now holds a game
		if (dl_d && !rom_dl) begin
			cart_loaded  <= 1'b1;
			valid[wr_slot] <= 1'b1;
		end

		// header bytes 0x00..0x0F: title 0x00..0x0B (ASCII padded with
		// zeros), game code 0x0C..0x0F. WIDE=1 delivers two bytes per
		// word at an even address, so the last pair starts at 0x0E.
		if (ioctl_wr && is_rom && ioctl_addr <= 27'd14) begin
			hdr[{wr_slot, 4'd0} + {2'd0, ioctl_addr[3:0]}]       <= ioctl_dout[7:0];
			hdr[{wr_slot, 4'd0} + {2'd0, ioctl_addr[3:0]} + 6'd1] <= ioctl_dout[15:8];
		end

		// header byte 0x80: the size the game declares, clamped to the DS's
		// 512 MB ceiling exactly as rom_bytes is, so the boot menu can show
		// which games fit the slot's 64 MB and which will be cut off
		if (ioctl_wr && is_rom && ioctl_addr == 27'h80)
			caps[wr_slot] <= (ioctl_dout[7:0] > 8'd12) ? 8'd12 : ioctl_dout[7:0];

		// header 0x24 (ARM9 entry) and 0x34 (ARM7 entry): two halfwords each,
		// latched little-endian as the WIDE stream delivers them
		if (ioctl_wr && is_rom && ioctl_addr == 27'h24)
			entry9[wr_slot][15:0]  <= ioctl_dout;
		if (ioctl_wr && is_rom && ioctl_addr == 27'h26)
			entry9[wr_slot][31:16] <= ioctl_dout;
		if (ioctl_wr && is_rom && ioctl_addr == 27'h34)
			entry7[wr_slot][15:0]  <= ioctl_dout;
		if (ioctl_wr && is_rom && ioctl_addr == 27'h36)
			entry7[wr_slot][31:16] <= ioctl_dout;

		// pack words into full 64-bit DDR lines
		if (ioctl_wr && is_rom && !fifo_full && !slot_full) begin
			pack[pack_idx] <= ioctl_dout;
			if (pack_idx == 2'd3) begin
				fifo_data[wr_ptr] <= {ioctl_dout, pack[2], pack[1], pack[0]};
				fifo_line[wr_ptr] <= line_no;
				fifo_be[wr_ptr]   <= 8'hFF;
				wr_ptr   <= wr_ptr + 6'd1;
				line_no  <= line_no + 29'd1;
				pack_idx <= 2'd0;
			end else begin
				pack_idx <= pack_idx + 2'd1;
			end
		end

		// queue a partial final line when the stream ends mid-line
		if (dl_d && !rom_dl && pack_idx != 2'd0) tail_flush <= 1'b1;

		// flush that partial line, retrying until the FIFO has room
		// (the FIFO could be near full when the stream ends)
		if (tail_flush && pack_idx != 2'd0 && !fifo_full) begin
			case (pack_idx)
				2'd1:    fifo_data[wr_ptr] <= {48'd0, pack[0]};
				2'd2:    fifo_data[wr_ptr] <= {32'd0, pack[1], pack[0]};
				default: fifo_data[wr_ptr] <= {16'd0, pack[2], pack[1], pack[0]};
			endcase
			fifo_line[wr_ptr] <= line_no;
			case (pack_idx)
				2'd1:    fifo_be[wr_ptr] <= 8'h03;
				2'd2:    fifo_be[wr_ptr] <= 8'h0F;
				default: fifo_be[wr_ptr] <= 8'h3F;
			endcase
			wr_ptr      <= wr_ptr + 6'd1;
			line_no     <= line_no + 29'd1;
			pack_idx    <= 2'd0;
			tail_flush  <= 1'b0;
		end
	end

	if (reset) begin
		cart_loaded <= 1'b0;
		tail_flush  <= 1'b0;
		// pack_idx/line_no are left alone; the next load resets them
	end

	// OSD action: forget every slot (the menu goes back to "no games")
	if (slot_clear) begin
		valid    <= 4'd0;
		wr_slot  <= 2'd0;
		saves    <= 16'd0;
	end

	// The OSD save-type row edits the game that is running, so each slot
	// keeps the type its own game was given and switching games switches the
	// type with it. A DS ROM header cannot supply this -- it has no save-type
	// field, and a real cart is classified by probing AUXSPI -- so this is a
	// per-game setting the core remembers, not something read from the ROM.
	save_type_d <= save_type;
	if (valid[boot_slot] && save_type != save_type_d)
		saves[{boot_slot, 2'b00} +: 4] <= {1'b0, save_type};
end

//------------------------------------------------------------------
// Block B — FIFO -> DDR3 drain. RD/WE are held until BUSY deasserts;
// a read wanting the port in the same cycle blocks the grant so RD and
// WE can never be high together.
//------------------------------------------------------------------
reg draining = 0;
reg [28:0] ddr_addr_wr = 0;
reg [28:0] ddr_addr_rd = 0;
always @(posedge clk) begin
	// accept: clear only when the controller took the write
	if (ddr_we && !ddr_busy) begin
		ddr_we   <= 1'b0;
		draining <= 1'b0;
	end

	// grant the next line when the port, the controller and the read
	// bridge are all idle
	if (!fifo_empty && !ddr_we && !draining && !ddr_busy && !ddr_rd
	    && !(rstate == R_IDLE && (pending_req || win_req))) begin
		ddr_burstcnt <= 8'd1;
		ddr_be       <= fifo_be[rd_ptr];
		ddr_addr_wr  <= fifo_line[rd_ptr];
		ddr_din      <= fifo_data[rd_ptr];
		ddr_we       <= 1'b1;
		draining     <= 1'b1;
		rd_ptr       <= rd_ptr + 6'd1;
	end

	// read path: latch the line number when a request first arrives
	// (even if DDR is busy then — the grant may happen later).
	// The window is 64 MB wide, so the address is the active slot's base
	// with the 23 in-slot line bits on top — exactly one slot is reachable.
	if (rstate == R_IDLE && win_req && !pending_req)
		ddr_addr_rd <= {boot_slot, win_addr[25:3]};
end

//------------------------------------------------------------------
// Device capacity: header byte 0x80 -> rom_bytes = 128 KB << cap,
// clamped to the DS's 4 Gbit (512 MB) ceiling. 32-bit because 256 MB
// and 512 MB (cap 11/12) do not fit in 28 bits.
//------------------------------------------------------------------
wire [7:0] cap_raw = ioctl_dout[7:0];
wire [7:0] cap = (cap_raw > 8'd12) ? 8'd12 : cap_raw;

always @(posedge clk) begin
	if (reset) rom_bytes <= 32'd0;
	else if (ioctl_wr && is_rom && ioctl_addr == 27'h80) begin
		rom_bytes <= 32'd131072 << cap;
	end
end

//------------------------------------------------------------------
// Block C — cart window read bridge: one outstanding DDR3 line at a
// time, little-endian halfwords (byte_addr[2:1]). RD is held until the
// controller accepts it; the grant waits for any in-flight write drain.
//------------------------------------------------------------------
reg [63:0] rline = 0;
reg [25:0] a_lat = 0;      // latched request address

always @(posedge clk) begin
	win_valid <= 1'b0;
	case (rstate)
	R_IDLE: begin
		if (win_req) begin
			a_lat       <= win_addr;
			pending_req <= 1'b1;
		end
		if ((pending_req || win_req) && !ddr_busy && !ddr_we
		    && !draining && !ddr_rd) begin
			ddr_rd      <= 1'b1;
			pending_req <= 1'b0;
			rstate      <= R_WAIT;
		end
	end
	R_WAIT: begin
		// hold RD until the controller takes it
		if (ddr_rd && !ddr_busy) ddr_rd <= 1'b0;
		if (ddr_dout_ready) begin
			rline  <= ddr_dout;
			rstate <= R_DONE;
		end
	end
	R_DONE: begin
		win_valid <= 1'b1;
		case (a_lat[2:1])
		2'd0: win_data <= rline[15:0];
		2'd1: win_data <= rline[31:16];
		2'd2: win_data <= rline[47:32];
		default: win_data <= rline[63:48];
		endcase
		rstate <= R_IDLE;
	end
	default: rstate <= R_IDLE;
	endcase
	if (reset) begin
		rstate      <= R_IDLE;
		ddr_rd      <= 1'b0;
		pending_req <= 1'b0;
	end
end

// address mux: valid while the matching strobe is asserted (the
// controller latches it on the accept cycle)
assign ddr_addr = ddr_rd ? ddr_addr_rd : ddr_addr_wr;

//------------------------------------------------------------------
// Save control (M4)
//------------------------------------------------------------------
wire        erase_req = erase_save;
// what the save path must use: the probe's finding for this slot, or the
// record it was given while a probe is still running
wire [3:0]  det_boot  = dets[{boot_slot, 2'b00} +: 4];
wire [3:0]  save_boot = saves[{boot_slot, 2'b00} +: 4];
wire  [2:0] save_kind = det_boot[3] ? det_boot[2:0] : save_boot[2:0];
wire [24:0] save_hint = SAVE_BASE;

wire _unused = &{1'b0, erase_req, save_kind, save_hint, save_done};

// Save master idle until M4 implements SRAM/EEPROM/Flash handshakes.
assign save_req  = 1'b0;
assign save_wr   = 1'b0;
assign save_addr = 25'd0;
assign save_din  = 16'd0;

endmodule
