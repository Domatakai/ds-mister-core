//============================================================================
// NDS MiSTer Test — the ARM9's cache tags and line state
//
// The caches themselves are not here yet: every access still goes to the
// bus, and nothing is served out of this module. What it holds is the part
// the c7 maintenance commands act on -- which line of which set and way is
// valid, which lines are dirty, and how a command turns into work on the
// arrays. That is the half of the cache the CP15 state already promised:
// before this, a test-and-clean had nothing to look at and answered "clean"
// by construction.
//
// Geometry is the ARM946E-S's, which is what CP15_CACHETYPE (0x0F0D2112)
// declares: 32-byte lines, four ways, 4 KB of data cache (32 sets) and 8 KB
// of instruction cache (64 sets). One way is one tag array, so an access
// reads four tags at once.
//
// Valid and dirty are one bit per set and way, in flops, and the tags are
// the only thing in an array. That split is what makes a whole-cache
// invalidate one cycle instead of a walk over the sets, and it is exact: a
// generation bit would flip back and revalidate lines a second invalidate
// had thrown away, and a walk would let an allocation land in a set that had
// already been cleared or was about to be.
//
// The compare is combinational and the state moves on the access's own
// cycle, deliberately: software writes a line and then cleans it (a DMA
// writeback does exactly that), so a maintenance command has to see the
// store that preceded it. A registered read would put the dirty bit one
// cycle behind the store and that clean would find nothing to do. The price
// is that the tag arrays cannot go to block RAM: Quartus put them in
// registers, 3,157 flops and 2,413 ALMs that take the design to 90% of its
// ALMs (AREA.md). The data arrays, when they land, are where the block RAM
// goes.
//
// Maintenance commands (one per pulse on `mnt`, in `mnt_cmd`):
//
//   1  invalidate the whole cache          (c7,c6,0 / c7,c5,0)
//   2  invalidate a line by address        (c7,c6,1 / c7,c5,1)
//   3  clean a line by address             (c7,c10,1)
//   4  clean and invalidate by address     (c7,c14,1)
//   5  clean a line by index               (c7,c10,2)
//   6  clean and invalidate by index       (c7,c14,2)
//   7  test and clean                      (mrc c7,c10,3)
//   8  test, clean and invalidate          (mrc c7,c14,3)
//
// The by-index forms take the way in bits 1:0 of the argument and the set
// above it -- the ARM946E-S's own encoding for them, which GBATEK does not
// spell out for the DS part. A command and an access in the same cycle is
// not a thing the core can produce; if it did, the command would win.
//============================================================================
`timescale 1ns / 1ps

module arm9_cache_tag #(
	parameter SETS  = 32,       // 32 for the data cache, 64 for the I cache
	parameter SETB  = 5,        // log2(SETS)
	parameter TAGW  = 22,       // address bits above the line
	parameter DIRTY = 1         // the instruction cache has no dirty state
) (
	input              clk,
	input              ce,
	input              reset,
	input              enable,     // c1: the cache's enable bit (allocation)
	input              acc,        // one access, one-cycle pulse
	input      [31:0]  acc_addr,
	input              acc_wr,     // a store: the line it lands on is dirty
	input              mnt,        // one maintenance command
	input      [3:0]   mnt_cmd,
	input      [31:0]  mnt_arg,
	input      [1:0]   lock_way,   // c9 lockdown: ways up to here stay
	input              lock_en,
	output             dirty_any,
	output reg         last_hit,   // the access just compared
	output reg  [1:0]  last_way,
	output reg  [3:0]  last_valid,
	output reg [15:0]  hits,
	output reg [15:0]  misses
);

	localparam M_NONE = 4'd0, M_INVALL = 4'd1, M_INVLINE = 4'd2,
	           M_CLEAN = 4'd3, M_CLEANINV = 4'd4, M_CLEANIDX = 4'd5,
	           M_CLEANINVIDX = 4'd6, M_TESTCLEAN = 4'd7,
	           M_TESTINV = 4'd8;

	//------------------------------------------------------------------
	// the four ways: tags in arrays, valid and dirty as bitmaps
	//------------------------------------------------------------------
	reg [TAGW-1:0] t0 [0:SETS-1];
	reg [TAGW-1:0] t1 [0:SETS-1];
	reg [TAGW-1:0] t2 [0:SETS-1];
	reg [TAGW-1:0] t3 [0:SETS-1];

	reg [SETS-1:0] v0, v1, v2, v3;
	reg [SETS-1:0] dw0, dw1, dw2, dw3;

	assign dirty_any = DIRTY ? (|dw0 | |dw1 | |dw2 | |dw3) : 1'b0;

	//------------------------------------------------------------------
	// addresses
	//------------------------------------------------------------------
	wire [SETB-1:0] set_of  = acc_addr[5 +: SETB];
	wire [TAGW-1:0] tag_of  = acc_addr[5 + SETB +: TAGW];

	wire [SETB-1:0] m_set   = mnt_arg[2 +: SETB];       // by index
	wire [1:0]      m_way   = mnt_arg[1:0];
	wire [SETB-1:0] m_a_set = mnt_arg[5 +: SETB];       // by address
	wire [TAGW-1:0] m_a_tag = mnt_arg[5 + SETB +: TAGW];

	//------------------------------------------------------------------
	// the compare, in the access's own cycle
	//------------------------------------------------------------------
	wire [TAGW-1:0] a0 = t0[set_of], a1 = t1[set_of];
	wire [TAGW-1:0] a2 = t2[set_of], a3 = t3[set_of];
	wire [TAGW-1:0] b0 = t0[m_a_set], b1 = t1[m_a_set];
	wire [TAGW-1:0] b2 = t2[m_a_set], b3 = t3[m_a_set];

	wire h0 = v0[set_of] && (a0 == tag_of);
	wire h1 = v1[set_of] && (a1 == tag_of);
	wire h2 = v2[set_of] && (a2 == tag_of);
	wire h3 = v3[set_of] && (a3 == tag_of);
	wire [3:0] hit_vec = {h3, h2, h1, h0};

	// a way is not available to allocate into if it is locked
	wire [3:0] allow = lock_en ? (4'b1111 << (lock_way + 2'd1)) : 4'b1111;

	wire [3:0] free_vec = {(~v3[set_of]), (~v2[set_of]),
	                       (~v1[set_of]), (~v0[set_of])} & allow;

	reg [1:0] rr_way;      // round robin among the ways that are not locked
	reg [1:0] rr0, rr1, rr2, rr3;
	always @(*) begin
		rr0 = rr_way;
		rr1 = rr_way + 2'd1;
		rr2 = rr_way + 2'd2;
		rr3 = rr_way + 2'd3;
	end

	reg [1:0] victim;
	always @(*) begin
		if      (free_vec[0]) victim = 2'd0;
		else if (free_vec[1]) victim = 2'd1;
		else if (free_vec[2]) victim = 2'd2;
		else if (free_vec[3]) victim = 2'd3;
		else if (allow[rr0])  victim = rr0;
		else if (allow[rr1])  victim = rr1;
		else if (allow[rr2])  victim = rr2;
		else                  victim = rr3;
	end

	// the line a by-address command acts on
	wire m0 = v0[m_a_set] && (b0 == m_a_tag);
	wire m1 = v1[m_a_set] && (b1 == m_a_tag);
	wire m2 = v2[m_a_set] && (b2 == m_a_tag);
	wire m3 = v3[m_a_set] && (b3 == m_a_tag);

	integer k;
	always @(posedge clk) begin
		if (reset) begin
			rr_way     <= 2'd0;
			last_hit   <= 1'b0;
			last_way   <= 2'd0;
			last_valid <= 4'd0;
			hits       <= 16'd0;
			misses     <= 16'd0;
			v0  <= {SETS{1'b0}};
			v1  <= {SETS{1'b0}};
			v2  <= {SETS{1'b0}};
			v3  <= {SETS{1'b0}};
			dw0 <= {SETS{1'b0}};
			dw1 <= {SETS{1'b0}};
			dw2 <= {SETS{1'b0}};
			dw3 <= {SETS{1'b0}};
			for (k = 0; k < SETS; k = k + 1) begin
				t0[k] <= {TAGW{1'b0}};
				t1[k] <= {TAGW{1'b0}};
				t2[k] <= {TAGW{1'b0}};
				t3[k] <= {TAGW{1'b0}};
			end
		end else if (ce) begin
			//------------------------------------------------------
			// a maintenance command
			//------------------------------------------------------
			if (mnt && mnt_cmd != M_NONE) begin
				if (mnt_cmd == M_INVALL || mnt_cmd == M_CLEANINV ||
				    mnt_cmd == M_TESTINV) begin
					// the whole cache, in one cycle
					v0 <= {SETS{1'b0}};
					v1 <= {SETS{1'b0}};
					v2 <= {SETS{1'b0}};
					v3 <= {SETS{1'b0}};
					if (DIRTY && mnt_cmd != M_INVALL) begin
						dw0 <= {SETS{1'b0}};
						dw1 <= {SETS{1'b0}};
						dw2 <= {SETS{1'b0}};
						dw3 <= {SETS{1'b0}};
					end
				end else if (mnt_cmd == M_TESTCLEAN) begin
					if (DIRTY) begin
						dw0 <= {SETS{1'b0}};
						dw1 <= {SETS{1'b0}};
						dw2 <= {SETS{1'b0}};
						dw3 <= {SETS{1'b0}};
					end
				end else if (mnt_cmd == M_INVLINE || mnt_cmd == M_CLEAN ||
				             mnt_cmd == M_CLEANINV) begin
					if (m0 && mnt_cmd != M_CLEAN) v0[m_a_set] <= 1'b0;
					if (m1 && mnt_cmd != M_CLEAN) v1[m_a_set] <= 1'b0;
					if (m2 && mnt_cmd != M_CLEAN) v2[m_a_set] <= 1'b0;
					if (m3 && mnt_cmd != M_CLEAN) v3[m_a_set] <= 1'b0;
					if (DIRTY && mnt_cmd != M_INVLINE) begin
						if (m0) dw0[m_a_set] <= 1'b0;
						if (m1) dw1[m_a_set] <= 1'b0;
						if (m2) dw2[m_a_set] <= 1'b0;
						if (m3) dw3[m_a_set] <= 1'b0;
					end
				end else begin
					// the by-index forms
					if (mnt_cmd == M_CLEANINVIDX) begin
						case (m_way)
						2'd0: v0[m_set] <= 1'b0;
						2'd1: v1[m_set] <= 1'b0;
						2'd2: v2[m_set] <= 1'b0;
						default: v3[m_set] <= 1'b0;
						endcase
					end
					if (DIRTY) begin
						case (m_way)
						2'd0: dw0[m_set] <= 1'b0;
						2'd1: dw1[m_set] <= 1'b0;
						2'd2: dw2[m_set] <= 1'b0;
						default: dw3[m_set] <= 1'b0;
						endcase
					end
				end
			end

			//------------------------------------------------------
			// an observed access
			//------------------------------------------------------
			if (acc && !(mnt && mnt_cmd != M_NONE)) begin
				last_valid <= {v3[set_of], v2[set_of], v1[set_of], v0[set_of]};
				last_hit   <= |hit_vec;
				last_way   <= (|hit_vec) ? (hit_vec[0] ? 2'd0 : hit_vec[1] ? 2'd1 :
				                            hit_vec[2] ? 2'd2 : 2'd3)
				                        : victim;
				if (|hit_vec) hits <= hits + 16'd1;
				else          misses <= misses + 16'd1;

				if (|hit_vec) begin
					// a store to a line that is already here
					if (acc_wr && DIRTY) begin
						if (hit_vec[0]) dw0[set_of] <= 1'b1;
						if (hit_vec[1]) dw1[set_of] <= 1'b1;
						if (hit_vec[2]) dw2[set_of] <= 1'b1;
						if (hit_vec[3]) dw3[set_of] <= 1'b1;
					end
				end else if (enable && (|allow)) begin
					// fill the line: nothing is fetched, only the tag
					case (victim)
					2'd0: begin t0[set_of] <= tag_of; v0[set_of] <= 1'b1; end
					2'd1: begin t1[set_of] <= tag_of; v1[set_of] <= 1'b1; end
					2'd2: begin t2[set_of] <= tag_of; v2[set_of] <= 1'b1; end
					default: begin t3[set_of] <= tag_of; v3[set_of] <= 1'b1; end
					endcase
					if (acc_wr && DIRTY) begin
						case (victim)
						2'd0: dw0[set_of] <= 1'b1;
						2'd1: dw1[set_of] <= 1'b1;
						2'd2: dw2[set_of] <= 1'b1;
						default: dw3[set_of] <= 1'b1;
						endcase
					end
					rr_way <= victim + 2'd1;
				end
			end
		end
	end

endmodule
