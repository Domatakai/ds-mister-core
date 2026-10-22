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

	// save control (M4 implements the sd_* sector path)
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
reg [15:0] pack [0:3];
reg  [1:0] pack_idx = 0;
reg [28:0] line_no = 0;
reg        dl_d = 0;
reg        tail_flush = 0;

always @(posedge clk) begin
	dl_d <= rom_dl;

	if (rom_dl && !dl_d) begin
		// start of a ROM download: reset the packer (a .cht load on
		// the shared pipe must never touch this state)
		cart_loaded <= 1'b0;
		line_no     <= 29'd0;
		pack_idx    <= 2'd0;
		tail_flush  <= 1'b0;
	end else begin
		// ROM download finished
		if (dl_d && !rom_dl) cart_loaded <= 1'b1;

		// pack words into full 64-bit DDR lines
		if (ioctl_wr && is_rom && !fifo_full) begin
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
end

//------------------------------------------------------------------
// Block B — FIFO -> DDR3 drain. RD/WE are held until BUSY deasserts;
// a read wanting the port in the same cycle blocks the grant so RD and
// WE can never be high together.
//------------------------------------------------------------------
reg draining = 0;
reg [28:0] ddr_addr_wr = 0;
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
reg [28:0] ddr_addr_rd = 0;

wire [25:0] req_a = win_req ? win_addr : a_lat;

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
			ddr_addr_rd <= {6'd0, req_a[25:3]};
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
wire  [2:0] save_kind = save_type;
wire [24:0] save_hint = SAVE_BASE;

wire _unused = &{1'b0, erase_req, save_kind, save_hint, save_done};

// Save master idle until M4 implements SRAM/EEPROM/Flash handshakes.
assign save_req  = 1'b0;
assign save_wr   = 1'b0;
assign save_addr = 25'd0;
assign save_din  = 16'd0;

endmodule
