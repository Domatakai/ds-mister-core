//============================================================================
// tb_3d_path — end-to-end 3D slice: GXFIFO command to on-screen pixel
//
//   iverilog -g2012 -o /tmp/tb_3dp tb/tb_3d_path.sv tb/sdram_model.sv \
//            rtl/mem/sdram_ctrl.sv rtl/mem/mem_arbiter.sv \
//            rtl/video/geometry_engine.sv rtl/video/raster_engine.sv \
//            rtl/video/vram_arbiter.sv rtl/video/renderer_2d.sv && \
//   vvp /tmp/tb_3dp
//
// This is the integration bench the per-module benches cannot be: a
// triangle submitted as GX commands must come out of the composer port as
// a visible RGB555 pixel. The real modules are wired to each other, and
// the memory chain is the real one down to a protocol-checking SDRAM
// device model:
//
//   geometry_engine -> raster_engine -> vram_arbiter (3D write)
//                                            |
//                     renderer_2d (engine A) <-+ (3D read burst)
//                                            |
//                          mem_arbiter -> sdram_ctrl -> device model
//
// Checks:
//   * a white TRIANGLES primitive covers the pixels inside its edges and
//     leaves the rest at the backdrop colour
//   * the frame address a pixel is written to is the one the compositor
//     reads back (both go through the MST=2 bank, 256-wide, 16 bpp)
//   * with DISP3DCNT bit 0 clear nothing of the frame reaches the screen
//   * a pixel written before the line is fetched does not appear on a line
//     that was fetched earlier (no retroactive compositing)
//============================================================================
`timescale 1ns/1ps

module tb_3d_path;
reg clk = 0;
always #10 clk = ~clk;   // 50 MHz

reg reset = 1;

integer errors = 0;
integer i, guard, prev_wr, stall;

task check(input ok, input [8*64:1] what);
	begin
		if (!ok) begin
			errors = errors + 1;
			$display("FAIL %0s (time %0t)", what, $time);
		end else begin
			$display("ok   %0s", what);
		end
	end
endtask

//------------------------------------------------------------------
// geometry engine
//------------------------------------------------------------------
reg         gx_we = 0;
reg  [9:0]  gx_addr = 10'h000;
reg  [31:0] gx_data = 0;
wire [31:0] gx_rdata;
wire        vtx_valid;
wire signed [31:0] vtx_x, vtx_y;
wire  [7:0] vtx_color;
wire  [1:0] vtx_poly;

geometry_engine geometry_engine (
	.clk(clk),
	.reset(reset),
	.reg_we(gx_we),
	.reg_addr(gx_addr),
	.reg_data(gx_data),
	.reg_rdata(gx_rdata),
	.vtx_valid(vtx_valid),
	.vtx_x(vtx_x),
	.vtx_y(vtx_y),
	.vtx_color(vtx_color),
	.vtx_poly(vtx_poly)
);

//------------------------------------------------------------------
// rasterizer
//------------------------------------------------------------------
wire        px_valid;
wire [15:0] px_addr;
wire [15:0] px_rgb555;
wire        px_ready;

raster_engine raster_engine (
	.clk(clk),
	.reset(reset),
	.vtx_valid(vtx_valid),
	.vtx_x(vtx_x),
	.vtx_y(vtx_y),
	.vtx_color(vtx_color),
	.vtx_poly(vtx_poly),
	.px_valid(px_valid),
	.px_addr(px_addr),
	.px_rgb555(px_rgb555),
	.px_ready(px_ready)
);

//------------------------------------------------------------------
// VRAM arbiter -> mem_arbiter -> sdram_ctrl -> SDRAM device model
//
// The real memory chain, not a stand-in: this bench exists to prove the
// pixel the geometry engine produced is the pixel the display shows, so
// the frame has to travel the same path it will on the board.
//------------------------------------------------------------------
reg         vcnt_we = 0;
reg  [3:0]  vcnt_addr = 0;
reg  [7:0]  vcnt_data = 0;

wire        cpu_ready;
wire [15:0] cpu_rdata;
wire        a_ready, b_ready;
wire        a_bs_valid;
wire [15:0] a_bs_data;
wire        g3r_ready, g3r_bs_valid;
wire [15:0] g3r_bs_data;

// engine A renderer ports (declared before the arbiter that consumes them)
wire        ea_v_req;
wire [19:0] ea_v_addr;
wire  [7:0] ea_v_len;
wire        ea_d3_req;
wire [16:0] ea_d3_addr;
wire  [7:0] ea_d3_len;
// vram_arbiter <-> mem_arbiter (VRAM master)
wire        vm_req, vm_wr, vm_ready, vm_bst;
wire [24:0] vm_addr;
wire [15:0] vm_wdata;
wire  [1:0] vm_be;
wire  [7:0] vm_len;
wire  [1:0] vm_step, ms_step;

// mem_arbiter <-> sdram_ctrl
wire        ms_req, ms_wr, ms_rd_done, ms_wr_done;
wire [24:0] ms_addr;
wire [15:0] ms_wdata;
wire  [1:0] ms_be;
wire [15:0] sdram_dout;
// read-burst channel: controller -> arbiter -> VRAM arbiter -> renderer
wire        ms_bst, ms_bst_done, ms_bs_valid, vm_bs_valid;
wire  [7:0] ms_len;
wire [15:0] ms_bst_data;   // straight from the controller
wire [15:0] vm_bs_data;    // forwarded by mem_arbiter

vram_arbiter vram_arbiter (
	.clk(clk),
	.reset(reset),
	.reg_we(vcnt_we),
	.reg_addr(vcnt_addr),
	.reg_data(vcnt_data),
	.cpu_req(1'b0),
	.cpu_wr(1'b0),
	.cpu_addr(20'h00000),
	.cpu_wdata(16'h0000),
	.cpu_ready(cpu_ready),
	.cpu_rdata(cpu_rdata),
	.a_req(ea_v_req),
	.a_addr(ea_v_addr),
	.a_len(ea_v_len),
	.a_ready(a_ready),
	.a_bs_valid(a_bs_valid),
	.a_bs_data(a_bs_data),
	.b_req(1'b0),
	.b_addr(20'h00000),
	.b_len(8'd0),
	.b_ready(b_ready),
	.b_bs_valid(),
	.b_bs_data(),
	.g3_req(px_valid),
	.g3_addr({px_addr, 1'b0}),
	.g3_wdata(px_rgb555),
	.g3_ready(px_ready),
	.g3r_req(ea_d3_req),
	.g3r_addr(ea_d3_addr),
	.g3r_len(ea_d3_len),
	.g3r_ready(g3r_ready),
	.g3r_bs_valid(g3r_bs_valid),
	.g3r_bs_data(g3r_bs_data),
	.v_req(vm_req),
	.v_wr(vm_wr),
	.v_addr(vm_addr),
	.v_wdata(vm_wdata),
	.v_be(vm_be),
	.v_bst(vm_bst),
	.v_len(vm_len),
	.v_step(vm_step),
	.v_ready(vm_ready),
	.v_rdata(sdram_dout),     // single-access read data
	.v_bs_valid(vm_bs_valid),
	.v_bs_data(vm_bs_data)
);

mem_arbiter mem_arbiter (
	.clk(clk),
	.reset(reset),
	.bus_req(1'b0),
	.bus_wr(1'b0),
	.bus_addr(25'd0),
	.bus_wdata(16'h0000),
	.bus_be(2'b11),
	.bus_ready(),
	.save_req(1'b0),
	.save_wr(1'b0),
	.save_addr(25'd0),
	.save_wdata(16'h0000),
	.save_be(2'b11),
	.save_ready(),
	.vram_req(vm_req),
	.vram_wr(vm_wr),
	.vram_addr(vm_addr),
	.vram_wdata(vm_wdata),
	.vram_be(vm_be),
	.vram_bst(vm_bst),
	.vram_len(vm_len),
	.vram_step(vm_step),
	.vram_ready(vm_ready),
	.vram_bs_valid(vm_bs_valid),
	.vram_bs_data(vm_bs_data),
	// the SPU's sample-fetch master is not exercised in this bench
	.spu_req(1'b0),
	.spu_addr(25'd0),
	.spu_ready(),
	.spu_rdata(),
	.sdram_req(ms_req),
	.sdram_wr(ms_wr),
	.sdram_addr(ms_addr),
	.sdram_wdata(ms_wdata),
	.sdram_be(ms_be),
	.sdram_bst(ms_bst),
	.sdram_len(ms_len),
	.sdram_step(ms_step),
	.sdram_rd_done(ms_rd_done),
	.sdram_wr_done(ms_wr_done),
	.sdram_bst_done(ms_bst_done),
	.sdram_bs_valid(ms_bs_valid),
	.sdram_bs_data(ms_bst_data),
	.sdram_rdata(sdram_dout)
);

wire [12:0] SD_A;
wire  [1:0] SD_BA;
wire [15:0] SD_DQ;
wire        SD_CLK, SD_CKE, SD_DQML, SD_DQMH;
wire        SD_nCS, SD_nCAS, SD_nRAS, SD_nWE;

sdram_ctrl sdram_ctrl (
	.clk(clk),
	.reset(reset),
	.addr(ms_addr),
	.din(ms_wdata),
	.be(ms_be),
	.rd(ms_req & ~ms_wr & ~ms_bst),
	.wr(ms_req &  ms_wr),
	.rd_bst(ms_req & ms_bst),
	.bst_len(ms_len),
	.bst_step(ms_step),
	.dout(sdram_dout),
	.rd_done(ms_rd_done),
	.wr_done(ms_wr_done),
	.bst_valid(ms_bs_valid),
	.bst_data(ms_bst_data),
	.bst_done(ms_bst_done),
	.SDRAM_CLK(SD_CLK),
	.SDRAM_CKE(SD_CKE),
	.SDRAM_A(SD_A),
	.SDRAM_BA(SD_BA),
	.SDRAM_DQ(SD_DQ),
	.SDRAM_DQML(SD_DQML),
	.SDRAM_DQMH(SD_DQMH),
	.SDRAM_nCS(SD_nCS),
	.SDRAM_nCAS(SD_nCAS),
	.SDRAM_nRAS(SD_nRAS),
	.SDRAM_nWE(SD_nWE)
);

// 512 rows is enough for this bench's frame (48 rows) with no aliasing
sdram_model #(.ROW_BITS(9)) sdram_model (
	.sclk(SD_CLK),
	.a(SD_A),
	.ba(SD_BA),
	.dq(SD_DQ),
	.dqm({SD_DQMH, SD_DQML}),
	.op({SD_nCS, SD_nCAS, SD_nRAS, SD_nWE}),
	.cke(SD_CKE)
);

//------------------------------------------------------------------
// engine A renderer (composes the 3D layer) + palette / OAM models
//------------------------------------------------------------------
reg  [7:0] px = 8'hFF, py = 8'hFF;
reg        on = 0;
wire [15:0] rgb555;

reg         reg_we = 0;
reg  [6:0]  reg_addr = 0;
reg  [15:0] reg_data = 0;

wire [9:0]  pal_addr, oam_addr;
reg  [15:0] pal_q = 0, oam_q = 0;
reg  [15:0] pal [0:1023];
reg  [15:0] oam [0:1023];
always @(posedge clk) begin
	pal_q <= pal[pal_addr];
	oam_q <= oam[oam_addr];
end

renderer_2d renderer_2d (
	.clk(clk),
	.reset(reset),
	.pixel_ce(1'b1),
	.px(px),
	.py(py),
	.on(on),
	.rgb555(rgb555),
	.reg_we(reg_we),
	.reg_addr(reg_addr),
	.reg_data(reg_data),
	.pal_addr(pal_addr),
	.pal_data(pal_q),
	.oam_addr(oam_addr),
	.oam_data(oam_q),
	.v_req(ea_v_req),
	.v_addr(ea_v_addr),
	.v_len(ea_v_len),
	.v_ready(a_ready),
	.v_bs_valid(a_bs_valid),
	.v_bs_data(a_bs_data),
	.d3_req(ea_d3_req),
	.d3_addr(ea_d3_addr),
	.d3_len(ea_d3_len),
	.d3_ready(g3r_ready),
	.d3_bs_valid(g3r_bs_valid),
	.d3_bs_data(g3r_bs_data),
	.d3_present(1'b1),
	.obj_base(20'h1_0000)
);

//------------------------------------------------------------------
// helpers
//------------------------------------------------------------------
localparam [9:0] A_FIFO = 10'h000, A_GXSTAT = 10'h200;

task wr(input [31:0] word);
	begin
		@(negedge clk);
		gx_we   = 1;
		gx_addr = A_FIFO;
		gx_data = word;
		@(negedge clk);
		gx_we = 0;
	end
endtask

task op(input [7:0] code);
	begin
		wr({24'd0, code});
	end
endtask

task idle_gx;
	begin
		guard = 0;
		gx_addr = A_GXSTAT;
		#1;
		while (gx_rdata[0] && guard < 2000) begin
			@(negedge clk);
			#1;
			guard = guard + 1;
		end
		gx_addr = A_FIFO;
		#1;
	end
endtask

task wr_reg(input [6:0] a, input [15:0] d);
	begin
		@(posedge clk);
		reg_we   <= 1'b1;
		reg_addr <= a;
		reg_data <= d;
		@(posedge clk);
		reg_we   <= 1'b0;
	end
endtask

task wr_cnt(input [3:0] a, input [7:0] d);
	begin
		@(posedge clk);
		vcnt_we   <= 1'b1;
		vcnt_addr <= a;
		vcnt_data <= d;
		@(posedge clk);
		vcnt_we <= 1'b0;
	end
endtask

// show one displayed line at x and sample what the composer port drives
task sample(input [7:0] x, input [7:0] y, output [15:0] v);
	begin
		py = y;
		px = x;
		on = 1'b1;
		@(posedge clk);
		#1 v = rgb555;
	end
endtask

reg [15:0] v;

//------------------------------------------------------------------
// measurement: cycles the 3D merge pass spends on each line, recorded per
// line rather than averaged. A line is four 64-halfword burst reads of the
// frame plus the composite, which is ~315 clocks; the first line is
// recorded separately because it can collide with a 2D BG fetch and then
// says nothing about the merge's own cost.
//------------------------------------------------------------------
integer merge_cycles = 0;
integer merge_lines  = 0;
integer merge_now    = 0;
integer merge_best   = 1 << 30;
integer merge_worst  = 0;
reg [4:0] f_last = 5'd0;
always @(posedge clk) begin
	if (renderer_2d.fstate == 5'd24) begin
		merge_cycles = merge_cycles + 1;
		merge_now    = merge_now + 1;
		if (f_last == 5'd23) merge_lines = merge_lines + 1;
	end else if (f_last == 5'd24 && merge_now != 0) begin
		if (merge_now < merge_best)  merge_best  = merge_now;
		if (merge_now > merge_worst) merge_worst = merge_now;
		$display("  merge for one line: %0d clocks", merge_now);
		merge_now = 0;
	end
	f_last = renderer_2d.fstate;
end

//------------------------------------------------------------------
// stimulus
//------------------------------------------------------------------
localparam [15:0] WHITE    = 16'h7FFF;
localparam [15:0] BACKDROP = 16'h001F;   // palette 0

initial begin
	sdram_model.clear();
	for (i = 0; i < 1024; i = i + 1) begin
		pal[i] = 16'h0000;
		oam[i] = 16'h4000;   // every sprite affine: skipped (M3)
	end
	pal[0] = BACKDROP;

	repeat (4) @(negedge clk);
	reset = 1'b0;
	repeat (2) @(negedge clk);

	// bank A (128 KB) becomes the 3D frame: enable + MST=2, offset 0
	wr_cnt(4'd0, 8'h82);
	// engine A shows only the 3D layer (DISP3DCNT bit 0, priority = BG0CNT[1:0])
	wr_reg(7'h00, 16'h0000);   // DISPCNT: nothing but the 3D layer
	wr_reg(7'h60, 16'h0001);   // DISP3DCNT: enable 3D

	// ---- submit one triangle: (0,0) (63.75,0) (0,47.75) ---------------
	// viewport 256x192 maps 4.12 (-1,-1) to (0,0), so a 63x47 wedge sits in
	// the top-left corner where line 0 pixels are easy to reason about
	op(8'h10); wr(32'h0000_0000);   // MTX_MODE = projection
	op(8'h15);                      // MTX_IDENTITY
	op(8'h60); wr(32'hBF_FF_00_00); // VIEWPORT
	op(8'h10); wr(32'h0000_0003);   // MTX_MODE = modelview
	op(8'h15);                      // MTX_IDENTITY
	op(8'h20); wr(32'h0000_00FF);   // COLOR = white
	op(8'h40); wr(32'h0000_0000);   // BEGIN_VTXS = triangles
	op(8'h25); wr(32'hF000_F000);   // VTX_XY (-1.0, -1.0) -> (0, 0)
	op(8'h25); wr(32'hF800_F000);   // VTX_XY (-0.5, -1.0) -> (63.75, 0)
	op(8'h25); wr(32'hF000_F800);   // VTX_XY (-1.0, -0.5) -> (0, 47.75)
	idle_gx;
	// let the rasterizer drain through the real memory chain; every pixel
	// is a full SDRAM write, so wait for the fill to finish instead of
	// guessing a cycle count (a short wait leaves writes in flight and they
	// then compete with the line fetch being measured)
	// drain = the frame's pixels have landed in SDRAM. Waiting on the write
	// count (not on an idle raster) also covers the vertices arriving late
	// from the command engine, and keeps the raster from competing with the
	// line fetch that is measured below.
	guard = 0;
	while (sdram_model.n_write < 1470 && guard < 300000) begin
		@(posedge clk);
		guard = guard + 1;
	end
	// let the last pixels settle (no new write for 1000 clocks)
	stall = 0;
	prev_wr = sdram_model.n_write;
	while (stall < 1000 && guard < 300000) begin
		@(posedge clk);
		guard = guard + 1;
		if (sdram_model.n_write == prev_wr) stall = stall + 1;
		else begin stall = 0; prev_wr = sdram_model.n_write; end
	end
	check(sdram_model.n_write >= 1470, "the whole triangle reached SDRAM");


	$display("  frame writes committed to SDRAM: %0d (%0d ACTIVE, %0d PRE)",
	         sdram_model.n_write, sdram_model.n_act, sdram_model.n_pre);
	check(sdram_model.errs == 0, "the memory chain ran without a protocol error");

	// ---- a displayed frame, then blanking, so line 0 is fetched with the
	//      triangle already in VRAM (the renderer fetches ahead of display)
	for (i = 0; i < 8; i = i + 1) begin
		py = 8'd0;
		px = 8'd0;
		on = 1'b1;
		@(posedge clk);
		py = 8'd5;
		@(posedge clk);
	end
	on  = 1'b0;
	px  = 8'hFF;
	py  = 8'hFF;
	repeat (7000) @(posedge clk);

	// ---- line 0: inside the wedge white, outside the backdrop ----------
	sample(8'd1,  8'd0, v);
	check(v === WHITE, "3D pixel inside the triangle reaches the screen");
	sample(8'd10, 8'd0, v);
	check(v === WHITE, "pixel further inside is covered too");
	sample(8'd100, 8'd0, v);
	check(v === BACKDROP, "pixel outside the triangle stays backdrop");
	// line 100 was never fetched, so the buffer still holds line 0: one
	// line of latency is the design, and no retro-composite of the 3D frame
	// happens into a line that has already been scanned out
	sample(8'd1, 8'd100, v);
	check(v === WHITE, "unfetched line still shows the fetched line 0");
	on = 1'b0;

	// ---- turning the layer off takes the frame off the screen ----------
	wr_reg(7'h60, 16'h0000);
	repeat (4) @(posedge clk);
	for (i = 0; i < 8; i = i + 1) begin
		py = 8'd0;  px = 8'd0;  on = 1'b1; @(posedge clk);
		py = 8'd5;              @(posedge clk);
	end
	on = 1'b0;
	repeat (7000) @(posedge clk);
	sample(8'd1, 8'd0, v);
	check(v === BACKDROP, "DISP3DCNT bit 0 clear hides the 3D layer");
	on = 1'b0;

	// ---- the frame really is a 256x192 16-bpp image at the 3D bank -----
	// pixel (x,0) is written at frame byte offset (0*256 + x)*2; there is
	// one address unit per byte, so the arbiter halves that offset into
	// halfword slot x of bank A's row 0 (VRAM_SDRAM_BASE sits on a row
	// edge). One stored halfword per pixel, back to back: a burst read of
	// a line is the pixels in order with nothing to skip. The wedge covers
	// line 0 from column 0 up to the hypotenuse (x = 63.08 on the centre
	// line), so the covered run ends at column 61.
	check(sdram_model.mem[0] === {1'b1, 15'h7FFF}, "vertex (0,0) counts as covered");
	check(sdram_model.mem[1] === {1'b1, 15'h7FFF},
	      "pixel (1,0) is the very next halfword, no hole between pixels");
	check(sdram_model.mem[61] === {1'b1, 15'h7FFF},
	      "the covered run on line 0 reaches column 61");
	check(sdram_model.mem[62] === 16'h0000,
	      "column 62 is past the hypotenuse, so its halfword stays clear");
	check(sdram_model.mem[200] === 16'h0000, "pixel (200,0) is never written");

	// ---- throughput, recorded rather than asserted tightly -------------
	$display("  3D merge: best %0d / worst %0d clocks per line over %0d lines (line period 1280)",
	         (merge_best == (1 << 30)) ? 0 : merge_best, merge_worst, merge_lines);
	check(merge_lines > 0, "the 3D merge ran at least once");
	// the merge is four burst reads per line: it has to fit inside the line
	// period with room for the sprite/BG passes and their fetches
	check(merge_best < 1280,
	      "an uncontended 3D merge fits inside one line period");
	check(merge_worst < 4000,
	      "even a contended merge stays well under the old per-access cost");

	if (errors == 0) $display("tb_3d_path: PASS");
	else             $display("tb_3d_path: FAIL (%0d errors)", errors);
	$finish;
end

initial begin
	#40_000_000;   // the real SDRAM chain is far slower than a flat model
	$display("tb_3d_path: FAIL (timeout)");
	$finish;
end

endmodule
