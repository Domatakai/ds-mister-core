//============================================================================
// NDS MiSTer Test — per-game overclock reference bench
//
//   iverilog -g2012 -o /tmp/tb_oc tb/tb_oc_lookup.sv rtl/cpu/oc_lookup.sv &&
//            vvp /tmp/tb_oc
//
// Checks the three things the OSD's auto row depends on:
//   - auto off passes the manual row straight through
//   - a listed game code selects its reference mode, whatever the manual row
//   - an unlisted code selects Normal rather than inheriting the last game's
//     mode, and an empty code (no game loaded) is Normal too
//============================================================================
`timescale 1ns / 1ps

module tb_oc_lookup;

reg  [1:0] manual = 2'd0;
reg        auto_on = 0;
reg [31:0] code = 32'd0;
wire [1:0] mode;

integer errors = 0;
task check;
	input [8*46:1] name;
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

oc_lookup dut (
	.manual(manual), .auto_on(auto_on), .code(code), .mode(mode)
);

initial begin
	// auto off: the manual row is the mode, whatever cartridge is in
	manual = 2'd0; auto_on = 0; code = 32'h414D4345;
	#1 check("auto off passes Normal through", mode === 2'd0);
	manual = 2'd2;
	#1 check("auto off passes ARM7 x4 through", mode === 2'd2);

	// auto on: a listed code selects its reference mode
	auto_on = 1;
	manual = 2'd2;
	code = 32'h414D4345;                  // "AMCE"
	#1 check("listed game code selects ARM7 x2", mode === 2'd1);
	check("the manual row is ignored while auto is on", mode !== 2'd2);

	// an unlisted code is Normal, not the previous game's mode
	code = 32'h5A5A5A5A;                  // "ZZZZ"
	#1 check("unlisted code selects Normal", mode === 2'd0);

	// no game loaded: the code reads as zero, which is Normal as well
	code = 32'd0;
	#1 check("no game loaded selects Normal", mode === 2'd0);

	// auto off again hands control straight back
	auto_on = 0;
	manual = 2'd1;
	#1 check("auto off returns the manual row", mode === 2'd1);

	if (errors == 0) $display("tb_oc_lookup: PASS");
	else             $display("tb_oc_lookup: FAIL (%0d errors)", errors);
	$finish;
end

endmodule
