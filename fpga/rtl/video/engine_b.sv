//============================================================================
// NDS MiSTer Test — 2D engine B (bottom screen) — STUB
//
// Engine B drives the touch screen: same mode set as A minus the
// capture unit, plus its own OBJ palette (milestone M2). The stub
// draws a dot grid so the bottom screen is recognisable on hardware.
//============================================================================
module engine_b (
	input            clk,
	input      [7:0] x,
	input      [7:0] y,
	input            on,
	output reg [15:0] rgb555
);

always @(*) begin
	if (!on) begin
		rgb555 = 16'h0000;
	end else if (x < 8'd4 || y < 8'd4 || x > 8'd251 || y > 8'd187) begin
		rgb555 = {5'd10, 5'd10, 5'd12};                 // border
	end else if (x[3:0] == 0 && y[3:0] == 0) begin
		rgb555 = {5'd20, 5'd20, 5'd22};                 // dot grid
	end else begin
		rgb555 = {5'd4, 5'd4, 5'd6};                    // backdrop
	end
end

wire _unused = &{1'b0, clk};

endmodule
