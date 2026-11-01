//============================================================================
// NDS MiSTer Test — VRAM bank arbiter (milestone M2)
//
// The DS exposes nine VRAM banks (A..I) whose mapping is controlled by
// the VRAMCNT registers (0x04000240..0x04000247, GBATEK):
//
//   [3:0] MST: 0 LCDC/CPU, 1 Engine A, 2 3D engine, 3 Engine B,
//              4 texture, 5 texture+palette, 6/7 ARM7
//   [6:4] offset in 64 KB units (128 KB banks A/I use bits [6:5])
//   [7]   enable
//
// Bank sizes: A and I are 128 KB, B..H are 64 KB (656 KB total).
// Storage lives in SDRAM behind mem_arbiter (VRAM_SDRAM_BASE + a fixed
// per-bank base), matching how main RAM is already external; the banks'
// *mapping* (window offset -> physical bank storage) is what this module
// owns. Any master may address a bank at its current window offset
// regardless of MST (permissive, matches how games upload tile data);
// engines normally only see banks mapped to their own MST.
//
// Grant priority: CPU9 > 3D rasterizer > 3D layer read > engine A >
// engine B. Capture joins this scheduler when it lands (M5).
// One outstanding request at a time. The CPU and rasterizer ports are
// single accesses (`*_ready` pulses with the data); the engine A/B and 3D
// read ports are bursts: the master holds `*_req` with a length, the beats
// stream back on `*_bs_valid` in address order, and `*_ready` marks the
// last one.
//
// Window offsets are 20-bit (the 1 MB per-master VRAM window). A request
// that hits no mapped bank answers with open bus (0) and never reaches
// SDRAM.
//
// The 3D rasterizer is different: it has no window of its own, it owns the
// bank whose VRAMCNT MST is 2 and addresses it from the start of that
// bank (`g3_addr` = byte offset into the frame). The DS frame is 256x192
// at 16 bpp = 96 KB, so it needs a 128 KB bank: banks A or I under this
// module's bank-size model (B..H are 64 KB here; GBATEK's real map has
// B/C/D at 128 KB, which is a VRAM-map task of its own).
//============================================================================
module vram_arbiter (
	input            clk,
	input            reset,

	// VRAMCNT_A..I writes from main_bus
	input            reg_we,
	input      [3:0] reg_addr,   // 0..8 -> banks A..I
	input      [7:0] reg_data,

	// CPU port (main_bus VRAM window, 0x06000000..0x060FFFFF)
	input            cpu_req,
	input            cpu_wr,
	input     [19:0] cpu_addr,
	input     [15:0] cpu_wdata,
	output reg       cpu_ready,
	output reg [15:0] cpu_rdata,

	// engine A port (reads only, M2): a burst of a_len halfwords streamed
	// back on a_bs_valid, with a_ready marking the end of the burst. The
	// engines fetch a whole map row or a whole tile row per request, so the
	// grant is paid once per run instead of once per halfword.
	input            a_req,
	input     [19:0] a_addr,
	input      [7:0] a_len,
	output reg       a_ready,
	output           a_bs_valid,
	output    [15:0] a_bs_data,
	// engine B port (reads only, M2)
	input            b_req,
	input     [19:0] b_addr,
	input      [7:0] b_len,
	output reg       b_ready,
	output           b_bs_valid,
	output    [15:0] b_bs_data,

	// 3D rasterizer port (writes, M3): offset inside the frame buffer
	input            g3_req,
	input     [16:0] g3_addr,
	input     [15:0] g3_wdata,
	output reg        g3_ready,

	// 3D layer read port (engine A compositing, M3): same address space.
	// One request is a linear burst of `g3r_len` halfwords, streamed back
	// one per cycle: `g3r_ready` marks the end, and every beat arrives on
	// `g3r_bs_valid` in address order. The whole round trip is paid once per
	// burst, not once per pixel.
	input            g3r_req,
	input     [16:0] g3r_addr,
	input      [7:0] g3r_len,
	output reg        g3r_ready,
	output            g3r_bs_valid,
	output    [15:0] g3r_bs_data,

	// SDRAM master (toward mem_arbiter)
	output reg       v_req,
	output reg       v_wr,
	output reg [24:0] v_addr,
	output reg [15:0] v_wdata,
	output reg [1:0] v_be,
	output reg       v_bst,
	output reg [7:0] v_len,
	output reg [1:0] v_step,   // address units between burst beats
	input            v_ready,
	input     [15:0] v_rdata,
	input            v_bs_valid,
	input     [15:0] v_bs_data
);

