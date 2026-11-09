//============================================================================
// NDS MiSTer Test — microphone ADC bench
//
//   iverilog -g2012 -o /tmp/tb_mic tb/tb_mic_adc.sv //            rtl/input/mic_adc.sv sys/ltc2308.sv && vvp /tmp/tb_mic
//
// The LTC2308 is modelled on the bus the way the part answers: after CONVST
// it clocks out twelve bits, MSB first, held on the data line while SCK is
// high. The bench checks that those bits reach `sample`, that a later
// conversion replaces the word, and that conversions run at the DS's 48 kHz.
//============================================================================
`timescale 1ns / 1ps

module tb_mic_adc;

reg clk_adc = 0;
always #10 clk_adc = ~clk_adc;          // 50 MHz, the converter's clock

reg clk = 0;
always #7.4599 clk = ~clk;              // 67.0274 MHz, clk_sys

reg reset_adc = 1;
reg reset = 1;

wire [3:0]  ADC_BUS;
wire [11:0] sample;
wire        sample_tick;

// the converter model: present the next bit while SCK is high
reg  [11:0] word = 12'h123;
reg         bit_out = 1'b0;
reg   [3:0] bit_i = 4'd0;
wire        sck = ADC_BUS[3];
assign ADC_BUS[2] = bit_out;            // SDO is the only bit the bench drives

// the part is read on SCK's rising edge, so each bit is presented while SCK
// is low and advanced on the falling edge
wire convst = ADC_BUS[0];

always @(posedge convst) begin
	bit_i   <= 4'd0;
	bit_out <= word[11];
end

always @(negedge sck) begin
	bit_i <= bit_i + 1'd1;
	if (bit_i < 4'd11) bit_out <= word[10 - bit_i];
end

mic_adc dut (
	.clk_adc(clk_adc), .reset_adc(reset_adc), .ADC_BUS(ADC_BUS),
	.clk(clk), .reset(reset), .sample_tick(sample_tick), .sample(sample)
);

integer errors = 0;
task check;
	input [8*46:1] name;
	input          ok;
	begin
		if (ok) $display("ok   %0s", name);
		else begin $display("FAIL %0s", name); errors = errors + 1; end
	end
endtask

time t0, t1;

initial begin
	repeat (4) @(posedge clk_adc);
	reset_adc = 0;
	repeat (4) @(posedge clk);
	reset = 0;

	check("the sample idles at mid-scale after reset", sample === 12'h400);

	// the word is written at the end of a conversion and latched when the
	// next one starts, so two ticks carry it across
	repeat (3) @(posedge sample_tick);
	repeat (10) @(posedge clk);
	check("the converted word reaches the sample", sample === 12'h123);

	word = 12'hF5A;
	repeat (3) @(posedge sample_tick);
	repeat (10) @(posedge clk);
	check("a later conversion replaces it", sample === 12'hF5A);

	word = 12'h000;
	repeat (3) @(posedge sample_tick);
	repeat (10) @(posedge clk);
	check("and a zero word reads as zero", sample === 12'h000);

	// 96 conversions at 48 kHz is 2 ms, to within one percent (times are ps)
	t0 = $time;                       // $time is in ns here (1ns/1ps)
	repeat (96) @(posedge sample_tick);
	t1 = $time;
	$display("     96 conversions: %0d ns", t1 - t0);
	check("96 conversions take 2 ms (48 kHz)",
	      (t1 - t0) > 1_980_000 && (t1 - t0) < 2_020_000);

	if (errors == 0) $display("tb_mic_adc: PASS");
	else             $display("tb_mic_adc: FAIL (%0d errors)", errors);
	$finish;
end

endmodule
