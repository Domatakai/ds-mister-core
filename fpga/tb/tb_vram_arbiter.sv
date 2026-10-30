//============================================================================
// NDS MiSTer Test — VRAM bank arbiter testbench
//
//   iverilog -g2012 -o /tmp/tb_vram tb/tb_vram_arbiter.sv \
//            rtl/video/vram_arbiter.sv && vvp /tmp/tb_vram
//
// Exercises the VRAMCNT bank map against a behavioural SDRAM master:
//   - reset defaults: banks enabled, LCDC (CPU) mapping, offset 0
//   - CPU roundtrip through bank A storage
//   - MST filtering: engine A only sees banks mapped MST=1, CPU sees
//     the lowest-index bank at any mapping; separate physical storage
//   - offset remap (64 KB units) per GBATEK
//   - disabled bank answers open bus with zero SDRAM traffic
//   - grant priority: simultaneous CPU + engine request -> CPU first
//   - engine B port with an MST=3 bank
//============================================================================
`timescale 1ns / 1ps

module tb_vram_arbiter;

reg clk = 0;
always #10 clk = ~clk; // 50 MHz

reg reset = 1;

// VRAMCNT write port (bank index 0..8)
reg        reg_we = 0;
reg  [3:0] reg_addr = 0;
reg  [7:0] reg_data = 0;

// CPU port
reg         cpu_req = 0, cpu_wr = 0;
reg  [19:0] cpu_addr = 0;
reg  [15:0] cpu_wdata = 0;
wire        cpu_ready;
wire [15:0] cpu_rdata;

// engine ports: burst requests, beats streamed back
reg         a_req = 0;
reg  [19:0] a_addr = 0;
reg   [7:0] a_len = 0;
wire        a_ready;
wire        a_bs_valid;
wire [15:0] a_bs_data;

reg         b_req = 0;
reg  [19:0] b_addr = 0;
reg   [7:0] b_len = 0;
wire        b_ready;
wire        b_bs_valid;
wire [15:0] b_bs_data;

// 3D rasterizer write port
reg         g3_req = 0;
reg  [16:0] g3_addr = 0;
reg  [15:0] g3_wdata = 0;
wire        g3_ready;

// 3D layer read port (engine A compositor): a burst of g3r_len halfwords
// streamed back on g3r_bs_valid
reg         g3r_req = 0;
reg  [16:0] g3r_addr = 0;
reg   [7:0] g3r_len = 0;
wire        g3r_ready;
wire        g3r_bs_valid;
wire [15:0] g3r_bs_data;

// SDRAM master (behavioural)
wire        v_req, v_wr, v_bst;
wire [24:0] v_addr;
wire [15:0] v_wdata;
wire  [1:0] v_be;
wire  [7:0] v_len;
wire  [1:0] v_step;
reg         v_ready = 0;
reg  [15:0] v_rdata = 0;
reg         v_bs_valid = 0;
reg  [15:0] v_bs_data = 0;

vram_arbiter dut (
	.clk(clk),
	.reset(reset),
	.reg_we(reg_we),
	.reg_addr(reg_addr),
	.reg_data(reg_data),
	.cpu_req(cpu_req),
	.cpu_wr(cpu_wr),
	.cpu_addr(cpu_addr),
	.cpu_wdata(cpu_wdata),
	.cpu_ready(cpu_ready),
	.cpu_rdata(cpu_rdata),
	.a_req(a_req),
	.a_addr(a_addr),
	.a_len(a_len),
	.a_ready(a_ready),
	.a_bs_valid(a_bs_valid),
	.a_bs_data(a_bs_data),
	.b_req(b_req),
	.b_addr(b_addr),
	.b_len(b_len),
	.b_ready(b_ready),
	.b_bs_valid(b_bs_valid),
	.b_bs_data(b_bs_data),
	.g3_req(g3_req),
	.g3_addr(g3_addr),
	.g3_wdata(g3_wdata),
	.g3_ready(g3_ready),
	.g3r_req(g3r_req),
	.g3r_addr(g3r_addr),
	.g3r_len(g3r_len),
	.g3r_ready(g3r_ready),
	.g3r_bs_valid(g3r_bs_valid),
	.g3r_bs_data(g3r_bs_data),
	.v_req(v_req),
	.v_wr(v_wr),
	.v_addr(v_addr),
	.v_wdata(v_wdata),
	.v_be(v_be),
	.v_bst(v_bst),
	.v_len(v_len),
	.v_step(v_step),
	.v_ready(v_ready),
	.v_rdata(v_rdata),
	.v_bs_valid(v_bs_valid),
	.v_bs_data(v_bs_data)
);

//------------------------------------------------------------------
// Behavioural SDRAM: one model word per stored halfword, indexed by the
// physical slot the arbiter puts on v_addr (bank I sits at 0x90000, so
// the array has to reach past 0xA0000 slots)
//------------------------------------------------------------------
reg [15:0] sd [0:1048575];
integer    sd_ops = 0;

localparam SI = 2'd0, SW = 2'd1, SD = 2'd2, SB = 2'd3;
reg [1:0] sstate = SI;
reg [1:0] scnt = 0;
reg [19:0] s_idx = 0;   // physical slot, 20 bits: bank I sits at 0x90000
// burst streaming: three clocks of latency, then one beat per cycle
reg [19:0] bs_next = 0;
reg  [7:0] bs_left = 0;
reg  [1:0] bs_lat = 0;
reg  [1:0] bs_step = 1;

always @(posedge clk) begin
	v_ready    <= 1'b0;
	v_bs_valid <= 1'b0;
	case (sstate)
	SI: if (v_req) begin
		s_idx  <= v_addr[19:0];
		scnt   <= 2'd2;
		sstate <= v_bst ? SB : SW;
		if (v_bst) begin
			bs_next <= v_addr[19:0];
			bs_left <= v_len;
			bs_lat  <= 2'd3;
			// one model word per stored halfword, so the physical stride is
			// the model stride
			bs_step <= (v_step == 2'd0) ? 2'd1 : v_step;
		end
	end
	SW: begin
		if (scnt == 2'd0) begin
			if (v_wr) sd[s_idx] <= v_wdata;
			v_rdata  <= sd[s_idx];
			v_ready  <= 1'b1;
			sd_ops   <= sd_ops + 1;
			sstate   <= SD;
		end else scnt <= scnt - 2'd1;
	end
	SB: begin
		// stream the burst: one halfword per cycle until the length runs out
		if (bs_lat != 2'd0) bs_lat <= bs_lat - 2'd1;
		else if (bs_left != 8'd0) begin
			v_bs_valid <= 1'b1;
			v_bs_data  <= sd[bs_next];
			bs_next    <= bs_next + {15'd0, bs_step};
			bs_left    <= bs_left - 1'd1;
			sd_ops     <= sd_ops + 1;
		end else begin
			v_ready <= 1'b1;
			sstate  <= SD;
		end
	end
	SD: if (!v_req) sstate <= SI;
	default: sstate <= SI;
	endcase
	if (reset) begin
		sstate <= SI;
		v_ready <= 1'b0;
		v_bs_valid <= 1'b0;
	end
end

// capture beats for the checks below
reg [15:0] g3b [0:255];
integer    g3n = 0;
integer    errors = 0;   // declared here: the burst reader reports into it
integer    i;
reg [15:0] ab [0:15];     // engine A burst beats (declared before the tasks
integer    abn = 0;       // that fill it: iverilog wants no use-before-declare)

//------------------------------------------------------------------
// helpers
//------------------------------------------------------------------
task wr_cnt;
	input [3:0] bank;
	input [7:0] v;
	begin
		@(posedge clk);
		reg_we   <= 1'b1;
		reg_addr <= bank;
		reg_data <= v;
		@(posedge clk);
		reg_we   <= 1'b0;
	end
endtask

task cpu_read;
	input  [19:0] addr;
	output [15:0] d;
	begin
		@(posedge clk);
		cpu_req  <= 1'b1;
		cpu_wr   <= 1'b0;
		cpu_addr <= addr;
		@(posedge clk);
		while (!cpu_ready) @(posedge clk);
		d = cpu_rdata;
		cpu_req <= 1'b0;
		@(posedge clk);
	end
endtask

task cpu_write;
	input [19:0] addr;
	input [15:0] d;
	begin
		@(posedge clk);
		cpu_req  <= 1'b1;
		cpu_wr   <= 1'b1;
		cpu_addr <= addr;
		cpu_wdata<= d;
		@(posedge clk);
		while (!cpu_ready) @(posedge clk);
		cpu_req <= 1'b0;
		@(posedge clk);
	end
endtask

// one burst request from engine A; beats land in ab[0..abn-1]
task eng_a_burst;
	input  [19:0] addr;
	input   [7:0] len;
	begin
		integer n;
		@(posedge clk);
		a_req  <= 1'b1;
		a_addr <= addr;
		a_len  <= len;
		abn    = 0;
		n      = 0;
		while (!a_ready && n < 200) begin
			@(posedge clk); #1;
			if (a_bs_valid) begin
				ab[abn] = a_bs_data;
				abn     = abn + 1;
			end
			n = n + 1;
		end
		a_req <= 1'b0;
		@(posedge clk);
	end
endtask

// single halfword read through the same burst port
task eng_a_read;
	input  [19:0] addr;
	output [15:0] d;
	begin
		eng_a_burst(addr, 8'd1);
		d = (abn == 0) ? 16'h0000 : ab[0];   // no mapped bank -> open bus
	end
endtask

task g3_write;
	input [16:0] addr;
	input [15:0] d;
	begin
		@(posedge clk);
		g3_req   <= 1'b1;
		g3_addr  <= addr;
		g3_wdata <= d;
		@(posedge clk);
		while (!g3_ready) @(posedge clk);
		g3_req <= 1'b0;
		@(posedge clk);
	end
endtask

// one burst request; beats land in g3b[0..g3n-1]
task g3_read;
	input  [16:0] addr;
	input   [7:0] len;
	begin
		@(posedge clk);
		g3r_req  <= 1'b1;
		g3r_addr <= addr;
		g3r_len  <= len;
		g3n      = 0;
		@(posedge clk);
		i = 0;
		while (!g3r_ready && i < 500) begin
			@(posedge clk);
			#1;
			if (g3r_bs_valid) begin
				g3b[g3n] = g3r_bs_data;
				g3n      = g3n + 1;
			end
			i = i + 1;
		end
		if (!g3r_ready) begin
			errors = errors + 1;
			$display("FAIL 3D read burst never completed (addr %h)", addr);
		end
		g3r_req <= 1'b0;
		@(posedge clk);
	end
endtask

task eng_b_read;
	input  [19:0] addr;
	output [15:0] d;
	begin
		integer n;
		@(posedge clk);
		b_req  <= 1'b1;
		b_addr <= addr;
		b_len  <= 8'd1;
		n      = 0;
		d      = 16'h0000;
		while (!b_ready && n < 200) begin
			@(posedge clk); #1;
			if (b_bs_valid) d = b_bs_data;
			n = n + 1;
		end
		b_req <= 1'b0;
		@(posedge clk);
	end
endtask

reg [15:0] v1;
reg [31:0] w1;
task check;
	input [8*56:1] name;
	input cond;
	begin
		if (!cond) begin
			$display("FAIL %0s", name);
			errors = errors + 1;
		end else $display("ok   %0s", name);
	end
endtask

// grant-order timestamps
reg [31:0] cyc = 0;
reg [31:0] t_cpu = 32'hFFFF, t_a = 32'hFFFF;
always @(posedge clk) begin
	cyc <= cyc + 1;
	if (cpu_ready) t_cpu <= cyc;
	if (a_ready)   t_a   <= cyc;
end

initial begin
	// bank A physical: offset 0x00000; bank B: 0x20000; bank C: 0x30000
	// model index = physical byte offset / 2 (halfword)
	for (i = 0; i < 1048576; i = i + 1) sd[i] = 16'h0000;
	// model word = stored halfword, so a window byte offset 2n lives at
	// slot n of the bank's storage (the arbiter's decode halves byte
	// offsets, and pbase is the bank's base slot)
	sd[17'h00000] = 16'hAAAA;  // bank A + byte 0x00000
	sd[17'h08000] = 16'hDDDD;  // bank A + byte 0x10000
	sd[20'h20000] = 16'hBBBB;  // bank B + byte 0x00000
	sd[20'h20008] = 16'hCCCC;  // bank B + byte 0x00010
	sd[20'h30000] = 16'hEEEE;  // bank C + byte 0x00000

	repeat (4) @(posedge clk);
	reset = 0;
	repeat (4) @(posedge clk);

	//----------------------------------------------------------------
	// 1. defaults + CPU roundtrip through bank A (LCDC mapping)
	//----------------------------------------------------------------
	cpu_write(20'h00010, 16'h1234);
	cpu_read (20'h00010, v1);
	check("CPU roundtrip (bank A, default map)", v1 === 16'h1234);

	//----------------------------------------------------------------
	// 2. MST filter: bank B -> engine A (MST 1), both at offset 0
	//----------------------------------------------------------------
	wr_cnt(4'd1, 8'h81);      // bank B: enable, MST=1, offset 0
	cpu_read(20'h00000, v1);
	check("CPU at 0 sees bank A (lowest index)", v1 === 16'hAAAA);
	eng_a_read(20'h00000, v1);
	check("engine A at 0 sees bank B (MST 1)", v1 === 16'hBBBB);
	eng_a_read(20'h00010, v1);
	check("engine A separate storage at +0x10", v1 === 16'hCCCC);
	cpu_read(20'h00010, v1);
	check("CPU at +0x10 still bank A", v1 === 16'h1234);

	// engine A fetches a run (a map row or a tile row) as one burst: four
	// consecutive halfwords, in address order, for a single grant
	sd[20'h20000] = 16'h1111;
	sd[20'h20001] = 16'h2222;
	sd[20'h20002] = 16'h3333;
	sd[20'h20003] = 16'h4444;
	i = sd_ops;
	eng_a_burst(20'h00000, 8'd4);
	check("engine A burst returned four beats", abn == 4);
	check("engine A burst beat 0", ab[0] === 16'h1111);
	check("engine A burst beat 1", ab[1] === 16'h2222);
	check("engine A burst beat 2", ab[2] === 16'h3333);
	check("engine A burst beat 3", ab[3] === 16'h4444);
	sd[20'h20000] = 16'hBBBB;
	sd[20'h20001] = 16'h0000;
	sd[20'h20002] = 16'h0000;
	sd[20'h20003] = 16'h0000;

	//----------------------------------------------------------------
	// 3. offset remap: bank B at window offset 0x10000 (64 KB units)
	//----------------------------------------------------------------
	wr_cnt(4'd1, 8'h91);      // bank B: enable, MST=1, offset=1
	eng_a_read(20'h10000, v1);
	check("engine A at 0x10000 -> bank B base", v1 === 16'hBBBB);
	cpu_read(20'h10000, v1);
	check("CPU at 0x10000 -> bank A (128K covers it)", v1 === 16'hDDDD);

	//----------------------------------------------------------------
	// 4. disabled bank: open bus, no SDRAM traffic
	//----------------------------------------------------------------
	wr_cnt(4'd1, 8'h10);      // bank B: MST=1, offset 0, DISABLED
	i = sd_ops;
	eng_a_read(20'h00000, v1);
	check("disabled bank -> open bus 0", v1 === 16'h0000);
	check("disabled bank -> no SDRAM access", (sd_ops - i) == 0);

	//----------------------------------------------------------------
	// 5. priority: simultaneous CPU + engine A -> CPU granted first
	//----------------------------------------------------------------
	wr_cnt(4'd1, 8'h81);      // re-enable bank B for engine A
	t_cpu = 32'hFFFF; t_a = 32'hFFFF;
	fork
		begin
			@(posedge clk);
			cpu_req <= 1'b1; cpu_wr <= 1'b0; cpu_addr <= 20'h00020;
			@(posedge clk);
			while (!cpu_ready) @(posedge clk);
			cpu_req <= 1'b0;
		end
		begin
			@(posedge clk);
			a_req <= 1'b1; a_addr <= 20'h00020;
			@(posedge clk);
			while (!a_ready) @(posedge clk);
			a_req <= 1'b0;
		end
	join
	repeat (4) @(posedge clk);
	check("CPU granted before engine A", t_cpu < t_a);

	//----------------------------------------------------------------
	// 6. engine B port with an MST=3 bank
	//----------------------------------------------------------------
	wr_cnt(4'd2, 8'h83);      // bank C: enable, MST=3, offset 0
	eng_b_read(20'h00000, v1);
	check("engine B at 0 -> bank C (MST 3)", v1 === 16'hEEEE);
	cpu_read(20'h00000, v1);
	check("CPU unaffected by MST 3 bank", v1 === 16'hAAAA);

	//----------------------------------------------------------------
	// 7. 3D rasterizer write-back
	//----------------------------------------------------------------
	// bank I (128K) is the only bank under this model that can hold the
	// 96 KB frame, so map it to the 3D engine at window 0x20000
	wr_cnt(4'd8, 8'hA2);      // enable, MST=2 (3D), 128K offset
	g3_write(17'h0_0000, 16'h5A5A);
	cpu_read(20'h20000, v1);
	check("3D pixel written into the MST=2 bank", v1 === 16'h5A5A);

	g3_write(17'h0_8000, 16'hA5A5);      // +32 KB, still inside bank I
	cpu_read(20'h28000, v1);
	check("3D frame address honours the byte offset", v1 === 16'hA5A5);

	// a frame offset past a 64 KB bank must not reach SDRAM or hang
	wr_cnt(4'd8, 8'h00);      // release bank I
	wr_cnt(4'd1, 8'h82);      // bank B (64K) -> 3D engine
i = sd_ops;
	g3_write(17'h1_0000, 16'hDEAD);
	check("3D write past a 64K bank drops without SDRAM", (sd_ops - i) == 0);

	//----------------------------------------------------------------
	// 8. 3D layer read port (engine A composites the frame)
	//----------------------------------------------------------------
	wr_cnt(4'd1, 8'h80);      // bank B back to CPU
	wr_cnt(4'd8, 8'hA2);      // bank I -> 3D engine again
	g3_read(17'h0_0000, 8'd1);
	check("3D read sees the rasterizer's pixel", g3b[0] === 16'h5A5A);
	g3_read(17'h0_8000, 8'd1);
	check("3D read honours the frame offset", g3b[0] === 16'hA5A5);

	// one request streams a whole run of halfwords in address order: the
	// merge pass fetches a line this way, paying one grant for 64 pixels
	g3_write(17'h0_0000, 16'h1111);
	g3_write(17'h0_0002, 16'h2222);
	g3_write(17'h0_0004, 16'h3333);
	g3_write(17'h0_0006, 16'h4444);
	g3_read(17'h0_0000, 8'd4);
	check("3D burst returned the requested number of beats", g3n == 4);
	check("3D burst beat 0 is the addressed halfword", g3b[0] === 16'h1111);
	check("3D burst beat 1 is the next halfword", g3b[1] === 16'h2222);
	check("3D burst beat 2 follows", g3b[2] === 16'h3333);
	check("3D burst beat 3 follows", g3b[3] === 16'h4444);

	// no bank mapped to the 3D engine: open bus, and it must not hang
	wr_cnt(4'd8, 8'h00);
	g3_read(17'h0_0000, 8'd4);
	check("3D read with no MST=2 bank -> open bus, no beats", g3n == 0);
	wr_cnt(4'd8, 8'hA2);      // restore for later checks

	if (errors == 0) $display("tb_vram_arbiter: PASS");
	else             $display("tb_vram_arbiter: FAIL (%0d errors)", errors);
	$finish;
end

initial begin
	#2_000_000;
	$display("tb_vram_arbiter: FAIL (timeout)");
	$finish;
end

endmodule