localparam [23:0] VRAM_SDRAM_BASE = 24'h60_0000; // after 4MB main RAM @0x20_0000

//------------------------------------------------------------------
// Bank control registers
//------------------------------------------------------------------
reg [7:0] vramcnt [0:8];

// fixed physical SDRAM base per bank (storage slot, not window offset)
function [23:0] pbase;
	input [3:0] idx;
	begin
		case (idx)
		4'd0: pbase = VRAM_SDRAM_BASE + 24'h00000; // A 128K
		4'd1: pbase = VRAM_SDRAM_BASE + 24'h20000; // B 64K
		4'd2: pbase = VRAM_SDRAM_BASE + 24'h30000; // C
		4'd3: pbase = VRAM_SDRAM_BASE + 24'h40000; // D
		4'd4: pbase = VRAM_SDRAM_BASE + 24'h50000; // E
		4'd5: pbase = VRAM_SDRAM_BASE + 24'h60000; // F
		4'd6: pbase = VRAM_SDRAM_BASE + 24'h70000; // G
		4'd7: pbase = VRAM_SDRAM_BASE + 24'h80000; // H
		default: pbase = VRAM_SDRAM_BASE + 24'h90000; // I 128K
		endcase
	end
endfunction

function is_128k;
	input [3:0] idx;
	begin
		is_128k = (idx == 4'd0) || (idx == 4'd8);
	end
endfunction

function [19:0] wbase; // window offset the bank is currently mapped at
	input [3:0] idx;
	input [7:0] cnt;
	begin
		wbase = is_128k(idx) ? {1'b0, cnt[6:5], 17'd0}   // 128K granularity
		                     : {1'b0, cnt[6:4], 16'd0};  // 64K granularity
	end
endfunction

function [19:0] bsize;
	input [3:0] idx;
	bsize = is_128k(idx) ? 20'h20000 : 20'h10000;
endfunction

