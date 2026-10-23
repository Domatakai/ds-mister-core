//============================================================================
// NDS MiSTer Test — DMA engine (milestone M2)
//
// The four general-purpose DMA channels (GBATEK "DMA0-3", ARM9 side:
// 0x040000B0..0x040000DF). Each channel moves `count` units between the
// DS address map through the shared bus fabric (same master interface
// the CPUs use), so DMA writes land in main RAM, WRAM, palette, OAM, IO
// and the cart window with the normal decode.
//
//   0xB0+12n  SAD   [31:0] source address
//   0xB4+12n  DAD   [31:0] destination address
//   0xB8+12n  CNT_L [15:0] word count (0 = 0x4000 units, GBATEK)
//   0xBC+12n  CNT_H [15:0] control
//             [0]     enable (0->1 write arms the channel)
//             [1]     IRQ on completion
//             [2]     dest mode: 0 inc, 1 dec, 2 fixed, 3 inc/reload
//             [4:3]   src  mode: 0 inc, 1 dec, 2 fixed, 3 prohibited
//             [5]     repeat (vblank/hblank only; reloads count/pointers)
//             [6]     32-bit (0 = 16-bit units)
//             [8:7]   timing: 0 immediate, 1 vblank, 2 hblank, 3 special
//
// Trigger behaviour: immediate runs on the enable write; vblank/hblank
// channels stay armed and run once per trigger while the enable bit is
// set. Multiple armed channels on one trigger run in order 0..3 (the
// pending trigger is held until no armed channel matches it). Special
// timing (video capture / GX FIFO) lands with M3/M5.
//
// Register file and transfer FSM are strictly separated: the register
// block owns SAD/DAD/CNT and emits one-cycle arm/disarm pulses; the
// FSM owns the run state and returns completion pulses that clear the
// enable bit. No register has two drivers.
//
// The bus master is single-outstanding: READ unit -> WRITE unit -> next.
// A 32-bit unit is one 32-bit bus op (the fabric assembles the two
// 16-bit halves); a 16-bit unit is one halfword beat with the unit
// mirrored into both lanes so the addressed halfword is correct at
// either alignment.
//============================================================================
module dma_engine (
	input            clk,
	input            reset,

	// register file port (byte offset in IO space: 0xB0..0xDF,
	// i.e. 16-bit regs land on even offsets 0xB0, 0xB2, ... 0xDF)
	input            reg_we,
	input      [7:0] reg_addr,
	input     [15:0] reg_data,
	input      [7:0] reg_rd_addr,
	output    [15:0] reg_rdata,

	// bus master (same interface shape as the CPU masters)
	output    [31:0] d_addr,
	output    [31:0] d_wdata,
	output     [3:0] d_be,
	output           d_rd,
	output           d_wr,
	input            d_ready,
	input     [31:0] d_rdata,

	// triggers
	input            vblank,
	input            hblank,

	// completion (maps to IRQ8+n in main_bus)
	output reg [3:0] irq_set
);

//------------------------------------------------------------------
// Offset decode: rebase onto the channel block (0xB0), then split
// into channel (12-byte stride) and BYTE offset within the channel.
// The register file stores halfwords, so only even byte offsets
// decode: 0 SAD_lo, 2 SAD_hi, 4 DAD_lo, 6 DAD_hi, 8 CNT_L, 10 CNT_H.
//------------------------------------------------------------------
wire [7:0] d_off = reg_addr    - 8'hB0;
wire [7:0] r_off = reg_rd_addr - 8'hB0;

