// =============================================================================
// esd_synth_top.sv — Standalone synthesis wrapper for ESD 16-bit Arcade
//
// Wraps esd_arcade + fx68k for gate3 standalone synthesis.
// SDRAM channels are stub-connected (synthesis checks RTL, not runtime data).
//
// Target: DE-10 Nano (Cyclone V 5CSEBA6U23I7)
// Goal:   Fit in < 41,910 ALMs (DE-10 Nano limit)
// =============================================================================
`default_nettype none

module esd_synth_top (
    input  logic        clk_sys,    // 48 MHz
    input  logic        clk_pix,    // Pixel clock enable (8 MHz)
    input  logic        reset_n,

    // CPU clock enables (from PLL divider in real sys_top)
    input  logic        cpu_phi1,
    input  logic        cpu_phi2,

    // Video outputs
    output logic  [7:0] vga_r,
    output logic  [7:0] vga_g,
    output logic  [7:0] vga_b,
    output logic        vga_hs,
    output logic        vga_vs,
    output logic        vga_de,

    // Audio
    output logic [15:0] audio_l,
    output logic [15:0] audio_r,

    // Player I/O
    input  logic  [9:0] joy0,
    input  logic  [9:0] joy1,
    input  logic [15:0] dip_sw
);

// =============================================================================
// CPU Bus wires
// =============================================================================

logic [23:1] cpu_addr;
logic [15:0] cpu_din;
logic [15:0] cpu_dout;
logic        cpu_rw;
logic        cpu_uds_n;
logic        cpu_lds_n;
logic        cpu_as_n;
logic        cpu_dtack_n;
logic  [2:0] cpu_ipl_n;
logic  [2:0] cpu_fc;
logic        cpu_halted_n;

// =============================================================================
// IACK detection (COMMUNITY_PATTERNS.md Section 1.2)
// =============================================================================

wire inta_n = ~&{cpu_fc[2], cpu_fc[1], cpu_fc[0], ~cpu_as_n};

// =============================================================================
// fx68k MC68000 (COMMUNITY_PATTERNS.md Section 1.8)
// =============================================================================

fx68k u_cpu (
    .clk        (clk_sys),
    .HALTn      (1'b1),
    .extReset   (~reset_n),
    .pwrUp      (~reset_n),
    .enPhi1     (cpu_phi1),
    .enPhi2     (cpu_phi2),
    .eRWn       (cpu_rw),
    .ASn        (cpu_as_n),
    .LDSn       (cpu_lds_n),
    .UDSn       (cpu_uds_n),
    .E          (),
    .VMAn       (),
    .FC0        (cpu_fc[0]),
    .FC1        (cpu_fc[1]),
    .FC2        (cpu_fc[2]),
    .BGn        (),
    .oRESETn    (),
    .oHALTEDn   (cpu_halted_n),
    .DTACKn     (cpu_dtack_n),
    .VPAn       (inta_n),
    .BERRn      (1'b1),
    .BRn        (1'b1),
    .BGACKn     (1'b1),
    .IPL0n      (cpu_ipl_n[0]),
    .IPL1n      (cpu_ipl_n[1]),
    .IPL2n      (cpu_ipl_n[2]),
    .iEdb       (cpu_dout),
    .oEdb       (cpu_din),
    .eab        (cpu_addr)
);

// =============================================================================
// SDRAM stub signals
// =============================================================================

logic [26:0] prog_rom_addr, spr_rom_addr, bg_rom_addr;
logic        prog_rom_req,  spr_rom_req,  bg_rom_req;
logic [15:0] prog_rom_data, spr_rom_data, bg_rom_data;
logic        prog_rom_ack,  spr_rom_ack,  bg_rom_ack;

// Stub SDRAM responses — synthesis tool will see the logic, not the data
assign prog_rom_data = 16'hFFFF;
assign prog_rom_ack  = prog_rom_req;
assign spr_rom_data  = 16'hFFFF;
assign spr_rom_ack   = spr_rom_req;
assign bg_rom_data   = 16'hFFFF;
assign bg_rom_ack    = bg_rom_req;

// =============================================================================
// ESD Arcade Core
// =============================================================================

logic        hblank_r, vblank_r;

esd_arcade u_esd (
    .clk_sys         (clk_sys),
    .clk_pix         (clk_pix),
    .reset_n         (reset_n),

    // CPU bus
    .cpu_addr        (cpu_addr),
    .cpu_din         (cpu_din),
    .cpu_dout        (cpu_dout),
    .cpu_lds_n       (cpu_lds_n),
    .cpu_uds_n       (cpu_uds_n),
    .cpu_rw          (cpu_rw),
    .cpu_as_n        (cpu_as_n),
    .cpu_fc          (cpu_fc),
    .cpu_dtack_n     (cpu_dtack_n),
    .cpu_ipl_n       (cpu_ipl_n),

    // ROM channels
    .prog_rom_addr   (prog_rom_addr),
    .prog_rom_data   (prog_rom_data),
    .prog_rom_req    (prog_rom_req),
    .prog_rom_ack    (prog_rom_ack),
    .spr_rom_addr    (spr_rom_addr),
    .spr_rom_data    (spr_rom_data),
    .spr_rom_req     (spr_rom_req),
    .spr_rom_ack     (spr_rom_ack),
    .bg_rom_addr     (bg_rom_addr),
    .bg_rom_data     (bg_rom_data),
    .bg_rom_req      (bg_rom_req),
    .bg_rom_ack      (bg_rom_ack),

    // Video
    .rgb_r           (vga_r),
    .rgb_g           (vga_g),
    .rgb_b           (vga_b),
    .hsync_n         (vga_hs),
    .vsync_n         (vga_vs),
    .hblank          (hblank_r),
    .vblank          (vblank_r),

    // Audio
    .audio_l         (audio_l),
    .audio_r         (audio_r),

    // Player inputs
    .joystick_0      (joy0),
    .joystick_1      (joy1),
    .dip_sw          (dip_sw),

    // ROM download (unused)
    .ioctl_download  (1'b0),
    .ioctl_addr      (27'h0),
    .ioctl_dout      (16'h0),
    .ioctl_wr        (1'b0),
    .ioctl_index     (8'h0),
    .ioctl_wait      ()
);

assign vga_de = ~(hblank_r | vblank_r);

endmodule
