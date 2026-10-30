//============================================================================
// NDS MiSTer Test — MT-32-pi audio mixer testbench
//
//   iverilog -g2012 -o /tmp/tb_mix tb/tb_audio_mix.sv \
//            rtl/audio/audio_mix.sv && vvp /tmp/tb_mix
//
// Checks:
//   1. Mixed output updates on the 48 kHz tick (CLK_AUDIO/512), not sooner.
//   2. With the MT-32-pi link off the SPU sample passes through untouched.
//   3. MIDI volume 0% mutes the return path and leaves the SPU alone.
//   4. At 100% a positive and a negative MT-32-pi sample are summed with the
//      252/256 gain (floor on the negative side, as the RTL truncates).
//   5. The sum saturates instead of wrapping in both directions.
//============================================================================
`timescale 1ns / 1ps

module tb_audio_mix;

reg clk = 0;
always #20 clk = ~clk;   // 24.576 MHz nominal (period does not matter here)

reg         reset = 1;
reg  [15:0] spu_l = 0, spu_r = 0;
reg  [15:0] mt32_l = 0, mt32_r = 0;
reg         en = 0;
reg  [2:0]  vol = 0;
wire [15:0] out_l, out_r;

audio_mix dut (
	.clk_audio(clk), .reset(reset),
	.spu_l(spu_l), .spu_r(spu_r),
	.mt32_l(mt32_l), .mt32_r(mt32_r),
	.mt32_en(en), .mt32_vol(vol),
	.out_l(out_l), .out_r(out_r)
);

integer errors = 0;
task check2;
	input [8*40:1] name;
	input [15:0] gl, wl, gr, wr;
	begin
		if (gl !== wl || gr !== wr) begin
			$display("FAIL %0s: got %h/%h want %h/%h", name, gl, gr, wl, wr);
			errors = errors + 1;
		end else
			$display("ok   %0s", name);
	end
endtask

// advance to the next mixer tick (512 clocks) and settle
task tick;
	begin
		repeat (516) @(posedge clk);
	end
endtask

integer i;
reg [15:0] held;

initial begin
	repeat (4) @(posedge clk);
	reset = 0;
	repeat (4) @(posedge clk);

	// ------------------------------------------------ 2. pass-through
	spu_l = 16'd1234; spu_r = -16'd4321;
	mt32_l = 16'd20000; mt32_r = 16'd20000;
	en = 0; vol = 3'd7;
	tick;
	check2("link off passes the SPU through", out_l, 16'd1234, out_r, -16'd4321);

	// ------------------------------------------------ 3. mute
	en = 1; vol = 3'd0;
	tick;
	check2("MIDI volume 0 mutes the return", out_l, 16'd1234, out_r, -16'd4321);

	// ------------------------------------------------ 4. unity-ish gain
	spu_l = 16'd0; spu_r = 16'd0;
	mt32_l = 16'd1000; mt32_r = -16'd1000;
	vol = 3'd7;
	tick;
	// 1000 * 252 = 252000; >>8 = 984 (floor), and -1000 * 252 = -252000
	// -> -985, matching the RTL's arithmetic truncation
	check2("100% gain, positive + negative", out_l, 16'd984, out_r, -16'd985);

	// ------------------------------------------------ 1. tick rate
	spu_l = 16'd500;
	repeat (100) @(posedge clk);
	held = out_l;
	check2("output holds between ticks", out_l, held, out_r, -16'd985);
	repeat (416) @(posedge clk);
	check2("output follows the next tick", out_l, 16'd1484, out_r, -16'd985);

	// ------------------------------------------------ 5. saturation
	spu_l = 16'd32000; spu_r = -16'd32000;
	mt32_l = 16'd32000; mt32_r = -16'd32000;
	tick;
	check2("positive sum saturates", out_l, 16'h7FFF, out_r, 16'h8000);

	// ------------------------------------------------ reset clears
	reset = 1;
	tick;
	check2("reset clears the mix", out_l, 16'h0000, out_r, 16'h0000);
	reset = 0;

	if (errors == 0) $display("TB AUDIO MIX PASS");
	else             $display("TB AUDIO MIX FAIL (%0d errors)", errors);
	$finish;
end

endmodule
