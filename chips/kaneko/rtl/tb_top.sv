// =============================================================================
// tb_top.sv — Simulation top-level for Kaneko 16 (berlwall)
//
// Instantiates kaneko16 + fx68k so the Verilator testbench can execute
// the real Berlin Wall program ROM.
//
// Architecture:
//   - fx68k CPU (direct instantiation, no adapter — same pattern as NMK)
//   - kaneko16 chip (Gate 1–5 RTL)
//   - enPhi1 / enPhi2 driven from C++ testbench (GUARDRAILS Rule 13)
//   - bypass_en/bypass_data/bypass_dtack_n: C++ drives CPU iEdb directly
//     for ROM reads (addresses 0x000000–0x0FFFFF)
//   - Combinational reads for sprite/BG tile ROMs (zero-latency)
//   - VBlank IRQ latched, cleared on IACK (GUARDRAILS Rule 11)
// =============================================================================
`default_nettype none

/* verilator lint_off SYNCASYNCNET */
module tb_top (
    // ── Clocks / Reset ──────────────────────────────────────────────────────
    input  logic        clk_sys,
    input  logic        reset_n,

    // ── Sprite ROM (combinational zero-latency) ──────────────────────────────
    output logic [20:0] spr_rom_addr,
    input  logic [31:0] spr_rom_data,
    output logic        spr_rom_rd,

    // ── BG Tile ROM (combinational zero-latency) ─────────────────────────────
    output logic [20:0] bg_tile_rom_addr,
    input  logic [7:0]  bg_tile_rom_data,

    // ── Video timing inputs (from C++ timing generator) ─────────────────────
    input  logic        vsync_n_in,
    input  logic        hsync_n_in,
    input  logic [8:0]  hpos,
    input  logic [7:0]  vpos,

    // ── Player inputs ───────────────────────────────────────────────────────
    input  logic [15:0] joystick_p1,
    input  logic [15:0] joystick_p2,
    input  logic [15:0] coin_in,
    input  logic [15:0] dip_switches,

    // ── Video outputs ────────────────────────────────────────────────────────
    output logic [7:0]  rgb_r,
    output logic [7:0]  rgb_g,
    output logic [7:0]  rgb_b,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,

    // ── Debug: CPU bus ───────────────────────────────────────────────────────
    output logic [23:1] dbg_cpu_addr,
    output logic        dbg_cpu_as_n,
    output logic        dbg_cpu_rw,
    output logic [15:0] dbg_cpu_din,
    output logic        dbg_cpu_dtack_n,
    output logic        dbg_cpu_halted_n,
    output logic [15:0] dbg_cpu_dout,

    // ── Bus bypass: C++ testbench drives CPU data/DTACK for ROM reads ────────
    // When bypass_en=1: CPU reads from bypass_data with bypass_dtack_n
    // When bypass_en=0: CPU reads from kaneko16 register space
    input  logic        bypass_en,
    input  logic [15:0] bypass_data,
    input  logic        bypass_dtack_n,

    // ── Clock enables (driven from C++ — GUARDRAILS Rule 13) ────────────────
    input  logic        enPhi1,
    input  logic        enPhi2
);

// =============================================================================
// Internal CPU bus wires
// =============================================================================
logic [23:1] cpu_addr;
logic [15:0] cpu_din;      // write data: CPU → kaneko16
logic [15:0] cpu_dout_k16; // read data: kaneko16 → CPU (register space)
logic [15:0] cpu_iEdb;     // data to feed into fx68k iEdb
logic        cpu_rw;
logic        cpu_uds_n;
logic        cpu_lds_n;
logic        cpu_as_n;
logic        cpu_dtack_n;
logic [2:0]  cpu_ipl_n;

// =============================================================================
// IACK detection: VPAn for 68000 autovector
// FC2:FC1:FC0 = 111 and AS_n=0 → interrupt acknowledge cycle
// GUARDRAILS Rule 11: VPAn = IACK, NOT tied to 1'b1
// =============================================================================
logic fx_FC0, fx_FC1, fx_FC2;
logic inta_n;
assign inta_n = ~&{fx_FC2, fx_FC1, fx_FC0, ~cpu_as_n};

logic cpu_halted_n_raw;

// =============================================================================
// Data/DTACK mux: bypass (ROM) vs kaneko16 register/RAM space
// =============================================================================
logic k16_dtack_n;

// kaneko16 register space: immediate DTACK (combinational, 1 cycle)
always_comb begin
    k16_dtack_n = 1'b1;
    if (!cpu_as_n && !bypass_en) begin
        k16_dtack_n = 1'b0;  // always immediate for register/RAM space
    end
end

assign cpu_iEdb   = bypass_en ? bypass_data    : cpu_dout_k16;
assign cpu_dtack_n = bypass_en ? bypass_dtack_n : k16_dtack_n;

// =============================================================================
// fx68k — MC68000 CPU (direct instantiation)
// =============================================================================
fx68k u_cpu (
    .clk        (clk_sys),
    .HALTn      (1'b1),
    .extReset   (!reset_n),
    .pwrUp      (!reset_n),
    .enPhi1     (enPhi1),
    .enPhi2     (enPhi2),

    // Bus outputs
    .eRWn       (cpu_rw),
    .ASn        (cpu_as_n),
    .LDSn       (cpu_lds_n),
    .UDSn       (cpu_uds_n),
    .E          (),
    .VMAn       (),

    // Function codes — for IACK detection
    .FC0        (fx_FC0),
    .FC1        (fx_FC1),
    .FC2        (fx_FC2),

    // Bus arbitration
    .BGn        (),
    .oRESETn    (),
    .oHALTEDn   (cpu_halted_n_raw),

    // Bus inputs
    .DTACKn     (cpu_dtack_n),
    .VPAn       (inta_n),
    .BERRn      (1'b1),
    .BRn        (1'b1),
    .BGACKn     (1'b1),

    // Interrupts
    .IPL0n      (cpu_ipl_n[0]),
    .IPL1n      (cpu_ipl_n[1]),
    .IPL2n      (cpu_ipl_n[2]),

    // Data
    .iEdb       (cpu_iEdb),
    .oEdb       (cpu_din),

    // Address
    .eab        (cpu_addr)
);

// =============================================================================
// VBlank/HBlank interrupt → CPU IPL
// GUARDRAILS Rule 11: cleared on IACK
// =============================================================================
logic vblank_irq_raw;
logic vblank_irq_latched;

// Latch vblank_irq — held until CPU acknowledges (IACK cycle)
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        vblank_irq_latched <= 1'b0;
    end else begin
        if (vblank_irq_raw) begin
            vblank_irq_latched <= 1'b1;
        end else if (!inta_n) begin
            // IACK cycle clears the interrupt
            vblank_irq_latched <= 1'b0;
        end
    end
end

// IPL level 2: IPL2n=1, IPL1n=0, IPL0n=1 → level 2 interrupt (VBlank)
assign cpu_ipl_n[2] = 1'b1;
assign cpu_ipl_n[1] = ~vblank_irq_latched;
assign cpu_ipl_n[0] = 1'b1;

// =============================================================================
// Scanline position tracking (for Gate 3/4 inputs)
// =============================================================================
logic [8:0] bg_hpos_r;
logic [7:0] bg_vpos_r;
logic [1:0] bg_layer_q;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        bg_hpos_r  <= 9'h0;
        bg_vpos_r  <= 8'h0;
        bg_layer_q <= 2'h0;
    end else begin
        bg_hpos_r  <= hpos;
        bg_vpos_r  <= vpos;
        bg_layer_q <= bg_layer_q + 2'h1;
    end
end

// Scan trigger: one pulse when hpos transitions from non-zero to zero
logic [8:0] hpos_prev;
logic       scan_trig;
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) hpos_prev <= 9'h1FF;
    else hpos_prev <= hpos;
end
assign scan_trig = (hpos == 9'd0) && (hpos_prev != 9'd0);

// =============================================================================
// kaneko16 instantiation
// =============================================================================
// Stub inputs for Gate 4 BG VRAM write port
/* verilator lint_off UNUSEDSIGNAL */
logic [15:0] k16_scroll_x_0, k16_scroll_y_0;
logic [15:0] k16_scroll_x_1, k16_scroll_y_1;
logic [15:0] k16_scroll_x_2, k16_scroll_y_2;
logic [15:0] k16_scroll_x_3, k16_scroll_y_3;
logic [7:0]  k16_layer_ctrl_0, k16_layer_ctrl_1;
logic [7:0]  k16_layer_ctrl_2, k16_layer_ctrl_3;
logic [7:0]  k16_sprite_ctrl;
logic [3:0]  k16_map_base_sel;
logic [15:0] k16_joystick_1, k16_joystick_2;
logic [15:0] k16_coin_in_out, k16_dip_out;
logic [7:0]  k16_watchdog_ctr;
logic        k16_watchdog_rst;
logic [7:0]  k16_video_int_ctrl;
logic        k16_hblank_irq;
logic [6:0]  k16_gfx_bank_sel;
logic [7:0]  k16_mcu_status, k16_mcu_command, k16_mcu_param1, k16_mcu_param2;
kaneko16_sprite_t k16_display_list [0:255];
logic [7:0]  k16_display_list_count;
logic        k16_display_list_ready;
logic [3:0]  k16_bg_pix_valid;
logic [3:0][7:0] k16_bg_pix_color;
logic [3:0]  k16_bg_pix_priority;
logic        k16_spr_render_done;
/* verilator lint_on UNUSEDSIGNAL */

logic [8:0]  spr_rd_addr;
logic [7:0]  spr_rd_color;
logic        spr_rd_valid;
logic [3:0]  spr_rd_priority;
assign spr_rd_addr = hpos[8:0];

logic [7:0]  final_color;
logic        final_valid;

logic [15:0] layer_ctrl_in;
assign layer_ctrl_in = {8'h0, k16_layer_ctrl_0};

// k16_cs_n: active when address is NOT in ROM space (A[23:21] != 000)
// and AS_n is asserted
logic k16_cs_n;
// ROM space: A[23:21] = 3'b000 → byte addr 0x000000–0x1FFFFF
// kaneko16 address space starts at 0x100000 (work RAM) so it should
// only be selected for non-ROM addresses. For simplicity, always select
// kaneko16 for non-bypass cycles.
assign k16_cs_n = bypass_en ? 1'b1 : cpu_as_n;

kaneko16 u_k16 (
    .clk            (clk_sys),
    .rst_n          (reset_n),

    // CPU bus
    /* verilator lint_off SELRANGE */
    .cpu_addr       (cpu_addr[20:0]),
    /* verilator lint_on SELRANGE */
    .cpu_din        (cpu_din),
    .cpu_dout       (cpu_dout_k16),
    .cpu_cs_n       (k16_cs_n),
    .cpu_rd_n       (cpu_rw  ? 1'b0 : 1'b1),
    .cpu_wr_n       (cpu_rw  ? 1'b1 : 1'b0),
    .cpu_lds_n      (cpu_lds_n),
    .cpu_uds_n      (cpu_uds_n),

    // Video sync
    .vsync_n        (vsync_n_in),
    .hsync_n        (hsync_n_in),

    // Register outputs
    .scroll_x_0     (k16_scroll_x_0),
    .scroll_y_0     (k16_scroll_y_0),
    .scroll_x_1     (k16_scroll_x_1),
    .scroll_y_1     (k16_scroll_y_1),
    .scroll_x_2     (k16_scroll_x_2),
    .scroll_y_2     (k16_scroll_y_2),
    .scroll_x_3     (k16_scroll_x_3),
    .scroll_y_3     (k16_scroll_y_3),
    .layer_ctrl_0   (k16_layer_ctrl_0),
    .layer_ctrl_1   (k16_layer_ctrl_1),
    .layer_ctrl_2   (k16_layer_ctrl_2),
    .layer_ctrl_3   (k16_layer_ctrl_3),
    .sprite_ctrl    (k16_sprite_ctrl),
    .map_base_sel   (k16_map_base_sel),
    .joystick_1     (k16_joystick_1),
    .joystick_2     (k16_joystick_2),
    .coin_in        (k16_coin_in_out),
    .dip_switches   (k16_dip_out),
    .watchdog_counter(k16_watchdog_ctr),
    .watchdog_reset (k16_watchdog_rst),
    .video_int_ctrl (k16_video_int_ctrl),
    .vblank_irq     (vblank_irq_raw),
    .hblank_irq     (k16_hblank_irq),
    .gfx_bank_sel   (k16_gfx_bank_sel),
    .mcu_status     (k16_mcu_status),
    .mcu_command    (k16_mcu_command),
    .mcu_param1     (k16_mcu_param1),
    .mcu_param2     (k16_mcu_param2),

    // Gate 2: sprite display list
    .display_list       (k16_display_list),
    .display_list_count (k16_display_list_count),
    .display_list_ready (k16_display_list_ready),
    .irq_vblank         (),

    // Gate 4: BG tilemap VRAM write port (stubbed — no CPU writes to BG VRAM in sim)
    .bg_layer_sel   (2'h0),
    .bg_row_sel     (5'h0),
    .bg_col_sel     (5'h0),
    .bg_vram_din    (16'h0),
    .bg_vram_wr     (1'b0),

    // Gate 4: BG pixel pipeline
    .bg_hpos        (bg_hpos_r),
    .bg_vpos        (bg_vpos_r),
    .bg_layer_query (bg_layer_q),
    .bg_tile_rom_addr(bg_tile_rom_addr),
    .bg_tile_rom_data(bg_tile_rom_data),
    .bg_pix_valid   (k16_bg_pix_valid),
    .bg_pix_color   (k16_bg_pix_color),
    .bg_pix_priority(k16_bg_pix_priority),

    // Gate 3: sprite rasterizer
    .scan_trigger   (scan_trig),
    .current_scanline(vpos),
    .spr_rom_addr   (spr_rom_addr),
    .spr_rom_rd     (spr_rom_rd),
    .spr_rom_data   (spr_rom_data),
    .spr_rd_addr    (spr_rd_addr),
    .spr_rd_color   (spr_rd_color),
    .spr_rd_valid   (spr_rd_valid),
    .spr_rd_priority(spr_rd_priority),
    .spr_render_done(k16_spr_render_done),

    // Gate 5: priority mixer
    .layer_ctrl     (layer_ctrl_in),
    .final_color    (final_color),
    .final_valid    (final_valid)
);

// =============================================================================
// Video output: expand 8-bit color {palette[3:0], index[3:0]} to RGB
// For sim visualization: palette → R, index → G, mixed → B
// =============================================================================
always_comb begin
    if (final_valid) begin
        rgb_r = {final_color[7:4], final_color[7:4]};
        rgb_g = {final_color[3:0], final_color[3:0]};
        rgb_b = {final_color[7:4], final_color[3:0]};
    end else begin
        rgb_r = 8'h00;
        rgb_g = 8'h00;
        rgb_b = 8'h00;
    end
end

assign hsync_n = hsync_n_in;
assign vsync_n = vsync_n_in;
assign hblank  = (hpos >= 9'd320);
assign vblank  = (vpos >= 8'd240);

// =============================================================================
// Debug outputs
// =============================================================================
assign dbg_cpu_addr     = cpu_addr;
assign dbg_cpu_as_n     = cpu_as_n;
assign dbg_cpu_rw       = cpu_rw;
assign dbg_cpu_din      = cpu_din;
assign dbg_cpu_dtack_n  = cpu_dtack_n;
assign dbg_cpu_dout     = cpu_iEdb;
assign dbg_cpu_halted_n = cpu_halted_n_raw;

endmodule
