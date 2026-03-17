`default_nettype none
// =============================================================================
// taito_z.sv — Taito Z System Board Top-Level Integration
// =============================================================================
//
// Primary target: Double Axle (dblaxle) / Racing Beat (racingb)
// Two MC68000 CPUs (CPU A @ 16 MHz, CPU B @ 16 MHz), Z80 + YM2610 sound.
//
// Instantiated chips / blocks:
//   tc0480scp     — Tilemap engine (BG0–BG3 + FG text)
//   tc0510nio     — I/O controller (joystick, coin, wheel, pedal)
//   taito_z_palette — Inline xBGR_555 palette BRAM (no TC0260DAR)
//   TC0140SYT     — 68000↔Z80 sound communication + ADPCM ROM arbiter
//   tc0150rod_stub — Road generator stub (TC0150ROD — deferred)
//   tc0370mso_stub — Sprite scanner stub (TC0370MSO — deferred)
//   sprite_ram    — 16KB BRAM, CPU A-writable
//   shared_ram    — 64KB dual-port BRAM (CPU A ↔ CPU B)
//   work_ram_a    — 64KB BRAM (CPU A private)
//   work_ram_b    — 32KB BRAM (CPU B private)
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
// Deferred / stubbed:
//   TC0150ROD: road generator chip (CPU B bus, 0x300000–0x301FFF)
//   TC0370MSO: sprite scanner/renderer
//   Priority mixer: BG0→BG1→road→sprites→BG3→text
//   SDRAM prog ROM fetches (CPU A/B): pass-through to sdr_* ports
//   GFX ROM SDRAM bridge: TC0480SCP 4-port gfx_addr → gfx_* ports
//   Sprite ROM SDRAM bridge: TC0370MSO sprite ROM → spr_* ports
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

    // ── Sprite ROM (TC0370MSO scanner — 64-bit wide) ──────────────────────────
    output logic [21:0] spr_addr,
    input  logic [63:0] spr_data,
    output logic        spr_req,
    input  logic        spr_ack,

    // ── SDRAM (prog ROM fetch + ADPCM — shared arbiter) ──────────────────────
    output logic [26:0] sdr_addr,
    input  logic [15:0] sdr_data,
    output logic        sdr_req,
    input  logic        sdr_ack,

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
logic [7:0] nio_out_reg [0:3];
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
    // Palette lookup: TC0480SCP pixel_out[11:0] = palette index
    .pix_index (scp_pixel_out[11:0]),
    .pix_valid (scp_pixel_valid),
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

    // Z80 interface — tied off (Z80 instantiated in HPS wrapper)
    .MREQn   (1'b1),
    .RDn     (1'b1),
    .WRn     (1'b1),
    .A       (16'b0),
    .Din     (4'b0),
    /* verilator lint_off PINCONNECTEMPTY */
    .Dout    (),
    .ROUTn   (),
    .ROMCS0n (),
    .ROMCS1n (),
    .RAMCSn  (),
    .ROMA14  (),
    .ROMA15  (),
    .OPXn    (),
    .YAOEn   (1'b1),
    .YBOEn   (1'b1),
    .YAA     (24'b0),
    .YBA     (24'b0),
    .YAD     (),
    .YBD     (),
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
// Sprite RAM — 16KB BRAM (CPU A write at 0xC00000–0xC03FFF)
// TC0370MSO reads this autonomously via stub below.
// =============================================================================
logic [15:0] spr_ram [0:8191];
logic [15:0] spr_ram_dout;

always_ff @(posedge clk_sys) begin
    if (spr_ram_cs && !cpua_rw) begin
        if (!cpua_uds_n) spr_ram[cpua_addr[13:1]][15:8] <= cpua_din[15:8];
        if (!cpua_lds_n) spr_ram[cpua_addr[13:1]][ 7:0] <= cpua_din[ 7:0];
    end
    spr_ram_dout <= spr_ram[cpua_addr[13:1]];
end

// =============================================================================
// Shared RAM — 64KB dual-port BRAM
//   CPU A: 0x200000–0x20FFFF  (byte) = word base 0x100000, 15-bit word index
//   CPU B: 0x110000–0x11FFFF  (byte) = word base 0x088000, 15-bit word index
// =============================================================================
logic [15:0] shared_ram [0:32767];
logic [15:0] shram_a_dout;
logic [15:0] shram_b_dout;

// Port A (CPU A)
always_ff @(posedge clk_sys) begin
    if (shram_a_cs && !cpua_rw) begin
        if (!cpua_uds_n) shared_ram[cpua_addr[15:1]][15:8] <= cpua_din[15:8];
        if (!cpua_lds_n) shared_ram[cpua_addr[15:1]][ 7:0] <= cpua_din[ 7:0];
    end
    shram_a_dout <= shared_ram[cpua_addr[15:1]];
end

// Port B (CPU B)
always_ff @(posedge clk_sys) begin
    if (shram_b_cs && !cpub_rw) begin
        if (!cpub_uds_n) shared_ram[cpub_addr[15:1]][15:8] <= cpub_din[15:8];
        if (!cpub_lds_n) shared_ram[cpub_addr[15:1]][ 7:0] <= cpub_din[ 7:0];
    end
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
// TC0150ROD Stub — Road Generator (CPU B bus, 0x300000–0x301FFF)
// Deferred: full TC0150ROD RTL not yet implemented.
// Stub: accepts CPU B writes (captured but ignored), returns open bus on read,
//       outputs road_pixel = 4'h0 (transparent / no road).
// =============================================================================
/* verilator lint_off UNUSED */
logic [15:0] rod_ram [0:4095];
/* verilator lint_on UNUSED */
logic [15:0] rod_dout;
/* verilator lint_off UNUSED */
logic [ 3:0] road_pixel;
/* verilator lint_on UNUSED */

always_ff @(posedge clk_sys) begin
    if (rod_cs && !cpub_rw) begin
        if (!cpub_uds_n) rod_ram[cpub_addr[12:1]][15:8] <= cpub_din[15:8];
        if (!cpub_lds_n) rod_ram[cpub_addr[12:1]][ 7:0] <= cpub_din[ 7:0];
    end
    rod_dout <= rod_ram[cpub_addr[12:1]];
end

assign road_pixel = 4'h0;   // stub: no road rendered

// =============================================================================
// TC0370MSO Stub — Sprite Scanner / Renderer
// Deferred: full sprite scanner RTL not yet implemented.
// Reads sprite_ram (wired above), outputs spr_pixel = 4'h0.
// spr_addr / spr_data / spr_req / spr_ack tied off.
// =============================================================================
/* verilator lint_off UNUSED */
logic [ 3:0] spr_pixel;
/* verilator lint_on UNUSED */

assign spr_pixel = 4'h0;    // stub: no sprites rendered
assign spr_addr  = 22'b0;
assign spr_req   = 1'b0;
// spr_data and spr_ack are inputs — no action needed

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
        cpua_dout = spr_ram_dout;
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
assign _unused = ^{scp_hpos, scp_vpos, scp_pixel_active, scp_hblank_fall,
                   scp_pixel_out[15:12],  // upper 4 bits of pixel_out not used as palette index
                   gfx_ack, spr_data, spr_ack};
/* verilator lint_on UNUSED */

endmodule