integer i;
always @(posedge clk) begin
	if (reset) begin
		for (i = 0; i < 9; i = i + 1)
			vramcnt[i] <= 8'h80; // enabled, LCDC (CPU) mapping
	end else if (reg_we && reg_addr < 4'd9) begin
		vramcnt[reg_addr] <= reg_data;
	end
end

//------------------------------------------------------------------
// Window decode per master: first matching bank (lowest index) wins
//------------------------------------------------------------------
// mst_want: 3'b000 = any (CPU), 3'b001 = engine A (MST 1), 3'b011 = B (MST 3)
reg        hit_cpu, hit_a, hit_b;
reg [24:0] phys_cpu, phys_a, phys_b;

task automatic decode;
	input  [19:0] off;
	input  [3:0]  mst_want;   // 4'hF = any
	output        hit;
	output [24:0] phys;
	integer b;
	reg [19:0] wb, bs;
	begin
		hit  = 1'b0;
		phys = 25'd0;
		// ascending: on overlapping mappings the LOWEST bank index
		// wins (A over B ... over I, GBATEK)
		for (b = 0; b <= 8; b = b + 1) begin
			wb = wbase(b[3:0], vramcnt[b]);
			bs = bsize(b[3:0]);
			if (!hit && vramcnt[b][7] &&
			    (mst_want == 4'hF || vramcnt[b][3:0] == mst_want) &&
			    off >= wb && off < wb + bs) begin
				hit  = 1'b1;
				// byte offset -> halfword slot: two bytes per stored halfword
				phys = {1'b0, pbase(b[3:0])} + {5'd0, (off - wb) >> 1};
			end
		end
	end
endtask

// Explicit sensitivity: the decode task reads vramcnt[] array words,
// which implicit @* does not reliably observe across tools.
// 3D frame decode: the first enabled bank carrying MST=2 that can hold
// the requested offset, addressed from that bank's own base. The
// rasterizer (writes) and engine A's compositor (reads) share it, so the
// frame has one address space no matter which side is asking.
//
// Every port speaks *byte* offsets (that is what the DS memory map is), so
// the decode halves them into the halfword slot the SDRAM side works in:
// two address units per stored 16-bit word, for the CPU window, the engine
// fetches and the 3D frame alike. Consecutive halfwords are therefore one
// slot apart, which is what lets a whole map row, a tile row or a run of
// frame pixels travel as one linear burst.
reg        hit_g3, hit_g3r;
reg [24:0] phys_g3, phys_g3r;

task automatic decode3d;
	input  [16:0] off;
	output        hit;
	output [24:0] phys;
	integer b;
	reg [19:0] bs;
	begin
		hit  = 1'b0;
		phys = 25'd0;
		for (b = 0; b <= 8; b = b + 1) begin
			bs = bsize(b[3:0]);
			if (!hit && vramcnt[b][7] && vramcnt[b][3:0] == 4'd2 &&
			    {3'd0, off} < bs) begin
				hit  = 1'b1;
				phys = {1'b0, pbase(b[3:0])} + {9'd0, off[16:1]};
			end
		end
	end
endtask

always @(cpu_addr or a_addr or b_addr or g3_addr or g3r_addr or
         vramcnt[0] or vramcnt[1] or vramcnt[2] or vramcnt[3] or vramcnt[4] or
         vramcnt[5] or vramcnt[6] or vramcnt[7] or vramcnt[8]) begin
	decode(cpu_addr, 4'hF, hit_cpu, phys_cpu);
	decode(a_addr,   4'd1, hit_a,   phys_a);
	decode(b_addr,   4'd3, hit_b,   phys_b);
	decode3d(g3_addr,  hit_g3,  phys_g3);
	decode3d(g3r_addr, hit_g3r, phys_g3r);
end

//------------------------------------------------------------------
// Scheduler: CPU > 3D write > 3D read > engine A > engine B,
// one outstanding
//
// The 3D read is the one exception to "one transaction per request": a
// request is a linear burst of g3r_len halfwords, granted once and then
// streamed back by the controller one beat per cycle, so the merge pass
// pays one round trip per burst instead of one per pixel. The beats are
// passed straight through to the renderer, which is why the stream is
// declared without back-pressure — the merge takes a beat every cycle.
//------------------------------------------------------------------
localparam S_IDLE = 2'd0, S_WAIT = 2'd1, S_COOL = 2'd2;

reg [1:0] state = S_IDLE;
reg [2:0] owner = 3'd0;  // 0 cpu, 1 a, 2 b, 3 3D write, 4 3D read

// burst beats belong to whoever holds the port this cycle
assign g3r_bs_valid = v_bs_valid && (owner == 3'd4);
assign a_bs_valid   = v_bs_valid && (owner == 3'd1);
assign b_bs_valid   = v_bs_valid && (owner == 3'd2);
assign g3r_bs_data  = v_bs_data;
assign a_bs_data    = v_bs_data;
assign b_bs_data    = v_bs_data;

// a frame pixel is two byte offsets wide, i.e. one slot: bursts are linear
localparam [1:0] D3_PIXEL_STEP = 2'd1;

always @(posedge clk) begin
	cpu_ready <= 0;
	a_ready   <= 0;
	b_ready   <= 0;
	g3_ready  <= 0;
	g3r_ready <= 0;
	v_bst     <= 0;   // only the 3D read branch holds it up for the grant
	v_step    <= 0;

	case (state)
	S_IDLE: begin
		if (cpu_req) begin
			owner <= 3'd0;
			if (hit_cpu) begin
				v_req   <= 1;
				v_wr    <= cpu_wr;
				v_addr  <= phys_cpu;
				v_wdata <= cpu_wdata;
				v_be    <= 2'b11;
				state   <= S_WAIT;
			end else begin
				cpu_ready <= 1;  // open bus
				cpu_rdata <= 16'h0000;
			end
		end else if (g3_req) begin
			owner <= 3'd3;
			if (hit_g3) begin
				v_req   <= 1;
				v_wr    <= 1'b1;
				v_addr  <= phys_g3;
				v_wdata <= g3_wdata;
				v_be    <= 2'b11;
				state   <= S_WAIT;
			end else begin
				g3_ready <= 1;  // no bank mapped to the 3D engine: drop
			end
		end else if (g3r_req) begin
			owner <= 3'd4;
			if (hit_g3r) begin
				v_req    <= 1;
				v_wr     <= 1'b0;
				v_bst    <= 1'b1;
				v_len    <= g3r_len;
				v_step   <= D3_PIXEL_STEP;
				v_addr   <= phys_g3r;
				v_be     <= 2'b11;
				state    <= S_WAIT;
			end else begin
				g3r_ready <= 1;  // no 3D bank: open bus, never hangs
				state     <= S_COOL;
			end
		end else if (a_req) begin
			owner <= 3'd1;
			if (hit_a) begin
				v_req <= 1;
				v_wr  <= 1'b0;
				v_bst <= 1'b1;
				v_len <= (a_len == 8'd0) ? 8'd1 : a_len;
				v_step<= 2'd1;              // one slot per halfword
				v_addr<= phys_a;
				v_be  <= 2'b11;
				state <= S_WAIT;
			end else begin
				a_ready <= 1;               // no bank mapped: open bus, no beats
				state   <= S_COOL;
			end
		end else if (b_req) begin
			owner <= 3'd2;
			if (hit_b) begin
				v_req <= 1;
				v_wr  <= 1'b0;
				v_bst <= 1'b1;
				v_len <= (b_len == 8'd0) ? 8'd1 : b_len;
				v_step<= 2'd1;
				v_addr<= phys_b;
				v_be  <= 2'b11;
				state <= S_WAIT;
			end else begin
				b_ready <= 1;
				state   <= S_COOL;
			end
		end
	end

	S_WAIT: begin
		// hold v_req until mem_arbiter completes; drop on v_ready
		if (v_ready) begin
			v_req <= 0;
			v_bst <= 0;
			case (owner)
			3'd0: begin cpu_ready <= 1; cpu_rdata <= v_rdata; end
			3'd1: begin a_ready   <= 1; end   // last beat already streamed
			3'd3: begin g3_ready  <= 1; end
			3'd4: begin g3r_ready <= 1; end
			default: begin b_ready <= 1; end
			endcase
			state <= S_COOL;
		end
	end

	// one dead cycle so a master that drops its req after seeing ready
	// can never be latched for a duplicate transaction
	S_COOL: state <= S_IDLE;

	default: state <= S_IDLE;
	endcase

	if (reset) begin
		state <= S_IDLE;
		v_req <= 0; v_wr <= 0;
		cpu_ready <= 0; a_ready <= 0; b_ready <= 0;
		g3_ready <= 0; g3r_ready <= 0; v_bst <= 0; v_step <= 0;
	end
end

wire _unused = &{1'b0, hit_b, phys_b};
	// Read the sink so the analyser does not call it "assigned but never read"
	// (warning 10036). The branch cannot be taken and synthesises to nothing:
	// measured on a throwaway module, the warning goes from 1 to 0 with this
	// line and the netlist is unchanged.
	always @(*) if (_unused) begin end


endmodule
