//============================================================================
// NDS MiSTer Test — DMA engine testbench
//
//   iverilog -g2012 -o /tmp/tb_dma tb/tb_dma_engine.sv \
//            rtl/bus/dma_engine.sv && vvp /tmp/tb_dma
//
// Exercises the four channels against a behavioural bus master with
// byte lanes (same handshake shape as main_bus: request held, ready
// pulse, request dropped before re-arm):
//   - immediate 16-bit inc/inc, odd-halfword destination, lane mirror
//   - immediate 32-bit word copy + register readback (SAD/CNT_L/CNT_H)
//   - vblank timing: armed channel does NOT run before the trigger
//   - two armed channels run on one trigger, sources can change
//   - IRQ pulse on completion (IRQ8+n mapping)
//   - hblank + repeat: enable bit stays set across triggers, disarm
//============================================================================
`timescale 1ns / 1ps

module tb_dma_engine;

reg clk = 0;
always #10 clk = ~clk; // 50 MHz

reg reset = 1;

// register file port (raw IO offsets 0xB0..0xDF)
reg         reg_we = 0;
reg  [7:0]  reg_addr = 0;
reg  [15:0] reg_data = 0;
reg  [7:0]  reg_rd_addr = 0;
wire [15:0] reg_rdata;

// bus master
wire [31:0] d_addr, d_wdata;
wire  [3:0] d_be;
wire        d_rd, d_wr;
reg         d_ready = 0;
reg  [31:0] d_rdata = 0;

// triggers + IRQ
reg         vblank = 0, hblank = 0;
wire  [3:0] irq_set;

dma_engine dut (
	.clk(clk),
	.reset(reset),
	.reg_we(reg_we),
	.reg_addr(reg_addr),
	.reg_data(reg_data),
	.reg_rd_addr(reg_rd_addr),
	.reg_rdata(reg_rdata),
	.d_addr(d_addr),
	.d_wdata(d_wdata),
	.d_be(d_be),
	.d_rd(d_rd),
	.d_wr(d_wr),
	.d_ready(d_ready),
	.d_rdata(d_rdata),
	.vblank(vblank),
	.hblank(hblank),
	.irq_set(irq_set)
);

//------------------------------------------------------------------
// Behavioural memory + single-outstanding handshake model
//------------------------------------------------------------------
reg [31:0] mem [0:255];

localparam MI = 2'd0, MB = 2'd1, MD = 2'd2;
reg [1:0]  mstate = MI;
reg [31:0] m_addr = 0, m_wd = 0;
reg  [3:0] m_be = 0;
reg        m_wr_r = 0;

always @(posedge clk) begin
	d_ready <= 1'b0;
	case (mstate)
	MI: if (d_rd || d_wr) begin
		m_addr  <= d_addr;
		m_wd    <= d_wdata;
		m_be    <= d_be;
		m_wr_r  <= d_wr;
		mstate  <= MB;
	end
	MB: begin
		if (m_wr_r) begin
			if (m_be == 4'hF)
				mem[m_addr[9:2]] <= m_wd;
			else if (m_addr[1])
				mem[m_addr[9:2]][31:16] <= m_wd[15:0];
			else
				mem[m_addr[9:2]][15:0] <= m_wd[15:0];
		end
		d_rdata <= mem[m_addr[9:2]];
		d_ready <= 1'b1;
		mstate  <= MD;
	end
	MD: if (!d_rd && !d_wr) mstate <= MI;
	default: mstate <= MI;
	endcase
	if (reset) begin
		mstate <= MI;
		d_ready <= 1'b0;
	end
end

// sticky IRQ capture
reg irq_seen = 0;
always @(posedge clk) if (|irq_set) irq_seen <= 1'b1;

//------------------------------------------------------------------
// helpers
//------------------------------------------------------------------
task wr16;
	input [7:0]  off;
	input [15:0] d;
	begin
		@(posedge clk);
		reg_we   <= 1'b1;
		reg_addr <= off;
		reg_data <= d;
		@(posedge clk);
		reg_we   <= 1'b0;
	end
endtask

task rd16;
	input  [7:0] off;
	output [15:0] v;
	begin
		reg_rd_addr = off;
		#1 v = reg_rdata;   // combinational readback
	end
endtask

reg [15:0] rv;
integer errors = 0;
task check;
	input [8*40:1] name;
	input cond;
	begin
		if (!cond) begin
			$display("FAIL %0s", name);
			errors = errors + 1;
		end else $display("ok   %0s", name);
	end
endtask

localparam DEAD = 32'hDEAD_DEAD;

integer i;
initial begin
	for (i = 0; i < 256; i = i + 1) mem[i] = DEAD;
	// source patterns
	mem[0]  = 32'h0003_0001;
	mem[1]  = 32'h0007_0005;
	mem[2]  = 32'h000B_0009;
	mem[3]  = 32'h000F_000D;
	mem[4]  = 32'h4444_4444;
	mem[5]  = 32'h5555_5555;
	mem[6]  = 32'h6666_6666;
	mem[7]  = 32'h7777_7777;
	mem[8]  = 32'h0808_0808;
	mem[9]  = 32'h0909_0909;
	mem[10] = 32'h1010_1010;
	mem[11] = 32'h1111_1111;

	repeat (4) @(posedge clk);
	reset = 0;
	repeat (4) @(posedge clk);

	//----------------------------------------------------------------
	// 1. immediate 16-bit, odd-halfword destination (0x42)
	//----------------------------------------------------------------
	wr16(8'hB0, 16'h0000); wr16(8'hB2, 16'h0200); // SAD 0x02000000
	wr16(8'hB4, 16'h0042); wr16(8'hB6, 16'h0200); // DAD 0x02000042
	wr16(8'hB8, 16'd8);                           // count 8 units
	wr16(8'hBA, 16'h0001);                        // enable, immediate
	repeat (300) @(posedge clk);

	check("16-bit odd dest w16", mem[16] === {16'h0001, DEAD[15:0]});
	check("16-bit odd dest w17", mem[17] === 32'h0005_0003);
	check("16-bit odd dest w18", mem[18] === 32'h0009_0007);
	check("16-bit odd dest w19", mem[19] === 32'h000D_000B);
	check("16-bit odd dest w20 tail", mem[20] === {DEAD[31:16], 16'h000F});

	rd16(8'hBA, rv);
	check("ch0 CNT_H cleared at completion", rv[0] === 1'b0);
	rd16(8'hB0, rv);
	check("ch0 SAD unchanged", rv === 16'h0000);
	rd16(8'hB2, rv);
	check("ch0 SAD hi readback", rv === 16'h0200);
	rd16(8'hB8, rv);
	check("ch0 CNT_L readback", rv === 16'd8);

	//----------------------------------------------------------------
	// 2. immediate 32-bit word copy
	//----------------------------------------------------------------
	// channel 1 base 0xBC: SAD 0xBC/0xBE, DAD 0xC0/0xC2, CNT_L 0xC4, CNT_H 0xC6
	wr16(8'hBC, 16'h0010); wr16(8'hBE, 16'h0200); // SAD 0x02000010 (w4)
	wr16(8'hC0, 16'h0030); wr16(8'hC2, 16'h0200); // DAD 0x02000030 (w12)
	wr16(8'hC4, 16'd4);
	wr16(8'hC6, 16'h0041);                        // enable, 32-bit, immediate
	repeat (200) @(posedge clk);

	check("32-bit copy w12", mem[12] === 32'h4444_4444);
	check("32-bit copy w13", mem[13] === 32'h5555_5555);
	check("32-bit copy w14", mem[14] === 32'h6666_6666);
	check("32-bit copy w15", mem[15] === 32'h7777_7777);
	rd16(8'hC6, rv);
	check("ch1 CNT_H cleared", rv[0] === 1'b0);

	//----------------------------------------------------------------
	// 3. vblank timing: armed channel waits for the trigger
	//----------------------------------------------------------------
	wr16(8'hC8, 16'h0020); wr16(8'hCA, 16'h0200); // ch2 SAD 0x02000020 (w8)
	wr16(8'hCC, 16'h0060); wr16(8'hCE, 16'h0200); // DAD 0x02000060 (w24)
	wr16(8'hD0, 16'd4);
	wr16(8'hD2, 16'h0081);                        // enable, vblank
	repeat (200) @(posedge clk);
	check("vblank: no run before trigger", mem[24] === DEAD && mem[25] === DEAD);
	rd16(8'hD2, rv);
	check("vblank: still armed", rv[0] === 1'b1);

	@(posedge clk); vblank <= 1;
	@(posedge clk); vblank <= 0;
	repeat (200) @(posedge clk);
	check("vblank: ran on trigger", mem[24] === 32'h0808_0808
	                              && mem[25] === 32'h0909_0909);
	rd16(8'hD2, rv);
	check("vblank: enable cleared after one-shot", rv[0] === 1'b0);

	//----------------------------------------------------------------
	// 4. two armed channels on ONE vblank trigger (ch2 + ch3)
	//----------------------------------------------------------------
	mem[8]  = 32'h8888_8888;                     // new source data proves
	mem[9]  = 32'h9999_9999;                     // ch2 runs a second time
	wr16(8'hD2, 16'h0081);                       // re-arm ch2
	wr16(8'hD4, 16'h0028); wr16(8'hD6, 16'h0200); // ch3 SAD 0x02000028 (w10)
	wr16(8'hD8, 16'h0070); wr16(8'hDA, 16'h0200); // DAD 0x02000070 (w28)
	wr16(8'hDC, 16'd4);
	wr16(8'hDE, 16'h0081);                       // ch3 armed, vblank
	repeat (50) @(posedge clk);

	@(posedge clk); vblank <= 1;
	@(posedge clk); vblank <= 0;
	repeat (300) @(posedge clk);
	check("one trigger runs ch2 (new data)", mem[24] === 32'h8888_8888
	                                       && mem[25] === 32'h9999_9999);
	check("one trigger runs ch3 too", mem[28] === 32'h1010_1010
	                                && mem[29] === 32'h1111_1111);
	rd16(8'hD2, rv);
	check("ch2 disarmed after run", rv[0] === 1'b0);
	rd16(8'hDE, rv);
	check("ch3 disarmed after run", rv[0] === 1'b0);

	//----------------------------------------------------------------
	// 5. IRQ on completion
	//----------------------------------------------------------------
	wr16(8'hD8, 16'h007C);                       // ch3 DAD 0x0200007C (w31)
	wr16(8'hDA, 16'h0200);
	wr16(8'hDC, 16'd1);
	wr16(8'hDE, 16'h0043);                       // enable+IRQ+32bit+immediate
	repeat (200) @(posedge clk);
	check("IRQ pulse on completion", irq_seen === 1'b1);
	check("IRQ transfer landed", mem[31] === 32'h1010_1010);

	//----------------------------------------------------------------
	// 6. hblank + repeat: enable stays set, disarm works
	//----------------------------------------------------------------
	wr16(8'hD0, 16'd4);
	wr16(8'hD2, 16'h0121);                       // enable+repeat+hblank
	repeat (50) @(posedge clk);

	@(posedge clk); hblank <= 1;
	@(posedge clk); hblank <= 0;
	repeat (200) @(posedge clk);
	rd16(8'hD2, rv);
	check("repeat: enable stays after hblank", rv[0] === 1'b1);

	// second trigger also completes without stalling
	@(posedge clk); hblank <= 1;
	@(posedge clk); hblank <= 0;
	repeat (200) @(posedge clk);
	rd16(8'hD2, rv);
	check("repeat: still armed on second hblank", rv[0] === 1'b1);

	wr16(8'hD2, 16'h0120);                       // write enable=0 -> stop
	repeat (20) @(posedge clk);
	rd16(8'hD2, rv);
	check("disarm by enable=0 write", rv[0] === 1'b0);

	if (errors == 0) $display("tb_dma_engine: PASS");
	else             $display("tb_dma_engine: FAIL (%0d errors)", errors);
	$finish;
end

initial begin
	#2_000_000;
	$display("tb_dma_engine: FAIL (timeout)");
	$finish;
end

endmodule
