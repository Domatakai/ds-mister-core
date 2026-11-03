//============================================================================
// NDS MiSTer Test — SPI backup chip + AUXSPI save-type probe
//
//   iverilog -g2012 -o /tmp/tb_sp tb/tb_save_probe.sv \
//            rtl/cart/save_spi.sv rtl/cart/save_probe.sv && vvp /tmp/tb_sp
//
// Part 1 drives the emulated chip by hand — WREN/RD/WR/RDSR/RDID at the byte
// level — and checks the GBATEK behaviour it depends on: write-enable latch,
// page-program WIP (which FRAM never raises), the JEDEC identity of the two
// FLASH parts, reads past the end folding onto the addresses they mirror, and
// and that a blank 24-bit FLASH reads FFh.
//
// Part 2 runs the probe against each modelled part and checks the type it
// reports: the OSD codes (1 EEPROM 512K, 2 EEPROM 8K, 3 FLASH 512K,
// 4 FLASH 1M, 5 FRAM), and 0 for a cart with no chip (Auto) or a NAND type,
// which is not SPI backup memory at all.
//============================================================================
`timescale 1ns / 1ps

module tb_save_probe;

reg clk = 0;
always #10 clk = ~clk;

reg         reset = 1;
reg  [2:0]  cfg = 3'd0;
reg         start = 0;

wire        p_cs_n, p_slot;
wire [7:0]  p_din;
wire [7:0]  dout;
wire        resp;

// the bus the chip sees: the manual phase drives it, the probe takes over
reg         manual = 1;
reg         m_cs_n = 1;
reg         m_slot = 0;
reg  [7:0]  m_din = 8'h00;
wire        cs_n = manual ? m_cs_n : p_cs_n;
wire [7:0]  din  = manual ? m_din  : p_din;
wire        slot = manual ? m_slot : p_slot;
wire [7:0]  chip_status;
wire        present;

wire [2:0]  det_type;
wire        valid, done;
wire [7:0]  seen_status;
wire [31:0] seen_id;
wire [1:0]  seen_cap;

save_spi u_chip (
	.clk(clk), .reset(reset), .cfg(cfg),
	.cs_n(cs_n), .din(din), .slot(slot),
	.dout(dout), .resp(resp),
	.status_o(chip_status), .present(present)
);

save_probe u_probe (
	.clk(clk), .reset(reset), .start(start),
	.cs_n(p_cs_n), .din(p_din), .slot(p_slot), .dout(dout), .resp(resp),
	.det_type(det_type), .valid(valid), .done(done),
	.seen_status(seen_status), .seen_id(seen_id), .seen_cap(seen_cap)
);

localparam [2:0] T_EEP64 = 3'd1, T_EEP8 = 3'd2,
                 T_FL512 = 3'd3, T_FL1M = 3'd4, T_FRAM = 3'd5;

integer errors = 0;
task check;
	input [8*46:1] name;
	input          cond;
	begin
		if (!cond) begin
			$display("FAIL %0s", name);
			errors = errors + 1;
		end else
			$display("ok   %0s", name);
	end
endtask

//------------------------------------------------------------------
// hand-driven byte transfers (the probe is idle in this phase)
//------------------------------------------------------------------
task xfer;
	input  [7:0] b;
	output [7:0] r;
	integer guard;
	begin
		@(negedge clk);
		m_din  = b;
		m_slot = 1;
		@(negedge clk);
		m_slot = 0;
		guard = 0;
		while (!resp && guard < 16) begin
			@(negedge clk);
			guard = guard + 1;
		end
		r = dout;
		@(negedge clk);
	end
endtask

reg [7:0] r0;

task cmd1;                       // one command byte, framed
	input [7:0] c;
	begin
		@(negedge clk); m_cs_n = 0;
		xfer(c, r0);
		@(negedge clk); m_cs_n = 1;
		@(negedge clk);
	end
endtask

task rd_byte;
	input  [23:0] a;
	input  [1:0]  ab;               // address bytes: 2 for EEPROM/FRAM
	output [7:0]  d;
	reg    [7:0]  x;
	begin
		@(negedge clk); m_cs_n = 0;
		xfer(8'h03, x);
		if (ab == 2'd3) xfer(a[23:16], x);
		xfer(a[15:8], x);
		xfer(a[7:0], x);
		xfer(8'h00, d);
		@(negedge clk); m_cs_n = 1;
		@(negedge clk);
	end
endtask

task wr_byte;
	input [23:0] a;
	input [1:0]  ab;
	input [7:0]  d;
	reg   [7:0]  x;
	begin
		cmd1(8'h06);                 // WREN
		@(negedge clk); m_cs_n = 0;
		xfer(8'h02, x);
		if (ab == 2'd3) xfer(a[23:16], x);
		xfer(a[15:8], x);
		xfer(a[7:0], x);
		xfer(d, x);
		@(negedge clk); m_cs_n = 1;
		@(negedge clk);
	end
endtask

task rdsr;
	output [7:0] s;
	reg    [7:0] x;
	begin
		@(negedge clk); m_cs_n = 0;
		xfer(8'h05, x);
		xfer(8'h00, s);
		@(negedge clk); m_cs_n = 1;
		@(negedge clk);
	end
endtask

task rdid;
	output [31:0] id;
	reg    [7:0]  a, b, c, d;
	begin
		@(negedge clk); m_cs_n = 0;
		xfer(8'h9F, a);
		xfer(8'h00, a);
		xfer(8'h00, b);
		xfer(8'h00, c);
		xfer(8'h00, d);
		id = {a, b, c, d};
		@(negedge clk); m_cs_n = 1;
		@(negedge clk);
	end
endtask

// run the probe and report what it concluded
reg [2:0] ptype;
reg       pok;
task probe_cfg;
	input [2:0] c;
	integer guard;
	begin
		manual = 0;
		cfg = c;
		repeat (3) @(posedge clk);
		@(negedge clk); start = 1;
		@(negedge clk); start = 0;
		guard = 0;
		while (!done && guard < 200000) begin
			@(posedge clk);
			guard = guard + 1;
		end
		ptype = det_type;
		pok   = valid;
		repeat (4) @(posedge clk);
	end
endtask

reg [7:0]  s;
reg [31:0] id;
reg [7:0]  d;

initial begin
	repeat (4) @(posedge clk);
	reset = 0;
	repeat (4) @(posedge clk);

	// ------------------------------------------------ EEPROM 8K, by hand
	cfg = T_EEP8;
	repeat (2) @(posedge clk);
	rdsr(s);
	check("EEPROM 8K: RDSR is 00h, not the 0.5K pattern", s === 8'h00);
	rdid(id);
	check("EEPROM 8K: RDID answers FFh x4", id === 32'hFFFF_FFFF);

	wr_byte(24'h000000, 2'd2, 8'hA5);
	rdsr(s);
	check("EEPROM 8K: WIP raised by a page write", s[0] === 1'b1);
	check("EEPROM 8K: WEL cleared when the write ends", s[1] === 1'b0);
	repeat (700) @(posedge clk);
	rdsr(s);
	check("EEPROM 8K: WIP clears", s[0] === 1'b0);

	rd_byte(24'h000000, 2'd2, d);
	check("EEPROM 8K: the byte written reads back", d === 8'hA5);
	rd_byte(24'h002000, 2'd2, d);
	check("EEPROM 8K: 8 KB folds back onto address 0", d === 8'hA5);
	u_chip.mem[16'h0007] = 8'h3C;
	rd_byte(24'h002007, 2'd2, d);
	check("EEPROM 8K: 8 KB + 7 mirrors address 7", d === 8'h3C);

	// ------------------------------------------------ EEPROM 64K
	cfg = T_EEP64;
	u_chip.mem[16'h2000] = 8'h22;
	repeat (2) @(posedge clk);
	rd_byte(24'h002000, 2'd2, d);
	check("EEPROM 64K: 8 KB is inside the chip, not aliased", d === 8'h22);

	// ------------------------------------------------ FRAM 32K
	cfg = T_FRAM;
	repeat (2) @(posedge clk);
	rdid(id);
	check("FRAM: RDID answers FFh x4", id === 32'hFFFF_FFFF);
	wr_byte(24'h000000, 2'd2, 8'h5E);
	rdsr(s);
	check("FRAM: no WIP after a write", s[0] === 1'b0);
	rd_byte(24'h000000, 2'd2, d);
	check("FRAM: the byte written reads back", d === 8'h5E);
	u_chip.mem[16'h4000] = 8'h77;
	rd_byte(24'h008000, 2'd2, d);
	check("FRAM: 32 KB aliases its low half", d === 8'h5E);

	// ------------------------------------------------ FLASH 512K / 1M
	cfg = T_FL512;
	repeat (2) @(posedge clk);
	rdid(id);
	check("FLASH 512K: JEDEC id 20 20 13", id === 32'h202013FF);
	rd_byte(24'h000010, 2'd3, d);
	check("FLASH 512K: a blank part reads FFh", d === 8'hFF);

	cfg = T_FL1M;
	repeat (2) @(posedge clk);
	rdid(id);
	check("FLASH 1M: JEDEC id 20 20 14", id === 32'h202014FF);

	// ------------------------------------------------ probe each part
	// a save image the probe must leave alone
	cfg = T_EEP8;
	u_chip.mem[16'h0000] = 8'h12;
	u_chip.mem[16'h0001] = 8'h34;
	probe_cfg(T_EEP8);
	check("probe: EEPROM 8K -> type 2", pok === 1'b1 && ptype === 3'd2);
	check("probe: 8K capacity found by mirroring", seen_cap === 2'd1);
	check("probe: the save image is restored", 
	      u_chip.mem[16'h0000] === 8'h12 && u_chip.mem[16'h0001] === 8'h34);

	probe_cfg(T_EEP64);
	check("probe: EEPROM 512K (64 KB) -> type 1", pok === 1'b1 && ptype === 3'd1);
	check("probe: 64 KB capacity found by elimination", seen_cap === 2'd3);

	probe_cfg(T_FRAM);
	check("probe: FRAM 32K -> type 5", pok === 1'b1 && ptype === 3'd5);
	check("probe: 32 KB capacity found by mirroring", seen_cap === 2'd2);

	probe_cfg(T_FL512);
	check("probe: FLASH 512K -> type 3", pok === 1'b1 && ptype === 3'd3);
	check("probe: FLASH capacity from the JEDEC id", seen_id[15:8] === 8'h13);

	probe_cfg(T_FL1M);
	check("probe: FLASH 1M -> type 4", pok === 1'b1 && ptype === 3'd4);
	check("probe: FLASH 1M id byte is 14h", seen_id[15:8] === 8'h14);

	probe_cfg(3'd0);
	check("probe: Auto = no chip fitted -> none", pok === 1'b1 && ptype === 3'd0);
	check("probe: open bus reads FFh", seen_status === 8'hFF);

	probe_cfg(3'd6);
	check("probe: NAND is not SPI backup memory -> none",
	      pok === 1'b1 && ptype === 3'd0);
	check("probe: NAND reports no chip present", present === 1'b0);

	if (errors == 0) $display("TB SAVE PROBE PASS");
	else             $display("TB SAVE PROBE FAIL (%0d errors)", errors);
	$finish;
end

initial begin
	#40_000_000;
	$display("TB SAVE PROBE FAIL - timeout");
	$finish;
end

endmodule
