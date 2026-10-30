//============================================================================
// NDS MiSTer Test — four hardware timers, one CPU's set
//
// GBATEK, *DS Timers*: "Same as GBA, except F = 33.513982 MHz (for both NDS9
// and NDS7). Both NDS9 and NDS7 have four Timers each, eight Timers in
// total." Each timer is the GBA one:
//
//   4000100h+8*n  TMxCNT_L  16-bit reload value (R/W)
//   4000102h+8*n  TMxCNT_H  control (R/W)
//                           0-1 prescaler  0=/1  1=/64  2=/256  3=/1024
//                           2   cascade    count on the previous timer's
//                                          overflow instead of the prescaler
//                           6   IRQ enable raise IF.3+n on overflow
//                           7   enable
//
// The counter reloads from TMxCNT_L on overflow and the overflow leaves as a
// one-cycle pulse, which is what the IRQ bank latches. A timer's cascade input
// is the overflow of the timer below it, so the four form a chain: with
// cascade set on timer 1 it counts timer 0's overflows and its own prescaler
// is ignored, exactly as GBATEK describes.
//
// `tick` is one tick of the timer clock, which on the DS is the ARM7's own
// clock: the timers are a divider of the 33.513982 MHz clock the ARM7 runs on
// (GBATEK gives that F for both NDS9 and NDS7), so a timer counts CPU cycles
// and nothing else. The divider between clk_sys and that clock lives outside
// this module, as a clock enable rather than a second clock domain.
//============================================================================
module nds_timers (
	input              clk,
	input              reset,
	input              tick,        // one 33.51 MHz cycle

	// register interface (halfword granularity, addresses 0x100..0x10F)
	input      [3:0]   reg_off,     // 0x0 = timer 0 reload, 0x2 = its control
	input              we,
	input      [15:0]  wdata,
	output reg [15:0]  rdata,

	output     [3:0]   irq          // one pulse per timer overflow
);

	reg [15:0] reload [0:3];
	reg [15:0] cnt    [0:3];
	reg [15:0] ctrl   [0:3];
	reg [9:0]  div    [0:3];        // prescaler accumulator

	// each timer owns four bytes: TMxCNT_L at +0, TMxCNT_H at +2
	wire [1:0] sel = reg_off[3:2];

	wire [3:0] enable = {ctrl[3][7], ctrl[2][7], ctrl[1][7], ctrl[0][7]};
	wire [3:0] casc   = {ctrl[3][2], ctrl[2][2], ctrl[1][2], ctrl[0][2]};

	// prescaler wrap: 1, 64, 256 or 1024 timer ticks per counter step
	wire [3:0] pre_hit;
	genvar g;
	generate
		for (g = 0; g < 4; g = g + 1) begin : pre
			wire [9:0] limit = (ctrl[g][1:0] == 2'd0) ? 10'd0  :
			                   (ctrl[g][1:0] == 2'd1) ? 10'd63 :
			                   (ctrl[g][1:0] == 2'd2) ? 10'd255 : 10'd1023;
			assign pre_hit[g] = tick && enable[g] && !casc[g] && (div[g] == limit);
		end
	endgenerate

	// count-chain: a cascaded timer steps on the overflow of the one below it
	// (timer 0 has none, so its cascade bit does nothing)
	wire [3:0] at_max = {cnt[3] == 16'hFFFF, cnt[2] == 16'hFFFF,
	                     cnt[1] == 16'hFFFF, cnt[0] == 16'hFFFF};
	wire [3:0] ovf;
	assign ovf[0] = pre_hit[0] && at_max[0];
	assign ovf[1] = (pre_hit[1] || (casc[1] && ovf[0])) && at_max[1];
	assign ovf[2] = (pre_hit[2] || (casc[2] && ovf[1])) && at_max[2];
	assign ovf[3] = (pre_hit[3] || (casc[3] && ovf[2])) && at_max[3];
	wire [3:0] step = pre_hit | {ovf[2] && casc[3], ovf[1] && casc[2],
	                             ovf[0] && casc[1], 1'b0};

	reg [3:0] irq_r = 4'd0;
	assign irq = irq_r;

	integer i;
	always @(posedge clk) begin
		irq_r <= 4'd0;

		for (i = 0; i < 4; i = i + 1) begin
			if (enable[i] && tick && !casc[i])
				div[i] <= pre_hit[i] ? 10'd0 : (div[i] + 10'd1);

			if (step[i] && enable[i]) begin
				if (at_max[i]) begin
					cnt[i]  <= reload[i];
					irq_r[i] <= ctrl[i][6];
				end else begin
					cnt[i] <= cnt[i] + 16'd1;
				end
			end
		end

		// a reload write also loads the counter, which is what a game does
		// before it enables the timer
		if (we) begin
			if (!reg_off[1]) begin
				reload[sel] <= wdata;
				cnt[sel]    <= wdata;
				div[sel]    <= 10'd0;
			end else begin
				ctrl[sel] <= wdata;
			end
		end

		if (reset) begin
			irq_r <= 4'd0;
			for (i = 0; i < 4; i = i + 1) begin
				reload[i] <= 16'd0;
				cnt[i]    <= 16'd0;
				ctrl[i]   <= 16'd0;
				div[i]    <= 10'd0;
			end
		end
	end

	always @(*) begin
		case (reg_off[3:0])
		4'h0:    rdata = reload[0];
		4'h2:    rdata = ctrl[0];
		4'h4:    rdata = reload[1];
		4'h6:    rdata = ctrl[1];
		4'h8:    rdata = reload[2];
		4'hA:    rdata = ctrl[2];
		4'hC:    rdata = reload[3];
		4'hE:    rdata = ctrl[3];
		default: rdata = 16'h0000;
		endcase
	end

endmodule
