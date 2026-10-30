//============================================================================
// NDS MiSTer Test — cart slot testbench
//
//   iverilog -g2012 -o /tmp/tb_cart tb/tb_cart_slot.sv \
//            rtl/cart/cart_slot.sv && vvp /tmp/tb_cart
//
// Drives a simulated .nds download into the line FIFO, models the DDRAM
// handshake with Avalon waitrequest semantics (a write/read is accepted
// only on a cycle with BUSY low), and verifies:
//   - packing of full 64-bit lines and the partial-line tail flush
//     (download size not a multiple of 8 bytes) with byte enables
//   - hold-until-accept: a strobe granted just before BUSY rises must
//     be held, never dropped (regression: a lost write wedged the drain)
//   - header byte 0x80 capacity detection, 32-bit (128 KB << 12 = 512 MB)
//   - CPU window reads, including a request whose accept cycle is
//     covered by BUSY (RD held until the controller takes it)
//   - the pending latch that keeps a request alive across DDR busy
//============================================================================
`timescale 1ns / 1ps

module tb_cart_slot;

reg clk = 0;
always #10 clk = ~clk; // 50 MHz

reg reset = 1;
reg ioctl_download = 0;
reg [26:0] ioctl_addr = 0;
reg [15:0] ioctl_dout = 0;
reg ioctl_wr = 0;
reg [15:0] ioctl_index = 1;

wire ioctl_wait;
wire [7:0] ddr_burstcnt;
wire [28:0] ddr_addr;
wire [63:0] ddr_din;
wire [7:0] ddr_be;
wire ddr_we, ddr_rd;
reg ddr_busy = 0;
reg ddr_dout_ready = 0;
reg [63:0] ddr_dout = 0;

reg win_req = 0;
reg [25:0] win_addr = 0;
wire win_valid;
wire [15:0] win_data;

reg erase_save = 0;
reg [2:0] save_type = 0;
wire save_req, save_wr;
wire [24:0] save_addr;
wire [15:0] save_din;
wire cart_loaded;
wire [31:0] rom_bytes;

// game slots
reg  [1:0] boot_slot = 2'd0;
reg        slot_clear = 0;
reg  [1:0] hdr_slot = 0;
reg  [3:0] hdr_char = 0;
wire [3:0] slot_valid;
wire [1:0] load_slot;
wire [31:0] slot_caps;
wire [15:0] slot_save;
wire [15:0] slot_save_det;
wire [7:0] hdr_data;
wire [31:0] slot9_entry, slot7_entry;

// the boot entry points the header carries (0x24 ARM9, 0x34 ARM7)
reg  [31:0] entry9_val = 32'h0200_0800;
reg  [31:0] entry7_val = 32'h0238_0000;

// address the controller was given on the last accepted READ
reg [28:0] rd_addr_seen = 0;
always @(posedge clk) if (ddr_rd && !ddr_busy) rd_addr_seen <= ddr_addr;

cart_slot dut (
	.clk(clk), .reset(reset),
	.ioctl_download(ioctl_download), .ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout), .ioctl_wr(ioctl_wr),
	.ioctl_index(ioctl_index), .ioctl_wait(ioctl_wait),
	.ddr_burstcnt(ddr_burstcnt), .ddr_addr(ddr_addr), .ddr_din(ddr_din),
	.ddr_be(ddr_be), .ddr_we(ddr_we), .ddr_rd(ddr_rd),
	.ddr_busy(ddr_busy), .ddr_dout_ready(ddr_dout_ready), .ddr_dout(ddr_dout),
	.win_req(win_req), .win_addr(win_addr),
	.win_valid(win_valid), .win_data(win_data),
	.erase_save(erase_save), .save_type(save_type),
	.save_req(save_req), .save_wr(save_wr),
	.save_addr(save_addr), .save_din(save_din), .save_done(1'b0),
	.cart_loaded(cart_loaded), .rom_bytes(rom_bytes),
	.boot_slot(boot_slot), .load_slot(load_slot), .slot_valid(slot_valid),
	.slot_clear(slot_clear),
	.hdr_slot(hdr_slot), .hdr_char(hdr_char), .hdr_data(hdr_data),
	.slot_caps(slot_caps), .slot_save(slot_save),
	.slot9_entry(slot9_entry), .slot7_entry(slot7_entry),
	.slot_save_det(slot_save_det)
);

//------------------------------------------------------------------
// behavioral DDR3: accepts strobes only on cycles with !busy
// (Avalon waitrequest), returns lines on read; captures byte enables
//------------------------------------------------------------------
reg [63:0] mem [0:255];
reg  [7:0] mem_be [0:255];
integer wr_beats = 0;
reg     seen_wr = 0;
reg [28:0] first_wr = 0;
always @(posedge clk) begin
	if (ddr_we && !ddr_busy) begin
		mem[ddr_addr[7:0]]    <= ddr_din;
		mem_be[ddr_addr[7:0]] <= ddr_be;
		wr_beats = wr_beats + 1;
		if (!seen_wr) begin
			first_wr <= ddr_addr;
			seen_wr  <= 1;
		end
	end
	ddr_dout_ready <= 0;
	if (ddr_rd && !ddr_busy) begin
		ddr_dout <= mem[ddr_addr[7:0]];
		ddr_dout_ready <= 1;
	end
end

// the probe walks the valid slots, so let it finish before reading back
integer wd;
task wait_det;
	input [1:0] s;
	input [2:0] want;
	begin
		wd = 0;
		while (slot_save_det[{s, 2'b00} +: 4] !== {1'b0, want} && wd < 40000) begin
			@(posedge clk);
			wd = wd + 1;
		end
	end
endtask

integer errors = 0;
task check;
	input [8*40:1] name;
	input cond;
	begin
		if (!cond) begin
			$display("FAIL %0s", name);
			errors = errors + 1;
		end else begin
			$display("ok   %0s", name);
		end
	end
endtask

task send_word;
	input [26:0] a;
	input [15:0] d;
	begin
		@(posedge clk);
		ioctl_addr <= a;
		ioctl_dout <= d;
		ioctl_wr   <= 1;
		@(posedge clk);
		ioctl_wr   <= 0;
	end
endtask

// one-cycle request pulse, then wait for the response
reg [15:0] got;
task win_read;
	input [25:0] a;
	begin
		@(posedge clk);
		win_addr <= a;
		win_req  <= 1;
		@(posedge clk);
		win_req  <= 0;
		wait (win_valid);
		got = win_data;
		@(posedge clk);
	end
endtask

//------------------------------------------------------------------
// game slots: a ROM whose header carries the title in tdat[]
//------------------------------------------------------------------
reg [7:0] tdat [0:11];
reg [7:0] cdat [0:3];    // 0x0C..0x0F: the game code
integer   title_err = 0;

task set_title;
	input [8*12-1:0] s;
	integer k;
	begin
		for (k = 0; k < 12; k = k + 1) tdat[k] = s[8*(11-k) +: 8];
	end
endtask

task set_code;
	input [8*4-1:0] s;
	integer k;
	begin
		for (k = 0; k < 4; k = k + 1) cdat[k] = s[8*(3-k) +: 8];
	end
endtask

// header byte k: 0x00..0x0B from the title, 0x0C..0x0F from the code
function [7:0] hbyte;
	input integer k;
	begin
		hbyte = (k < 12) ? tdat[k] : cdat[k-12];
	end
endfunction

task load_rom;
	input [7:0] cap;      // header byte 0x80: 128 KB << cap
	integer w;
	begin
		@(posedge clk); ioctl_download <= 1;
		// eight words = the 16 header bytes (title + game code), then payload
		for (w = 0; w < 8; w = w + 1)
			send_word(w * 2, {hbyte(2*w+1), hbyte(2*w)});
		for (w = 8; w < 14; w = w + 1)
			send_word(w * 2, 16'hA000 + w[15:0]);
		// the declared size sits far past the header block; 0xFF means the
		// file has no such byte, which must read back as unknown, not zero
		if (cap != 8'hFF) send_word(27'h80, {8'h00, cap});
		// header 0x24 / 0x34: the ARM9 and ARM7 entry points, two halfwords each
		send_word(27'h24, entry9_val[15:0]);
		send_word(27'h26, entry9_val[31:16]);
		send_word(27'h34, entry7_val[15:0]);
		send_word(27'h36, entry7_val[31:16]);
		@(posedge clk); ioctl_download <= 0;
		repeat (80) @(posedge clk);
		if (load_slot == boot_slot) begin
			check("ARM9 entry latched from header 0x24", slot9_entry === entry9_val);
			check("ARM7 entry latched from header 0x34", slot7_entry === entry7_val);
		end
	end
endtask

// read a slot's 16 header bytes back through the header port
task check_hdr;
	input [1:0] s;
	integer k;
	reg [7:0] want;
	begin
		hdr_slot = s;
		for (k = 0; k < 16; k = k + 1) begin
			want = hbyte(k);
			hdr_char = k[3:0];
			@(posedge clk);
			if (hdr_data !== want) begin
				$display("  slot %0d char %0d: %02x, expected %02x",
				         s, k, hdr_data, want);
				title_err = title_err + 1;
			end
		end
	end
endtask

integer i;
initial begin
	for (i = 0; i < 256; i = i + 1) begin
		mem[i] = 64'd0;
		mem_be[i] = 8'd0;
	end

	repeat (5) @(posedge clk);
	reset = 0;
	repeat (2) @(posedge clk);

	// --- download with BUSY covering the drain window except one cycle:
	//     the grant lands on the free cycle and the accept cycle is
	//     busy — the strobe must be HELD, not dropped.
	@(posedge clk); ioctl_download <= 1;
	ddr_busy = 1;
	for (i = 0; i < 4; i = i + 1) send_word(i * 2, 16'h1000 + i[15:0]);
	repeat (2) @(posedge clk);
	@(posedge clk); ddr_busy <= 0;  // one cycle visible-low: grant lands here
	@(posedge clk); ddr_busy <= 1;  // accept cycle is busy: must be held
	repeat (4) @(posedge clk);
	@(posedge clk); ddr_busy <= 0;

	// second line + header word (byte 0x80 -> capacity 8 = 256 Mbit)
	for (i = 4; i < 8; i = i + 1) send_word(i * 2, 16'h1000 + i[15:0]);
	send_word(27'h80, 16'h0008); // 128 KB << 8 = 32 MB = 256 Mbit
	@(posedge clk); ioctl_download <= 0;
	repeat (400) @(posedge clk);

	check("download -> 3 DDR lines (2 full + tail)", wr_beats == 3);
	check("line 0 packing {w3,w2,w1,w0}",
		mem[0] === {16'h1003, 16'h1002, 16'h1001, 16'h1000});
	check("line 1 packing {w7,w6,w5,w4}",
		mem[1] === {16'h1007, 16'h1006, 16'h1005, 16'h1004});
	check("full lines carry BE=FF", mem_be[0] === 8'hFF && mem_be[1] === 8'hFF);
	check("tail line flush {0,header word}",
		mem[2] === {48'd0, 16'h0008});
	check("tail line BE=03 (one word)", mem_be[2] === 8'h03);
	check("cart loaded", cart_loaded === 1'b1);
	check("256 Mbit capacity detected", rom_bytes == 32'd33554432);

	// --- window read: byte 4 -> line0 halfword2 = 0x1002
	win_read(26'd4);
	check("window byte 4 -> 0x1002", got === 16'h1002);

	// --- window read: byte 8 -> line1 halfword0 = 0x1004
	repeat (4) @(posedge clk);
	win_read(26'd8);
	check("window byte 8 -> 0x1004", got === 16'h1004);

	// --- busy backpressure: request arrives while DDR is busy; the
	//     pending latch must carry it through and answer correctly.
	repeat (4) @(posedge clk);
	ddr_busy = 1;
	@(posedge clk);
	win_addr <= 26'd0;
	win_req  <= 1;
	@(posedge clk);
	win_req  <= 0;
	repeat (8) @(posedge clk);
	ddr_busy = 0;
	wait (win_valid);
	check("pending request survives DDR busy", win_data === 16'h1000);
	@(posedge clk);

	// --- post-grant BUSY: RD is granted with BUSY low, then BUSY
	//     covers the accept cycle — RD must be held, not dropped.
	repeat (4) @(posedge clk);
	@(posedge clk);
	win_addr <= 26'd4;
	win_req  <= 1;
	@(posedge clk);        // FSM grants here (ddr_rd goes high)
	win_req  <= 0;
	ddr_busy <= 1;         // accept cycle is busy: must be held
	repeat (3) @(posedge clk);
	@(posedge clk); ddr_busy <= 0;
	wait (win_valid);
	check("RD held across post-grant BUSY", win_data === 16'h1002);
	@(posedge clk);

	// --- save master stays idle until M4
	repeat (4) @(posedge clk);
	check("save master idle", save_req === 1'b0 && save_wr === 1'b0);

	// --- second load: capacity byte 0x80 = 12 -> 128 KB << 12 = 512 MB.
	//     A 28-bit rom_bytes would truncate this to 0 (regression).
	@(posedge clk); ioctl_download <= 1;
	send_word(27'h80, 16'h000C);
	@(posedge clk); ioctl_download <= 0;
	repeat (100) @(posedge clk);
	check("reload sets cart_loaded", cart_loaded === 1'b1);
	check("512 MB capacity detected (32-bit)", rom_bytes == 32'd536870912);

	// ------------------------------------------------ game slots
	// Each download lands in its own 64 MB region, its title is taken from
	// the ROM header, and the cart window follows boot_slot. The slot list
	// deliberately survives a core reset, since booting a game resets the
	// core and the menu must still be able to offer the others.
	slot_clear = 1;
	repeat (3) @(negedge clk);
	slot_clear = 0;
	repeat (4) @(posedge clk);
	check("clear forgets every slot", slot_valid === 4'd0);
	check("next load goes to slot 0", load_slot === 2'd0);

	save_type = 3'd3;               // FLASH 512K for the game being loaded
	set_title("FIRST GAME  ");
	set_code("AMCE");
	seen_wr = 0;
	load_rom(8'd8);                  // 32 MB
	check("first game fills slot 0", slot_valid === 4'b0001);
	check("slot 0 download starts at line 0", first_wr === 29'd0);
	title_err = 0; check_hdr(2'd0);
	check("slot 0 title + game code are read back", title_err == 0);
	check("slot 0 keeps its declared size", slot_caps[7:0] === 8'd8);
	check("slot 0 records its save type", slot_save[3:0] === 4'd3);
	wait_det(2'd0, 3'd3);
	check("the probe classifies slot 0's chip as FLASH 512K",
	      slot_save_det[3:0] === 4'd3);

	set_title("SECOND GAME ");
	set_code("AZEP");
	seen_wr = 0;
	load_rom(8'd20);                 // declares 2^20 KB: clamps to 512 MB
	check("second game fills slot 1", slot_valid === 4'b0011);
	check("slot 1 download is 64 MB higher",
	      first_wr === 29'd8388608);
	title_err = 0; check_hdr(2'd1);
	check("slot 1 title + game code are read back", title_err == 0);
	check("slot 1 size clamps to 512 MB", slot_caps[15:8] === 8'd12);
	check("slot 0 size is untouched by slot 1", slot_caps[7:0] === 8'd8);
	check("slot 1 records its own save type", slot_save[7:4] === 4'd3);
	wait_det(2'd1, 3'd3);
	check("the probe classifies slot 1's chip too", slot_save_det[7:4] === 4'd3);
	check("slot 0 save type is untouched by slot 1", slot_save[3:0] === 4'd3);

	// the OSD row describes the game in the active slot, so it edits that
	// record alone: slot 0 changes, slot 1 keeps what it was given
	save_type = 3'd5;               // FRAM
	repeat (4) @(posedge clk);
	check("the OSD row edits the active slot", slot_save[3:0] === 4'd5);
	wait_det(2'd0, 3'd5);
	check("the probe follows the record it was given", slot_save_det[3:0] === 4'd5);
	check("the other slot keeps its save type", slot_save[7:4] === 4'd3);

	set_title("FIRST GAME  ");
	set_code("AMCE");
	title_err = 0; check_hdr(2'd0);
	check("slot 0 keeps its own title", title_err == 0);

	// the cart window follows the chosen slot
	boot_slot = 2'd1;
	repeat (4) @(posedge clk);
	win_read(26'd0);
	check("window reads slot 1's region", rd_addr_seen === 29'd8388608);
	set_title("SECOND GAME ");
	check("slot 1 data comes back", got === {tdat[1], tdat[0]});

	// the OSD save-type row edits the game that is running, so slot 1
	// changes and slot 0 keeps what it was given
	save_type = 3'd6;
	repeat (4) @(posedge clk);
	check("editing the save type follows the active slot",
	      slot_save[7:4] === 4'd6);
	check("the previously active slot is left alone", slot_save[3:0] === 4'd5);

	boot_slot = 2'd0;
	repeat (4) @(posedge clk);
	win_read(26'd0);
	check("window reads slot 0 again", rd_addr_seen === 29'd0);

	// a core reset must not empty the slot list
	reset = 1; repeat (4) @(posedge clk); reset = 0;
	repeat (4) @(posedge clk);
	check("slots survive a core reset", slot_valid === 4'b0011);
	set_title("SECOND GAME ");
	set_code("AZEP");
	title_err = 0; check_hdr(2'd1);
	check("titles + codes survive a core reset", title_err == 0);
	check("declared sizes survive a core reset",
	      slot_caps[7:0] === 8'd8 && slot_caps[15:8] === 8'd12);
	check("save types survive a core reset",
	      slot_save[3:0] === 4'd5 && slot_save[7:4] === 4'd6);

	// a file that never presents byte 0x80 leaves the size unknown
	set_title("THIRD GAME  ");
	set_code("AYCE");
	load_rom(8'hFF);
	check("third game fills slot 2", slot_valid === 4'b0111);
	check("a file without 0x80 has no declared size", slot_caps[23:16] === 8'hFF);
	check("the third game records its save type", slot_save[11:8] === 4'd6);
	// NAND is not SPI backup memory: the chip answers nothing, so the probe
	// reports no save type for that slot instead of echoing the OSD row
	wait_det(2'd2, 3'd0);
	check("NAND reports no SPI save chip", slot_save_det[11:8] === 4'd0);

	// with all four slots full the next download overwrites one, so the type
	// detected for that slot described the game that just left: it must be
	// dropped and measured again, not carried over to the new one
	save_type = 3'd4;               // FLASH 1M
	set_title("FOURTH GAME ");
	set_code("AZWE");
	load_rom(8'd10);
	check("fourth game fills the last slot", slot_valid === 4'b1111);
	check("the fourth slot records its save type", slot_save[15:12] === 4'd4);

	set_title("FIFTH GAME  ");
	set_code("AVUE");
	load_rom(8'd10);
	check("a full cart overwrites a slot", slot_valid === 4'b1111);
	check("the overwritten slot takes the new record", slot_save[3:0] === 4'd4);
	wait_det(2'd0, 3'd4);
	check("the overwritten slot is probed again", slot_save_det[3:0] === 4'd4);

	// a clear that lands while a probe is running must not leave the probe
	// mid-transaction: the next game still gets classified
	save_type = 3'd5;               // FRAM
	set_title("SIXTH GAME  ");
	set_code("ARDE");
	load_rom(8'd10);
	repeat (30) @(posedge clk);     // the probe is a couple of hundred cycles
	slot_clear = 1;
	repeat (3) @(negedge clk);
	slot_clear = 0;
	repeat (4) @(posedge clk);
	set_title("SEVENTH GAM");
	set_code("ASXE");
	save_type = 3'd5;
	load_rom(8'd10);
	wait_det(2'd0, 3'd5);
	check("a probe abandoned by clear does not block the next one",
	      slot_save_det[3:0] === 4'd5);

	// clearing the slots drops the records with them
	slot_clear = 1;
	repeat (3) @(negedge clk);
	slot_clear = 0;
	repeat (4) @(posedge clk);
	check("clear drops every save type", slot_save === 16'd0);
	repeat (8) @(posedge clk);
	check("clear drops every detected type", slot_save_det === 16'd0);

	if (errors == 0) $display("tb_cart_slot: PASS");
	else             $display("tb_cart_slot: FAIL (%0d errors)", errors);
	$finish;
end

initial begin
	#10_000_000;
	$display("tb_cart_slot: FAIL — timeout");
	$finish;
end

endmodule
