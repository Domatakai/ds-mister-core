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

// engine ports
reg         a_req = 0;
reg  [19:0] a_addr = 0;
wire        a_ready;
wire [15:0] a_rdata;

reg         b_req = 0;
reg  [19:0] b_addr = 0;
wire        b_ready;
wire [15:0] b_rdata;

// SDRAM master (behavioural)
wire        v_req, v_wr;
wire [24:0] v_addr;
wire [15:0] v_wdata;
wire  [1:0] v_be;
reg         v_ready = 0;
reg  [15:0] v_rdata = 0;

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
	.a_ready(a_ready),
	.a_rdata(a_rdata),
	.b_req(b_req),
	.b_addr(b_addr),
	.b_ready(b_ready),
	.b_rdata(b_rdata),
	.v_req(v_req),
	.v_wr(v_wr),
	.v_addr(v_addr),
	.v_wdata(v_wdata),
	.v_be(v_be),
	.v_ready(v_ready),
	.v_rdata(v_rdata)
);

//------------------------------------------------------------------
// Behavioural SDRAM: 256 KB indexed by the physical offset after
// VRAM_SDRAM_BASE (0x60_0000 -> banks A/B/C fit in 192 KB)
//------------------------------------------------------------------
reg [15:0] sd [0:131071];
integer    sd_ops = 0;

localparam SI = 2'd0, SW = 2'd1, SD = 2'd2;
reg [1:0] sstate = SI;
reg [1:0] scnt = 0;
reg [16:0] s_idx = 0;

always @(posedge clk) begin
	v_ready <= 1'b0;
	case (sstate)
	SI: if (v_req) begin
		s_idx  <= v_addr[17:1];
		scnt   <= 2'd2;
		sstate <= SW;
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
	SD: if (!v_req) sstate <= SI;
	default: sstate <= SI;
	endcase
	if (reset) begin
		sstate <= SI;
		v_ready <= 1'b0;
	end
end

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

task eng_a_read;
	input  [19:0] addr;
	output [15:0] d;
	begin
		@(posedge clk);
		a_req  <= 1'b1;
		a_addr <= addr;
		@(posedge clk);
		while (!a_ready) @(posedge clk);
		d = a_rdata;
		a_req <= 1'b0;
		@(posedge clk);
	end
endtask

task eng_b_read;
	input  [19:0] addr;
	output [15:0] d;
	begin
		@(posedge clk);
		b_req  <= 1'b1;
		b_addr <= addr;
		@(posedge clk);
		while (!b_ready) @(posedge clk);
		d = b_rdata;
		b_req <= 1'b0;
		@(posedge clk);
	end
endtask

reg [15:0] v1;
integer errors = 0;
task check;
	input [8*44:1] name;
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

integer i;
initial begin
	// bank A physical: offset 0x00000; bank B: 0x20000; bank C: 0x30000
	// model index = physical byte offset / 2 (halfword)
	for (i = 0; i < 131072; i = i + 1) sd[i] = 16'h0000;
	sd[17'h00000] = 16'hAAAA;  // bank A + 0x00000
	sd[17'h08000] = 16'hDDDD;  // bank A + 0x10000
	sd[17'h10000] = 16'hBBBB;  // bank B + 0x00000
	sd[17'h10008] = 16'hCCCC;  // bank B + 0x00010
	sd[17'h18000] = 16'hEEEE;  // bank C + 0x00000

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
