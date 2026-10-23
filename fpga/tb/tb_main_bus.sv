//============================================================================
// NDS MiSTer Test — main bus testbench
//
//   iverilog -g2012 -o /tmp/tb_bus tb/tb_main_bus.sv \
//            rtl/bus/main_bus.sv rtl/mem/mem_arbiter.sv \
//            rtl/cart/cheat_engine.sv && vvp /tmp/tb_bus
//
// End-to-end fabric check: both CPU masters against private regions
// (WRAM BRAM, IO registers incl. KEYINPUT), shared main RAM through
// mem_arbiter with a behavioural SDRAM model (byte enables, two-halfword
// assembly), the cart window through a bridge model, an end-to-end cheat
// patch through S_CPATCH, and concurrent two-master traffic.
//============================================================================
`timescale 1ns / 1ps

module tb_main_bus;

reg clk = 0;
always #10 clk = ~clk; // 50 MHz

reg reset = 1;

reg [11:0] ds_keys = 12'hFFF;

// ---- master signals
reg [31:0] m9_addr = 0, m9_wdata = 0;
reg  [3:0] m9_be = 0;
reg        m9_rd = 0, m9_wr = 0;
wire       m9_ready;
wire [31:0] m9_rdata;

reg [31:0] m7_addr = 0, m7_wdata = 0;
reg  [3:0] m7_be = 0;
reg        m7_rd = 0, m7_wr = 0;
wire       m7_ready;
wire [31:0] m7_rdata;

// ---- cart bridge model
wire        cart_req, win_valid;
wire [25:0] cart_addr;
wire [15:0] win_data;

// ---- SDRAM path
wire        bus_ram_req, bus_ram_wr, bus_ram_done;
wire [24:0] bus_ram_addr;
wire [15:0] bus_ram_wdata;
wire  [1:0] bus_ram_be;
wire        arb_req, arb_wr;
wire [24:0] arb_addr;
wire [15:0] arb_wdata;
wire  [1:0] arb_be;
wire        arb_rd_done, arb_wr_done;
wire [15:0] arb_rdata;

// ---- cheat
reg         f2_wr = 0;
reg   [7:0] f2_dout = 0;
wire        cheat_chk_en, cheat_hit;
wire [31:0] cheat_chk_addr, cheat_chk_word;
wire [15:0] cheat_patch, cheat_patch_hi;
wire        cheat_patch_hi_en;

main_bus dut (
	.clk(clk), .reset(reset),
	.ds_keys(ds_keys),
	.touch_x(9'd0), .touch_y(8'd0), .touch_down(1'b0), .mic_in(1'b0),
	.m9_addr(m9_addr), .m9_wdata(m9_wdata), .m9_be(m9_be),
	.m9_rd(m9_rd), .m9_wr(m9_wr), .m9_ready(m9_ready), .m9_rdata(m9_rdata),
	.m7_addr(m7_addr), .m7_wdata(m7_wdata), .m7_be(m7_be),
	.m7_rd(m7_rd), .m7_wr(m7_wr), .m7_ready(m7_ready), .m7_rdata(m7_rdata),
	.cart_req(cart_req), .cart_addr(cart_addr),
	.cart_valid(win_valid), .cart_rdata(win_data),
	.ram_req(bus_ram_req), .ram_wr(bus_ram_wr), .ram_addr(bus_ram_addr),
	.ram_wdata(bus_ram_wdata), .ram_be(bus_ram_be),
	.ram_done(bus_ram_done), .ram_rdata(arb_rdata),
	.vramcnt_we(), .vramcnt_addr(), .vramcnt_data(),
	// M2 ports not exercised here: tie the DMA master and engine
	// consumers off (DMA fabric traffic is covered by tb_dma_engine;
	// VRAM by tb_vram_arbiter)
	.vram_valid(1'b0), .vram_rdata(16'd0),
	.dma_reg_rdata(16'd0),
	.d_addr(32'd0), .d_wdata(32'd0), .d_be(4'd0),
	.d_rd(1'b0), .d_wr(1'b0),
	.dma_irq(4'd0),
	.pal_ra_a(10'd0), .pal_ra_b(10'd0),
	.oam_ra_a(10'd0), .oam_ra_b(10'd0),
	.cheat_chk_en(cheat_chk_en), .cheat_chk_addr(cheat_chk_addr),
	.cheat_chk_word(cheat_chk_word), .cheat_patch(cheat_patch),
	.cheat_patch_hi_en(cheat_patch_hi_en), .cheat_patch_hi(cheat_patch_hi),
	.cheat_hit(cheat_hit),
	.dispcnt_a(), .dispcnt_b(), .irq_master_enable(),
	.irq_enable(), .irq_flags()
);

mem_arbiter arbiter (
	.clk(clk), .reset(reset),
	.bus_req(bus_ram_req), .bus_wr(bus_ram_wr), .bus_addr(bus_ram_addr),
	.bus_wdata(bus_ram_wdata), .bus_be(bus_ram_be), .bus_ready(bus_ram_done),
	.save_req(1'b0), .save_wr(1'b0), .save_addr(25'd0),
	.save_wdata(16'd0),	.save_be(2'b00), .save_ready(),
	.vram_req(1'b0), .vram_wr(1'b0), .vram_addr(25'd0),
	.vram_wdata(16'd0), .vram_be(2'b00), .vram_ready(),
	.sdram_req(arb_req), .sdram_wr(arb_wr), .sdram_addr(arb_addr),
	.sdram_wdata(arb_wdata), .sdram_be(arb_be),
	.sdram_rd_done(arb_rd_done), .sdram_wr_done(arb_wr_done),
	.sdram_rdata(arb_rdata)
);

//------------------------------------------------------------------
// behavioural SDRAM: one-cycle accept, byte-masked writes
//------------------------------------------------------------------
reg [15:0] ram [0:1023];
reg [15:0] sd_dout = 0;
reg sd_rd_done = 0, sd_wr_done = 0;
always @(posedge clk) begin : sdram_model
	reg [15:0] t;
	sd_rd_done <= 0;
	sd_wr_done <= 0;
	if (arb_req && !arb_wr) begin
		sd_dout   <= ram[arb_addr[9:0]];
		sd_rd_done <= 1;
	end else if (arb_req && arb_wr) begin
		t = ram[arb_addr[9:0]];
		if (arb_be[0]) t[7:0]  = arb_wdata[7:0];
		if (arb_be[1]) t[15:8] = arb_wdata[15:8];
		ram[arb_addr[9:0]] <= t;
		sd_wr_done <= 1;
	end
end
assign arb_rdata = sd_dout;
assign arb_rd_done = sd_rd_done;
assign arb_wr_done = sd_wr_done;

//------------------------------------------------------------------
// cart bridge model: pulse accepted, one-cycle response
//------------------------------------------------------------------
reg [15:0] rom [0:255];
reg        br_valid = 0;
reg [15:0] br_data = 0;
always @(posedge clk) begin
	br_valid <= 0;
	if (cart_req) begin
		br_data   <= rom[cart_addr[9:1]];
		br_valid  <= 1;
	end
end
assign win_valid = br_valid;
assign win_data  = br_data;

//------------------------------------------------------------------
// cheat engine
//------------------------------------------------------------------
wire hit_dummy, hi_en_dummy;
wire [15:0] patch_dummy, patch_hi_dummy;

cheat_engine cheat (
	.clk(clk), .reset(reset),
	.f2_wr(f2_wr), .f2_dout(f2_dout),
	.clr_cheats(1'b0),
	.chk_en(cheat_chk_en), .chk_addr(cheat_chk_addr),
	.chk_word(cheat_chk_word),
	.hit(cheat_hit), .patch(cheat_patch),
	.patch_hi_en(cheat_patch_hi_en), .patch_hi(cheat_patch_hi)
);

//------------------------------------------------------------------
// tasks
//------------------------------------------------------------------
integer errors = 0;
task check;
	input [8*44:1] name;
	input cond;
	begin
		if (!cond) begin
			$display("FAIL %0s", name);
			errors = errors + 1;
		end else
			$display("ok   %0s", name);
	end
endtask

task m9_write;
	input [31:0] a;
	input [31:0] d;
	input  [3:0] be;
	begin
		@(posedge clk);
		m9_addr <= a; m9_wdata <= d; m9_be <= be;
		m9_wr <= 1; m9_rd <= 0;
		@(posedge clk);
		while (!m9_ready) @(posedge clk);
		m9_wr <= 0;
		@(posedge clk);
	end
endtask

task m9_read;
	input  [31:0] a;
	output [31:0] d;
	begin
		@(posedge clk);
		m9_addr <= a; m9_be <= 4'hF;
		m9_rd <= 1; m9_wr <= 0;
		@(posedge clk);
		while (!m9_ready) @(posedge clk);
		d = m9_rdata;
		m9_rd <= 0;
		@(posedge clk);
	end
endtask

task m7_write;
	input [31:0] a;
	input [31:0] d;
	input  [3:0] be;
	begin
		@(posedge clk);
		m7_addr <= a; m7_wdata <= d; m7_be <= be;
		m7_wr <= 1; m7_rd <= 0;
		@(posedge clk);
		while (!m7_ready) @(posedge clk);
		m7_wr <= 0;
		@(posedge clk);
	end
endtask

task m7_read;
	input  [31:0] a;
	output [31:0] d;
	begin
		@(posedge clk);
		m7_addr <= a; m7_be <= 4'hF;
		m7_rd <= 1; m7_wr <= 0;
		@(posedge clk);
		while (!m7_ready) @(posedge clk);
		d = m7_rdata;
		m7_rd <= 0;
		@(posedge clk);
	end
endtask

task send_byte;
	input [7:0] b;
	begin
		@(posedge clk);
		f2_dout <= b;
		f2_wr   <= 1;
		@(posedge clk);
		f2_wr   <= 0;
	end
endtask

reg [31:0] r1, r2;
integer i;

initial begin
	for (i = 0; i < 256; i = i + 1) rom[i] = 16'h5000 + i[15:0];
	for (i = 0; i < 1024; i = i + 1) ram[i] = 16'h0000;

	repeat (5) @(posedge clk);
	reset = 0;
	repeat (2) @(posedge clk);

	// ---- cheat file: type0 write32 0x42 at 0x02000000
	send_byte("0"); send_byte("2"); send_byte("0"); send_byte("0");
	send_byte("0"); send_byte("0"); send_byte("0"); send_byte("0");
	send_byte(" ");
	send_byte("0"); send_byte("0"); send_byte("0"); send_byte("0");
	send_byte("0"); send_byte("0"); send_byte("4"); send_byte("2");
	send_byte("\n");
	repeat (10) @(posedge clk);

	// ---- shared WRAM: word rw
	m9_write(32'h0300_0010, 32'hDEAD_BEEF, 4'hF);
	m9_read (32'h0300_0010, r1);
	check("WRAM word rw", r1 === 32'hDEAD_BEEF);

	// ---- byte enable into WRAM (high byte only)
	m9_write(32'h0300_0010, 32'h0000_AA00, 4'b0010);
	m9_read (32'h0300_0010, r1);
	check("WRAM byte enable", r1 === 32'hDEAD_AAEF);

	// ---- KEYINPUT: active low per GBATEK (0 = Pressed)
	ds_keys = 12'hAAA;               // bits 0,2,4,... pressed
	m9_read (32'h0400_0130, r1);
	check("KEYINPUT {4'hF, ~keys}", r1 === 32'h0000_F555);

	// ---- IO: DISPCNT write/readback
	m9_write(32'h0400_0000, 32'h0000_1011, 4'hF);
	m9_read (32'h0400_0000, r1);
	check("DISPCNT_A rw", r1 === 32'h0000_1011);

	// ---- palette: 32-bit write fills both halfwords
	m9_write(32'h0500_0000, 32'hAAAA_BBBB, 4'hF);
	m9_read (32'h0500_0000, r1);
	check("palette 32-bit rw", r1 === 32'hAAAA_BBBB);

	// 16-bit odd-halfword write: lanes in [31:16] hit pal[1] only
	m9_write(32'h0500_0002, 32'hCCCC_0000, 4'b1100);
	m9_read (32'h0500_0000, r1);
	check("palette 16-bit odd", r1 === 32'hCCCC_BBBB);

	// 16-bit even-halfword write must NOT clobber pal[1]
	m9_write(32'h0500_0000, 32'h0000_DDDD, 4'b0011);
	m9_read (32'h0500_0000, r1);
	check("palette 16-bit even keeps neighbour", r1 === 32'hCCCC_DDDD);

	// ---- main RAM: 32-bit word through arbiter (two halves)
	m9_write(32'h0200_0004, 32'h7777_8888, 4'hF);
	m9_read (32'h0200_0004, r1);
	check("RAM 32-bit rw", r1 === 32'h7777_8888);

	// ---- RAM byte enable: partial store keeps neighbours
	m9_write(32'h0200_0008, 32'h1234_5678, 4'hF);
	m9_write(32'h0200_0008, 32'h0000_00EE, 4'b0001);
	m9_read (32'h0200_0008, r1);
	check("RAM byte enable masking", r1 === 32'h1234_56EE);

	// ---- cheat end-to-end: stored value replaced on read
	m9_write(32'h0200_0000, 32'hAAAA_5555, 4'hF);
	m9_read (32'h0200_0000, r1);
	check("cheat patch on read (both halves)", r1 === 32'h0000_0042);
	m9_read (32'h0200_0004, r1);
	check("neighbour address unpatched", r1 === 32'h7777_8888);

	// ---- cart window: 32-bit assembly of two halfwords
	m9_read (32'h0800_0004, r1);
	check("cart window {h1,h0}", r1 === {16'h5003, 16'h5002});
	m9_read (32'h0800_0000, r1);
	check("cart window line 0", r1 === {16'h5001, 16'h5000});

	// ---- ARM7 master: private WRAM + concurrent traffic with ARM9
	m7_write(32'h0380_0004, 32'h0BAD_F00D, 4'hF);
	m7_read (32'h0380_0004, r1);
	check("ARM7 WRAM rw", r1 === 32'h0BAD_F00D);

	m9_write(32'h0300_0020, 32'hCAFE_BABE, 4'hF);
	m7_write(32'h0300_0040, 32'h1357_9BDF, 4'hF);
	fork
		m9_read(32'h0300_0020, r1);
		m7_read(32'h0300_0040, r2);
	join
	check("concurrent ARM9 read", r1 === 32'hCAFE_BABE);
	check("concurrent ARM7 read", r2 === 32'h1357_9BDF);

	if (errors == 0) $display("tb_main_bus: PASS");
	else             $display("tb_main_bus: FAIL (%0d errors)", errors);
	$finish;
end

initial begin
	#10_000_000;
	$display("tb_main_bus: FAIL — timeout");
	$display("dbg state=%0d m9_act=%b m7_act=%b d_act=%b blk9=%b need_b=%b is_rd=%b ram_req=%b ram_done=%b m9_wr=%b",
	         dut.state, dut.m9_active, dut.m7_active, dut.d_active,
	         dut.m9_block, dut.need_b, dut.is_read, bus_ram_req,
	         bus_ram_done, m9_wr);
	$finish;
end

endmodule
