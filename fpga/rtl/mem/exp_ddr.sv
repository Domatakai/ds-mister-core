//============================================================================
// NDS MiSTer -- slot-2 32 MB expansion pak, backed by DDR3
//
// The 8 and 16 MB paks fit in the 32 MB SDRAM module, on main_bus's is_exp
// path. The 32 MB pak does not: it is 16M halfwords by itself, more than
// the whole SDRAM module, and its window runs from 0x09000000 to
// 0x0AFFFFFF. So it lives in DDR3 beside the cart ROM, past the four cart
// slots, and NDS.sv routes its transactions here instead of to
// mem_arbiter. main_bus keeps presenting its usual held halfword request,
// so the bus state machine never learns which memory answered.
//
// DDR3 is slow and shared, so a line is kept and the next one is fetched
// ahead:
//
//   slot 0  the last line a bus access used
//   slot 1  the line after it, fetched while the bus was idle
//
// A line holds four halfwords, and main_bus asks for two of them per 32-bit
// access, so the second half now costs nothing. The prefetch only ever runs
// with no request pending -- a real access never waits behind it, and a hit
// during a prefetch is served without the port, so prefetching cannot make
// an access slower than no cache at all. It only fetches when the walk
// looks sequential (same line or the next one), because a random access
// pattern would make every prefetch a wasted line.
//
// Writes go through to DDR3 (the memory is the truth) and are also applied
// to a cached copy, so a read after a write sees it without a fetch.
//============================================================================
module exp_ddr (
	input             clk,
	input             reset,

	// ---- from main_bus: a held halfword request ----
	input             req,
	input             wr,
	input      [23:0] hw,        // halfword offset inside the pak
	input      [15:0] wdata,
	input       [1:0] be,        // be[0] is the low byte, be[1] the high
	output reg        done,      // pulse while the access is served
	output reg [15:0] rdata,

	// ---- DDR3 (ddr_arb's second requester) ----
	output reg        d_req,
	output reg        d_wr,
	output reg [28:0] d_addr,
	output reg [63:0] d_din,
	output reg  [7:0] d_be,
	input             d_ack,
	input      [63:0] d_dout,
	input             d_busy
);

// Line 0x200_0000 is 256 MB into the DDR3: a cart slot addresses 256 MB at
// most, so nothing staged as a ROM can reach the pak's lines.
localparam [28:0] EXP_LINE_BASE = 29'h200_0000;

localparam [2:0] E_IDLE = 3'd0, E_WAIT = 3'd1, E_DONE = 3'd2,
                 E_HOLD = 3'd3, E_PFWAIT = 3'd4;
reg [2:0] st = E_IDLE;

reg [23:0] last_hw = 24'd0;
reg        served  = 1'b0;      // one access served in this hold window

