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
// TODO(M1): prefetch FIFO on the read side to satisfy cart waitstates.
// TODO(M4): save sector path via sd_* into SDRAM, save erase, and the
//           cart unlock command sequence (0x00000555/0x00000AAA) that
//           some 256 Mbit+ carts issue before large reads.
//============================================================================
module cart_slot (
	input            clk,
	input            reset,

	// HPS download stream (F1 -> .nds, index 1). WIDE=1: one 16-bit word
	// per write, ioctl_addr counts bytes and steps by 2.
	input            ioctl_download,
	input     [26:0] ioctl_addr,
	input     [15:0] ioctl_dout,
	input            ioctl_wr,
	input     [15:0] ioctl_index,
	output           ioctl_wait,  // -> hps_io: pause the transfer

	// DE10-Nano DDR3 (framework DDRAM interface)
	output reg [7:0]  ddr_burstcnt,
	output reg [28:0] ddr_addr,   // unit: 8-byte line (byte addr >> 3)
	output reg [63:0] ddr_din,
	output reg [7:0]  ddr_be,
	output reg        ddr_we,
	output reg        ddr_rd,
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

	output reg        cart_loaded,
	output reg [27:0] rom_bytes   // detected ROM size in bytes
);

localparam SAVE_BASE = 25'h280000;
wire is_rom = ioctl_index[3:0] == 4'd1;

//------------------------------------------------------------------
// line FIFO: 16-bit words -> 64-bit DDR3 lines
//------------------------------------------------------------------
localparam FIFO_DEPTH = 64;
reg [63:0] fifo_data [0:FIFO_DEPTH-1];
reg [28:0] fifo_line [0:FIFO_DEPTH-1];
reg  [5:0] wr_ptr = 0;
reg  [5:0] rd_ptr = 0;

wire [5:0] fifo_used = wr_ptr - rd_ptr;
wire       fifo_empty = (wr_ptr == rd_ptr);
wire       fifo_full  = (fifo_used >= 6'd60); // pause download near full

assign ioctl_wait = fifo_full;

reg [15:0] pack [3:0];
reg  [1:0] pack_idx = 0;
reg [28:0] line_no = 0;

always @(posedge clk) begin
	if (ioctl_wr && is_rom && !fifo_full) begin
		pack[pack_idx] <= ioctl_dout;
		if (pack_idx == 2'd3) begin
			fifo_data[wr_ptr] <= {ioctl_dout, pack[2], pack[1], pack[0]};
			fifo_line[wr_ptr] <= line_no;
			wr_ptr  <= wr_ptr + 1'd1;
			line_no <= line_no + 1'd1;
			pack_idx <= 0;
		end else begin
			pack_idx <= pack_idx + 1'd1;
		end
	end
end

//------------------------------------------------------------------
// FIFO -> DDR3 drain (respects BUSY, one burst at a time)
//------------------------------------------------------------------
reg draining = 0;
always @(posedge clk) begin
	ddr_we <= 0;
	if (ddr_we && !ddr_busy) draining <= 0;

	if (!fifo_empty && !ddr_we && !draining && !ddr_busy) begin
		ddr_burstcnt <= 8'd1;
		ddr_be       <= 8'hFF;
		ddr_addr     <= fifo_line[rd_ptr];
		ddr_din      <= fifo_data[rd_ptr];
		ddr_we       <= 1;
		draining     <= 1;
		rd_ptr       <= rd_ptr + 1'd1;
	end
end

//------------------------------------------------------------------
// Device capacity: header byte 0x80 -> rom_bytes = 128 KB << cap,
// clamped to the DS's 4 Gbit (512 MB) ceiling.
//------------------------------------------------------------------
wire [7:0] cap_raw = ioctl_dout[7:0];
wire [7:0] cap = (cap_raw > 8'd12) ? 8'd12 : cap_raw;

always @(posedge clk) begin
	if (reset) rom_bytes <= 28'd0;
	else if (ioctl_wr && is_rom && ioctl_addr == 27'h80) begin
		rom_bytes <= 28'd131072 << cap;
	end
end

//------------------------------------------------------------------
// Load lifecycle
//------------------------------------------------------------------
reg dl_d = 0;
always @(posedge clk) begin
	// only the F1 ROM stream owns the load lifecycle — a later F2
	// (.cht) download on the shared pipe must not clear cart state
	dl_d <= ioctl_download && is_rom;
	if (ioctl_download && is_rom && !dl_d) begin
		cart_loaded <= 0;
		line_no     <= 0;
		pack_idx    <= 0;
	end
	if (!(ioctl_download && is_rom) && dl_d) cart_loaded <= 1;
	if (reset) cart_loaded <= 0;
end

//------------------------------------------------------------------
// Cart window read bridge: one outstanding DDR3 line at a time,
// little-endian halfwords (byte_addr[2:1]).
//------------------------------------------------------------------
localparam R_IDLE = 2'd0, R_WAIT = 2'd1, R_DONE = 2'd2;
reg  [1:0] rstate = R_IDLE;
reg [63:0] rline = 0;
reg [25:0] a_lat = 0;      // latched request address
reg        pending_req = 0; // win_req pulse arrived while DDR busy

wire [25:0] req_a = win_req ? win_addr : a_lat;

always @(posedge clk) begin
	win_valid <= 0;
	case (rstate)
	R_IDLE: begin
		if (win_req) begin
			a_lat       <= win_addr;
			pending_req <= 1;
		end
		if ((pending_req || win_req) && !ddr_busy) begin
			ddr_rd   <= 1;
			ddr_addr <= {6'd0, req_a[25:3]};
			pending_req <= 0;
			rstate   <= R_WAIT;
		end
	end
	R_WAIT: begin
		ddr_rd <= 0;
		if (ddr_dout_ready) begin
			rline  <= ddr_dout;
			rstate <= R_DONE;
		end
	end
	R_DONE: begin
		win_valid <= 1;
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
		rstate <= R_IDLE;
		ddr_rd <= 0;
		pending_req <= 0;
	end
end

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
