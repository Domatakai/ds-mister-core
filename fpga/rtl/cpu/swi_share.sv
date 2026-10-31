//============================================================================
// NDS MiSTer Test — the shared BIOS SWI bank
//
// One `swi_hle` engine, two cores. The core that executes an `SWI` raises
// `go` and waits; this module picks a core, routes the engine's bus access to
// *that* core's master port (the engine never touches the other one), hands
// the completion back to it, and releases the engine.
//
// Why share at all: the engine is 1,214 combinational ALUTs on its own, and
// two instances in the design cost 1,397 + 1,387 in the mapper's per-entity
// table. The A6 is out of room (AREA.md), so the second copy is the cheapest
// big block to remove. Nothing about a call needs CPU state that the engine
// keeps for itself: the function number and r0..r3 are latched at `go`, the
// results are handed back at `done`, and every memory access goes out through
// the calling core's own master — so a shared engine still reads *that*
// core's `IE`/`IF` for Halt and IntrWait, and therefore still sees the right
// interrupt bank.
//
// Grant: round-robin, not fixed priority. A game can call `Div` in a tight
// loop on the ARM9, and with fixed priority an ARM7 `Halt` would wait behind
// every one of them; the `last` flop makes whoever called most recently yield
// to the other when both are waiting. A waiting core's own bus stays idle: its
// `b_req` is held low until it owns the engine, and its `SWI` state simply
// does not retire — no timeout, no abort, exactly as a core waiting on slow
// memory behaves.
//
// Clock enables: the engine runs on the *owner's* enable (`ce9` or `ce7`), not
// on a fixed one. That matters for the ARM7 side, whose bus path sits behind
// `cpu_ce_bridge`: with the engine advancing every cycle while the ARM7 is
// gated, the acknowledge handshake could retire an access in a cycle the core
// had not presented yet — the same double-answer bug that the registered ack
// caused before it was made combinational. Running at the caller's rate keeps
// one engine step per core step on both sides.
//============================================================================
module swi_share (
	input             clk,
	input             reset,
	input             ce9,          // the ARM9's clock enable
	input             ce7,          // the ARM7's

	// ---- ARM9 caller ----
	input             c9_go,        // held from the SWI trap until done
	input       [7:0] c9_num,
	input      [31:0] c9_r0, c9_r1, c9_r2, c9_r3,
	output            c9_done,
	output            c9_handled,
	output     [31:0] c9_res0, c9_res1, c9_res3,
	output            c9_wr0, c9_wr1, c9_wr3,
	output            c9_b_req, c9_b_wr,
	output     [31:0] c9_b_addr, c9_b_wlane,
	output      [3:0] c9_b_be,
	input             c9_b_ack,
	input      [31:0] c9_b_rdata,

	// ---- ARM7 caller ----
	input             c7_go,
	input       [7:0] c7_num,
	input      [31:0] c7_r0, c7_r1, c7_r2, c7_r3,
	output            c7_done,
	output            c7_handled,
	output     [31:0] c7_res0, c7_res1, c7_res3,
	output            c7_wr0, c7_wr1, c7_wr3,
	output            c7_b_req, c7_b_wr,
	output     [31:0] c7_b_addr, c7_b_wlane,
	output      [3:0] c7_b_be,
	input             c7_b_ack,
	input      [31:0] c7_b_rdata,

	// ---- observable ----
	output            busy,         // an engine call is in flight
	output            owner         // who has it: 0 = ARM9, 1 = ARM7
);

//------------------------------------------------------------------
// Arbitration
//------------------------------------------------------------------
reg  owned = 1'b0;      // an engine call is in flight
reg  holder = 1'b0;     // 0 = ARM9, 1 = ARM7 (valid while owned)
reg  last = 1'b1;       // the caller that ran most recently

wire pend9 = c9_go & ~owned;      // waiting, but not the owner yet
wire pend7 = c7_go & ~owned;