wire [24:0] byte_off = {hw, 1'b0};
wire [21:0] line_idx = byte_off[24:3];
wire  [2:0] lane     = byte_off[2:0];

// the two bytes of the halfword, placed at their lane inside the line
wire [7:0] lane_be = (be[0] ? (8'h01 << lane)          : 8'h00) |
                     (be[1] ? (8'h01 << (lane + 3'd1)) : 8'h00);

wire [63:0] dout_sh = d_dout >> {lane, 3'b000};

//------------------------------------------------------------------
// the line kept from the last access, and the one fetched ahead of it
//------------------------------------------------------------------
reg [63:0] cl0_dat = 64'd0, cl1_dat = 64'd0;
reg [21:0] cl0_idx = 22'd0, cl1_idx = 22'd0;
reg        cl0_val = 1'b0,  cl1_val = 1'b0;

wire hit0 = cl0_val && (cl0_idx == line_idx);
wire hit1 = cl1_val && (cl1_idx == line_idx);
wire hit  = hit0 || hit1;
wire [63:0] hit_dat = hit0 ? cl0_dat : cl1_dat;
wire [63:0] hit_sh  = hit_dat >> {lane, 3'b000};

// a cached line with this halfword written into it
function [63:0] merged;
	input [63:0] line;
	input [21:0] idx;
	input [21:0] want;
	input  [2:0] ln;
	input [15:0] d;
	input  [1:0] b;
	begin
		merged = line;
		if (idx == want) begin
			if (b[0]) merged[{ln, 3'b000} +: 8] = d[7:0];
			if (b[1]) merged[{ln, 3'b000} + 4'd8 +: 8] = d[15:8];
		end
	end
endfunction

//------------------------------------------------------------------
// is this access continuing a walk through the pak?
//------------------------------------------------------------------
reg [21:0] prev_idx = 22'd0;
reg        prev_val = 1'b0;
wire seq_ok = !prev_val || (line_idx == prev_idx) ||
              (line_idx == prev_idx + 22'd1);

// pending prefetch: the line after the one just served. It waits for the
// bus to go quiet first: firing at the first free cycle would put a fetch
// in front of the next real access, and take a line from the cart, to gain
// nothing when the access pattern is already keeping the port busy.
reg        pf_want = 1'b0;
reg [21:0] pf_idx  = 22'd0;
reg  [3:0] quiet   = 4'd0;      // consecutive cycles with no request
localparam [3:0] PF_QUIET = 4'd8;

always @(posedge clk) begin
	if (reset) begin
		st      <= E_IDLE;
		last_hw <= 24'd0;
		served  <= 1'b0;
		done    <= 1'b0;
		rdata   <= 16'h0000;
		d_req   <= 1'b0;
		d_wr    <= 1'b0;
		d_addr  <= 29'd0;
		d_din   <= 64'd0;
		d_be    <= 8'h00;
		cl0_val <= 1'b0;
		cl1_val <= 1'b0;
		prev_val <= 1'b0;
		pf_want <= 1'b0;
		quiet   <= 4'd0;
	end else begin
		done <= 1'b0;
		if (!req) served <= 1'b0;
		quiet <= req ? 4'd0 : (quiet == 4'd15 ? 4'd15 : quiet + 4'd1);

		case (st)
		E_IDLE: begin
			if (req && (!served || hw != last_hw)) begin
				last_hw  <= hw;
				served   <= 1'b1;
				prev_idx <= line_idx;
				prev_val <= 1'b1;
				if (!wr && hit) begin
					// served from the cache, no port traffic. Only a line in
					// slot 0 leaves the other slot free to prefetch into: an
					// access served from slot 1 is using the prefetched line
					// itself, and fetching on from there would evict the line
					// still in use.
					rdata   <= hit_sh[15:0];
					pf_want <= hit0 && seq_ok;
					pf_idx  <= line_idx + 22'd1;
					st      <= E_DONE;
				end else begin
					d_req  <= 1'b1;
					d_wr   <= wr;
					d_addr <= EXP_LINE_BASE + {7'd0, line_idx};
					d_din  <= {4{wdata}};
					d_be   <= wr ? lane_be : 8'hFF;
					st     <= E_WAIT;
				end
			end else if (!req && pf_want) begin
				if (cl1_val && cl1_idx == pf_idx) begin
					pf_want <= 1'b0;      // already here: nothing to fetch
				end else if (quiet >= PF_QUIET) begin
					d_req  <= 1'b1;
					d_wr   <= 1'b0;
					d_addr <= EXP_LINE_BASE + {7'd0, pf_idx};
					d_be   <= 8'hFF;
					st     <= E_PFWAIT;
				end
			end
		end

		E_WAIT: if (d_ack) begin
			d_req <= 1'b0;
			if (d_wr) begin
				// write-through, and the cached copies follow
				cl0_dat <= merged(cl0_dat, cl0_idx, line_idx, lane, wdata, be);
				cl1_dat <= merged(cl1_dat, cl1_idx, line_idx, lane, wdata, be);
				pf_want <= 1'b0;
			end else begin
				cl0_dat <= d_dout;
				cl0_idx <= line_idx;
				cl0_val <= 1'b1;
				cl1_val <= 1'b0;   // the old prefetch is behind us now
				pf_want <= seq_ok;
				pf_idx  <= line_idx + 22'd1;
			end
			rdata <= dout_sh[15:0];
			st    <= E_DONE;
		end

		E_DONE: begin
			done <= 1'b1;
			st   <= E_HOLD;
		end

		// The bus holds req across both halfwords of a 32-bit access, so a
		// new beat is also a new address: either end of that ends the hold.
		E_HOLD: if (!req || hw != last_hw) st <= E_IDLE;

		E_PFWAIT: begin
			// a real access still gets served: a hit needs no port, so it
			// is answered while the prefetch is in flight
			if (req && (!served || hw != last_hw) && !wr && hit) begin
				last_hw  <= hw;
				served   <= 1'b1;
				prev_idx <= line_idx;
				prev_val <= 1'b1;
				rdata    <= hit_sh[15:0];
				done     <= 1'b1;
			end
			if (d_ack) begin
				d_req   <= 1'b0;
				cl1_dat <= d_dout;
				cl1_idx <= pf_idx;
				cl1_val <= 1'b1;
				pf_want <= 1'b0;
				st      <= E_IDLE;
			end
		end

		default: st <= E_IDLE;
		endcase
	end
end

endmodule
