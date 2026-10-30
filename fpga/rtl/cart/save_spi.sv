//============================================================================
// NDS MiSTer Test — emulated SPI backup chip (cart save memory)
//
// GBATEK, *DS Cartridge Backup*: a DS cart's save chip hangs on the AUX SPI
// bus and speaks the SPI command set — WREN, WRDI, RDSR, WRSR, RDID, RD and
// WR, with the address bus 8+1, 16 or 24 bits wide depending on the part.
// This module is that chip, and it is what the core's probe talks to instead
// of trusting the OSD row.
//
// It speaks *bytes*, not bits: the bit shifter belongs to the AUXSPI port,
// and every command below is defined by the byte stream it produces, so the
// port can drive this unchanged once the ARM cores run. A transaction is one
// `cs_n` low stretch; each byte is offered with `slot` and answered two
// cycles later with `resp`, which is the stall a real chip answers with.
//
// Modelled parts (the OSD save-type row picks which one the cart contains):
//   1 EEPROM 512K  ST M95512      64 KB, 16-bit address, 128-byte pages
//   2 EEPROM 8K    ST M95640       8 KB, 16-bit address,  32-byte pages
//   3 FLASH 512K   ST 45PE40V6   512 KB, 24-bit address, 256-byte pages
//   4 FLASH 1M     ST 45PE80V6     1 MB, 24-bit address, 256-byte pages
//   5 FRAM 32K     Ramtron FM25L256 32 KB, 16-bit address, no page limit
//
// Data lives in a 64 KB block RAM, which holds every EEPROM and FRAM above
// whole — and that is exactly what the capacity mirror test needs (an
// address past the chip's end reads back the low address it folds onto).
// The two FLASH parts are larger than the block RAM, so they answer their
// identity — manufacturer 20h, memory type 20h, capacity 13h for 4 Mbit and
// 14h for 8 Mbit, which is where a probe reads their size — while their data
// path stays M4: reads return FFh, writes are accepted and dropped.
//
// Status register (GBATEK): bit 7 SRWD, bits 6..4 000, bits 3..2 WP, bit 1
// WEL, bit 0 WIP. FRAM never raises WIP; EEPROM and FLASH do, which is the
// one bit that tells FRAM from EEPROM over the bus. The program time is
// scaled (512 cycles, ~10 us) rather than the real few milliseconds.
//============================================================================
module save_spi (
	input             clk,
	input             reset,

	input      [2:0]  cfg,      // OSD save type: which part the cart holds
	input             cs_n,     // chip select, low for a whole transaction
	input      [7:0]  din,      // MOSI byte for this slot
	input             slot,     // one-cycle: shift a byte through the chip
	output reg [7:0]  dout,     // MISO byte, valid with `resp`
	output reg        resp,     // one cycle of answer latency
	output     [7:0]  status_o, // live status register (diagnostics)
	output            present   // a chip is fitted for this type
);

	localparam [2:0] T_EEP64 = 3'd1, T_EEP8 = 3'd2,
	                 T_FL512 = 3'd3, T_FL1M = 3'd4, T_FRAM = 3'd5;

	wire is_flash = (cfg == T_FL512) || (cfg == T_FL1M);
	wire is_eep   = (cfg == T_EEP64) || (cfg == T_EEP8);
	wire is_fram  = (cfg == T_FRAM);
	assign present = is_flash | is_eep | is_fram;

	// capacity in bytes, and the mask its addresses fold through
	wire [20:0] cap = (cfg == T_EEP64) ? 21'd65536 :
	                  (cfg == T_EEP8)  ? 21'd8192 :
	                  (cfg == T_FL512) ? 21'd524288 :
	                  (cfg == T_FL1M)  ? 21'd1048576 :
	                  (cfg == T_FRAM)  ? 21'd32768 : 21'd0;
	wire [20:0] cap_mask = cap - 21'd1;

	// page size - 1: EEPROM and FLASH wrap a write inside one page, FRAM has
	// no pages at all
	wire [15:0] page_mask = (cfg == T_EEP64) ? 16'd127 :
	                        (cfg == T_EEP8)  ? 16'd31 :
	                        is_flash         ? 16'd255 : 16'd0;
	wire [2:0]  naddr = is_flash ? 3'd3 : 3'd2;   // address bytes

	//------------------------------------------------------------------
	// save data: simple dual-port block RAM, read and write every cycle
	//------------------------------------------------------------------
	// a blank part reads FFh, like an erased flash or a factory-fresh FRAM.
	// The contents come from a file rather than an `initial` loop over all
	// 65,536 bytes: Quartus refuses to elaborate a loop that long ("must
	// terminate within 5000 iterations"), and a file is the supported way to
	// initialise an inferred RAM anyway — the hex is what the part powers up
	// with, so it is identical in simulation and on the board.
	// tools/gen_save_blank.py writes it.
	reg  [7:0]  mem [0:65535];
	initial $readmemh("rtl/cart/save_blank.hex", mem);
	reg  [15:0] ridx = 0;
	reg  [7:0]  mout = 8'hFF;

	reg         wr_en = 0;
	reg  [15:0] wr_idx = 0;
	reg  [7:0]  wr_byte = 0;

	always @(posedge clk) begin
		if (wr_en) mem[wr_idx] <= wr_byte;
		mout <= mem[ridx];
	end

	//------------------------------------------------------------------
	// status register and program timing
	//------------------------------------------------------------------
	reg         wel = 0;
	reg         wip = 0;
	reg  [1:0]  wp = 0;
	reg  [9:0]  wcnt = 0;
	wire [7:0]  sr = {1'b0, 3'b000, wp, wel, wip};
	assign status_o = sr;

	//------------------------------------------------------------------
	// transaction state
	//------------------------------------------------------------------
	reg  [7:0]  cmd = 8'hFF;
	reg  [1:0]  ph = 2'd0;      // 0 command, 1 address, 2 data, 3 discard
	reg  [2:0]  aleft = 3'd0;   // address bytes still to come
	reg  [23:0] addr = 24'd0;
	reg  [1:0]  idleft = 2'd0;
	reg         wrpend = 0;     // this transaction has written data
	reg  [7:0]  rd_byte = 8'hFF;
	reg         cs_d = 1'b1;
	reg  [1:0]  pf = 2'd0;      // read prefetch pipeline
	reg  [7:0]  ans_p = 8'hFF;
	reg         stage = 1'b0;

	// address of the byte being shifted, and the one after it
	wire [15:0] mask16   = cap_mask[15:0];
	wire [23:0] addr_nxt = {addr[15:0], din};
	wire [15:0] idx_cur  = addr[15:0] & mask16;
	wire [15:0] idx_nxt  = addr_nxt[15:0] & mask16;

	// the address after this one: inside one page for EEPROM and FLASH,
	// straight on for FRAM, which has no pages
	wire [15:0] wr_wrap  = (page_mask == 16'd0) ? (addr[15:0] + 16'd1) :
	                       ((addr[15:0] & ~page_mask) | ((addr[15:0] + 16'd1) & page_mask));

	// RDID: manufacturer, memory type, capacity, then FFh. EEPROM and FRAM
	// do not answer RDID at all, they leave the bus pulled high.
	wire [7:0] id_byte = !is_flash ? 8'hFF :
	                     (idleft == 2'd3) ? 8'h20 :
	                     (idleft == 2'd2) ? 8'h20 :
	                     (idleft == 2'd1) ? ((cfg == T_FL1M) ? 8'h14 : 8'h13) :
	                                        8'hFF;

	// the byte this slot is answered with, from the state before the slot.
	// With no chip fitted the bus is pulled high, which is what an open bus
	// reads and what the probe's "nothing here" answer is made of.
	reg [7:0] ans;
	always @(*) begin
		if (!present) begin
			ans = 8'hFF;
		end else if (ph == 2'd2) begin
			case (cmd)
			8'h05:   ans = sr;                        // RDSR
			8'h9F:   ans = id_byte;                   // RDID
			8'h03:   ans = is_flash ? 8'hFF : rd_byte; // RD
			default: ans = 8'hFF;
			endcase
		end else ans = 8'hFF;
	end

	// A different part in the cart is a fresh part: nothing of the previous
	// chip's transaction (enable latch, program time, address phase) carries
	// over to it.
	reg  [2:0]  cfg_l = 3'd0;
	wire        part_chg = (cfg != cfg_l);

	always @(posedge clk) begin
		cfg_l  <= reset ? 3'd0 : cfg;
		resp   <= 1'b0;
		wr_en  <= 1'b0;
		cs_d   <= cs_n;

		if (reset || part_chg) begin
			wel    <= 1'b0;
			wip    <= 1'b0;
			wcnt   <= 10'd0;
			cmd    <= 8'hFF;
			ph     <= 2'd0;
			aleft  <= 3'd0;
			addr   <= 24'd0;
			idleft <= 2'd0;
			wrpend <= 1'b0;
			pf     <= 2'd0;
			ridx   <= 16'd0;
			stage  <= 1'b0;
		end

		// program time: WIP stays up until the count runs out
		if (wip) begin
			if (wcnt != 10'd0) wcnt <= wcnt - 10'd1;
			else               wip  <= 1'b0;
		end

		// answer pipeline: the slot byte is decoded here, the answer is
		// presented with resp two cycles later
		ans_p <= ans;
		if (slot) begin
			stage <= 1'b1;
		end else if (stage) begin
			dout  <= ans_p;
			resp  <= 1'b1;
			stage <= 1'b0;
		end

		// read prefetch: ridx/mout run one byte ahead of the data phase
		if (pf[1]) rd_byte <= mout;
		pf <= {pf[0], 1'b0};

		// chip select framing
		if (cs_d && !cs_n) begin
			// transaction start
			cmd    <= 8'hFF;
			ph     <= 2'd0;
			aleft  <= 3'd0;
			addr   <= 24'd0;
			idleft <= 2'd0;
			wrpend <= 1'b0;
			pf     <= 2'd0;
		end
		if (!cs_d && cs_n) begin
			// transaction end: a write starts its program time now
			if (wrpend) begin
				wrpend <= 1'b0;
				wel    <= 1'b0;
				if (!is_fram) begin
					wip  <= 1'b1;
					wcnt <= 10'd511;
				end
			end
		end

		if (slot && !cs_n) begin
			case (ph)
			2'd0: begin      // command byte
				cmd <= din;
				case (din)
				8'h06: begin wel <= 1'b1; ph <= 2'd3; end   // WREN
				8'h04: begin wel <= 1'b0; ph <= 2'd3; end   // WRDI
				8'h05: begin ph <= 2'd2; idleft <= 2'd0; end
				8'h9F: begin ph <= 2'd2; idleft <= 2'd3; end
				8'h01: begin ph <= 2'd2; end                // WRSR
				8'h03,
				8'h02: begin ph <= 2'd1; aleft <= naddr; addr <= 24'd0; end
				default: ph <= 2'd3;
				endcase
			end
			2'd1: begin      // address byte, most significant first
				addr <= {addr[15:0], din};
				if (aleft == 3'd1) begin
					ph <= 2'd2;
					if (!is_flash) begin
						ridx <= idx_nxt;
						pf   <= 2'd1;
					end
				end else begin
					aleft <= aleft - 3'd1;
				end
			end
			2'd2: begin      // data byte
				case (cmd)
				8'h03: begin // RD: answer from rd_byte, walk on
					addr <= addr + 24'd1;
					if (!is_flash) begin
						ridx <= (idx_cur + 16'd1) & mask16;
						pf   <= 2'd1;
					end
				end
				8'h02: begin // WR: store this byte, then the next
					if (wel && !is_flash) begin
						wr_en   <= 1'b1;
						wr_idx  <= idx_cur;
						wr_byte <= din;
						wrpend  <= 1'b1;
					end else if (wel) begin
						wrpend  <= 1'b1;   // FLASH data path is M4
					end
					addr <= wr_wrap;
				end
				8'h9F: begin // RDID: four bytes, then FFh
					if (idleft != 2'd0) idleft <= idleft - 2'd1;
				end
				8'h01: begin // WRSR: only the two WP bits are writable
					wp <= din[3:2];
				end
				default: ;
				endcase
			end
			default: ;
			endcase
		end

		if (reset) begin
			resp   <= 1'b0;
			stage  <= 1'b0;
			cmd    <= 8'hFF;
			ph     <= 2'd0;
			aleft  <= 3'd0;
			addr   <= 24'd0;
			idleft <= 2'd0;
			wrpend <= 1'b0;
			wel    <= 1'b0;
			wip    <= 1'b0;
			wcnt   <= 10'd0;
			cs_d   <= 1'b1;
			pf     <= 2'd0;
			wr_en  <= 1'b0;
		end
	end

endmodule
