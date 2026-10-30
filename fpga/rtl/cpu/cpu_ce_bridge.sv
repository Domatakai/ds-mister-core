//============================================================================
// NDS MiSTer Test — clock-enabled CPU bus adapter
//
// A core whose clock enable is low does not advance, so a response that
// arrives on one of those cycles is invisible to it — and `main_bus` is not
// free to send another: it holds a master blocked (`m9_block` / `m7_block`)
// from the moment it answers until that master retires the access. A pulse
// that lands on a gated-off cycle would therefore hang the core for good.
//
// This adapter is what makes the clock-enable ratio safe. It passes the
// request through unchanged (the bus must see the access exactly when the
// core issues it, and the core holds it until it sees `ready`), and it turns
// the response into something the core cannot miss:
//
//   * the cycle is enabled    — the bus response goes straight through, so a
//                              1:1 core behaves exactly as if it were wired to
//                              the bus directly, same cycle and same data
//   * the cycle is gated off  — `ready` and the read data are latched, and the
//                              core sees them (a level, held until it retires
//                              the access) on its next enabled cycle
//
// `retain` is the core's own request, so the latch clears itself the cycle the
// core has taken the response — no timer, no state machine to get out of step
// with the core.
//============================================================================
module cpu_ce_bridge (
	input             clk,
	input             ce,           // this core's clock enable (cpu_ce)

	// ---- core side ----
	input      [31:0] core_addr,
	input      [31:0] core_wdata,
	input      [3:0]  core_be,
	input             core_rd,
	input             core_wr,
	output     [31:0] core_rdata,
	output            core_ready,

	// ---- bus side ----
	output     [31:0] bus_addr,
	output     [31:0] bus_wdata,
	output     [3:0]  bus_be,
	output            bus_rd,
	output            bus_wr,
	input      [31:0] bus_rdata,
	input             bus_ready
);

assign bus_addr  = core_addr;
assign bus_wdata = core_wdata;
assign bus_be    = core_be;
assign bus_rd    = core_rd;
assign bus_wr    = core_wr;

wire       retain  = core_rd | core_wr;   // the access is still outstanding
reg        latched = 1'b0;
reg [31:0] latched_rdata = 32'd0;

always @(posedge clk) begin
	if (!retain)
		latched <= 1'b0;
	else if (!ce && bus_ready) begin
		latched       <= 1'b1;
		latched_rdata <= bus_rdata;
	end
end

// The latch wins: once a response is held, the core must take that one, not
// whatever the bus happens to be carrying when it comes back.
assign core_ready = bus_ready | latched;
assign core_rdata = latched ? latched_rdata : bus_rdata;

endmodule
