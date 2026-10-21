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
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;
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
localparam CONF_STR = {
"NDS MiSTer Test;;",
"-;",
"P1,Cartridge;",
"P1F1,NDS;",
"P1-,",
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
"-;",
"P3,Audio;",
"P3O[22:19],Master volume,0%,10%,20%,30%,40%,50%,60%,70%,80%,90%,100%;",
"P3O[24:23],Output mix,Stereo,Mono,Headphones;",
"P3O[26:25],I2S latency,1 frame,2 frames,4 frames;",
"P3O[27],SPU sync,Off,On;",
"-;",
"P4,BIOS & Input;",
"P4O[28],Slot-1 BIOS,HLE,Real;",
"P4O[29],Firmware,HLE,Flash dump;",
"P4O[30],Skip intro logo,Off,On;",
"P4O[32:31],Region,Auto,NTSC-U,NTSC-J,PAL;",
"P4-,",
"P4O[34:33],Stylus mode,D-pad,Touch pad,Off;",
"P4O[36:35],Microphone,Off,Button,Host device;",
"P4O[37],Rumble pak,Off,On;",
"P4O[39:38],Pad profile,Default,Left-hand,Arcade stick;",
"-;",
"P5,Emulation;",
"P5O[41:40],Core speed,100%,150%,200%,Max;",
"P5O[43:42],Frameskip,Off,1,2,3;",
"P5O[44],Auto frameskip,Off,On;",
"P5O[46:45],Rewind buffer,Off,5 s,15 s,30 s;",
"P5-,",
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
wire   [3:0] sd_rd, sd_wr;
wire  [31:0] sd_lba [1];
wire   [5:0] sd_blk_cnt [1];
wire  [15:0] sd_buff_dout;
wire  [12:0] sd_buff_addr;
wire         sd_buff_wr;
wire  [15:0] sd_buff_din [1];
wire   [0:0] sd_ack;
wire   [0:0] img_mounted;
wire  [63:0] img_size;

assign sd_blk_cnt[0] = 0; // single 512-byte block per request

hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),
	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.ps2_key(ps2_key),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ioctl_download(ioctl_download),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wr(ioctl_wr),
	.ioctl_index(ioctl_index),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_lba(sd_lba),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_wr(sd_buff_wr),
	.sd_buff_din(sd_buff_din),
	.sd_ack(sd_ack),
	.img_mounted(img_mounted),
	.img_size(img_size)
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
// Reset — released on a frame boundary so video never glitches
//------------------------------------------------------------------
wire frame_start;
reg reset_pending = 1;
always @(posedge clk_sys) begin
	if (reset_core)                  reset_pending <= 1;
	else if (soft_reset)             reset_pending <= 1;
	else if (frame_start)            reset_pending <= 0;
end
wire reset = reset_pending;

//------------------------------------------------------------------
// Video path: fixed 256x384 stacked frame (top screen above bottom).
// 12.5 MHz CE, H_TOTAL 320, V_TOTAL 653  ->  59.8201 Hz (DS native is
// 59.8261 Hz — within one frame every 16 minutes).
//------------------------------------------------------------------
wire  [8:0] pix_x, pix_y;
wire        pix_de, pix_hs, pix_vs;
wire [15:0] pix_out;

