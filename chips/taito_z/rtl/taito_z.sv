`default_nettype none
// =============================================================================
// taito_z.sv — Taito Z System Board Top-Level Integration
// =============================================================================
//
// Primary target: Double Axle (dblaxle) / Racing Beat (racingb)
// Two MC68000 CPUs (CPU A @ 16 MHz, CPU B @ 16 MHz), Z80 + YM2610 sound.
//
// Instantiated chips / blocks:
//   tc0480scp          — Tilemap engine (BG0–BG3 + FG text)
//   tc0510nio          — I/O controller (joystick, coin, wheel, pedal)
//   taito_z_palette    — Inline xBGR_555 palette BRAM (no TC0260DAR)
//   taito_z_compositor — Priority compositor (SCP + ROD + MSO → palette index)
//   TC0140SYT          — 68000↔Z80 sound communication + ADPCM ROM arbiter
//   tc0150rod          — Road generator (TC0150ROD, CPU B bus)
//   tc0370mso          — Sprite scanner + line buffer (TC0370MSO + TC0300FLA)
//   shared_ram         — 64KB dual-port BRAM (CPU A ↔ CPU B)
//   work_ram_a         — 64KB BRAM (CPU A private)
//   work_ram_b         — 32KB BRAM (CPU B private)
//
// CPU A address map (dblaxle byte addresses):
//   0x000000–0x07FFFF  prog ROM A (512KB, SDRAM via sdr_*)
//   0x100000–0x10FFFF  work RAM A (64KB)
//   0x200000–0x20FFFF  shared RAM (64KB; maps to CPU B 0x110000)
//   0x400000–0x40001F  TC0510NIO (I/O)
//   0x600000–0x600001  CPU B reset register (write bit 0: 1=run, 0=reset)
//   0x620000–0x620003  TC0140SYT master port + comm
//   0x800000–0x801FFF  palette RAM (4096 × 16-bit xBGR_555)
//   0x900000–0x90FFFF  TC0480SCP VRAM mirror (same as 0xA00000)
//   0xA00000–0xA0FFFF  TC0480SCP VRAM
//   0xA30000–0xA3002F  TC0480SCP control registers
//   0xC00000–0xC03FFF  sprite RAM (16KB)
//
// CPU B address map (dblaxle byte addresses):
//   0x000000–0x03FFFF  prog ROM B (256KB, SDRAM)
//   0x100000–0x103FFF  work RAM B (16KB — only lower 16KB used in dblaxle)
//   0x110000–0x11FFFF  shared RAM (same 64KB block as CPU A 0x200000)
//   0x300000–0x301FFF  TC0150ROD (road generator, stub)
//   0x500000–0x503FFF  network RAM (plain RAM, no external interface needed)
//
// Interrupt controller:
//   VBL (vblank_fall from TC0480SCP) → IRQ4 on CPU A and CPU B
//
// Deferred / incomplete:
//   SDRAM prog ROM fetches (CPU A/B): pass-through to sdr_* ports
//   GFX ROM SDRAM bridge: TC0480SCP 4-port gfx_addr → gfx_* ports
//   Sprite ROM SDRAM bridge: TC0370MSO OBJ ROM (spr_*) + STYM ROM (stym_*)
//   Road ROM SDRAM bridge: TC0150ROD rod_rom_* ports
//   Per-layer BG priority for BG3/text vs sprites (SCP composites internally)
//
// Assumptions / known differences from MAME:
//   1. dblaxle address map used as primary target. racingb differs in:
//      - TC0510NIO at 0x300000 (not 0x400000)
//      - CPU B reset register at 0x500002 (not 0x600000)
//      - TC0140SYT at 0x520000 (not 0x620000)
//      - Palette at 0x700000 (not 0x800000)
//      - TC0480SCP VRAM at 0x900000 only (no mirror)
//      - Sprite RAM at 0xB00000
//      These require per-game parameters (not implemented in this skeleton).
//   2. TC0480SCP uses its own pixel clock internally. Wired to clk_pix here.
//   3. GFX ROM: TC0480SCP 4 × 32-bit ports collapsed to top-level gfx_addr/
//      gfx_data arrays with req/ack toggle per BG engine.
//   4. SDRAM prog ROM access: CPU AS_N-gated, single-cycle DTACK for now;
//      a real SDRAM arbiter (latency 3–8 cycles) will require wait states.
//   5. Work RAM A declared 64KB (ABITS=15 words); dblaxle only uses 16KB
//      (0x200000–0x203FFF), but 64KB declared to match max shared RAM size.
//
// Reference: chips/taito_z/integration_plan.md
//            MAME src/mame/taito/taito_z.cpp (dblaxle_map, dblaxle_cpub_map)
// =============================================================================

/* verilator lint_off SYNCASYNCNET */
module taito_z (
    // ── Clocks / Reset ────────────────────────────────────────────────────────
    input  logic        clk_sys,        // system clock (e.g. 48 MHz)
    input  logic        clk_pix,        // pixel clock (TC0480SCP clock domain)
    input  logic        reset_n,        // active-low async reset

    // ── CPU A 68000 Bus ────────────────────────────────────────────────────────
    input  logic [23:1] cpua_addr,
    input  logic [15:0] cpua_din,       // data FROM CPU A (write)
    output logic [15:0] cpua_dout,      // data TO CPU A (read mux)
    input  logic        cpua_lds_n,
    input  logic        cpua_uds_n,
    input  logic        cpua_rw,        // 1=read, 0=write
    input  logic        cpua_as_n,      // address strobe
    output logic        cpua_dtack_n,
    output logic [ 2:0] cpua_ipl_n,     // active-low encoded IPL

    // ── CPU B 68000 Bus ────────────────────────────────────────────────────────
    input  logic [23:1] cpub_addr,
    input  logic [15:0] cpub_din,
    output logic [15:0] cpub_dout,
    input  logic        cpub_lds_n,
    input  logic        cpub_uds_n,
    input  logic        cpub_rw,
    input  logic        cpub_as_n,
    output logic        cpub_dtack_n,
    output logic [ 2:0] cpub_ipl_n,
    output logic        cpub_reset_n,   // driven by CPU A control register bit 0

    // ── GFX ROM (TC0480SCP tilemap — 4 × 32-bit ports, one per BG engine) ────
    // Each engine gets independent req/ack toggle handshake.
    // gfx_addr[n][22:0] = 21-bit byte address into SCR GFX region (upper bits unused)
    output logic [3:0][22:0] gfx_addr,
    input  logic [3:0][31:0] gfx_data,
    output logic [3:0]       gfx_req,
    input  logic [3:0]       gfx_ack,

    // ── Sprite OBJ ROM (TC0370MSO scanner — 64-bit wide) ─────────────────────
    output logic [22:0] spr_addr,       // OBJ GFX ROM byte address (obj_row_addr → 23-bit)
    input  logic [63:0] spr_data,
    output logic        spr_req,
    input  logic        spr_ack,

    // ── Spritemap ROM (TC0370MSO STYM — 16-bit wide) ──────────────────────────
    output logic [17:0] stym_addr,      // word address into 512KB spritemap ROM
    input  logic [15:0] stym_data,
    output logic        stym_req,
    input  logic        stym_ack,

    // ── Road ROM (TC0150ROD — 16-bit wide) ────────────────────────────────────
    output logic [17:0] rod_rom_addr,   // word address into 512KB road ROM
    input  logic [15:0] rod_rom_data,
    output logic        rod_rom_req,
    input  logic        rod_rom_ack,

    // ── SDRAM (ADPCM ROM via TC0140SYT) ─────────────────────────────────────
    output logic [26:0] sdr_addr,
    input  logic [15:0] sdr_data,
    output logic        sdr_req,
    input  logic        sdr_ack,

    // ── Z80 ROM SDRAM Interface (CH4) ─────────────────────────────────────────
    // Z80 audio program ROM at SDRAM 0x0C0000 (word addr 0x060000).
    // Z80 sees this as 0x0000–0xFFFF; TC0140SYT decodes bank select.
    output logic [26:0] z80_rom_addr,   // SDRAM word address
    input  logic [15:0] z80_rom_data,   // SDRAM read data (16-bit word)
    output logic        z80_rom_req,    // request toggle
    input  logic        z80_rom_ack,    // acknowledge toggle

    // ── Sound Clock ───────────────────────────────────────────────────────────
    input  logic        clk_sound,      // ~4 MHz clock enable for YM2610 + Z80

    // ── Audio Output ──────────────────────────────────────────────────────────
    output logic signed [15:0] snd_left,
    output logic signed [15:0] snd_right,

    // ── Video Output ──────────────────────────────────────────────────────────
    output logic [ 7:0] rgb_r,
    output logic [ 7:0] rgb_g,
    output logic [ 7:0] rgb_b,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,

    // ── Player Inputs ─────────────────────────────────────────────────────────
    input  logic [ 7:0] joystick_p1,
    input  logic [ 7:0] joystick_p2,
    input  logic [ 1:0] coin,
    input  logic        service,
    input  logic [ 7:0] wheel,          // steering wheel analog
    input  logic [ 7:0] pedal           // gas pedal analog
);

// =============================================================================
// CPU A Chip-Select Decode
// =============================================================================
// All comparisons on cpua_addr[23:1] (word address).
// Window qualifications use cpua_as_n to gate on valid bus cycle.

// Work RAM A: 0x100000–0x10FFFF (64KB = 32K words, 15-bit index)
logic wrama_cs;
assign wrama_cs = (cpua_addr[23:16] == 8'h10) && !cpua_as_n;

// Shared RAM (CPU A port): 0x200000–0x20FFFF (64KB = 32K words, 15-bit index)
logic shram_a_cs;
assign shram_a_cs = (cpua_addr[23:16] == 8'h20) && !cpua_as_n;

// TC0510NIO: 0x400000–0x40001F (32-byte window = 16 word addresses, 4-bit index)
logic nio_cs_n;
assign nio_cs_n = !((cpua_addr[23:5] == 19'h020000) && !cpua_as_n);

// CPU B reset register: 0x600000–0x600001
logic cpub_rst_cs;
assign cpub_rst_cs = (cpua_addr[23:1] == 23'h300000) && !cpua_as_n;

// TC0140SYT master: 0x620000–0x620003 (2 word addresses: port @ +0, comm @ +2)
//   cpua_addr[23:2] selects the SYT; addr[1] = MA1 (port vs comm)
logic syt_mcs_n;
assign syt_mcs_n = !((cpua_addr[23:2] == 22'h188000) && !cpua_as_n);

// Palette RAM: 0x800000–0x801FFF (4KB = 2048 words, 12-bit index from addr[12:1])
logic pal_cs;
assign pal_cs = (cpua_addr[23:13] == 11'h400) && !cpua_as_n;

// TC0480SCP VRAM: 0xA00000–0xA0FFFF (64KB, 15-bit word index)
//   Also mirror at 0x900000–0x90FFFF — decode both ranges to same vram_cs.
logic scp_vram_cs;
assign scp_vram_cs = ((cpua_addr[23:16] == 8'hA0) || (cpua_addr[23:16] == 8'h90)) && !cpua_as_n;

// TC0480SCP control registers: 0xA30000–0xA3002F (24 × 16-bit, 5-bit word index)
logic scp_ctrl_cs;
assign scp_ctrl_cs = (cpua_addr[23:6] == 18'h28C00) && !cpua_as_n;

// Sprite RAM: 0xC00000–0xC03FFF (16KB = 8K words, 13-bit index)
logic spr_ram_cs;
assign spr_ram_cs = (cpua_addr[23:14] == 10'h300) && !cpua_as_n;

// =============================================================================
// CPU B Chip-Select Decode
// =============================================================================

// Work RAM B: 0x100000–0x103FFF (16KB = 8K words, 13-bit index)
logic wramb_cs;
assign wramb_cs = (cpub_addr[23:14] == 10'h040) && !cpub_as_n;

// Shared RAM (CPU B port): 0x110000–0x11FFFF (64KB, 15-bit index)
logic shram_b_cs;
assign shram_b_cs = (cpub_addr[23:16] == 8'h11) && !cpub_as_n;

// TC0150ROD (stub): CPU B 0x300000–0x301FFF (8KB)
logic rod_cs;
assign rod_cs = (cpub_addr[23:13] == 11'h180) && !cpub_as_n;

// Network RAM (CPU B): 0x500000–0x503FFF (16KB, 13-bit index)
logic netram_cs;
assign netram_cs = (cpub_addr[23:14] == 10'h140) && !cpub_as_n;

// =============================================================================
// TC0480SCP — Tilemap Engine
// =============================================================================
logic [15:0] scp_ctrl_dout;
logic [15:0] scp_vram_dout;
logic        scp_hblank, scp_vblank;
logic        scp_hsync,  scp_vsync;
logic [ 9:0] scp_hpos;
logic [ 8:0] scp_vpos;
logic        scp_pixel_active;
logic        scp_hblank_fall, scp_vblank_fall;
logic [15:0] scp_pixel_out;
logic        scp_pixel_valid;

// GFX ROM request wires (TC0480SCP → top-level)
logic [3:0][31:0] scp_gfx_addr_raw;    // [n][20:0] is the 21-bit byte address
logic [3:0][31:0] scp_gfx_data_raw;
logic [3:0]       scp_gfx_rd;

// TC0480SCP address/data to top-level gfx ports
// The gfx_addr TC0480SCP output is 32-bit wide (upper 11 bits unused),
// 21-bit effective address. Top-level gfx_addr is 23-bit (integration plan §8.2).
// Pass through lower 21 bits; upper 2 bits = 0 (GFX ROM base offset handled by SDRAM arbiter).
genvar gi;
generate
    for (gi = 0; gi < 4; gi++) begin : scp_gfx_bridge
        assign gfx_addr[gi]         = {2'b0, scp_gfx_addr_raw[gi][20:0]};
        assign scp_gfx_data_raw[gi] = gfx_data[gi];
        // Toggle-request bridge: raise gfx_req when TC0480SCP asserts gfx_rd
        // (single-cycle pulse → latched as toggle req)
        logic gfx_req_prev;
        always_ff @(posedge clk_pix or negedge reset_n) begin
            if (!reset_n) begin
                gfx_req[gi]      <= 1'b0;
                gfx_req_prev     <= 1'b0;
            end else begin
                gfx_req_prev <= scp_gfx_rd[gi];
                if (scp_gfx_rd[gi] && !gfx_req_prev)
                    gfx_req[gi] <= ~gfx_req[gi];
            end
        end
    end
endgenerate

tc0480scp u_scp (
    .clk               (clk_pix),
    .async_rst_n       (reset_n),

    // CPU control register interface (0xA30000–0xA3002F)
    .cpu_cs            (scp_ctrl_cs),
    .cpu_we            (!cpua_rw),
    .cpu_addr          (cpua_addr[5:1]),    // 5-bit word address within 24-word bank
    .cpu_din           (cpua_din),
    .cpu_be            ({!cpua_uds_n, !cpua_lds_n}),
    .cpu_dout          (scp_ctrl_dout),

    // CPU VRAM interface (0xA00000–0xA0FFFF, mirror 0x900000)
    .vram_cs           (scp_vram_cs),
    .vram_we           (!cpua_rw),
    .vram_addr         (cpua_addr[15:1]),   // 15-bit word address within 64KB VRAM
    .vram_din          (cpua_din),
    .vram_be           ({!cpua_uds_n, !cpua_lds_n}),
    .vram_dout         (scp_vram_dout),

    // Video timing
    .hblank            (scp_hblank),
    .vblank            (scp_vblank),
    .hsync             (scp_hsync),
    .vsync             (scp_vsync),
    .hpos              (scp_hpos),
    .vpos              (scp_vpos),
    .pixel_active      (scp_pixel_active),
    .hblank_fall       (scp_hblank_fall),
    .vblank_fall       (scp_vblank_fall),

    // Decoded register outputs (not used in this integration layer)
    /* verilator lint_off PINCONNECTEMPTY */
    .bgscrollx         (),
    .bgscrolly         (),
    .bgzoom            (),
    .bg_dx             (),
    .bg_dy             (),
    .text_scrollx      (),
    .text_scrolly      (),
    .dblwidth          (),
    .flipscreen        (),
    .priority_order    (),
    .rowzoom_en        (),
    .bg_priority       (),
    /* verilator lint_on PINCONNECTEMPTY */

    // GFX ROM interface (4 independent ports)
    .gfx_addr          (scp_gfx_addr_raw),
    .gfx_data          (scp_gfx_data_raw),
    .gfx_rd            (scp_gfx_rd),

    // Pixel output → palette
    .pixel_out         (scp_pixel_out),
    .pixel_valid_out   (scp_pixel_valid)
);

// =============================================================================
// TC0510NIO — I/O Controller
// =============================================================================
logic [15:0] nio_dout;
/* verilator lint_off UNUSED */
logic [3:0][7:0] nio_out_reg;
/* verilator lint_on UNUSED */

tc0510nio u_nio (
    .clk          (clk_sys),
    .reset_n      (reset_n),
    .cs_n         (nio_cs_n),
    .we           (!cpua_rw),
    .addr         (cpua_addr[4:1]),
    .din          (cpua_din),
    .be           ({!cpua_uds_n, !cpua_lds_n}),
    .dout         (nio_dout),
    .joystick_p1  (joystick_p1),
    .joystick_p2  (joystick_p2),
    .coin         (coin),
    .service      (service),
    .wheel        (wheel),
    .pedal        (pedal),
    .out_reg      (nio_out_reg)
);

// =============================================================================
// Priority Compositor
// =============================================================================
// Resolves the final pixel from TC0480SCP (BG/text), TC0150ROD (road), and
// TC0370MSO (sprites) using MAME dblaxle priority rules.
// All three chips run in clk_pix domain; compositor is purely combinational.
// =============================================================================
logic [11:0] comp_pix_index;
logic        comp_pix_valid;

taito_z_compositor u_comp (
    // TC0480SCP output
    .scp_pixel_out    (scp_pixel_out),
    .scp_pixel_valid  (scp_pixel_valid),

    // TC0150ROD road output
    .rod_pix_out      (rod_pix_out),
    .rod_pix_valid    (rod_pix_valid),
    .rod_pix_transp   (rod_pix_transp),

    // TC0370MSO sprite output
    .mso_pix_out      (mso_pix_out),
    .mso_pix_valid    (mso_pix_valid),
    .mso_pix_priority (mso_pix_priority),

    // Compositor output → palette
    .comp_pix_index   (comp_pix_index),
    .comp_pix_valid   (comp_pix_valid)
);

// =============================================================================
// Palette RAM
// =============================================================================
logic [15:0] pal_dout;

taito_z_palette u_pal (
    .clk       (clk_sys),
    .reset_n   (reset_n),
    .cpu_cs    (pal_cs),
    .cpu_we    (!cpua_rw),
    .cpu_addr  (cpua_addr[12:1]),
    .cpu_din   (cpua_din),
    .cpu_be    ({!cpua_uds_n, !cpua_lds_n}),
    .cpu_dout  (pal_dout),
    // Palette lookup: compositor output — final priority-resolved palette index
    .pix_index (comp_pix_index),
    .pix_valid (comp_pix_valid),
    .rgb_r     (rgb_r),
    .rgb_g     (rgb_g),
    .rgb_b     (rgb_b)
);

// =============================================================================
// TC0140SYT — Sound Communication
// =============================================================================
// dblaxle: SYT master at 0x620000–0x620003 (byte).
//   Word addresses: 0x310000–0x310001
//   cpua_addr[1] = MA1 (port register vs comm register)
//
// Data nibble protocol: D[4:1] per TC0140SYT spec.
//   MDin[3:0] = cpua_din[4:1]
//   MDout[3:0] → placed back on D[4:1]
//
// ADPCM ROM base addresses (from integration_plan §7.4 SDRAM layout):
//   ADPCM-A: SDRAM 0x700000, ADPCM-B: SDRAM 0x880000
logic [3:0] syt_mdout;

// Z80 bus signals (driven by T80s u_z80 below)
logic [15:0] z80_addr;
logic  [7:0] z80_din;       // data Z80 writes to bus
logic        z80_mreq_n;
logic        z80_rd_n;
logic        z80_wr_n;
logic        z80_iorq_n;

// SYT → Z80 decoded outputs
logic [3:0] syt_z80_dout;
logic       z80_reset_n;
logic       z80_rom_cs0_n;
logic       z80_rom_cs1_n;
logic       z80_ram_cs_n;
logic       z80_rom_a14;
logic       z80_rom_a15;
logic       z80_opx_n;

// ADPCM ROM addresses from YM2610 (jt10) → TC0140SYT
logic [19:0] ym_adpcma_addr;
logic  [3:0] ym_adpcma_bank;
logic        ym_adpcma_roe_n;
logic [23:0] ym_adpcmb_addr;
logic        ym_adpcmb_roe_n;

// ADPCM data bytes: TC0140SYT → YM2610
logic [7:0] ym_ya_dout;
logic [7:0] ym_yb_dout;

// YM2610 /IRQ → Z80 /INT
logic z80_int_n;

// Construct 24-bit ADPCM addresses for TC0140SYT
logic [23:0] syt_yaa, syt_yba;
assign syt_yaa = { ym_adpcma_bank, ym_adpcma_addr };
assign syt_yba = { 4'b0, ym_adpcmb_addr[23:4] };

TC0140SYT #(
    .ADPCMA_ROM_BASE (27'h700000),
    .ADPCMB_ROM_BASE (27'h880000)
) u_syt (
    .clk     (clk_sys),
    .ce_12m  (1'b0),
    .ce_4m   (1'b0),
    .RESn    (reset_n),

    // 68000 master interface
    .MDin    (cpua_din[4:1]),
    .MDout   (syt_mdout),
    .MA1     (cpua_addr[1]),
    .MCSn    (syt_mcs_n),
    .MWRn    (cpua_rw),       // active-low write: 0 when cpua_rw=0 (write)
    .MRDn    (~cpua_rw),      // active-low read:  0 when cpua_rw=1 (read)

    // Z80 slave interface (wired to T80s u_z80 below)
    .MREQn   (z80_mreq_n),
    .RDn     (z80_rd_n),
    .WRn     (z80_wr_n),
    .A       (z80_addr),
    .Din     (z80_din[3:0]),  // Z80 data lower nibble

    // Z80 control outputs
    .Dout    (syt_z80_dout),
    .ROUTn   (z80_reset_n),
    .ROMCS0n (z80_rom_cs0_n),
    .ROMCS1n (z80_rom_cs1_n),
    .RAMCSn  (z80_ram_cs_n),
    .ROMA14  (z80_rom_a14),
    .ROMA15  (z80_rom_a15),
    .OPXn    (z80_opx_n),

    // ADPCM ROM: YM2610 drives OEn + address, SYT fetches bytes from SDRAM
    .YAOEn   (ym_adpcma_roe_n),
    .YBOEn   (ym_adpcmb_roe_n),
    .YAA     (syt_yaa),
    .YBA     (ym_adpcmb_addr),
    .YAD     (ym_ya_dout),
    .YBD     (ym_yb_dout),

    /* verilator lint_off PINCONNECTEMPTY */
    .CSAn    (),
    .CSBn    (),
    .IOA     (),
    .IOC     (),
    /* verilator lint_on PINCONNECTEMPTY */

    // SDRAM for ADPCM ROM
    .sdr_address (sdr_addr),
    .sdr_data    (sdr_data),
    .sdr_req     (sdr_req),
    .sdr_ack     (sdr_ack)
);

// =============================================================================
// YM2610 (jt10) — FM synthesis + ADPCM-A + ADPCM-B
// =============================================================================
// Clock: clk_sound (~4 MHz, provided by emu.sv clock divider).
// Bus: Z80 drives addr[1:0] + din + cs_n + wr_n; jt10 outputs dout.
// ADPCM ROM: addresses sent to TC0140SYT; byte data returned via YAD/YBD.
logic [7:0] ym_dout;

/* verilator lint_off PINCONNECTEMPTY */
jt10 u_ym2610 (
    .rst          (~z80_reset_n),
    .clk          (clk_sys),
    .cen          (clk_sound),
    .din          (z80_din),
    .addr         (z80_addr[1:0]),
    .cs_n         (z80_opx_n),
    .wr_n         (z80_wr_n),

    .dout         (ym_dout),
    .irq_n        (z80_int_n),      // YM2610 /IRQ → Z80 /INT

    // ADPCM-A ROM interface (TC0140SYT handles SDRAM fetches)
    .adpcma_addr  (ym_adpcma_addr),
    .adpcma_bank  (ym_adpcma_bank),
    .adpcma_roe_n (ym_adpcma_roe_n),
    .adpcma_data  (ym_ya_dout),

    // ADPCM-B ROM interface
    .adpcmb_addr  (ym_adpcmb_addr),
    .adpcmb_roe_n (ym_adpcmb_roe_n),
    .adpcmb_data  (ym_yb_dout),

    // Audio output
    .snd_left     (snd_left),
    .snd_right    (snd_right),
    .snd_sample   (),

    // Separated outputs (unused — combined output used)
    .psg_A        (),
    .psg_B        (),
    .psg_C        (),
    .psg_snd      (),
    .fm_snd       (),

    // ADPCM-A channel enable: all 6 channels active
    .ch_enable    (6'h3f)
);
/* verilator lint_on PINCONNECTEMPTY */

// =============================================================================
// Z80 Sound CPU (T80s)
// =============================================================================
// The Z80 runs at ~4 MHz (clk_sound clock enable) and accesses:
//   0x0000–0x7FFF  Z80 ROM bank 0 (SDRAM 0x0C0000–0x0C7FFF; 32KB fixed)
//   0x8000–0xBFFF  banked ROM (via TC0140SYT ROMCS1n / ROMA14-15)
//   0xC000–0xC7FF  Z80 work RAM (2KB, internal BRAM — mirrors to fill 8KB)
//   0xE000–0xE001  YM2610 registers (TC0140SYT decodes → z80_opx_n)
//   0xE200         TC0140SYT comm register (decoded by TC0140SYT itself)
//
// Z80 ROM SDRAM reads: when z80_rom_cs0_n or z80_rom_cs1_n is active and the
// Z80 asserts RD_n, we toggle z80_rom_req to SDRAM CH4 and hold WAIT_n=0
// until z80_rom_ack matches.
// Word address = 27'h060000 + {z80_rom_a15, z80_rom_a14, z80_addr[13:1]}
// (SDRAM base 0x0C0000 = word 0x060000; ROM is 16-bit word-organised)

// Z80 2KB work RAM (0xC000–0xC7FF)
logic [7:0] z80_ram [0:2047];
logic [7:0] z80_ram_dout;

always_ff @(posedge clk_sys) begin
    if (!z80_ram_cs_n && !z80_wr_n && clk_sound)
        z80_ram[z80_addr[10:0]] <= z80_din;
end

always_ff @(posedge clk_sys) begin
    if (!z80_ram_cs_n)
        z80_ram_dout <= z80_ram[z80_addr[10:0]];
end

// Z80 ROM chip-select: active when either ROM CS is asserted by TC0140SYT
logic z80_rom_cs;
assign z80_rom_cs = !z80_rom_cs0_n | !z80_rom_cs1_n;

// Z80 ROM SDRAM request/stall logic
logic z80_rom_req_r;
logic z80_rom_pending;
logic z80_rom_byte_sel;
logic z80_wait_n;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        z80_rom_req_r    <= 1'b0;
        z80_rom_pending  <= 1'b0;
        z80_rom_byte_sel <= 1'b0;
        z80_wait_n       <= 1'b1;
    end else begin
        if (z80_rom_cs && !z80_rd_n && !z80_mreq_n && !z80_rom_pending) begin
            // New Z80 ROM read — issue SDRAM request
            z80_rom_req_r    <= ~z80_rom_req_r;
            z80_rom_pending  <= 1'b1;
            z80_rom_byte_sel <= z80_addr[0];
            z80_wait_n       <= 1'b0;   // stall Z80
        end else if (z80_rom_pending && (z80_rom_req_r == z80_rom_ack)) begin
            // SDRAM returned data
            z80_rom_pending <= 1'b0;
            z80_wait_n      <= 1'b1;   // release Z80
        end
    end
end

assign z80_rom_req  = z80_rom_req_r;
assign z80_rom_addr = 27'h060000 + {z80_rom_a15, z80_rom_a14, z80_addr[13:1]};

// Z80 data input mux
logic [7:0] z80_cpu_din;
always_comb begin
    if (!z80_opx_n)
        z80_cpu_din = ym_dout;
    else if (!z80_ram_cs_n)
        z80_cpu_din = z80_ram_dout;
    else if (z80_rom_cs)
        // Select byte lane: even address → word[15:8], odd → word[7:0]
        z80_cpu_din = z80_rom_byte_sel ? z80_rom_data[7:0] : z80_rom_data[15:8];
    else
        z80_cpu_din = {4'hF, syt_z80_dout};  // SYT nibble in lower 4 bits
end

// Z80 CPU — T80s (Verilog-synthesised T80)
/* verilator lint_off UNUSED */
logic z80_m1_n, z80_rfsh_n, z80_halt_n, z80_busak_n;
/* verilator lint_on UNUSED */

T80s u_z80 (
    .RESET_n (z80_reset_n),
    .CLK     (clk_sys),
    .CEN     (clk_sound),
    .WAIT_n  (z80_wait_n),
    .INT_n   (z80_int_n),
    .NMI_n   (1'b1),
    .BUSRQ_n (1'b1),
    .OUT0    (1'b0),
    .DI      (z80_cpu_din),
    .M1_n    (z80_m1_n),
    .MREQ_n  (z80_mreq_n),
    .IORQ_n  (z80_iorq_n),
    .RD_n    (z80_rd_n),
    .WR_n    (z80_wr_n),
    .RFSH_n  (z80_rfsh_n),
    .HALT_n  (z80_halt_n),
    .BUSAK_n (z80_busak_n),
    .A       (z80_addr),
    .DOUT    (z80_din)
);

// =============================================================================
// Sprite RAM note — no standalone BRAM needed
// =============================================================================
// TC0370MSO owns sprite RAM internally (8K × 16-bit dual-port BRAM).
// CPU A writes are routed to TC0370MSO's spr_cs/spr_we/spr_addr/spr_din.
// CPU A reads return mso_spr_dout (TC0370MSO registered read port).
// No separate sprite_ram BRAM is needed in taito_z.sv.

// =============================================================================
// Shared RAM — 64KB dual-port BRAM
//   CPU A: 0x200000–0x20FFFF  (byte) = word base 0x100000, 15-bit word index
//   CPU B: 0x110000–0x11FFFF  (byte) = word base 0x088000, 15-bit word index
// =============================================================================
logic [15:0] shared_ram [0:32767];
logic [15:0] shram_a_dout;
logic [15:0] shram_b_dout;

// Port A and Port B combined — single always_ff driver for shared_ram (avoids Error 10028)
always_ff @(posedge clk_sys) begin
    // Write: Port A has priority over Port B on same-address collision
    if (shram_a_cs && !cpua_rw) begin
        if (!cpua_uds_n) shared_ram[cpua_addr[15:1]][15:8] <= cpua_din[15:8];
        if (!cpua_lds_n) shared_ram[cpua_addr[15:1]][ 7:0] <= cpua_din[ 7:0];
    end else if (shram_b_cs && !cpub_rw) begin
        if (!cpub_uds_n) shared_ram[cpub_addr[15:1]][15:8] <= cpub_din[15:8];
        if (!cpub_lds_n) shared_ram[cpub_addr[15:1]][ 7:0] <= cpub_din[ 7:0];
    end
    // Read: both ports always active
    shram_a_dout <= shared_ram[cpua_addr[15:1]];
    shram_b_dout <= shared_ram[cpub_addr[15:1]];
end

// =============================================================================
// Work RAM A — 64KB BRAM (CPU A private, 0x100000–0x10FFFF)
// Only 16KB (0x100000–0x103FFF) used in dblaxle; full 64KB declared for margin.
// =============================================================================
logic [15:0] work_ram_a [0:32767];
logic [15:0] wrama_dout;

always_ff @(posedge clk_sys) begin
    if (wrama_cs && !cpua_rw) begin
        if (!cpua_uds_n) work_ram_a[cpua_addr[15:1]][15:8] <= cpua_din[15:8];
        if (!cpua_lds_n) work_ram_a[cpua_addr[15:1]][ 7:0] <= cpua_din[ 7:0];
    end
    wrama_dout <= work_ram_a[cpua_addr[15:1]];
end

// =============================================================================
// Work RAM B — 32KB BRAM (CPU B private, 0x100000–0x107FFF)
// dblaxle CPU B uses only 0x100000–0x103FFF (16KB). 32KB declared for margin.
// =============================================================================
logic [15:0] work_ram_b [0:16383];
logic [15:0] wramb_dout;

always_ff @(posedge clk_sys) begin
    if (wramb_cs && !cpub_rw) begin
        if (!cpub_uds_n) work_ram_b[cpub_addr[14:1]][15:8] <= cpub_din[15:8];
        if (!cpub_lds_n) work_ram_b[cpub_addr[14:1]][ 7:0] <= cpub_din[ 7:0];
    end
    wramb_dout <= work_ram_b[cpub_addr[14:1]];
end

// =============================================================================
// Network RAM — 16KB BRAM (CPU B 0x500000–0x503FFF)
// Inert for single-cabinet operation. Plain RAM, no external interface.
// =============================================================================
logic [15:0] net_ram [0:8191];
logic [15:0] netram_dout;

always_ff @(posedge clk_sys) begin
    if (netram_cs && !cpub_rw) begin
        if (!cpub_uds_n) net_ram[cpub_addr[13:1]][15:8] <= cpub_din[15:8];
        if (!cpub_lds_n) net_ram[cpub_addr[13:1]][ 7:0] <= cpub_din[ 7:0];
    end
    netram_dout <= net_ram[cpub_addr[13:1]];
end

// =============================================================================
// CPU B Reset Register (CPU A write at 0x600000–0x600001)
//   bit 0 = 1 → release CPU B reset (run)
//   bit 0 = 0 → assert CPU B reset (hold)
// =============================================================================
logic cpub_reset_reg;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)
        cpub_reset_reg <= 1'b0;
    else if (cpub_rst_cs && !cpua_rw)
        cpub_reset_reg <= cpua_din[0];
end

assign cpub_reset_n = reset_n && cpub_reset_reg;

// =============================================================================
// TC0150ROD — Road Generator (CPU B bus, 0x300000–0x301FFF)
// =============================================================================
// dblaxle parameters (from screen_update_dblaxle):
//   y_offs = 0 (default road Y alignment)
//   palette_offs = 0
//   road_type = 0 (standard road A/B fill)
//   road_trans = 0 (road not transparent overall)
//   low_priority = 1, high_priority = 2 (road between BG2 and sprites)
//
// CPU B address: 0x300000–0x301FFF (8KB = 4096 × 16-bit words, 12-bit index)
//   cpub_addr[12:1] = 12-bit word index
// =============================================================================
logic [15:0] rod_dout;
logic [14:0] rod_pix_out;
logic        rod_pix_valid;
logic        rod_pix_transp;
logic [ 7:0] rod_line_priority;
/* verilator lint_off UNUSED */
logic        rod_render_done;
/* verilator lint_on UNUSED */

tc0150rod u_rod (
    .clk            (clk_pix),
    .rst_n          (reset_n),

    // CPU B bus (0x300000–0x301FFF, byte address → word address cpub_addr[12:1])
    .cpu_cs         (rod_cs),
    .cpu_we         (!cpub_rw),
    .cpu_addr       (cpub_addr[12:1]),
    .cpu_din        (cpub_din),
    .cpu_dout       (rod_dout),
    .cpu_be         ({!cpub_uds_n, !cpub_lds_n}),
    /* verilator lint_off PINCONNECTEMPTY */
    .cpu_dtack_n    (),
    /* verilator lint_on PINCONNECTEMPTY */

    // Road ROM (toggle-req/ack SDRAM arbiter)
    .rom_addr       (rod_rom_addr),
    .rom_data       (rod_rom_data),
    .rom_req        (rod_rom_req),
    .rom_ack        (rod_rom_ack),

    // Video timing (from TC0480SCP, pixel-clock domain)
    .hblank         (scp_hblank),
    .vblank         (scp_vblank),
    .hpos           (scp_hpos[8:0]),
    .vpos           (scp_vpos[7:0]),

    // Game-specific parameters for dblaxle
    .y_offs         (8'sd0),
    .palette_offs   (8'd0),
    .road_type      (2'd0),
    .road_trans     (1'b0),
    .low_priority   (8'd1),
    .high_priority  (8'd2),

    // Pixel output
    .pix_out        (rod_pix_out),
    .pix_valid      (rod_pix_valid),
    .pix_transp     (rod_pix_transp),
    .line_priority  (rod_line_priority),
    .render_done    (rod_render_done)
);

// =============================================================================
// TC0370MSO — Sprite Scanner + TC0300FLA Line Buffer
// =============================================================================
// Sprite RAM is the 16KB BRAM above (CPU A writes at 0xC00000–0xC03FFF).
// TC0370MSO has its own internal copy of sprite RAM; here we wire the CPU A
// bus directly to TC0370MSO's spr_cs/spr_we interface so it maintains its own
// internal copy (the taito_z sprite_ram BRAM above is now the CPU-read path
// only; TC0370MSO owns the scanner-write/scan-read path internally).
//
// dblaxle parameters:
//   y_offs    = 7 (shifts sprites 7 pixels up to align with display area,
//               from bshark_draw_sprites_16x8 call in screen_update_dblaxle)
//   frame_sel = 0 (dblaxle uses single-buffer; frame toggle unused)
//   flip_screen = 0 (no screen flip in dblaxle)
// =============================================================================
logic [11:0] mso_pix_out;
logic        mso_pix_valid;
logic        mso_pix_priority;
/* verilator lint_off UNUSED */
logic [15:0] mso_spr_dout;
logic        mso_spr_dtack_n;
/* verilator lint_on UNUSED */

tc0370mso u_mso (
    .clk            (clk_pix),
    .rst_n          (reset_n),

    // CPU A sprite RAM interface (0xC00000–0xC03FFF)
    // cpua_addr[13:1] = 13-bit word address within 16KB sprite RAM
    .spr_cs         (spr_ram_cs),
    .spr_we         (!cpua_rw),
    .spr_addr       (cpua_addr[13:1]),
    .spr_din        (cpua_din),
    .spr_dout       (mso_spr_dout),
    .spr_be         ({!cpua_uds_n, !cpua_lds_n}),
    .spr_dtack_n    (mso_spr_dtack_n),

    // Spritemap (STYM) ROM — 16-bit, 18-bit word address
    .stym_addr      (stym_addr),
    .stym_data      (stym_data),
    .stym_req       (stym_req),
    .stym_ack       (stym_ack),

    // OBJ GFX ROM — 64-bit wide, 23-bit byte address
    .obj_addr       (spr_addr),
    .obj_data       (spr_data),
    .obj_req        (spr_req),
    .obj_ack        (spr_ack),

    // Video timing (from TC0480SCP, pixel-clock domain)
    .vblank         (scp_vblank),
    .hblank         (scp_hblank),
    .hpos           (scp_hpos[8:0]),
    .vpos           (scp_vpos[7:0]),

    // Game-specific parameters for dblaxle
    .y_offs         (4'sd7),
    .frame_sel      (1'b0),
    .flip_screen    (1'b0),

    // Pixel output
    .pix_out        (mso_pix_out),
    .pix_valid      (mso_pix_valid),
    .pix_priority   (mso_pix_priority)
);

// =============================================================================
// CPU A Data Bus Read Mux
// Priority: SCP VRAM > SCP CTRL > PAL > NIO > SYT > SPR_RAM > SHRAM_A > WRAM_A
// Open bus = 0xFFFF
// =============================================================================
logic [15:0] syt_a_dout_word;
assign syt_a_dout_word = {11'b0, syt_mdout, 1'b0};  // nibble in D[4:1]

always_comb begin
    if (scp_vram_cs)
        cpua_dout = scp_vram_dout;
    else if (scp_ctrl_cs)
        cpua_dout = scp_ctrl_dout;
    else if (pal_cs)
        cpua_dout = pal_dout;
    else if (!nio_cs_n)
        cpua_dout = nio_dout;
    else if (!syt_mcs_n)
        cpua_dout = syt_a_dout_word;
    else if (spr_ram_cs)
        cpua_dout = mso_spr_dout;
    else if (shram_a_cs)
        cpua_dout = shram_a_dout;
    else if (wrama_cs)
        cpua_dout = wrama_dout;
    else
        cpua_dout = 16'hFFFF;
end

// =============================================================================
// CPU B Data Bus Read Mux
// Priority: SHRAM_B > WRAM_B > ROD > NET_RAM
// Open bus = 0xFFFF
// =============================================================================
always_comb begin
    if (shram_b_cs)
        cpub_dout = shram_b_dout;
    else if (wramb_cs)
        cpub_dout = wramb_dout;
    else if (rod_cs)
        cpub_dout = rod_dout;
    else if (netram_cs)
        cpub_dout = netram_dout;
    else
        cpub_dout = 16'hFFFF;
end

// =============================================================================
// DTACK Generation (CPU A)
// Simple 1-cycle registered DTACK for all local chips.
// SDRAM-backed regions (prog ROM 0x000000–0x07FFFF) require the external
// SDRAM arbiter to assert DTACK; those accesses must be handled by the
// HPS wrapper — they fall through to open bus here (no local CS).
// =============================================================================
logic cpua_any_cs;
logic cpua_dtack_r;

assign cpua_any_cs = scp_vram_cs | scp_ctrl_cs | pal_cs | !nio_cs_n |
                     !syt_mcs_n | spr_ram_cs | shram_a_cs | wrama_cs | cpub_rst_cs;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)
        cpua_dtack_r <= 1'b0;
    else
        cpua_dtack_r <= cpua_any_cs;
end

assign cpua_dtack_n = cpua_as_n ? 1'b1 : !cpua_dtack_r;

// =============================================================================
// DTACK Generation (CPU B)
// =============================================================================
logic cpub_any_cs;
logic cpub_dtack_r;

assign cpub_any_cs = shram_b_cs | wramb_cs | rod_cs | netram_cs;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)
        cpub_dtack_r <= 1'b0;
    else
        cpub_dtack_r <= cpub_any_cs;
end

assign cpub_dtack_n = cpub_as_n ? 1'b1 : !cpub_dtack_r;

// =============================================================================
// Interrupt Controller
// VBL (vblank_fall from TC0480SCP) → IRQ4 on CPU A and CPU B
// HOLD_LINE semantics: latch and hold for 16-bit timer window.
// dblaxle: single IRQ4 per VBL; no IRQ6 (racingb IRQ6 deferred).
// =============================================================================
logic        ipl_a_active, ipl_b_active;
logic [15:0] ipl_a_timer,  ipl_b_timer;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ipl_a_active <= 1'b0;
        ipl_b_active <= 1'b0;
        ipl_a_timer  <= 16'b0;
        ipl_b_timer  <= 16'b0;
    end else begin
        // vblank_fall is in clk_pix domain; sample in clk_sys domain.
        // At the resolutions involved this is safe (vblank_fall is a single
        // clk_pix pulse, and clk_sys is typically much faster than clk_pix).
        if (scp_vblank_fall) begin
            ipl_a_active <= 1'b1;
            ipl_a_timer  <= 16'hFFFF;
            ipl_b_active <= 1'b1;
            ipl_b_timer  <= 16'hFFFF;
        end else begin
            if (ipl_a_active) begin
                if (ipl_a_timer == 16'b0) ipl_a_active <= 1'b0;
                else                       ipl_a_timer  <= ipl_a_timer - 16'd1;
            end
            if (ipl_b_active) begin
                if (ipl_b_timer == 16'b0) ipl_b_active <= 1'b0;
                else                       ipl_b_timer  <= ipl_b_timer - 16'd1;
            end
        end
    end
end

// IRQ4: active-low IPL encoding = ~3'd4 = 3'b011
assign cpua_ipl_n = ipl_a_active ? ~3'd4 : 3'b111;
assign cpub_ipl_n = ipl_b_active ? ~3'd4 : 3'b111;

// =============================================================================
// Video Sync / Blank Output
// TC0480SCP generates its own timing in clk_pix domain.
// hsync/vsync from SCP are active-high internally; invert for active-low output.
// =============================================================================
assign hsync_n = !scp_hsync;
assign vsync_n = !scp_vsync;
assign hblank  = scp_hblank;
assign vblank  = scp_vblank;

// =============================================================================
// Unused signal suppression
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused;
assign _unused = ^{scp_pixel_active, scp_hblank_fall,
                   scp_pixel_out[15:12],  // upper 4 bits not used as palette index
                   scp_hpos[9],           // TC0370MSO/TC0150ROD only need hpos[8:0]
                   scp_vpos[8],           // TC0370MSO/TC0150ROD only need vpos[7:0]
                   gfx_ack,              // TC0480SCP gfx_ack consumed by toggle-bridge
                   rod_line_priority,    // road priority tag not consumed by compositor
                   z80_m1_n, z80_rfsh_n, z80_halt_n, z80_busak_n,
                   z80_iorq_n};
/* verilator lint_on UNUSED */

endmodule
