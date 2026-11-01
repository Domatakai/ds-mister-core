//============================================================================
// NDS MiSTer Test — 3D rasterizer
//
// Milestone M3 (first slice). Takes the screen-space vertex stream from
// `geometry_engine`, assembles triangles for the active primitive mode,
// runs triangle setup and fills the covered pixels.
//
// What is real here:
//   * Triangle assembly for TRIANGLES and TRIANGLE_STRIP, with the strip
//     sliding its window (v0,v1,v2 -> v1,v2,v3) and a mode change restarting
//     assembly so a stale window never forms a triangle.
//   * Setup: integer bounding box clipped to the 256x192 screen, signed
//     area for winding, and degenerate (zero-area) primitives dropped.
//   * Fill: every pixel centre inside the bounding box is tested against
//     the three half-plane edge functions, with one covered pixel emitted
//     per cycle as an RGB555 value and a linear 256-wide address.
//
// Pixel convention: a pixel is covered when its centre falls inside the
// triangle, with edges treated as inclusive. The DS tie-break rule and
// sub-pixel (4.12) coverage land with the span fill.
//
// Pixel delivery: each accepted pixel is presented to the VRAM bus and
// held until `px_ready`, so the arbiter's SDRAM round-trip paces the fill.
//
// Vertex intake: vertices are queued 16 deep so the geometry engine can
// keep submitting while a triangle is being filled. That queue is a stop
// gap, not a solution — this slice walks the bounding box one pixel per
// cycle, which is correct but far slower than the hardware's 15-cycle
// budget, so a dense mesh overruns it and further vertices are dropped.
// Pacing the geometry engine (and span fill) is the throughput slice.
//
// What is not here yet (later M3 slices):
//   * QUADS / QUAD_STRIP primitive modes — vertices are consumed but no
//     triangle is formed, so nothing is drawn for them.
//   * W-buffer/depth, toon shading, edge marking, fog and alpha test —
//     every covered pixel is written opaque, and the blend unit that
//     would turn per-vertex alpha into a real alpha test is later work.
//
// Output colour convention: px_rgb555 = {1'b1, r5, g5, b5}. Bit 15 is the
// coverage/alpha bit of the 3D colour word; `renderer_2d` treats a frame
// halfword with bit 15 clear as transparent while it composites the 3D
// layer, so nothing needs to pre-clear the frame for black to draw.
//============================================================================
module raster_engine (
	input            clk,
	input            reset,

	input            vtx_valid,
	input signed [31:0] vtx_x,     // 4.12 fixed, ±2048 px
	input signed [31:0] vtx_y,
	input      [7:0] vtx_color,
	input      [1:0] vtx_poly,

	// pixel request toward VRAM — held until the arbiter accepts it
	output reg       px_valid,
	output reg [15:0] px_addr,      // linear pixel index (y*256+x)
	output reg [15:0] px_rgb555,
	input            px_ready
);

localparam [1:0] S_IDLE  = 2'd0,
                 S_SETUP = 2'd1,
                 S_FILL  = 2'd2,
                 S_EMIT  = 2'd3;

localparam [1:0] P_TRIANGLES = 2'd0,
                 P_STRIP     = 2'd2;

//------------------------------------------------------------------
// Vertex queue — {poly(2), colour(8), y(32), x(32)}
//------------------------------------------------------------------
localparam VF_POLY = 73, VF_COL = 64, VF_Y = 32, VF_X = 0;

reg [73:0] vfifo [0:15];
reg  [3:0] vf_wr = 4'd0;
reg  [3:0] vf_rd = 4'd0;
reg  [4:0] vf_cnt = 5'd0;

reg  [1:0]  state = S_IDLE;

