//============================================================================
// NDS MiSTer Test — SDRAM arbiter (two masters, fixed priority)
//
//   master A: main_bus RAM window  (CPU main RAM, round-robin server)
//   master B: cart_slot save path (SRAM/EEPROM/Flash, M4)
//
// The cart save path has fixed priority over the bus window: saves are
// tiny, latency-sensitive bursts that must never be starved by a stream
// of CPU RAM accesses, while CPU window traffic tolerates a few extra
// cycles. One outstanding request at a time; the granted master sees
// `bus_ready` / `save_ready` pulse when its data (read) or acceptance
// (write) completes.
//============================================================================
module mem_arbiter (
	input            clk,
	input            reset,

	// master A: main bus RAM window
	input            bus_req,
	input            bus_wr,
	input     [24:0] bus_addr,
	input     [15:0] bus_wdata,
	input      [1:0] bus_be,
	output reg       bus_ready,

	// master B: cart save path
	input            save_req,
	input            save_wr,
	input     [24:0] save_addr,
	input     [15:0] save_wdata,
	input      [1:0] save_be,
	output reg       save_ready,

	// toward sdram_ctrl
	output reg       sdram_req,
	output reg       sdram_wr,
	output reg [24:0] sdram_addr,
	output reg [15:0] sdram_wdata,
	output reg [1:0] sdram_be,
	input            sdram_rd_done, // read data valid
	input            sdram_wr_done, // write committed
	input     [15:0] sdram_rdata
);

localparam S_IDLE = 2'd0, S_BUSY = 2'd1;

reg [1:0] state = S_IDLE;
reg       owner = 0;  // 0 = bus window, 1 = save path
reg       pending = 0; // waiting for sdram_rd/wr_done

always @(posedge clk) begin
	bus_ready  <= 0;
	save_ready <= 0;

	case (state)
	S_IDLE: begin
		if (save_req) begin
			owner      <= 1;
			sdram_req  <= 1;
			sdram_wr   <= save_wr;
			sdram_addr <= save_addr;
			sdram_wdata<= save_wdata;
			sdram_be   <= save_be;
			pending    <= 1;
			state      <= S_BUSY;
		end else if (bus_req) begin
			owner      <= 0;
			sdram_req  <= 1;
			sdram_wr   <= bus_wr;
			sdram_addr <= bus_addr;
			sdram_wdata<= bus_wdata;
			sdram_be   <= bus_be;
			pending    <= 1;
			state      <= S_BUSY;
		end
	end

	S_BUSY: begin
		sdram_req <= 0; // single-cycle accept pulse
		if (pending && (sdram_rd_done || sdram_wr_done)) begin
			pending <= 0;
			if (owner) save_ready <= 1;
			else       bus_ready  <= 1;
			state <= S_IDLE;
		end
	end

	default: state <= S_IDLE;
	endcase

	if (reset) begin
		state <= S_IDLE;
		sdram_req <= 0; sdram_wr <= 0;
		bus_ready <= 0; save_ready <= 0;
		pending <= 0; owner <= 0;
	end
end

endmodule
