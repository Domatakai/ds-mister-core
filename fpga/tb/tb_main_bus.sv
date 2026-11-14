//============================================================================
// NDS MiSTer Test — main bus testbench
//
//   iverilog -g2012 -o /tmp/tb_bus tb/tb_main_bus.sv \
//            rtl/bus/main_bus.sv rtl/mem/mem_arbiter.sv \
//            rtl/cart/cheat_engine.sv && vvp /tmp/tb_bus
//
// End-to-end fabric check: both CPU masters against private regions
// (WRAM BRAM, IO registers incl. KEYINPUT and the ARM7-only EXTKEYIN),
// shared main RAM through
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
reg         ram_exp = 1'b0;      // OSD row: Slot-2 RAM expansion pak
reg         rumble_pak = 1'b0;   // OSD row: Slot-2 rumble pak
reg         motion_pak = 1'b0;   // OSD row: Slot-2 motion pak
reg  [15:0] stick_l = 16'h0000;  // left stick, centred
reg  [15:0] stick_r = 16'h0000;  // right stick, centred
wire        rumble_lvl;
reg        hinge = 1'b0;
reg  [2:0] lang = 3'd0;

// ---- MIDI / AUX SPI port
wire        midi_wr, midi_rd;
wire [15:0] midi_addr, midi_wdata, midi_rdata;
wire        midi_tx, midi_busy;
reg         midi_rx = 1;

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
wire        cheat_chk_en, cheat_hit, cheat_ready;
wire [31:0] cheat_chk_addr, cheat_chk_word;
wire [15:0] cheat_patch, cheat_patch_hi;
wire        cheat_patch_hi_en;

// 3D window (M3): the bus forwards command/matrix writes and returns the
// engine's status word on reads of the GX block.
wire        gx_we;
wire [9:0]  gx_addr;
wire [31:0] gx_data;
reg  [31:0] gx_rdata = 32'h0100_0000;
reg         gx_hit = 0;
reg  [9:0]  gx_seen_addr = 10'd0;
reg  [31:0] gx_seen_data = 32'd0;

always @(posedge clk) begin
	if (gx_we) begin
		gx_hit       <= 1;
		gx_seen_addr <= gx_addr;
		gx_seen_data <= gx_data;
	end
end

// SPU register window (M4): ARM7-only, 0x04000400..0x0400051F.  The bus
// forwards halfword beats; the model holds the last one written so a read
// round-trips through the real decode.
wire        spu_acc, spu_we;
wire [15:0] spu_addr, spu_wdata;
reg  [15:0] spu_rdata = 16'h0000;
reg         spu_hit = 0;
reg  [15:0] spu_seen_addr = 16'd0, spu_seen_data = 16'd0;

always @(posedge clk) begin
	if (spu_we) begin
		spu_hit       <= 1;
		spu_seen_addr <= spu_addr;
		spu_seen_data <= spu_wdata;
		spu_rdata     <= spu_wdata;
	end
end