wire       vf_empty = (vf_cnt == 5'd0);
wire       vf_full  = (vf_cnt == 5'd16);
wire       vf_push  = vtx_valid && !vf_full;
wire       vf_pop   = (state == S_IDLE) && !vf_empty;
wire [73:0] vf_head = vfifo[vf_rd];

// triangle vertices, integer screen coordinates
reg signed [15:0] ax = 0, ay = 0;
reg signed [15:0] bx = 0, by = 0;
reg signed [15:0] cx = 0, cy = 0;

reg  [15:0] vertex_count = 0;
reg  [15:0] cur_rgb = 16'h7FFF;
reg  [1:0]  prim = P_TRIANGLES;

// a mode change restarts assembly, so a stale window never forms a triangle
wire [1:0]  q_poly = vf_head[VF_POLY:VF_POLY-1];
wire [7:0]  q_col  = vf_head[VF_COL+7:VF_COL];
wire [15:0] vcount = (q_poly != prim) ? 16'd0 : vertex_count;

// fill state
// the fill window: the y start needs no register of its own, because py is
// loaded with it in S_SETUP and only ever counts up from there
reg signed [15:0] bbox_x0 = 0, bbox_x1 = 0, bbox_y1 = 0;
reg signed [15:0] px = 0, py = 0;
reg signed [31:0] area = 0;

// the queued vertex, in integer pixels. The screen is 256 wide, so the low
// 16 bits of the fixed-point shift are the whole coordinate
wire signed [31:0] qx32 = $signed(vf_head[VF_X+31:VF_X]) >>> 12;
wire signed [31:0] qy32 = $signed(vf_head[VF_Y+31:VF_Y]) >>> 12;
wire signed [15:0] qvx  = qx32[15:0];
wire signed [15:0] qvy  = qy32[15:0];

// split the queued 8-bit colour into a full-range RGB555 value
wire [4:0] q_r5 = {q_col[7:5], q_col[7:6]};
wire [4:0] q_g5 = {q_col[4:2], q_col[4:3]};
wire [4:0] q_b5 = {q_col[1:0], q_col[1:0], q_col[1]};

//------------------------------------------------------------------
// Setup helpers — bounding box + signed area from the live vertices
//------------------------------------------------------------------
wire signed [15:0] min_x = (ax < bx) ? ((ax < cx) ? ax : cx) : ((bx < cx) ? bx : cx);
wire signed [15:0] max_x = (ax > bx) ? ((ax > cx) ? ax : cx) : ((bx > cx) ? bx : cx);
wire signed [15:0] min_y = (ay < by) ? ((ay < cy) ? ay : cy) : ((by < cy) ? by : cy);
wire signed [15:0] max_y = (ay > by) ? ((ay > cy) ? ay : cy) : ((by > cy) ? by : cy);

wire signed [15:0] clamp_x0 = (min_x < 0) ? 16'sd0 : (min_x > 16'sd255) ? 16'sd255 : min_x;
wire signed [15:0] clamp_x1 = (max_x < 0) ? 16'sd0 : (max_x > 16'sd255) ? 16'sd255 : max_x;
wire signed [15:0] clamp_y0 = (min_y < 0) ? 16'sd0 : (min_y > 16'sd191) ? 16'sd191 : min_y;
wire signed [15:0] clamp_y1 = (max_y < 0) ? 16'sd0 : (max_y > 16'sd191) ? 16'sd191 : max_y;

wire signed [31:0] edge_ab_x = ($signed(bx) - $signed(ax)) * 2;
wire signed [31:0] edge_ab_y = ($signed(by) - $signed(ay)) * 2;
wire signed [31:0] edge_bc_x = ($signed(cx) - $signed(bx)) * 2;
wire signed [31:0] edge_bc_y = ($signed(cy) - $signed(by)) * 2;
wire signed [31:0] edge_ca_x = ($signed(ax) - $signed(cx)) * 2;
wire signed [31:0] edge_ca_y = ($signed(ay) - $signed(cy)) * 2;

wire signed [31:0] area_w = ($signed(bx) - $signed(ax)) * ($signed(cy) - $signed(ay)) -
                           ($signed(by) - $signed(ay)) * ($signed(cx) - $signed(ax));

