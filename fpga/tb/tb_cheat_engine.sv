//============================================================================
// NDS MiSTer Test — cheat engine testbench
//
//   iverilog -g2012 -o /tmp/tb_cheat tb/tb_cheat_engine.sv \
//            rtl/cart/cheat_engine.sv && vvp /tmp/tb_cheat
//
// Streams a .cht-style text file byte by byte, then exercises:
//   type 0 (write32, both halves), type 1 (write16), type 2 (write8 both
//   lanes), comment lines, non-matching addresses, the type-5 guard
//   (block on fail / release on pass), "Disable all cheats" lockout and
//   new-file reload (codes replaced, lockout cleared).
//============================================================================
`timescale 1ns / 1ps

module tb_cheat_engine;

reg clk = 0;
always #10 clk = ~clk; // 50 MHz

reg reset = 1;
reg f2_wr = 0;
reg [7:0] f2_dout = 0;
reg f2_dl = 0;
reg clr_cheats = 0;

reg         chk_en = 0;
reg  [31:0] chk_addr = 0;
reg  [31:0] chk_word = 0;
wire        hit, patch_hi_en;
wire [15:0] patch, patch_hi;

cheat_engine dut (
	.clk(clk),
	.reset(reset),
	.f2_wr(f2_wr),
	.f2_dout(f2_dout),
	.f2_dl(f2_dl),
	.clr_cheats(clr_cheats),
	.chk_en(chk_en),
	.chk_addr(chk_addr),
	.chk_word(chk_word),
	.hit(hit),
	.patch(patch),
	.patch_hi_en(patch_hi_en),
	.patch_hi(patch_hi)
);

integer errors = 0;
task check;
	input [8*48:1] name;
	input cond;
	begin
		if (!cond) begin
			$display("FAIL %0s", name);
			errors = errors + 1;
		end else
			$display("ok   %0s", name);
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

// begin/end bracket each "file" exactly like ioctl_download does:
// the download-active edge clears codes, the falling edge flushes
// a tail line with no trailing newline.
task file_open;
	begin
		@(posedge clk);
		f2_dl <= 1;
		@(posedge clk);
	end
endtask

task file_close;
	begin
		@(posedge clk);
		f2_dl <= 0;
		repeat (2) @(posedge clk);
	end
endtask

// send n characters of a vector (leftmost char first)
task send_str;
	input [8*24:1] s;
	input integer n;
	integer k;
	begin
		for (k = n; k >= 1; k = k - 1) send_byte(s[8*k -: 8]);
	end
endtask

// issue one runtime query and sample the comb response on the negedge
task q;
	input [31:0] a;
	input [31:0] w;
	begin
		@(posedge clk);
		chk_addr <= a;
		chk_word <= w;
		chk_en   <= 1;
		@(negedge clk);
	end
endtask

task q_done;
	begin
		@(posedge clk);
		chk_en <= 0;
	end
endtask

integer i;
initial begin
	repeat (5) @(posedge clk);
	reset = 0;
	repeat (2) @(posedge clk);

	// ---- file 1
	// 02000100 00000042   type0 write32
	file_open;
	send_str("; infinite hearts", 16); send_byte("\n");
	send_str("02000100 00000042", 17); send_byte("\n");
	send_str("12000104 00000055", 17); send_byte("\n"); // type1 write16
	send_str("22000108 000000AA", 17); send_byte("\n"); // type2 write8
	send_str("2200010B 000000CC", 17); send_byte("\n"); // type2 odd lane
	send_str("02000120 00000099", 17); send_byte("\n"); // guard THEN-write
	send_str("52000120 00000010", 17); send_byte("\n"); // type5 guard (EQ)
	file_close;

	// type 0: both halves patched
	q(32'h0200_0100, 32'h1111_2222);
	check("type0 hit + low patch 0x0042", hit === 1'b1 && patch === 16'h0042);
	check("type0 high patch en/value", patch_hi_en === 1'b1 && patch_hi === 16'h0000);
	q_done;

	// type 1: halfword only
	q(32'h0200_0104, 32'hDEAD_BEEF);
	check("type1 halfword patch 0x0055", hit === 1'b1 && patch === 16'h0055);
	check("type1 high untouched", patch_hi_en === 1'b0);
	q_done;

	// type 2 even lane: replaces byte0 of the halfword, keeps byte1
	q(32'h0200_0108, 32'h0000_1200);
	check("type2 byte lane0 -> 0x12AA", hit === 1'b1 && patch === 16'h12AA);
	q_done;

	// type 2 odd lane
	q(32'h0200_010B, 32'h0000_3400);
	check("type2 byte lane1 -> 0xCC00", hit === 1'b1 && patch === 16'hCC00);
	q_done;

	// no match
	q(32'h0200_0900, 32'h0000_0000);
	check("no matching code -> no hit", hit === 1'b0);
	q_done;

	// ---- guard: type5 EQ at its own address; the THEN-write sits before
	// it in the list, so the guard's evaluation gates the NEXT accesses.
	q(32'h0200_0120, 32'h0000_0010);
	check("guard pass: THEN-write applies", hit === 1'b1 && patch === 16'h0099);
	q_done;

	q(32'h0200_0120, 32'h0000_0099);
	check("guard fail: eval after write still applies", hit === 1'b1);
	q_done;

	q(32'h0200_0100, 32'h1111_2222);
	check("block gates all writes globally", hit === 1'b0);
	q_done;

	q(32'h0200_0120, 32'h0000_0010);
	check("pass release: 1st read still blocked", hit === 1'b0);
	q_done;

	q(32'h0200_0120, 32'h0000_0010);
	check("guard pass released (write applies)", hit === 1'b1);
	q_done;

	// ---- lockout
	@(posedge clk); clr_cheats <= 1;
	@(posedge clk); clr_cheats <= 0;
	q(32'h0200_0100, 32'h0000_0010);
	check("disable all cheats -> no hits", hit === 1'b0);
	q_done;

	// ---- new file reload: clear old codes + lockout
	file_open;
	send_str("02000100 00000077", 17); send_byte("\n");
	file_close;

	q(32'h0200_0100, 32'h1111_2222);
	check("reload: new code value 0x0077", hit === 1'b1 && patch === 16'h0077);
	q_done;

	q(32'h0200_0104, 32'h0000_0000);
	check("reload: old codes cleared", hit === 1'b0);
	q_done;

	q(32'h0200_0100, 32'h0000_0010);
	check("reload: lockout cleared", hit === 1'b1);
	q_done;

	// ---- file 3: format robustness
	file_open;
	// 'F' hex digits must parse (hexv invalid-vs-'F' collision)
	send_str("02000FFF FFFFFFFF", 17); send_byte("\n");
	// tab separator + BOM bytes before the line
	send_byte(8'hEF); send_byte(8'hBB); send_byte(8'hBF);
	send_str("12000104\t0000FFFF", 17); send_byte("\n");
	// double space separator
	send_str("22000108  000000EE", 18); send_byte("\n");
	// tail line WITHOUT trailing newline -> flushed on file_close
	send_str("0200010C 000000DD", 17);
	file_close;
	repeat (10) @(posedge clk);

	q(32'h0200_0FFF, 32'h1234_5678);
	check("F-hex digits: addr+data parsed", hit === 1'b1 && patch === 16'hFFFF && patch_hi_en === 1'b1 && patch_hi === 16'hFFFF);
	q_done;

	q(32'h0200_0104, 32'h1111_2222);
	check("BOM skipped + tab separator", hit === 1'b1 && patch === 16'hFFFF);
	q_done;

	q(32'h0200_0108, 32'h3434_0000);
	check("double space separator", hit === 1'b1 && patch === 16'h00EE);
	q_done;

	q(32'h0200_010C, 32'h0000_0000);
	check("tail line flushed w/o newline", hit === 1'b1 && patch === 16'h00DD);
	q_done;

	if (errors == 0) $display("tb_cheat_engine: PASS");
	else             $display("tb_cheat_engine: FAIL (%0d errors)", errors);
	$finish;
end

initial begin
	#50_000_000;
	$display("tb_cheat_engine: FAIL — timeout");
	$finish;
end

endmodule