wire [1:0] wch = (d_off < 8'd12) ? 2'd0 :
                 (d_off < 8'd24) ? 2'd1 :
                 (d_off < 8'd36) ? 2'd2 : 2'd3;
wire [4:0] wk  = (d_off < 8'd12) ? {1'b0, d_off[3:0]} :
                 (d_off < 8'd24) ? (d_off - 8'd12) :
                 (d_off < 8'd36) ? (d_off - 8'd24) :
                                   (d_off - 8'd36);

wire [1:0] rch = (r_off < 8'd12) ? 2'd0 :
                 (r_off < 8'd24) ? 2'd1 :
                 (r_off < 8'd36) ? 2'd2 : 2'd3;
wire [4:0] rk  = (r_off < 8'd12) ? {1'b0, r_off[3:0]} :
                 (r_off < 8'd24) ? (r_off - 8'd12) :
                 (r_off < 8'd36) ? (r_off - 8'd24) :
                                   (r_off - 8'd36);

//------------------------------------------------------------------
// Register file block — owns SAD/DAD/CNT, emits arm/disarm pulses,
// consumes completion pulses to hardware-clear the enable bit
//------------------------------------------------------------------
reg [31:0] sad   [0:3];
reg [31:0] dad   [0:3];
reg [15:0] cnt_l [0:3];
reg [15:0] cnt_h [0:3];

reg [3:0] arm_pulse   = 4'd0;
reg [3:0] disarm_pulse = 4'd0;

wire [3:0] done_pulse;         // from the transfer FSM

integer i;
initial begin
	for (i = 0; i < 4; i = i + 1) begin
		sad[i]   = 32'd0;
		dad[i]   = 32'd0;
		cnt_l[i] = 16'd0;
		cnt_h[i] = 16'd0;
	end
end

always @(posedge clk) begin
	arm_pulse   <= 4'd0;
	disarm_pulse <= 4'd0;

	if (reg_we) begin
		case (wk)
		5'd0:  sad[wch][15:0]  <= reg_data;
		5'd2:  sad[wch][31:16] <= reg_data;
		5'd4:  dad[wch][15:0]  <= reg_data;
		5'd6:  dad[wch][31:16] <= reg_data;
		5'd8:  cnt_l[wch]      <= reg_data;
		5'd10: begin
			cnt_h[wch] <= reg_data;
			if (reg_data[0] && !cnt_h[wch][0])
				arm_pulse[wch]   <= 1'b1;  // 0->1 enable: arm
			else if (!reg_data[0] && cnt_h[wch][0])
				disarm_pulse[wch] <= 1'b1; // 1->0: stop
		end
		default: ;
		endcase
	end

	// hardware clears the enable bit of a one-shot channel at completion
	for (i = 0; i < 4; i = i + 1)
		if (done_pulse[i]) cnt_h[i][0] <= 1'b0;

	if (reset) begin
		arm_pulse    <= 4'd0;
		disarm_pulse <= 4'd0;
	end
end

// readback
reg [15:0] rd_mux;
always @(*) begin
	case (rk)
	5'd0:  rd_mux = sad[rch][15:0];
	5'd2:  rd_mux = sad[rch][31:16];
	5'd4:  rd_mux = dad[rch][15:0];
	5'd6:  rd_mux = dad[rch][31:16];
	5'd8:  rd_mux = cnt_l[rch];
	5'd10: rd_mux = cnt_h[rch];
	default: rd_mux = 16'd0;
	endcase
end
assign reg_rdata = rd_mux;

//------------------------------------------------------------------
// Transfer FSM block — owns run_en / pointers / trigger state
//------------------------------------------------------------------
localparam T_IDLE = 3'd0, T_RD = 3'd1, T_RDW = 3'd2, T_WR = 3'd3, T_WRW = 3'd4;

reg [2:0]  tstate = T_IDLE;
reg [1:0]  tch = 2'd0;
reg [31:0] latched = 32'd0;

reg [3:0]  run_en = 4'd0;
reg [31:0] cur_src [0:3];
reg [31:0] cur_dst [0:3];
reg [15:0] cur_cnt [0:3];

reg [3:0]  imm_pend = 4'd0;   // immediate channels waiting to run
reg        trig_pending = 1'b0;
reg [1:0]  trig_kind = 2'd0;  // 1 = vblank, 2 = hblank
reg [3:0]  done_r = 4'd0;
assign done_pulse = done_r;

wire [15:0] ctl    = cnt_h[tch];
wire        unit32 = ctl[6];
wire [1:0]  timing = ctl[8:7];

// pick the lowest-index armed channel matching the pending trigger
// (loop runs 3->0 so the last match is the lowest index)
reg [1:0] pick;
reg       pick_found;
integer   kk;
always @(*) begin
	pick       = 2'd0;
	pick_found = 1'b0;
	for (kk = 3; kk >= 0; kk = kk - 1) begin
		if (run_en[kk] && cnt_h[kk][8:7] == trig_kind && cur_cnt[kk] != 16'd0) begin
			pick       = kk[1:0];
			pick_found = 1'b1;
		end
	end
end

// lowest-index pending immediate channel
reg [1:0] ipick;
reg       ifound;
integer   ii;
always @(*) begin
	ipick  = 2'd0;
	ifound = 1'b0;
	for (ii = 3; ii >= 0; ii = ii - 1) begin
		if (imm_pend[ii] && run_en[ii]) begin
			ipick  = ii[1:0];
			ifound = 1'b1;
		end
	end
end

assign d_addr  = (tstate == T_WR || tstate == T_WRW) ? cur_dst[tch] : cur_src[tch];
assign d_wdata = latched;
assign d_rd    = (tstate == T_RDW);
assign d_wr    = (tstate == T_WRW);
assign d_be    = unit32 ? 4'hF : 4'b0011; // 16-bit units are lane-mirrored

wire [31:0] unit_bytes = unit32 ? 32'd4 : 32'd2;

always @(posedge clk) begin
	irq_set  <= 4'd0;
	done_r   <= 4'd0;

	// consume arm / disarm pulses
	for (i = 0; i < 4; i = i + 1) begin
		if (arm_pulse[i]) begin
			run_en[i]  <= 1'b1;
			cur_src[i] <= sad[i];
			cur_dst[i] <= dad[i];
			cur_cnt[i] <= (cnt_l[i] == 16'd0) ? 16'h4000 : cnt_l[i];
			if (cnt_h[i][8:7] == 2'd0)
				imm_pend[i] <= 1'b1;
		end
		if (disarm_pulse[i]) begin
			run_en[i]    <= 1'b0;
			imm_pend[i]  <= 1'b0;
		end
	end

	case (tstate)
	T_IDLE: begin
		if (ifound) begin
			// immediate channel: start it, keep the rest pending
			imm_pend[ipick] <= 1'b0;
			tch             <= ipick;
			tstate          <= T_RD;
		end else if (vblank || hblank) begin
			// latch the trigger (a later one may override kind —
			// acceptable: both stay pending as a single kind)
			trig_pending <= 1'b1;
			trig_kind    <= vblank ? 2'd1 : 2'd2;
		end else if (trig_pending && pick_found) begin
			// start the lowest matching channel; keep the trigger
			// pending so the remaining channels run in order 0..3
			tch    <= pick;
			tstate <= T_RD;
		end else if (trig_pending) begin
			trig_pending <= 1'b0; // no armed channel left
		end
	end

	T_RD: tstate <= T_RDW;

	T_RDW: begin
		if (d_ready) begin
			// latch the unit; mirror into both lanes for 16-bit
			// ops so a halfword write hits either alignment
			latched <= unit32 ? d_rdata :
			           d_addr[1] ? {d_rdata[31:16], d_rdata[31:16]}
			                      : {d_rdata[15:0],  d_rdata[15:0]};
			tstate  <= T_WR;
		end
	end

	T_WR: tstate <= T_WRW;

	T_WRW: begin
		if (d_ready) begin
			// advance pointers per the control modes
			if (ctl[4:3] == 2'd0)      cur_src[tch] <= cur_src[tch] + unit_bytes;
			else if (ctl[4:3] == 2'd1) cur_src[tch] <= cur_src[tch] - unit_bytes;
			if (ctl[2] == 1'b0)        cur_dst[tch] <= cur_dst[tch] + unit_bytes;
			else if (ctl[2] == 1'b1)   cur_dst[tch] <= cur_dst[tch] - unit_bytes;

			if (cur_cnt[tch] == 16'd1) begin
				// channel complete
				if (ctl[1]) irq_set[tch] <= 1'b1;
				if (!ctl[5] || timing == 2'd0) begin
					// one-shot (or immediate): disarm; the
					// completion pulse clears cnt_h enable
					run_en[tch]   <= 1'b0;
					imm_pend[tch] <= 1'b0;
					done_r[tch]   <= 1'b1;
				end else begin
					// repeat: reload per GBATEK
					cur_cnt[tch] <= (cnt_l[tch] == 16'd0) ? 16'h4000 : cnt_l[tch];
					if (ctl[2] == 1'b0 || ctl[2] == 1'b1)
						cur_dst[tch] <= dad[tch]; // inc/dec reload
					if (ctl[4:3] != 2'd2)
						cur_src[tch] <= sad[tch]; // fixed keeps src
				end
				tstate <= T_IDLE;
			end else begin
				cur_cnt[tch] <= cur_cnt[tch] - 16'd1;
				tstate       <= T_RD;
			end
		end
	end

	default: tstate <= T_IDLE;
	endcase

	if (reset) begin
		tstate       <= T_IDLE;
		run_en       <= 4'd0;
		imm_pend     <= 4'd0;
		trig_pending <= 1'b0;
		trig_kind    <= 2'd0;
		irq_set      <= 4'd0;
		done_r       <= 4'd0;
		tch          <= 2'd0;
		latched      <= 32'd0;
		for (i = 0; i < 4; i = i + 1) begin
			cur_src[i] <= 32'd0;
			cur_dst[i] <= 32'd0;
			cur_cnt[i] <= 16'd0;
		end
	end
end

endmodule