wire bbox_ok = (clamp_x0 <= clamp_x1) && (clamp_y0 <= clamp_y1) && (area_w != 32'sd0);

//------------------------------------------------------------------
// Edge test at the centre of the current pixel: doubled coordinates keep
// the half-pixel offset in integer arithmetic (max 512 x 512 products).
//------------------------------------------------------------------
reg signed [31:0] px2, py2, ax2, ay2;
reg signed [31:0] e0, e1, e2;
reg               covered;

always @(*) begin
	ax2 = $signed(ax) * 2;
	ay2 = $signed(ay) * 2;
	px2 = ($signed({16'd0, px}) * 2) + 32'sd1;
	py2 = ($signed({16'd0, py}) * 2) + 32'sd1;

	e0 = edge_ab_x * (py2 - ay2) - edge_ab_y * (px2 - ax2);
	e1 = edge_bc_x * (py2 - ($signed(by) * 2)) - edge_bc_y * (px2 - ($signed(bx) * 2));
	e2 = edge_ca_x * (py2 - ($signed(cy) * 2)) - edge_ca_y * (px2 - ($signed(cx) * 2));

	covered = (area > 0) ? ((e0 >= 0) && (e1 >= 0) && (e2 >= 0))
	                     : ((e0 <= 0) && (e1 <= 0) && (e2 <= 0));
end

//------------------------------------------------------------------
// Vertex queue, triangle assembly, setup and fill
//------------------------------------------------------------------
always @(posedge clk) begin
	if (reset) begin
		state        <= S_IDLE;
		vertex_count <= 16'd0;
		prim         <= P_TRIANGLES;
		cur_rgb      <= 16'h7FFF;
		px_valid     <= 1'b0;
		px_addr      <= 16'd0;
		px_rgb555    <= 16'd0;
		vf_wr        <= 4'd0;
		vf_rd        <= 4'd0;
		vf_cnt       <= 5'd0;
		ax <= 0; ay <= 0; bx <= 0; by <= 0; cx <= 0; cy <= 0;
		px <= 0; py <= 0; area <= 0;
		bbox_x0 <= 0; bbox_x1 <= 0; bbox_y1 <= 0;
	end else begin
		// px_valid is only cleared by the handshake in S_EMIT (and reset),
		// so a request stays asserted until the arbiter accepts it.
		if (vf_push) begin
			vfifo[vf_wr] <= {vtx_poly, vtx_color, vtx_y, vtx_x};   // 2+8+32+32
			vf_wr        <= vf_wr + 4'd1;
		end

		case (state)
		S_IDLE: begin
			if (!vf_empty) begin
				vf_rd  <= vf_rd + 4'd1;
				prim   <= q_poly;
				cur_rgb <= {q_r5, q_g5, q_b5};

				case (q_poly)
				P_TRIANGLES: begin
					case (vcount)
					16'd0: begin ax <= qvx; ay <= qvy; vertex_count <= 16'd1; end
					16'd1: begin bx <= qvx; by <= qvy; vertex_count <= 16'd2; end
					default: begin
						cx <= qvx; cy <= qvy;
						vertex_count <= 16'd0;
						state <= S_SETUP;
					end
					endcase
				end

				P_STRIP: begin
					case (vcount)
					16'd0: begin ax <= qvx; ay <= qvy; vertex_count <= 16'd1; end
					16'd1: begin bx <= qvx; by <= qvy; vertex_count <= 16'd2; end
					16'd2: begin
						// first triangle of the strip: (A,B,C)
						cx <= qvx; cy <= qvy;
						vertex_count <= 16'd3;
						state <= S_SETUP;
					end
					default: begin
						// window slides: (A,B,C) -> (B,C,new)
						cx <= qvx;        cy <= qvy;
						ax <= bx;         ay <= by;
						bx <= cx;         by <= cy;
						vertex_count <= 16'd3;
						state <= S_SETUP;
					end
					endcase
				end

				default: begin
					// QUADS / QUAD_STRIP: consumed, not drawn yet
					vertex_count <= 16'd0;
				end
				endcase
			end
		end

		S_SETUP: begin
			area    <= area_w;
			bbox_x0 <= clamp_x0;
			bbox_x1 <= clamp_x1;
			bbox_y1 <= clamp_y1;
			px      <= clamp_x0;
			py      <= clamp_y0;
			state   <= bbox_ok ? S_FILL : S_IDLE;
		end

		S_FILL: begin
			if (covered) begin
				// hand the pixel to the VRAM master and wait for its ack
				px_valid  <= 1'b1;
				px_addr   <= ({8'd0, py[7:0]} << 8) | {8'd0, px[7:0]};
				// coverage bit 15 set: the compositor treats a clear bit as
				// transparent, so a black polygon still draws
				px_rgb555 <= {1'b1, cur_rgb[14:0]};
				state     <= S_EMIT;
			end else if (px >= bbox_x1) begin
				px <= bbox_x0;
				if (py >= bbox_y1) state <= S_IDLE;
				else               py <= py + 16'sd1;
			end else begin
				px <= px + 16'sd1;
			end
		end

		S_EMIT: begin
			if (px_ready) begin
				px_valid <= 1'b0;
				state    <= S_FILL;
				if (px >= bbox_x1) begin
					px <= bbox_x0;
					if (py >= bbox_y1) state <= S_IDLE;
					else               py <= py + 16'sd1;
				end else begin
					px <= px + 16'sd1;
				end
			end
		end

		default: state <= S_IDLE;
		endcase

		vf_cnt <= vf_cnt + (vf_push ? 5'd1 : 5'd0) - (vf_pop ? 5'd1 : 5'd0);
	end
end

wire _unused = &{1'b0};
	// Read the sink so the analyser does not call it "assigned but never read"
	// (warning 10036). The branch cannot be taken and synthesises to nothing:
	// measured on a throwaway module, the warning goes from 1 to 0 with this
	// line and the netlist is unchanged.
	always @(*) if (_unused) begin end


endmodule