video_timing #(
	.H_ACTIVE(256), .H_FRONT(8), .H_SYNC(32), .H_BACK(24),   // H_TOTAL 320
	.V_ACTIVE(384), .V_FRONT(24), .V_SYNC(4),  .V_BACK(241)   // V_TOTAL 653
) video_timing (
	.clk(clk_sys),
	.ce(1'b1),
	.pixel_ce(clk_pix_ce),
	.reset(reset),
	.x(pix_x),
	.y(pix_y),
	.de(pix_de),
	.hs(pix_hs),
	.vs(pix_vs),
	.frame_start(frame_start)
);

//------------------------------------------------------------------
// 2D engines A/B — stubs. Interface is final: the composer asks for a
// native pixel; the stubs answer with a boot pattern until the real
// renderers land (M2). The composer reads from line buffers fed by
// VRAM once engine A/B exist.
//------------------------------------------------------------------
wire [7:0] na_x, nb_x;
wire [7:0] na_y, nb_y;
wire       na_on, nb_on;
wire [15:0] pix_top, pix_bot;

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

engine_a engine_a (.clk(clk_sys), .x(na_x), .y(na_y), .on(na_on), .rgb555(pix_top));
engine_b engine_b (.clk(clk_sys), .x(nb_x), .y(nb_y), .on(nb_on), .rgb555(pix_bot));

// RGB555 -> RGB888 for the framework
wire [4:0] out_r = pix_out[14:10], out_g = pix_out[9:5], out_b = pix_out[4:0];
assign VGA_R = pix_de ? {out_r, out_r[4:2]} : 8'd0;
assign VGA_G = pix_de ? {out_g, out_g[4:2]} : 8'd0;
assign VGA_B = pix_de ? {out_b, out_b[4:2]} : 8'd0;
assign VGA_HS = pix_hs;
assign VGA_VS = pix_vs;
assign VGA_DE = pix_de;
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
// SDRAM: 64 MB shared by cart ROM, main RAM, save data, VRAM overflow
//------------------------------------------------------------------
wire [24:0] mem_addr;
wire [15:0] mem_dout;
wire        mem_rd, mem_wr;
wire [15:0] mem_din;
wire        mem_rd_done, mem_wr_done;

sdram_ctrl sdram_ctrl (
	.clk(clk_sys),
	.reset(reset),
	.addr(mem_addr),
	.din(mem_din),
	.rd(mem_rd),
	.wr(mem_wr),
	.dout(mem_dout),
	.rd_done(mem_rd_done),
	.wr_done(mem_wr_done),
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
// Cart slot: .nds download into SDRAM, header capture, save plumbing
//------------------------------------------------------------------
wire        cart_loaded;

cart_slot cart_slot (
	.clk(clk_sys),
	.reset(reset),
	.ioctl_download(ioctl_download),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wr(ioctl_wr),
	.ioctl_index(ioctl_index),
	.mem_addr(mem_addr),
	.mem_din(mem_din),
	.mem_wr(mem_wr),
	.mem_wr_done(mem_wr_done),
	.erase_save(erase_save),
	.save_type(save_type),
	.cart_loaded(cart_loaded)
);

//------------------------------------------------------------------
// CPUs + bus — stubs (M1). The bus keeps the NDS memory map; both CPUs
// idle until their pipelines are implemented.
//------------------------------------------------------------------
main_bus main_bus (
	.clk(clk_sys),
	.reset(reset)
);

arm9_core arm9 (
	.clk(clk_sys),
	.reset(reset),
	.ce(1'b1)
);

arm7_core arm7 (
	.clk(clk_sys),
	.reset(reset),
	.ce(1'b1)
);

//------------------------------------------------------------------
// Audio: 16-channel SPU stub (M4) -> I2S at frame rate
//------------------------------------------------------------------
spu spu (
	.clk(clk_sys),
	.clk_audio(CLK_AUDIO),
	.reset(reset),
	.volume(volume),
	.mix_mode(mix_mode),
	.frame_start(frame_start),
	.audio_l(AUDIO_L),
	.audio_r(AUDIO_R)
);

//------------------------------------------------------------------
// User LED: cart activity, or the bus-activity option from diagnostics
//------------------------------------------------------------------
reg [24:0] led_cnt = 0;
always @(posedge clk_sys) led_cnt <= led_cnt + 1'd1;
assign LED_USER = bus_leds ? led_cnt[22] : (ioctl_download ? led_cnt[20] : led_cnt[24]);

// Unused-in-skeleton outputs
wire _unused = &{1'b0, aspect, bios_real, firmware_dump, skip_logo, region,
                 stylus_mode, mic_source, rumble, pad_profile, core_speed,
                 frameskip, autoskip, rewind_buf, show_fps, frame_graph,
                 log_level, i2s_latency, spu_sync, ps2_key, joystick_1,
                 img_mounted, img_size, cart_loaded, HDMI_WIDTH, HDMI_HEIGHT,
                 1'b0};

endmodule