// both waiting: the one that did *not* run last goes first
wire pick7 = pend7 & (pend9 ? ~last : 1'b1);
wire pick9 = pend9 & ~pick7;
wire start = pick9 | pick7;

wire owned_now = owned | start;   // combinational, so the engine sees `go`
                                  // in the same cycle the grant is taken
wire sel = owned ? holder : pick7;

// The engine is started by a *pulse*, not by the caller's level. Two callers
// can both be holding `go` when the engine changes hands, so a muxed level
// never falls between them and a rising-edge dispatch would never fire again.
// `taken` is raised when the engine has the call (busy, or already finished a
// call it did not implement) and cleared whenever no call is owned, so every
// grant presents one clean rising edge.
reg taken = 1'b0;

wire        e_done, e_handled, e_busy, e_req, e_wr;
wire [31:0] e_res0, e_res1, e_res3;
wire        e_wr0, e_wr1, e_wr3;

// A grant always presents a fresh pulse (start has priority over the clear),
// because back-to-back calls leave no idle cycle in which to reset it. `e_done`
// counts as well as `e_busy`: a call the bank does not implement finishes in one
// step and never looks busy at all.
always @(posedge clk) begin
	if (reset)                taken <= 1'b0;
	else if (start)           taken <= 1'b0;
	else if (e_busy | e_done) taken <= 1'b1;
end

// the engine's own inputs, from whichever core holds the call
wire       e_go  = owned_now & ~taken;
wire [7:0] e_num = sel ? c7_num : c9_num;
wire [31:0] e_r0 = sel ? c7_r0 : c9_r0,
            e_r1 = sel ? c7_r1 : c9_r1,
            e_r2 = sel ? c7_r2 : c9_r2,
            e_r3 = sel ? c7_r3 : c9_r3;

// and the engine's bus access, presented on the owner's master only
wire  [1:0] e_size;
wire [31:0] e_addr, e_wdata, e_wlane;
wire  [3:0] e_be;

assign c9_b_req   = owned_now & ~sel & e_req;
assign c9_b_wr    = e_wr;
assign c9_b_addr  = e_addr;
assign c9_b_wlane = e_wlane;
assign c9_b_be    = e_be;

assign c7_b_req   = owned_now &  sel & e_req;
assign c7_b_wr    = e_wr;
assign c7_b_addr  = e_addr;
assign c7_b_wlane = e_wlane;
assign c7_b_be    = e_be;

// the completion goes to the caller alone
wire to9 = owned & ~holder;
wire to7 = owned &  holder;

assign c9_done    = e_done & to9;
assign c9_handled = e_handled & to9;
assign c9_res0    = e_res0;
assign c9_res1    = e_res1;
assign c9_res3    = e_res3;
assign c9_wr0     = e_wr0 & to9;
assign c9_wr1     = e_wr1 & to9;
assign c9_wr3     = e_wr3 & to9;

assign c7_done    = e_done & to7;
assign c7_handled = e_handled & to7;
assign c7_res0    = e_res0;
assign c7_res1    = e_res1;
assign c7_res3    = e_res3;
assign c7_wr0     = e_wr0 & to7;
assign c7_wr1     = e_wr1 & to7;
assign c7_wr3     = e_wr3 & to7;

assign busy  = owned;
assign owner = holder;

always @(posedge clk) begin
	if (reset) begin
		owned  <= 1'b0;
		holder <= 1'b0;
		last   <= 1'b1;      // the ARM9 gets the first call
	end else if (start) begin
		owned  <= 1'b1;
		holder <= pick7;
		last   <= pick7;
	end else if (owned && e_done) begin
		// the caller drops its `go` on this same edge, so the engine sees
		// an idle bank on its next step and cannot re-dispatch the call
		owned <= 1'b0;
	end
end

//------------------------------------------------------------------
// The one engine
//------------------------------------------------------------------
swi_hle u_engine (
	.clk(clk), .reset(reset),
	.ce(owned_now ? (sel ? ce7 : ce9) : ce9),
	.go(e_go), .num(e_num),
	.r0(e_r0), .r1(e_r1), .r2(e_r2), .r3(e_r3),
	.m_req(e_req), .m_wr(e_wr), .m_size(e_size),
	.m_addr(e_addr), .m_wdata(e_wdata),
	.m_be(e_be), .m_wlane(e_wlane),
	.m_rdata(sel ? c7_b_rdata : c9_b_rdata),
	.m_ack(owned_now & (sel ? c7_b_ack : c9_b_ack)),
	.done(e_done), .handled(e_handled),
	.res0(e_res0), .res1(e_res1), .res3(e_res3),
	.wr0(e_wr0), .wr1(e_wr1), .wr3(e_wr3),
	.busy(e_busy)
);

endmodule
