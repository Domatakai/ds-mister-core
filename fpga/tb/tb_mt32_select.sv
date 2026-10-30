//============================================================================
// NDS MiSTer Test — MT-32-pi selection testbench
//
//   iverilog -g2012 -o /tmp/tb_sel tb/tb_mt32_select.sv \
//            rtl/audio/mt32_select.sv && vvp /tmp/tb_sel
//
// RST_HOLD is 8 here so a reload pulse is short enough to count, but the
// logic is the same as in the core. The point of the block is that the Pi
// gets told to re-read its mode request when the OSD changes — without the
// pulse, changing "MT-32-pi synth" or the bank mid-session would do nothing.
//
// Checks:
//   1. MT-32 default: mode request low, index 0, no reload pulse.
//   2. Switching to SoundFont raises the mode request and pulses exactly
//      RST_HOLD clocks, then settles.
//   3. The index follows the bank, 0..7.
//   4. A bank change in SoundFont mode pulses again (new soundfont to load).
//   5. A bank change in MT-32 mode does not: the Pi ignores the index then.
//   6. Switching back to MT-32 pulses once more.
//============================================================================
`timescale 1ns / 1ps

module tb_mt32_select;

reg clk = 0;
always #10 clk = ~clk;

localparam integer RST_HOLD = 8;

reg         reset = 1;
reg  [2:0]  sf_bank = 3'd0;
reg         synth = 1'b0;

wire        mode_sf, restart;
wire [7:0]  sf_index;

mt32_select #(.RST_HOLD(RST_HOLD)) dut (
	.clk(clk), .reset(reset),
	.sf_bank(sf_bank), .synth(synth),
	.mode_sf(mode_sf), .sf_index(sf_index), .restart(restart)
);

integer errors = 0;
task check;
	input [8*52:1] name;
	input          cond;
	begin
		if (!cond) begin
			$display("FAIL %0s", name);
			errors = errors + 1;
		end else
			$display("ok   %0s", name);
	end
endtask

// count reload clocks for the current stimulus
integer pulse = 0;
always @(posedge clk) if (restart) pulse = pulse + 1;

task settle;
	begin
		repeat (RST_HOLD * 4) @(posedge clk);
	end
endtask

integer i;
reg     seen_low = 0;

initial begin
	repeat (4) @(posedge clk);
	reset = 0;
	repeat (4) @(posedge clk);

	// ------------------------------------------------ 1. MT-32 default
	pulse = 0;
	settle;
	check("MT-32 mode request is low", mode_sf === 1'b0);
	check("index starts at 0", sf_index === 8'd0);
	check("no reload pulse when nothing changed", pulse == 0);

	// ------------------------------------------------ 2. SoundFont
	pulse = 0;
	synth = 1'b1;
	@(posedge clk);
	repeat (RST_HOLD + 4) @(posedge clk);
	check("SoundFont raises the mode request", mode_sf === 1'b1);
	check("reload pulse is exactly RST_HOLD clocks", pulse == RST_HOLD);
	check("reload pulse ends on its own", restart === 1'b0);

	// ------------------------------------------------ 3. index == bank
	begin : banks
		integer ok;
		ok = 1;
		for (i = 0; i < 8; i = i + 1) begin
			sf_bank = i[2:0];
			@(posedge clk);
			if (sf_index !== i[7:0]) ok = 0;
		end
		check("index follows the bank 0..7", ok == 1);
	end

	// ------------------------------------------------ 4. bank change in SF
	sf_bank = 3'd2;
	settle;
	pulse = 0;
	sf_bank = 3'd5;
	@(posedge clk);
	repeat (RST_HOLD + 4) @(posedge clk);
	check("bank change in SoundFont mode pulses", pulse == RST_HOLD);
	check("new index reaches the Pi", sf_index === 8'd5);

	// ------------------------------------------------ 5. bank change in MT-32
	synth = 1'b0;
	settle;
	pulse = 0;
	sf_bank = 3'd1;
	@(posedge clk);
	repeat (RST_HOLD + 4) @(posedge clk);
	check("bank change in MT-32 mode does not pulse", pulse == 0);

	// ------------------------------------------------ 6. back to MT-32
	synth = 1'b1;
	settle;
	pulse = 0;
	synth = 1'b0;
	@(posedge clk);
	repeat (RST_HOLD + 4) @(posedge clk);
	check("switching back to MT-32 pulses", pulse == RST_HOLD);
	check("mode request is low again", mode_sf === 1'b0);

	if (errors == 0) $display("TB MT32 SELECT PASS");
	else             $display("TB MT32 SELECT FAIL (%0d errors)", errors);
	$finish;
end

endmodule
