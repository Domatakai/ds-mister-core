//============================================================================
// NDS MiSTer Test — Nintendo DS core for MiSTer FPGA
// Core top level (module emu), following the MiSTer framework interface.
//
// This file is derived from MiSTer-devel/Template_MiSTer (GPL v2+):
//   https://github.com/MiSTer-devel/Template_MiSTer
//
// Status bit allocation (128-bit status word from hps_io). The OSD Lab on
// the project website is the menu prototype — keep the two in sync.
//
//   [0]     reset core (R[0], main menu)
//   [127]   soft reset (T[127])
//   [126]   erase save data (T[126], action)
//   [125]   disable all cheats (T[125], action)
//   [4:2]   save type        (Auto/EEPROM512K/EEPROM8K/FLASH512K/FLASH1M/FRAM/NAND)
//   [7:5]   screen layout    (Stacked/Side/Top only/Bottom only)
//   [9:8]   rotation         (0/90/180/270)
//   [12:10] aspect ratio     (Original/Full/ARC1/ARC2)
//   [14:13] scanlines        (VGA_SL 0..3)
//   [15]    swap screens
//   [18:16] brightness       (1..5)
//   [53:52] refresh rate     (Native 59.82 / 59.95 / 60.00)
//   [22:19] master volume    (0%..100%)
//   [24:23] output mix       (Stereo/Mono/Headphones)
//   [26:25] I2S latency      (1/2/4 frames)
//   [27]    SPU sync
//   [28]    slot-1 BIOS      (HLE/Real)
//   [29]    firmware         (HLE/Flash dump)
//   [30]    skip intro logo
//   [32:31] region           (Auto/NTSC-U/NTSC-J/PAL) — informational only:
//                            the core is region-free, any cart boots.
//   [34:33] stylus mode
//   [36:35] microphone
//   [37]    rumble pak
//   [39:38] pad profile
//   [41:40] core speed       (100/150/200/Max %)
//   [43:42] frameskip
//   [44]    auto frameskip
//   [46:45] rewind buffer
//   [47]    show FPS
//   [48]    frame graph
//   [49]    bus activity LEDs
//   [51:50] log level
//   [55:54] stylus tap button(L2/R2/L3/R3)
//   [56]    face buttons     (standard / swapped)
//   [57]    shoulders        (normal / swapped)
//   [59:58] CPU overclock    (Normal / ARM7 x2 / ARM7 x4)
//   [62:60] video filter     (Off / Soft / Smooth / Sharp)
//   [65:63] palette          (Original / DS LCD / Vivid / Warm / Cool / Grayscale)
//   [67:66] audio filter     (Off / Warm / Bright / Bass)
//   [69:68] stereo width     (Off / Soft / Strong)
//============================================================================
module emu
(
`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////
assign ADC_BUS = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// DDRAM is driven by the cart slot (ROM image in DDR3)
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;
assign AUDIO_S   = 1; // signed samples from the SPU
assign AUDIO_MIX = 0;
assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;
//////////////////////////////////////////////////////////////////

`include "build_id.v"

//------------------------------------------------------------------
// OSD menu definition (drawn by sys/osd.sv, values arrive in status[])
//------------------------------------------------------------------
localparam [13887:0] CONF_STR = {   // 1730 string bytes + 6-char `BUILD_DATE
                                      // (sys/build_id.tcl: %y%m%d as a quoted string)
"NDS MiSTer Test;;",
"-;",
"P1,Cartridge;",
"P1F1,NDS;",
"P1-;",
"P1O[4:2],Save type,Auto,EEPROM 512K,EEPROM 8K,FLASH 512K,FLASH 1M,FRAM,NAND;",
"P1T[126],Erase save data;",
"-;",
"P2,Video;",
"P2O[7:5],Screen layout,Stacked,Side by side,Top only,Bottom only;",
"P2O[9:8],Rotation,0,90,180,270;",
"P2O[12:10],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
"P2O[14:13],Scanlines,Off,Soft,Medium,Hard;",
"P2O[15],Swap screens,Off,On;",
"P2O[18:16],Brightness,1,2,3,4,5;",
"P2O[53:52],Refresh rate,Native 59.82,59.95,60.00;",
"P2O[62:60],Video filter,Off,Soft,Smooth,Sharp;",
"P2O[65:63],Palette,Original,DS LCD,Vivid,Warm,Cool,Grayscale;",
"-;",
"P3,Audio;",
"P3O[22:19],Master volume,0%,10%,20%,30%,40%,50%,60%,70%,80%,90%,100%;",
"P3O[24:23],Output mix,Stereo,Mono,Headphones;",
"P3O[26:25],I2S latency,1 frame,2 frames,4 frames;",
"P3O[27],SPU sync,Off,On;",
"P3O[67:66],Audio filter,Off,Warm,Bright,Bass;",
"P3O[69:68],Stereo width,Off,Soft,Strong;",
"-;",
"P4,BIOS & Input;",
"P4O[28],Slot-1 BIOS,HLE,Real;",
"P4O[29],Firmware,HLE,Flash dump;",
"P4O[30],Skip intro logo,Off,On;",
"P4O[32:31],Region,Auto,NTSC-U,NTSC-J,PAL;",
"P4-;",
"P4O[34:33],Stylus cursor,Off,D-pad,Left stick;",
"P4O[55:54],Stylus tap,L2,R2,L3,R3;",
"P4O[56],Face buttons,Standard,Swapped;",
"P4O[57],Shoulders,Normal,Swapped;",
"P4O[36:35],Microphone,Off,Button,Host device;",
"P4O[37],Rumble pak,Off,On;",
"P4O[39:38],Pad profile,Default,Left-hand,Arcade stick;",
"-;",
"P5,Emulation;",
"P5O[41:40],Core speed,100%,150%,200%,Max;",
"P5O[59:58],CPU overclock,Normal,ARM7 x2,ARM7 x4;",
"P5O[43:42],Frameskip,Off,1,2,3;",
"P5O[44],Auto frameskip,Off,On;",
"P5O[46:45],Rewind buffer,Off,5 s,15 s,30 s;",
"P5-;",
"P5-,Diagnostics;",
"P5O[47],Show FPS,Off,On;",
"P5O[48],Frame graph,Off,On;",
"P5O[49],Bus activity LEDs,Off,On;",
"P5O[51:50],Log level,Off,Errors,Verbose;",
"P5T[125],Disable all cheats;",
"-;",
"F2,CHT;",
"-;",
"T[127],Soft reset;",
"R[0],Reset core and close OSD;",
"v,0;",
"V,v",`BUILD_DATE
};

//------------------------------------------------------------------
// HPS I/O — menu, ROM download (F1 .nds), cheat file (F2 .cht),
// save file access (sd_*), joysticks, PS/2
//------------------------------------------------------------------
wire [127:0] status;
wire   [1:0] buttons;
wire         forced_scandoubler;
wire  [10:0] ps2_key;
wire  [31:0] joystick_0, joystick_1;
wire         ioctl_download;
wire  [26:0] ioctl_addr;
wire  [15:0] ioctl_dout;
wire         ioctl_wr;
wire  [15:0] ioctl_index;
wire   [0:0] sd_rd, sd_wr;
wire  [15:0] sd_buff_dout;
wire  [12:0] sd_buff_addr;
wire         sd_buff_wr;
wire   [0:0] sd_ack;
wire   [0:0] img_mounted;
wire  [63:0] img_size;
wire         ioctl_wait;   // cart slot backpressure -> HPS
wire  [15:0] stick0;       // left analog stick (stylus cursor mode)

// no SD block-device saves yet: keep HPS request inputs deasserted
assign sd_rd = 1'b0;
assign sd_wr = 1'b0;

//------------------------------------------------------------------
// F2 (.cht) text path: secondary files share the ioctl pipe, keyed by
// ioctl_index (F1 -> 1, F2 -> 2). WIDE=1 delivers two ASCII bytes per
// 16-bit word, low byte first; the high byte of an odd final word is
// zero padding and is filtered by the engine (0 is never a hex digit
// or a separator). One byte per clk_sys cycle: the HPS spaces WIDE
// words >= 16 SCK (~160 ns @100 MHz) apart vs the single cycle needed,
// so consecutive words can never collide.
//------------------------------------------------------------------
wire        cheat_dl = ioctl_download & (ioctl_index[5:0] == 6'd2);

wire        f2_wr;
wire  [7:0] f2_dout;
assign f2_wr   = cheat_dl & ioctl_wr;
assign f2_dout = ioctl_dout[7:0];

hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),
	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0), // no conditional menu entries yet (H0/d0)
	.ps2_key(ps2_key),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_l_analog_0(stick0),
	.ioctl_download(ioctl_download),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wr(ioctl_wr),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),
	.ioctl_din(16'd0),            // no save upload
	.ioctl_upload_req(1'b0),
	.ioctl_upload_index(8'd0),

	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_lba('{32'd0}),
	.sd_blk_cnt('{6'd0}),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_wr(sd_buff_wr),
	.sd_buff_din('{16'd0}),
	.sd_ack(sd_ack),
	.img_mounted(img_mounted),
	.img_size(img_size),

	// no block-device saves yet: keep the SD request inputs low
	.status_in(128'd0),
	.status_set(1'b0),
	.info_req(1'b0),
	.info(8'd0),
	.new_vmode(1'b0),
	.video_rotated(1'b0),

	.ps2_kbd_clk_in(1'b1),
	.ps2_kbd_data_in(1'b1),
	.ps2_kbd_led_status(3'd0),
	.ps2_kbd_led_use(3'd0),
	.ps2_mouse_clk_in(1'b1),
	.ps2_mouse_data_in(1'b1),

	.joystick_0_rumble(16'd0),
	.joystick_1_rumble(16'd0),
	.joystick_2_rumble(16'd0),
	.joystick_3_rumble(16'd0),
	.joystick_4_rumble(16'd0),
	.joystick_5_rumble(16'd0)
);

//------------------------------------------------------------------
// Status word decode — named wires keep CONF_STR and RTL in step.
//------------------------------------------------------------------
wire        reset_core    = RESET | status[0] | buttons[1];
wire        soft_reset    = status[127];
wire        erase_save    = status[126];
wire  [2:0] save_type     = status[4:2];
wire  [2:0] scr_layout    = status[7:5];
wire  [1:0] rotation      = status[9:8];
wire  [2:0] aspect        = status[12:10];
wire  [1:0] scanlines     = status[14:13];
wire        swap_screens  = status[15];
wire  [2:0] brightness    = status[18:16];
wire  [1:0] refresh       = status[53:52];
wire  [3:0] volume        = status[22:19];
wire  [1:0] mix_mode      = status[24:23];
wire  [1:0] i2s_latency   = status[26:25];
wire        spu_sync      = status[27];
wire        bios_real     = status[28];
wire        firmware_dump = status[29];
wire        skip_logo     = status[30];
wire  [1:0] region        = status[32:31];
wire  [1:0] stylus_mode   = status[34:33];
wire  [1:0] mic_source    = status[36:35];
wire        rumble        = status[37];
wire  [1:0] pad_profile   = status[39:38];
wire  [1:0] core_speed    = status[41:40];
wire  [1:0] frameskip     = status[43:42];
wire        autoskip      = status[44];
wire  [1:0] rewind_buf    = status[46:45];
wire        show_fps      = status[47];
wire        frame_graph   = status[48];
wire        bus_leds      = status[49];
wire  [1:0] log_level     = status[51:50];
wire  [1:0] tap_sel       = status[55:54];
wire        face_swap     = status[56];
wire        shoulder_swap = status[57];
wire  [1:0] oc_mode       = status[59:58];
wire  [2:0] vfilter       = status[62:60]; // Video filter
wire  [2:0] palette_sel   = status[65:63]; // Colour palette
wire  [1:0] afilter       = status[67:66]; // Audio filter
wire  [1:0] stereo_width  = status[69:68]; // Stereo width

//------------------------------------------------------------------
// Clocks
//
// TODO(M3): replace the single 50 MHz domain with a PLL:
//   clk_sys1  67.02 MHz  — ARM9 domain
//   clk_sys2  33.51 MHz  — ARM7 domain (enable from clk_sys1)
//   clk_pix   12.50 MHz  — pixel CE for the 256x384 stacked frame
// Everything below runs from clk_sys with clock enables until then; the
// video path already derives a 12.5 MHz CE so the timing is final.
//------------------------------------------------------------------
wire clk_sys = CLK_50M;
wire clk_pix_ce;

//------------------------------------------------------------------
// Reset — released on a frame boundary so video never glitches.
// frame_start pulses once per frame and timing is free-running, so
// this always releases (a synchronous-clear version would deadlock:
// reset would freeze ce_div, so frame_start could never fire).
//------------------------------------------------------------------
wire frame_start;
reg  reset_hold = 1'b1;
always @(posedge clk_sys) begin
	if (reset_core | soft_reset) reset_hold <= 1'b1;   // assert immediately
	else if (frame_start)        reset_hold <= 1'b0;   // release on frame boundary
end
wire reset = reset_hold;

//------------------------------------------------------------------
// Video path: fixed 256x384 stacked frame (top screen above bottom).
// 12.5 MHz CE; the OSD "Refresh rate" option picks the frame totals:
//   Native  320 x 653 -> 59.8201 Hz  (DS native is 59.8261 Hz)
//   59.95   332 x 628 -> 59.9532 Hz
//   60.00   320 x 651 -> 60.0038 Hz
//------------------------------------------------------------------
wire  [8:0] h_total = (refresh == 2'd1) ? 9'd332 : 9'd320;
wire  [9:0] v_total = (refresh == 2'd1) ? 10'd628 :
                      (refresh == 2'd2) ? 10'd651 : 10'd653;

wire  [8:0] pix_x, pix_y;
wire        pix_de, pix_hs, pix_vs;
wire [15:0] pix_out;

video_timing video_timing (
	.clk(clk_sys),
	.ce(1'b1),
	.pixel_ce(clk_pix_ce),
	// free-running: holding video_timing in reset would freeze ce_div,
	// so frame_start could never fire and reset_pending would deadlock
	.reset(1'b0),
	.h_total(h_total),
	.v_total(v_total),
	.x(pix_x),
	.y(pix_y),
	.de(pix_de),
	.hs(pix_hs),
	.vs(pix_vs),
	.frame_start(frame_start)
);

//------------------------------------------------------------------
// 2D engines A/B — real text renderers (M2). The composer asks for a
// native pixel; the engines answer combinationally from their front
// line buffers, which fetch FSMs fill by streaming VRAM through
// vram_arbiter while the current line displays.
//------------------------------------------------------------------
wire [7:0] na_x, nb_x;
wire [7:0] na_y, nb_y;
wire       na_on, nb_on;
wire [15:0] pix_top, pix_bot;

// Engine plumbing: register writes, palette/OAM second BRAM ports,
// VRAM fetch ports
wire        ea_we, eb_we;
wire  [6:0] ea_addr;
wire [15:0] ea_data;
wire  [9:0] ea_pal_addr, ea_oam_addr, eb_pal_addr, eb_oam_addr;
wire [15:0] ea_pal_data, ea_oam_data, eb_pal_data, eb_oam_data;
wire        ea_v_req, ea_v_ready, eb_v_req, eb_v_ready;
wire [19:0] ea_v_addr, eb_v_addr;
wire [15:0] ea_v_rdata, eb_v_rdata;

// DMA: register file + bus master (third main_bus master), triggers
wire        dma_reg_we, dma_ready, dma_rd, dma_wr;
wire  [7:0] dma_reg_addr, dma_reg_rd_addr;
wire [15:0] dma_reg_data, dma_reg_rdata;
wire [31:0] dma_addr, dma_wdata, dma_rdata;
wire  [3:0] dma_be, dma_irq;
reg         hs_d = 1'b0, vs_d = 1'b0;
always @(posedge clk_sys) begin
	hs_d <= pix_hs;
	vs_d <= pix_vs;
end
wire hblank_t = pix_hs & ~hs_d;   // rising edge = hblank start
wire vblank_t = pix_vs & ~vs_d;   // rising edge = vblank start

// CPU VRAM window <-> vram_arbiter, and vram_arbiter -> mem_arbiter
wire        bus_vram_req, bus_vram_wr, bus_vram_valid;
wire [19:0] bus_vram_addr;
wire [15:0] bus_vram_wdata, bus_vram_rdata;
wire        v2a_req, v2a_wr, v2a_ready;
wire [24:0] v2a_addr;
wire [15:0] v2a_wdata, v2a_rdata;
wire  [1:0] v2a_be;

screen_composer screen_composer (
	.clk(clk_sys),
	.ce(clk_pix_ce),
	.x(pix_x),
	.y(pix_y),
	.de(pix_de),
	.layout(scr_layout),
	.rotation(rotation),
	.swap(swap_screens),
	.brightness(brightness),
	.na_x(na_x), .na_y(na_y), .na_on(na_on), .pix_top(pix_top),
	.nb_x(nb_x), .nb_y(nb_y), .nb_on(nb_on), .pix_bot(pix_bot),
	.rgb555(pix_out)
);

engine_a engine_a (
	.clk(clk_sys),
	.reset(reset),
	.x(na_x), .y(na_y), .on(na_on), .rgb555(pix_top),
	.reg_we(ea_we), .reg_addr(ea_addr), .reg_data(ea_data),
	.pal_addr(ea_pal_addr), .pal_data(ea_pal_data),
	.oam_addr(ea_oam_addr), .oam_data(ea_oam_data),
	.v_req(ea_v_req), .v_addr(ea_v_addr),
	.v_ready(ea_v_ready), .v_rdata(ea_v_rdata)
);
engine_b engine_b (
	.clk(clk_sys),
	.reset(reset),
	.x(nb_x), .y(nb_y), .on(nb_on), .rgb555(pix_bot),
	.reg_we(eb_we), .reg_addr(ea_addr), .reg_data(ea_data),
	.pal_addr(eb_pal_addr), .pal_data(eb_pal_data),
	.oam_addr(eb_oam_addr), .oam_data(eb_oam_data),
	.v_req(eb_v_req), .v_addr(eb_v_addr),
	.v_ready(eb_v_ready), .v_rdata(eb_v_rdata)
);

// Spatial filter (exactly 1 CE latency, sync delayed to match) then
// the colour profile, then RGB888 for the framework.
wire [15:0] filt_out, pal_out;
wire        f_de, f_hs, f_vs;

video_filter video_filter (
	.clk(clk_sys),
	.ce(clk_pix_ce),
	.mode(vfilter),
	.x(pix_x),
	.y(pix_y),
	.de(pix_de),
	.hs(pix_hs),
	.vs(pix_vs),
	.rgb_in(pix_out),
	.rgb_o(filt_out),
	.de_o(f_de),
	.hs_o(f_hs),
	.vs_o(f_vs)
);

palette palette (
	.mode(palette_sel),
	.rgb_in(filt_out),
	.rgb_o(pal_out)
);

wire [4:0] out_r = pal_out[14:10], out_g = pal_out[9:5], out_b = pal_out[4:0];
assign VGA_R = f_de ? {out_r, out_r[4:2]} : 8'd0;
assign VGA_G = f_de ? {out_g, out_g[4:2]} : 8'd0;
assign VGA_B = f_de ? {out_b, out_b[4:2]} : 8'd0;
assign VGA_HS = f_hs;
assign VGA_VS = f_vs;
assign VGA_DE = f_de;
assign VGA_F1 = 0;
assign VGA_SL = scanlines;
assign VGA_SCALER = 0;

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = clk_pix_ce;

// Aspect: stacked output is 256x384 (2:3), single-screen 4:3, side 8:3.
// The OSD override replaces these with ARC values (TODO in M4).
assign VIDEO_ARX = (scr_layout == 3'd0) ? 13'd2 : (scr_layout == 3'd1) ? 13'd8 : 13'd4;
assign VIDEO_ARY = (scr_layout == 3'd0) ? 13'd3 : (scr_layout == 3'd1) ? 13'd3 : 13'd3;

//------------------------------------------------------------------
// SDRAM cluster: two masters — the bus RAM window and the cart save
// path — through mem_arbiter into sdram_ctrl (per-byte write masks).
// Cart ROM lives in DDR3 (see cart slot) so 256 Mbit+ carts fit.
//------------------------------------------------------------------
wire        bus_ram_req, bus_ram_wr, bus_ram_done;
wire [24:0] bus_ram_addr;
wire [15:0] bus_ram_wdata;
wire  [1:0] bus_ram_be;

wire        save_req, save_wr, save_done;
wire [24:0] save_addr;
wire [15:0] save_din;

wire        arb_req, arb_wr;
wire [24:0] arb_addr;
wire [15:0] arb_wdata;
wire  [1:0] arb_be;
wire        arb_rd_done, arb_wr_done;
wire [15:0] arb_rdata;

mem_arbiter mem_arbiter (
	.clk(clk_sys),
	.reset(reset),
	.bus_req(bus_ram_req),
	.bus_wr(bus_ram_wr),
	.bus_addr(bus_ram_addr),
	.bus_wdata(bus_ram_wdata),
	.bus_be(bus_ram_be),
	.bus_ready(bus_ram_done),
	.save_req(save_req),
	.save_wr(save_wr),
	.save_addr(save_addr),
	.save_wdata(save_din),
	.save_be(2'b11),       // save writes are halfword-wide (M4 refines)
	.save_ready(save_done),
	.vram_req(v2a_req),
	.vram_wr(v2a_wr),
	.vram_addr(v2a_addr),
	.vram_wdata(v2a_wdata),
	.vram_be(v2a_be),
	.vram_ready(v2a_ready),
	.sdram_req(arb_req),
	.sdram_wr(arb_wr),
	.sdram_addr(arb_addr),
	.sdram_wdata(arb_wdata),
	.sdram_be(arb_be),
	.sdram_rd_done(arb_rd_done),
	.sdram_wr_done(arb_wr_done),
	.sdram_rdata(arb_rdata)
);

sdram_ctrl sdram_ctrl (
	.clk(clk_sys),
	.reset(reset),
	.addr(arb_addr),
	.din(arb_wdata),
	.be(arb_be),
	.rd(arb_req && !arb_wr),
	.wr(arb_req &&  arb_wr),
	.dout(arb_rdata),
	.rd_done(arb_rd_done),
	.wr_done(arb_wr_done),
	.SDRAM_CLK(SDRAM_CLK),
	.SDRAM_CKE(SDRAM_CKE),
	.SDRAM_A(SDRAM_A),
	.SDRAM_BA(SDRAM_BA),
	.SDRAM_DQ(SDRAM_DQ),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nWE(SDRAM_nWE)
);

//------------------------------------------------------------------
// Cart slot: .nds download into DDR3 (all cart sizes up to 4 Gbit),
// header + capacity detection, CPU window bridge, save plumbing (M4)
//------------------------------------------------------------------
wire        cart_loaded;
wire [31:0] rom_bytes;

cart_slot cart_slot (
	.clk(clk_sys),
	.reset(reset),
	.ioctl_download(ioctl_download),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wr(ioctl_wr),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),
	.ddr_burstcnt(DDRAM_BURSTCNT),
	.ddr_addr(DDRAM_ADDR),
	.ddr_din(DDRAM_DIN),
	.ddr_be(DDRAM_BE),
	.ddr_we(DDRAM_WE),
	.ddr_rd(DDRAM_RD),
	.ddr_busy(DDRAM_BUSY),
	.ddr_dout_ready(DDRAM_DOUT_READY),
	.ddr_dout(DDRAM_DOUT),
	.win_req(win_req),          // CPU fetch path <- main_bus cart window
	.win_addr(win_addr),
	.win_valid(win_valid),
	.win_data(win_data),
	.save_req(save_req),
	.save_wr(save_wr),
	.save_addr(save_addr),
	.save_din(save_din),
	.save_done(save_done),
	.erase_save(erase_save),
	.save_type(save_type),
	.cart_loaded(cart_loaded),
	.rom_bytes(rom_bytes)
);

assign DDRAM_CLK = clk_sys;

//------------------------------------------------------------------
// Input: DS keys (KEYINPUT), stylus position/press, microphone
//------------------------------------------------------------------
wire [11:0] ds_keys;
wire  [8:0] touch_x;
wire  [7:0] touch_y;
wire        touch_down;
wire        mic_pressed;

input_mapper input_mapper (
	.clk(clk_sys),
	.reset(reset),
	.joy0(joystick_0),
	.joy1(joystick_1),
	.stick0(stick0),
	.stylus_cursor(stylus_mode),
	.tap_sel(tap_sel),
	.face_swap(face_swap),
	.shoulder_swap(shoulder_swap),
	.mic_source(mic_source),
	.keys(ds_keys),
	.touch_x(touch_x),
	.touch_y(touch_y),
	.touch_down(touch_down),
	.mic_pressed(mic_pressed)
);

//------------------------------------------------------------------
// CPUs + bus — stubs (M1). The bus keeps the NDS memory map; both CPUs
// idle until their pipelines are implemented.
//------------------------------------------------------------------
//------------------------------------------------------------------
// Main bus + cheat engine + VRAM register file
//------------------------------------------------------------------
wire [25:0] win_addr;
wire        win_req, win_valid;
wire [15:0] win_data;

wire        bus_vramcnt_we;
wire  [3:0] bus_vramcnt_addr;
wire  [7:0] bus_vramcnt_data;

wire        cheat_chk_en, cheat_hit;
wire [31:0] cheat_chk_addr;
wire [31:0] cheat_chk_word;
wire [15:0] cheat_patch, cheat_patch_hi;
wire        cheat_patch_hi_en;

wire [15:0] dispcnt_a, dispcnt_b;
wire        irq_me;
wire [31:0] irq_en, irq_fl;

main_bus main_bus (
	.clk(clk_sys),
	.reset(reset),
	.ds_keys(ds_keys),
	.touch_x(touch_x),
	.touch_y(touch_y),
	.touch_down(touch_down),
	.mic_in(mic_pressed),
	.m9_addr(m9_addr),
	.m9_wdata(m9_wdata),
	.m9_be(m9_be),
	.m9_rd(m9_rd),
	.m9_wr(m9_wr),
	.m9_ready(),              // consumed by the ARM9 core (M1)
	.m9_rdata(m9_rdata),
	.m7_addr(m7_addr),
	.m7_wdata(m7_wdata),
	.m7_be(m7_be),
	.m7_rd(m7_rd),
	.m7_wr(m7_wr),
	.m7_ready(),              // consumed by the ARM7 core (M1)
	.m7_rdata(m7_rdata),
	.cart_req(win_req),
	.cart_addr(win_addr),
	.cart_valid(win_valid),
	.cart_rdata(win_data),
	.ram_req(bus_ram_req),
	.ram_wr(bus_ram_wr),
	.ram_addr(bus_ram_addr),
	.ram_wdata(bus_ram_wdata),
	.ram_be(bus_ram_be),
	.ram_done(bus_ram_done),
	.ram_rdata(arb_rdata),
	.vramcnt_we(bus_vramcnt_we),
	.vramcnt_addr(bus_vramcnt_addr),
	.vramcnt_data(bus_vramcnt_data),
	.vram_req(bus_vram_req),
	.vram_wr(bus_vram_wr),
	.vram_addr(bus_vram_addr),
	.vram_wdata(bus_vram_wdata),
	.vram_valid(bus_vram_valid),
	.vram_rdata(bus_vram_rdata),
	.dma_reg_we(dma_reg_we),
	.dma_reg_addr(dma_reg_addr),
	.dma_reg_data(dma_reg_data),
	.dma_reg_rd_addr(dma_reg_rd_addr),
	.dma_reg_rdata(dma_reg_rdata),
	.d_addr(dma_addr),
	.d_wdata(dma_wdata),
	.d_be(dma_be),
	.d_rd(dma_rd),
	.d_wr(dma_wr),
	.d_ready(dma_ready),
	.d_rdata(dma_rdata),
	.dma_irq(dma_irq),
	.ea_we(ea_we),
	.ea_addr(ea_addr),
	.ea_data(ea_data),
	.eb_we(eb_we),
	.pal_ra_a(ea_pal_addr),
	.pal_rd_a(ea_pal_data),
	.pal_ra_b(eb_pal_addr),
	.pal_rd_b(eb_pal_data),
	.oam_ra_a(ea_oam_addr),
	.oam_rd_a(ea_oam_data),
	.oam_ra_b(eb_oam_addr),
	.oam_rd_b(eb_oam_data),
	.cheat_chk_en(cheat_chk_en),
	.cheat_chk_addr(cheat_chk_addr),
	.cheat_chk_word(cheat_chk_word),
	.cheat_patch(cheat_patch),
	.cheat_patch_hi_en(cheat_patch_hi_en),
	.cheat_patch_hi(cheat_patch_hi),
	.cheat_hit(cheat_hit),
	.dispcnt_a(dispcnt_a),
	.dispcnt_b(dispcnt_b),
	.irq_master_enable(irq_me),
	.irq_enable(irq_en),
	.irq_flags(irq_fl)
);

vram_arbiter vram_arbiter (
	.clk(clk_sys),
	.reset(reset),
	.reg_we(bus_vramcnt_we),
	.reg_addr(bus_vramcnt_addr),
	.reg_data(bus_vramcnt_data),
	.cpu_req(bus_vram_req),
	.cpu_wr(bus_vram_wr),
	.cpu_addr(bus_vram_addr),
	.cpu_wdata(bus_vram_wdata),
	.cpu_ready(bus_vram_valid),
	.cpu_rdata(bus_vram_rdata),
	.a_req(ea_v_req),
	.a_addr(ea_v_addr),
	.a_ready(ea_v_ready),
	.a_rdata(ea_v_rdata),
	.b_req(eb_v_req),
	.b_addr(eb_v_addr),
	.b_ready(eb_v_ready),
	.b_rdata(eb_v_rdata),
	.v_req(v2a_req),
	.v_wr(v2a_wr),
	.v_addr(v2a_addr),
	.v_wdata(v2a_wdata),
	.v_be(v2a_be),
	.v_ready(v2a_ready),
	.v_rdata(v2a_rdata)
);

//------------------------------------------------------------------
// DMA: four channels against the shared fabric; immediate runs on
// the enable write, vblank/hblank on the sync edges (M2). Special
// timing (capture/GX FIFO) lands with M3/M5.
//------------------------------------------------------------------
dma_engine dma_engine (
	.clk(clk_sys),
	.reset(reset),
	.reg_we(dma_reg_we),
	.reg_addr(dma_reg_addr),
	.reg_data(dma_reg_data),
	.reg_rd_addr(dma_reg_rd_addr),
	.reg_rdata(dma_reg_rdata),
	.d_addr(dma_addr),
	.d_wdata(dma_wdata),
	.d_be(dma_be),
	.d_rd(dma_rd),
	.d_wr(dma_wr),
	.d_ready(dma_ready),
	.d_rdata(dma_rdata),
	.vblank(vblank_t),
	.hblank(hblank_t),
	.irq_set(dma_irq)
);

cheat_engine cheat_engine (
	.clk(clk_sys),
	.reset(reset),
	.f2_wr(f2_wr),
	.f2_dout(f2_dout),
	.f2_dl(cheat_dl),
	.clr_cheats(status[125]),   // OSD: Disable all cheats (until next load)
	.chk_en(cheat_chk_en),
	.chk_addr(cheat_chk_addr),
	.chk_word(cheat_chk_word),
	.hit(cheat_hit),
	.patch(cheat_patch),
	.patch_hi_en(cheat_patch_hi_en),
	.patch_hi(cheat_patch_hi)
);

//------------------------------------------------------------------
// CPU stubs (M1). The bus master ports below are what the pipelines
// will drive: address, write data, byte enables, rd/wr strobes; the
// bus answers with ready + rdata. Idle stubs hold the request lines
// low so the bus fabric stays quiet.
//------------------------------------------------------------------
wire [31:0] m9_addr  = 32'h0;
wire [31:0] m9_wdata = 32'h0;
wire  [3:0] m9_be    = 4'h0;
wire        m9_rd    = 1'b0;
wire        m9_wr    = 1'b0;
wire [31:0] m9_rdata;

wire [31:0] m7_addr  = 32'h0;
wire [31:0] m7_wdata = 32'h0;
wire  [3:0] m7_be    = 4'h0;
wire        m7_rd    = 1'b0;
wire        m7_wr    = 1'b0;
wire [31:0] m7_rdata;

arm9_core arm9 (
	.clk(clk_sys),
	.reset(reset),
	.ce(1'b1),
	.oc_mode(oc_mode)
);

arm7_core arm7 (
	.clk(clk_sys),
	.reset(reset),
	.ce(1'b1),
	.oc_mode(oc_mode)
);

//------------------------------------------------------------------
// Audio: 16-channel SPU stub (M4) -> I2S at frame rate
//------------------------------------------------------------------
wire [15:0] spu_l, spu_r;
reg         frame_s = 0;
always @(posedge clk_sys) frame_s <= frame_start; // sample after SPU latches

spu spu (
	.clk(clk_sys),
	.clk_audio(CLK_AUDIO),
	.reset(reset),
	.volume(volume),
	.mix_mode(mix_mode),
	.frame_start(frame_start),
	.audio_l(spu_l),
	.audio_r(spu_r)
);

audio_filter audio_filter (
	.clk(clk_sys),
	.reset(reset),
	.strobe(frame_s),
	.mode(afilter),
	.width(stereo_width),
	.in_l(spu_l),
	.in_r(spu_r),
	.out_l(AUDIO_L),
	.out_r(AUDIO_R)
);

//------------------------------------------------------------------
// User LED: cart activity, or the bus-activity option from diagnostics
//------------------------------------------------------------------
reg [24:0] led_cnt = 0;
always @(posedge clk_sys) led_cnt <= led_cnt + 1'd1;
assign LED_USER = bus_leds ? led_cnt[22] : (ioctl_download ? led_cnt[20] : led_cnt[24]);

// Unused-in-skeleton outputs
wire _unused = &{1'b0, aspect, bios_real, firmware_dump, skip_logo, region,
                 rumble, pad_profile, core_speed, frameskip, autoskip,
                 rewind_buf, show_fps, frame_graph, log_level, i2s_latency,
                 spu_sync, ps2_key, img_mounted, img_size, cart_loaded,
                 rom_bytes, m9_rdata, m7_rdata, dispcnt_a, dispcnt_b,
                 irq_me, irq_en, irq_fl, sd_rd, sd_wr,
                 sd_buff_dout, sd_buff_addr, sd_buff_wr, sd_ack,
                 HDMI_WIDTH, HDMI_HEIGHT, 1'b0};

endmodule
