//============================================================================
// NDS MiSTer Test — DDRAM clock-domain bridge
//
// The framework's DDR3 interface is generated for a 50 MHz reference: its PLL
// and its PHY phase are tuned for DDRAM_CLK = CLK_50M, and feeding it the
// core's 67.0274 MHz would move the DDR clock with it and take the capture
// window with it. So the cart keeps the framework clock on its DDR side, while
// everything that owns DDR3 *state* — the download drain, the window read, the
// 64-line FIFO — runs with the core. This module is the one place the two
// clocks meet.
//
// One transaction at a time, and every transaction is a single 64-bit line
// (`ddr_burstcnt` is 1 wherever cart_slot issues one), which is what keeps the
// crossing small enough to be provable rather than plausible:
//
//   core side   `req` (and addr/din/be/wr) held until `ack`; `ack` is a level,
//               so the core cannot miss a one-cycle pulse and cannot see two
//               acks for one request
//   DDR side    RD/WE asserted only while BUSY is low and held until the
//               controller takes them (the framework's waitrequest protocol,
//               exactly as cart_slot issued them before)
//   50 -> 67    `ack` is the DDR-side done flag through two flops; `dout` is
//               captured on DOUT_READY in the DDR domain and held while the
//               request is outstanding, so it is stable long before `ack`
//
// The handshake closes when the core drops `req`, which the DDR side sees
// through two more flops — the same "hold it until the master retires it" rule
// the bus itself uses, applied across the clock boundary.
//============================================================================
module ddr_bus_bridge (
	input             clk,          // core clock (67.0274 MHz)
	input             reset,

	// ---- core side (cart_slot's DDRAM port) ----
	input             req,
	input             req_wr,
	input      [28:0] req_addr,
	input      [63:0] req_din,
	input      [7:0]  req_be,
	output            ack,          // level: the line is done, held until req drops
	output            busy,         // the DDR controller's waitrequest, to the core
	output     [63:0] dout,

	// ---- DDR side (framework DDRAM interface, 50 MHz) ----
	input             clk_ddr,
	input             reset_ddr,
	output     [7:0]  ddr_burstcnt,
	output     [28:0] ddr_addr,
	output     [63:0] ddr_din,
	output     [7:0]  ddr_be,
	output reg        ddr_we,
	output reg        ddr_rd,
	input             ddr_busy,
	input             ddr_dout_ready,
	input      [63:0] ddr_dout
);

assign ddr_burstcnt = 8'd1;                 // one 64-bit line per transaction
assign ddr_addr     = req_addr;
assign ddr_din      = req_din;
assign ddr_be       = req_be;

//------------------------------------------------------------------
// core -> DDR: the request level, two flops deep
//------------------------------------------------------------------
reg req_meta = 1'b0, req_sync = 1'b0;

always @(posedge clk_ddr) begin
	req_meta <= req;
	req_sync <= req_meta;
end

//------------------------------------------------------------------
// DDR -> core: the done flag (a level) and the line it carries
//------------------------------------------------------------------
reg        done_ddr  = 1'b0;
reg [63:0] line_ddr  = 64'd0;

reg ack_meta = 1'b0, ack_sync = 1'b0;

always @(posedge clk) begin
	ack_meta <= done_ddr;
	ack_sync <= ack_meta;
	if (reset) begin
		ack_meta <= 1'b0;
		ack_sync <= 1'b0;
	end
end

assign ack  = ack_sync;
assign dout = line_ddr;                     // stable before ack, held while req is up

//------------------------------------------------------------------
// The core-visible waitrequest
//
// cart_slot issued RD/WE straight at the DDR controller and expected it to
// answer with BUSY: it holds the strobe while BUSY is high and retires it on
// the cycle BUSY drops (reading the line there, for a read). Reproducing that
// exactly is what lets the cart logic stay untouched — the bridge *is* the
// controller from its point of view, just one that answers across a clock
// boundary. BUSY therefore rises with the request itself (not two flops
// later, which would let a write be retired before it was ever seen) and falls
// on the ack cycle.
//------------------------------------------------------------------
reg in_flight = 1'b0;

always @(posedge clk) begin
	if (reset)                 in_flight <= 1'b0;
	else if (req && !in_flight) in_flight <= 1'b1;
	if (ack_sync)              in_flight <= 1'b0;
end

assign busy = req | (in_flight & ~ack_sync);

//------------------------------------------------------------------
// DDR side transaction FSM
//
// The request is served on its rising edge only: `done_ddr` stays set while
// the core still holds `req`, and clears two DDR cycles after `req_sync`
// drops, so one request is one transaction however long the core keeps it up.
//------------------------------------------------------------------
localparam D_IDLE = 3'd0,
           D_WR   = 3'd1,   // WE asserted, waiting for the controller to take it
           D_RD   = 3'd2,   // RD asserted, waiting for the controller to take it
           D_DATA = 3'd3;   // RD taken: waiting for the line

reg [2:0] dst = D_IDLE;

always @(posedge clk_ddr) begin
	ddr_we <= 1'b0;
	ddr_rd <= 1'b0;

	case (dst)
	D_IDLE: begin
		if (req_sync && !done_ddr) begin
			if (req_wr) begin
				ddr_we <= 1'b1;
				dst    <= D_WR;
			end else begin
				ddr_rd <= 1'b1;
				dst    <= D_RD;
			end
		end
	end

	D_WR: begin
		// held until the controller takes it (a cycle with BUSY low), and
		// dropped on exactly that cycle so one request is one transfer
		if (!ddr_busy) begin
			done_ddr <= 1'b1;
			dst      <= D_IDLE;
		end else begin
			ddr_we <= 1'b1;
		end
	end

	D_RD: begin
		if (!ddr_busy) dst <= D_DATA;
		else           ddr_rd <= 1'b1;
	end

	D_DATA: begin
		// DOUT_READY may arrive well after the command is taken (DDR latency);
		// the line is captured once and held for the core side
		if (ddr_dout_ready) begin
			line_ddr <= ddr_dout;
			done_ddr <= 1'b1;
			dst      <= D_IDLE;
		end
	end

	default: dst <= D_IDLE;
	endcase

	// the core has retired the access: the transaction is over
	if (done_ddr && !req_sync) begin
		done_ddr <= 1'b0;
		dst      <= D_IDLE;
	end

	if (reset_ddr) begin
		dst      <= D_IDLE;
		done_ddr <= 1'b0;
		ddr_we   <= 1'b0;
		ddr_rd   <= 1'b0;
		line_ddr <= 64'd0;
	end
end

endmodule
