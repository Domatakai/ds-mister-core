//============================================================================
// NDS MiSTer Test — MT-32-pi LCD overlay
//
// MT-32-pi drives an SSD1306 OLED over the same I2C bus the core uses to
// hand it the synth mode. sys/mt32pi.sv squirts that display's framebuffer
// at the core as a serial bitstream in video timing: one pixel per CE, with
// src_en marking the pixels that belong to the panel (128x64 bits, or
// 128x32 on a smaller panel).
//
// This module captures the stream into a small 1-bit framebuffer and draws
// it as a black/white box over the picture — the scaler then enlarges the
// whole 256x384 frame, so on a TV each OLED dot lands on several screen
// pixels and the Pi's status text ("MT-32: ROM OK") is readable without
// touching the game image.
//
// Size: 1x (128x64, exact device pixels, half the picture width) or 2x
// (256x128, the full width). At 2x two adjacent output pixels and two
// adjacent lines read the same framebuffer bit, so the read address is just
// the coordinate shifted right by one and no separate scaler, line buffer or
// replication stage is needed.
//
// Corner: top/bottom x left/right, from the OSD. Only the box origin moves;
// the capture side does not care where the box is drawn. At 2x the box is as
// wide as the frame, so the left and right corners coincide — the vertical
// choice still applies.
//
// The capture side runs on its own raster counters (a pixel is captured when
// src_de && src_en, a row starts after W captures, everything restarts on the
// rising edge of src_vs), so it does not care where in the frame the panel
// window sits. The display side reads the framebuffer through its registered
// output, which costs one CE: de/hs/vs leave the module two CEs after they
// arrive, and each output pixel is paired with the framebuffer bit captured
// for its own coordinate.
//============================================================================
module lcd_overlay #(
	parameter integer W = 128,     // panel width  in pixels
	parameter integer H = 64,      // panel height in pixels
	parameter integer H_ACT = 256, // composed frame width,  for the corners
	parameter integer V_ACT = 384  // composed frame height, for the corners
)(
	input             clk,
	input             ce,        // pixel clock enable
	input             reset,
	input             enable,    // draw the panel over the picture
	input             scale2x,   // 0 = 1x (128x64), 1 = 2x (256x128)
	input      [1:0]  corner,    // 0 = top left, 1 = top right,
	                             // 2 = bottom left, 3 = bottom right

	// the panel stream, delivered at video timing by sys/mt32pi.sv
	input             src_de,
	input             src_en,
	input             src_pix,
	input             src_vs,

	// destination pixel, aligned with de
	input      [8:0]  x,
	input      [8:0]  y,
	input             de,
	input             hs,
	input             vs,
	input      [15:0] rgb_in,    // RGB555 from the composer/palette

	output reg [15:0] rgb_o,
	output reg        de_o,
	output reg        hs_o,
	output reg        vs_o
);

	localparam integer AW = $clog2(W * H);
	localparam integer CW = $clog2(W);
	localparam integer RW = $clog2(H);

	localparam [15:0] ON_PIX  = 16'h7FFF;   // panel lit  -> white
	localparam [15:0] OFF_PIX = 16'h0000;   // panel dark -> black

	//------------------------------------------------------------------
	// box geometry
	//------------------------------------------------------------------
	// the panel and frame sizes are integer parameters; the geometry here is
	// ten bits wide, so each is taken at that width (all of them fit)
	wire [9:0] box_w = scale2x ? (W[9:0] << 1) : W[9:0];
	wire [9:0] box_h = scale2x ? (H[9:0] << 1) : H[9:0];

	wire [9:0] org_x = (corner[0] && (box_w < H_ACT[9:0])) ? (H_ACT[9:0] - box_w) : 10'd0;
	wire [9:0] org_y = corner[1] ? (V_ACT[9:0] - box_h) : 10'd0;

	wire [9:0] edge_x = org_x + box_w;
	wire [9:0] edge_y = org_y + box_h;

	//------------------------------------------------------------------
	// framebuffer: W*H bits, packed eight dots to a byte
	//------------------------------------------------------------------
	// An M10K block has no 1-bit mode (its narrowest is 1024x10), so a plain
	// `reg [0:0] fb [0:8191]` cannot be a RAM: Quartus built it out of 8,192
	// flip-flops and the read was a 8,192:1 mux. Eight dots per byte makes the
	// array 1024x8, which is one block, and the dot within the byte is a
	// 8:1 select on the read data.
	//
	// The panel rows are whole bytes (W = 128 on both panel sizes), so a byte
	// boundary always falls on a column boundary and the write index is just
	// the pixel address shifted right by three. Capture therefore commits a
	// row eight dots at a time rather than one at a time; the frame after a
	// capture is complete either way, and tb_lcd_overlay only inspects that
	// frame.
	localparam integer BW = (W * H) / 8;
	reg  [7:0]        fb [0:BW-1];

	//------------------------------------------------------------------
	// capture: own raster counters, restarted by the frame marker
	//------------------------------------------------------------------
	reg        src_vs_d = 1'b0;
	wire       frame_t  = src_vs & ~src_vs_d;   // rising edge = new frame

	reg [CW-1:0] cap_col  = {CW{1'b0}};
	reg [RW-1:0] cap_row  = {RW{1'b0}};
	reg          cap_done = 1'b0;               // whole panel captured
	reg  [7:0]   cap_byte = 8'h00;              // dots of the byte being filled

	// the dot's place in the byte: bit 0 is the first dot of the group, which
	// is the order the display side picks the bit back out in
	wire [7:0]   cap_dot  = {7'd0, src_pix} << cap_col[2:0];

	wire [AW-1:0] cap_addr = {cap_row, cap_col};

	always @(posedge clk) begin
		if (reset) begin
			cap_col  <= {CW{1'b0}};
			cap_row  <= {RW{1'b0}};
			cap_done <= 1'b0;
		end else if (ce) begin
			src_vs_d <= src_vs;
			if (frame_t) begin
				cap_col  <= {CW{1'b0}};
				cap_row  <= {RW{1'b0}};
				cap_done <= 1'b0;
			end else if (src_de && src_en && !cap_done) begin
				cap_byte <= (cap_col[2:0] == 3'd0) ? cap_dot : (cap_byte | cap_dot);
				// the byte this dot completes, on the eighth dot of the row
				if (cap_col[2:0] == 3'd7)
					fb[cap_addr[AW-1:3]] <= cap_byte | cap_dot;
				if (cap_col == W - 1) begin
					cap_col <= {CW{1'b0}};
					if (cap_row == H - 1) cap_done <= 1'b1;
					else                   cap_row <= cap_row + 1'b1;
				end else begin
					cap_col <= cap_col + 1'b1;
				end
			end
		end
	end

	//------------------------------------------------------------------
	// display: registered read, one-CE pipeline
	//------------------------------------------------------------------
	// Panel coordinate for this pixel: offset by the box origin, then the
	// low address bits at 1x or every second one on both axes at 2x. Out of
	// the box the address is meaningless, but the bits read stay inside the
	// array and the box test below gates what is drawn.
	wire [9:0] ix = {1'b0, x} - org_x;
	wire [9:0] iy = {1'b0, y} - org_y;

	wire [CW-1:0] rd_px = scale2x ? ix[CW:1] : ix[CW-1:0];
	wire [RW-1:0] rd_py = scale2x ? iy[RW:1] : iy[RW-1:0];

	// address straight from the pixel counters, data out one CE later
	wire [AW-1:0] rd_addr = {rd_py, rd_px};
	// the byte the dot lives in, and which of its eight bits it is; both are
	// registered so the dot still arrives with the pixel it belongs to
	reg  [7:0]    rd_byte = 8'h00;
	reg  [2:0]    rd_sel  = 3'd0;
	wire          rd_bit  = rd_byte[rd_sel];

	reg [8:0]  d_x   = 9'd0;
	reg [8:0]  d_y   = 9'd0;
	reg        d_de  = 1'b0;
	reg        d_hs  = 1'b0;
	reg        d_vs  = 1'b0;
	reg [15:0] d_rgb = 16'd0;

	wire [9:0] dx10 = {1'b0, d_x};
	wire [9:0] dy10 = {1'b0, d_y};
	wire in_box = (dx10 >= org_x) && (dx10 < edge_x) &&
	              (dy10 >= org_y) && (dy10 < edge_y);

	wire [15:0] lit = rd_bit ? ON_PIX : OFF_PIX;
	wire [15:0] mix = (enable && d_de && in_box) ? lit : d_rgb;

	// The read is unconditional on purpose: Quartus will not turn a gated read
	// into a block RAM, and a pixel only advances on `ce`, so the address is
	// stable between ticks and the value captured on the tick is the one the
	// pixel pairs with.
	always @(posedge clk) begin
		rd_byte <= fb[rd_addr[AW-1:3]];
		rd_sel  <= rd_addr[2:0];
	end

	always @(posedge clk) begin
		if (reset) begin
			d_de    <= 1'b0;
			d_hs    <= 1'b0;
			d_vs    <= 1'b0;
			de_o    <= 1'b0;
			hs_o    <= 1'b0;
			vs_o    <= 1'b0;
			rgb_o   <= 16'd0;
		end else if (ce) begin
			// the panel bit for this pixel lands one cycle later, which is
			// exactly when d_* holds the pixel itself (the byte read is in the
			// block above; the dot is picked out of it combinationally)
			d_x   <= x;
			d_y   <= y;
			d_de  <= de;
			d_hs  <= hs;
			d_vs  <= vs;
			d_rgb <= rgb_in;

			rgb_o <= mix;
			de_o  <= d_de;
			hs_o  <= d_hs;
			vs_o  <= d_vs;
		end
	end

endmodule
