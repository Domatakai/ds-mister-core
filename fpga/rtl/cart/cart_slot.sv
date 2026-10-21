//============================================================================
// NDS MiSTer Test — Slot-1 cartridge interface
//
// Responsibilities (growing through the milestones):
//   M1  stream the .nds from the HPS into SDRAM, capture the header
//   M4  save types (EEPROM/FLASH/FRAM/NAND) with .sav read/write,
//       save erase, cart data reads back toward the CPUs
//
// Region policy: none. The header's game code is captured for the
// diagnostics overlay only — every cart boots regardless of region.
//============================================================================
module cart_slot (
	input            clk,
	input            reset,

	// HPS download stream (F1 -> .nds, index 1). WIDE=1: one 16-bit
	// word per write, ioctl_addr counts bytes and steps by 2.
	input            ioctl_download,
	input     [26:0] ioctl_addr,
	input     [15:0] ioctl_dout,
	input            ioctl_wr,
	input     [15:0] ioctl_index,

	// write port towards SDRAM (ROM window at 0x000000)
	output reg [24:0] mem_addr,
	output reg [15:0] mem_din,
	output reg        mem_wr,
	input             mem_wr_done,

	// OSD-driven save control
	input             erase_save,
	input       [2:0] save_type,

	output reg        cart_loaded
);

localparam ROM_BASE  = 25'h000000;
localparam SAVE_BASE = 25'h280000;

wire is_rom = ioctl_index[3:0] == 4'd1;

//------------------------------------------------------------------
// In wide mode every write is a full ROM word; capture the first
// eight words (16 header bytes: title + game code + maker code).
//------------------------------------------------------------------
reg [15:0] hdr_words [7:0];

always @(posedge clk) begin
	mem_wr <= 0;

	if (ioctl_wr && is_rom) begin
		mem_wr   <= 1;
		mem_din  <= ioctl_dout;
		mem_addr <= ROM_BASE + {2'b00, ioctl_addr[26:2]};

		if (ioctl_addr < 27'd16) hdr_words[ioctl_addr[3:1]] <= ioctl_dout;
	end

	if (mem_wr && mem_wr_done) mem_wr <= 0;
end

//------------------------------------------------------------------
// Load lifecycle
//------------------------------------------------------------------
reg dl_d = 0;
always @(posedge clk) begin
	dl_d <= ioctl_download;
	if (ioctl_download && !dl_d) cart_loaded <= 0;
	if (!ioctl_download && dl_d) cart_loaded <= 1;
	if (reset) cart_loaded <= 0;
end

//------------------------------------------------------------------
// Save control
//
// TODO(M4): erase_save pulses a state machine that zeroes SAVE_BASE
// for the detected type's size; sd_rd/sd_wr from hps_io move .sav
// sectors in and out of the same region. save_type currently overrides
// autodetection from the header byte at 0x140.
//------------------------------------------------------------------
wire [24:0] save_base = SAVE_BASE;
wire [2:0]  save_kind = save_type;
wire        erase_req = erase_save;

wire _unused = &{1'b0, save_base, save_kind, erase_req, hdr_words[0], hdr_words[7]};

endmodule