main_bus dut (
	.clk(clk), .reset(reset),
	// timers are not under test here; the ARM7's enable held high makes them
	// advance on every clock, which is the pre-retiming behaviour
	.ce7(1'b1), .ram_exp(ram_exp),
	.rumble_pak(rumble_pak), .rumble_lvl(rumble_lvl),
	.motion_pak(motion_pak), .stick_l(stick_l), .stick_r(stick_r),
	.ds_keys(ds_keys), .lang(lang), .hinge_closed(hinge),
	.touch_x(9'd0), .touch_y(8'd0), .touch_down(1'b0), .mic_in(12'h400),
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
	.gx_we(gx_we), .gx_addr(gx_addr), .gx_data(gx_data), .gx_rdata(gx_rdata),
	.cheat_hit(cheat_hit), .cheat_ready(cheat_ready),
	.midi_wr(midi_wr), .midi_rd(midi_rd),
	.midi_addr(midi_addr), .midi_wdata(midi_wdata), .midi_rdata(midi_rdata),
	.spu_acc(spu_acc), .spu_we(spu_we), .spu_addr(spu_addr),
	.spu_wdata(spu_wdata), .spu_rdata(spu_rdata),
	.dispcnt_a(), .dispcnt_b(), .irq_master_enable(),
	.irq_enable(), .irq_flags()
);

//------------------------------------------------------------------
// MIDI / AUX SPI port (0x04000150..0x0400015A)
//
// tick_48k is tied high, so a MIDI bit is 1536 clocks and a frame is 15 360
// — short enough for this bench to watch one byte leave and one arrive.
//------------------------------------------------------------------
midi_port midi (
	.clk(clk), .reset(reset), .tick_48k(1'b1),
	.wr(midi_wr), .rd(midi_rd),
	.addr(midi_addr), .wdata(midi_wdata), .rdata(midi_rdata),
	.tx(midi_tx), .tx_busy(midi_busy), .rx(midi_rx),
	.demo_en(1'b0), .demo_restart(1'b0)
);

task midi_rx_byte;
	input [7:0] b;
	integer k;
	begin
		midi_rx = 0;
		repeat (1536) @(posedge clk);
		for (k = 0; k < 8; k = k + 1) begin
			midi_rx = b[k];
			repeat (1536) @(posedge clk);
		end
		midi_rx = 1;
		repeat (1536) @(posedge clk);
	end
endtask

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
// The index carries SDRAM bits 23:22, so the expansion pak region
// (0xA00000) and main RAM (0x200000) cannot alias inside this small model.
wire [11:0] m_idx = {arb_addr[23], arb_addr[22], arb_addr[9:0]};
reg [15:0] ram [0:4095];
reg [15:0] sd_dout = 0;
reg sd_rd_done = 0, sd_wr_done = 0;
always @(posedge clk) begin : sdram_model
	reg [15:0] t;
	sd_rd_done <= 0;
	sd_wr_done <= 0;
	if (arb_req && !arb_wr) begin
		sd_dout   <= ram[m_idx];
		sd_rd_done <= 1;
	end else if (arb_req && arb_wr) begin
		t = ram[m_idx];
		if (arb_be[0]) t[7:0]  = arb_wdata[7:0];
		if (arb_be[1]) t[15:8] = arb_wdata[15:8];
		ram[m_idx] <= t;
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
	.patch_hi_en(cheat_patch_hi_en), .patch_hi(cheat_patch_hi),
	.chk_ready(cheat_ready)
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

task m9_read8;
	input  [31:0] a;
	output  [7:0] d;
	begin
		@(posedge clk);
		m9_addr <= a; m9_be <= 4'b0001;
		m9_rd <= 1; m9_wr <= 0;
		@(posedge clk);
		while (!m9_ready) @(posedge clk);
		d = m9_rdata[7:0];
		m9_rd <= 0;
		@(posedge clk);
	end
endtask

task m9_read16;
	input  [31:0] a;
	output [15:0] d;
	begin
		@(posedge clk);
		m9_addr <= a; m9_be <= 4'b0011;
		m9_rd <= 1; m9_wr <= 0;
		@(posedge clk);
		while (!m9_ready) @(posedge clk);
		d = m9_rdata[15:0];
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
reg  [7:0] b1;
reg [15:0] h1;
integer i;

initial begin
	for (i = 0; i < 256; i = i + 1) rom[i] = 16'h5000 + i[15:0];
	for (i = 0; i < 4096; i = i + 1) ram[i] = 16'h0000;

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

	// ---- EXTKEYIN (0x04000136): the hinge, and ARM7-only
	ds_keys = 12'hFFF;               // everything released
	hinge = 1'b1;
	repeat (2) @(posedge clk);
	m7_read (32'h0400_0136, r1);
	check("EXTKEYIN hinge closed (ARM7)", r1 === 32'h0000_00FF);
	hinge = 1'b0;
	repeat (2) @(posedge clk);
	m7_read (32'h0400_0136, r1);
	check("EXTKEYIN hinge open, pen released", r1 === 32'h0000_007F);
	ds_keys = 12'hBFF;               // X held down: bit 0 is the same button
	hinge = 1'b1;
	repeat (2) @(posedge clk);
	m7_read (32'h0400_0136, r1);
	check("EXTKEYIN mirrors X", r1 === 32'h0000_00FE);
	hinge = 1'b0;
	ds_keys = 12'hFFF;
	repeat (2) @(posedge clk);
	m9_read (32'h0400_0136, r1);
	check("EXTKEYIN is ARM7-only", r1 === 32'h0000_0000);
	// ---- hinge IRQ 22 (GBATEK DS Keypad): edge triggered, ARM7 side
	m7_write(32'h0400_0212, 32'h0000_0040, 4'hF);   // IE7 bit 22
	m7_write(32'h0400_0208, 32'h0000_0001, 4'hF);   // IME7
	m7_write(32'h0400_0216, 32'h0000_0040, 4'hF);   // drop a pending bit 22
	// let the acknowledgement retire before the edge: a write-1-to-clear that
	// lands after a new edge is *meant* to clear it, so the settle is part of
	// the test being realistic, not a workaround for the interrupt
	repeat (8) @(posedge clk);
	hinge = 1'b1;                                   // lid closes
	repeat (3) @(posedge clk);
	m7_read (32'h0400_0216, r1);
	check("hinge IRQ 22 fires when the lid closes", r1 === 32'h0000_0040);
	m7_write(32'h0400_0216, 32'h0000_0040, 4'hF);   // acknowledge it
	repeat (4) @(posedge clk);
	m7_read (32'h0400_0216, r1);
	check("hinge IRQ 22 is an edge, not a level", r1 === 32'h0000_0000);
	hinge = 1'b0;                                   // lid opens
	repeat (3) @(posedge clk);
	m7_read (32'h0400_0216, r1);
	check("hinge IRQ 22 fires when the lid opens", r1 === 32'h0000_0040);
	m7_write(32'h0400_0216, 32'h0000_0040, 4'hF);   // acknowledge it
	repeat (2) @(posedge clk);

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

	// ---- Slot-2 RAM expansion pak: 8 MB at 0x09000000..0x097FFFFF ----
	// with the OSD row off the window does not decode at all, which is what
	// a DS with an empty slot sees, and writes go nowhere
	m9_read (32'h0900_0000, r1);
	check("RAM expansion window empty when off", r1 === 32'h0000_0000);
	m9_write(32'h0900_0000, 32'hFFFF_FFFF, 4'hF);
	m9_read (32'h0900_0000, r1);
	check("writes dropped while the row is off", r1 === 32'h0000_0000);

	ram_exp = 1'b1;
	repeat (2) @(posedge clk);
	m9_write(32'h0900_0000, 32'hC0DE_1234, 4'hF);
	m9_read (32'h0900_0000, r1);
	check("RAM expansion 32-bit rw", r1 === 32'hC0DE_1234);

	m9_write(32'h0900_0004, 32'hAABB_CCDD, 4'hF);
	m9_write(32'h0900_0004, 32'h0000_00EE, 4'b0001);
	m9_read (32'h0900_0004, r1);
	check("RAM expansion byte enable", r1 === 32'hAABB_CCEE);

	// the far end of the 8 MB window, and main RAM untouched by it
	m9_write(32'h097F_FFFC, 32'h5A5A_0F0F, 4'hF);
	m9_read (32'h097F_FFFC, r1);
	check("last word of the 8 MB window", r1 === 32'h5A5A_0F0F);
	m9_read (32'h0200_0004, r1);
	check("expansion leaves main RAM alone", r1 === 32'h7777_8888);
	m9_read (32'h097F_FFFC, r1);
	check("main RAM does not reach the expansion", r1 === 32'h5A5A_0F0F);

	// both CPUs see the same pak, as on hardware
	m7_read (32'h0900_0000, r2);
	check("ARM7 reads the expansion too", r2 === 32'hC0DE_1234);

	ram_exp = 1'b0;
	repeat (2) @(posedge clk);
	m9_read (32'h0900_0000, r1);
	check("the OSD row gates the window again", r1 === 32'h0000_0000);

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

	// ---- 3D window: command write, status read, matrix offset ----
	m9_write(32'h0400_0400, 32'h1234_5678, 4'hF);
	check("GX FIFO write forwarded", gx_hit && gx_seen_addr == 10'h000 &&
	                                gx_seen_data === 32'h1234_5678);

	m9_read (32'h0400_0600, r1);
	check("GXSTAT read passthrough", r1 === 32'h0100_0000);

	gx_hit = 0;
	m9_write(32'h0400_0510, 32'hCAFE_1234, 4'hF);
	check("GX matrix window offset", gx_hit && gx_seen_addr == 10'h110);

	// ---- AUX SPI / MIDI port: register decode through the real bus
	m9_write(32'h0400_0150, 32'h0000_0000, 4'hF);   // direction = write
	m9_read (32'h0400_0150, r1);
	check("AUXSPICNT rw", r1 === 32'h0000_0000);

	m9_write(32'h0400_0154, 32'h0000_0090, 4'hF);   // a status byte out
	repeat (8) @(posedge clk);
	check("AUXSPIDATA reaches the wire", midi_tx === 1'b0 || midi_busy === 1'b1);
	m9_read (32'h0400_0150, r1);
	check("AUXSPICNT busy while a byte shifts", r1[0] === 1'b1);

	// let the byte finish before using the line for receive checks
	repeat (1536 * 12) @(posedge clk);
	midi_rx_byte(8'h7E);
	repeat (4) @(posedge clk);
	m9_read (32'h0400_015A, r1);
	check("AUXSPIDATA returns the received byte", r1[7:0] === 8'h7E);

	// ---- SPU window: 0x04000400..0x0400051F, ARM7 only ----
	spu_hit = 0;
	m7_write(32'h0400_0404, 32'h0000_1234, 4'b0011);
	check("ARM7 write reaches the SPU window", spu_hit &&
	                                          spu_seen_addr === 16'h0404 &&
	                                          spu_seen_data === 16'h1234);

	spu_hit = 0;
	m7_write(32'h0400_051E, 32'h0000_5678, 4'b0011);  // top of the block
	check("the SPU block runs to 0x51F", spu_hit && spu_seen_addr === 16'h051E);

	m7_write(32'h0400_0500, 32'h0000_BEEF, 4'b0011);  // SOUNDCNT
	m7_read (32'h0400_0500, r1);
	check("SOUNDCNT reads back through the bus", r1 === 32'h0000_BEEF);

	spu_hit = 0;
	m7_write(32'h0400_0100, 32'h0000_0002, 4'b0011);  // a timer
	check("another ARM7 I/O register is not sound", !spu_hit);

	// from the ARM9 those addresses are the geometry engine, as on hardware
	spu_hit = 0;
	m9_write(32'h0400_0404, 32'h0000_0003, 4'b0011);
	check("the ARM9 sees the geometry window, not sound", !spu_hit);

	// ---- Slot-2 rumble pak: the cart-port latch at 0x08000000 ----
	// with the row off the window stays cart space and nothing rumbles
	rumble_pak = 1'b0;
	m9_read(32'h0800_0000, r1);
	check("row off: the pak is not in the cart window", rumble_lvl === 1'b0);

	rumble_pak = 1'b1;
	repeat (2) @(posedge clk);
	m9_read(32'h0800_0000, r1);
	check("rumble open bus at 0x08000000", r1 === 32'h0001_0000);
	m9_read(32'h0800_0010, r1);
	check("open bus follows the halfword index", r1 === 32'h0009_0008);
	m9_write(32'h0800_0000, 32'h0000_0002, 4'h3);
	repeat (2) @(posedge clk);
	check("writing AD1 = 1 turns the actuator on", rumble_lvl === 1'b1);
	m9_write(32'h0800_0000, 32'h0000_0000, 4'h3);
	repeat (2) @(posedge clk);
	check("writing AD1 = 0 turns it back off", rumble_lvl === 1'b0);
	m9_write(32'h0800_1000, 32'h0000_0002, 4'h3);
	repeat (2) @(posedge clk);
	check("0x08001000 is the same latch", rumble_lvl === 1'b1);
	rumble_pak = 1'b0;

	// ---- Slot-2 motion pak: the byte sequence on 0x0A000000 ----
	motion_pak = 1'b0;
	m9_read(32'h0A00_0000, r1);
	check("row off: 0x0A000000 stays open bus", r1 === 32'h0);

	motion_pak = 1'b1;
	stick_l = 16'h0000; stick_r = 16'h0000;   // both sticks centred
	repeat (2) @(posedge clk);
	m9_read(32'h0A00_0000, r1);
	check("the pack answers the detector with 0xFC00",
	      r1 === 32'hFC00_FC00);
	check("a word read does not advance the sequence",
	      dut.mot_cnt === 5'd0);

	// a halfword is a probe too, whichever half it lands in
	m9_read16(32'h0A00_0000, h1);
	check("a halfword read answers 0xFC00", h1 === 16'hFC00);
	m9_read16(32'h0A00_0002, h1);
	check("the upper halfword answers 0xFC00", h1 === 16'hFC00);
	check("neither halfword advanced the sequence",
	      dut.mot_cnt === 5'd0);

	m9_read8(32'h0A00_0000, b1);
	check("byte 0 of the poll is 0x00", b1 === 8'h00);
	begin : poll
		integer i;
		for (i = 0; i < 4; i = i + 1) begin
			m9_read8(32'h0A00_0000, b1);
			check("bytes 1..4 of the poll are 0x03", b1 === 8'h03);
		end
	end

	// X and Y from the left stick, Z from the right one's Y: +127 /
	// -128 / -28 become 0xFF / 0x00 / 0x64 (the pack reads level as
	// 0x80), two bits per read from the most significant pair
	stick_l = {8'h00, 8'h7F};
	stick_r = {8'hE4, 8'h80};
	repeat (2) @(posedge clk);
	begin : axes
		integer i;
		for (i = 0; i < 4; i = i + 1) begin
			m9_read8(32'h0A00_0000, b1);
			check("X reads 0xFF as four 0x03 chunks", b1 === 8'h03);
		end
		m9_read8(32'h0A00_0000, b1);
		check("Y reads 0x80 top pair first", b1 === 8'h02);
		for (i = 0; i < 3; i = i + 1) begin
			m9_read8(32'h0A00_0000, b1);
			check("Y reads 0x80 as 0x00 chunks", b1 === 8'h00);
		end
		m9_read8(32'h0A00_0000, b1);
		check("Z reads 0x64 top pair first", b1 === 8'h01);
		m9_read8(32'h0A00_0000, b1);
		check("Z reads 0x64 second pair", b1 === 8'h02);
		m9_read8(32'h0A00_0000, b1);
		check("Z reads 0x64 third pair", b1 === 8'h01);
		m9_read8(32'h0A00_0000, b1);
		check("Z reads 0x64 low pair", b1 === 8'h00);
	end
	m9_read8(32'h0A00_0000, b1);
	check("the sequence wraps back to 0x00", b1 === 8'h00);

	// the deadzone: 3 of 127 is inside it, so X reads 0x80 (level)
	stick_l = {8'h08, 8'h03};
	repeat (2) @(posedge clk);
	// resync: the counter is wherever the previous check left it, and
	// a 0x00 axis chunk does not mark the start, so walk it to step 0
	begin : sync
		while (dut.mot_cnt !== 5'd0) m9_read8(32'h0A00_0000, b1);
		m9_read8(32'h0A00_0000, b1);
		check("the sequence restarts on 0x00", b1 === 8'h00);
	end
	begin : dz
		integer i;
		for (i = 0; i < 4; i = i + 1) begin
			m9_read8(32'h0A00_0000, b1);
			check("deadzone: the poll still reads 0x03", b1 === 8'h03);
		end
	end
	m9_read8(32'h0A00_0000, b1);
	check("a stick inside the deadzone reads 0x80", b1 === 8'h02);

	// and the same on the negative side: -3 is inside it too
	stick_l = {8'h00, 8'hFD};
	repeat (2) @(posedge clk);
	while (dut.mot_cnt !== 5'd0) m9_read8(32'h0A00_0000, b1);
	m9_read8(32'h0A00_0000, b1);
	begin : dzneg
		integer i;
		for (i = 0; i < 4; i = i + 1) m9_read8(32'h0A00_0000, b1);
	end
	m9_read8(32'h0A00_0000, b1);
	check("-3 of 127 reads 0x80 too", b1 === 8'h02);

	// the guard: only the first 64 KB of the page answers
	m9_read(32'h0A01_0000, r1);
	check("above 64 KB the window is open bus", r1 === 32'h0);

	// the row is the device's power: off forgets the poll
	motion_pak = 1'b0;
	repeat (2) @(posedge clk);
	check("row off resets the sequence", dut.mot_cnt === 5'd0);

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
