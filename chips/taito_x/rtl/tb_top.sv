// =============================================================================
// tb_top.sv — Simulation top-level for Taito X (Gigandes)
//
// Combines taito_x + fx68k (MC68000) + T80s (Z80 sound CPU) so the Verilator
// testbench gets real CPUs executing actual game ROMs.
//
// Key differences from NMK tb_top.sv:
//   - taito_x generates video timing INTERNALLY (no hblank_n_in/hpos/vpos inputs)
//   - External Z80 CPU (T80s) is instantiated here and wired to taito_x Z80 ports
//   - Z80 ROM served from SDRAM at offset 0x080000 (z80_rom_ channel)
//   - Z80 RAM is 8KB BRAM at addresses 0xC000–0xDFFF
//   - GFX ROM uses toggle-handshake 18-bit addr / 16-bit data (gfx_ channel)
//   - SDRAM (sdr_) for 68000 program ROM (27-bit addr / 16-bit data)
//   - 5-bit RGB from taito_x; expanded to 8-bit at top level for C++ capture
//   - No audio outputs (handled in emu.sv, not in taito_x core)
//
// Clock enables:
//   enPhi1/enPhi2  — MC68000 phi, driven from C++ testbench (top-level inputs)
//   z80_cen        — Z80 clock enable, driven from C++ testbench (top-level input)
//   clk_pix        — pixel clock enable, driven from C++ testbench (top-level input)
//
// All SDRAM channels and I/O are passed through as top-level ports so the C++
// testbench can drive / capture them directly.
// =============================================================================
`default_nettype none

/* verilator lint_off SYNCASYNCNET */
module tb_top (
    // ── Clocks / Reset ──────────────────────────────────────────────────────────
    input  logic        clk_sys,
    input  logic        clk_pix,        // 1-cycle pulse, 8 MHz from 32 MHz sys
    input  logic        reset_n,

    // ── Program ROM SDRAM (68000 program ROM, 0x000000–0x07FFFF) ─────────────
    output logic [26:0] sdr_addr,
    input  logic [15:0] sdr_data,
    output logic        sdr_req,
    input  logic        sdr_ack,

    // ── Z80 ROM SDRAM (Z80 audio ROM, SDRAM base 0x080000) ───────────────────
    // tb_top manages the Z80 ROM fetch on behalf of the Z80 CPU.
    // 27-bit byte address (maps to sdram[0x080000 + z80_rom_offset])
    output logic [26:0] z80_rom_addr,
    input  logic [15:0] z80_rom_data,   // 16-bit word; tb_top selects byte
    output logic        z80_rom_req,
    input  logic        z80_rom_ack,

    // ── GFX ROM Interface (X1-001A sprites, SDRAM 0x100000–0x4FFFFF) ─────────
    output logic [17:0] gfx_addr,       // 18-bit word address from taito_x
    input  logic [15:0] gfx_data,
    output logic        gfx_req,
    input  logic        gfx_ack,

    // ── Player Inputs (active-low) ────────────────────────────────────────────
    input  logic [7:0]  joystick_p1,
    input  logic [7:0]  joystick_p2,
    input  logic [1:0]  coin,
    input  logic        service,
    input  logic [7:0]  dipsw1,
    input  logic [7:0]  dipsw2,

    // ── Video Outputs (8-bit expanded from 5-bit taito_x output) ─────────────
    output logic  [7:0] rgb_r,
    output logic  [7:0] rgb_g,
    output logic  [7:0] rgb_b,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,

    // ── Debug: CPU bus (for testbench diagnostics only) ──────────────────────
    output logic [23:1] dbg_cpu_addr,
    output logic        dbg_cpu_as_n,
    output logic        dbg_cpu_rw,
    output logic [15:0] dbg_cpu_din,
    output logic        dbg_cpu_dtack_n,
    output logic        dbg_cpu_halted_n,
    output logic [15:0] dbg_cpu_dout,
<<<<<<< HEAD
=======
    output logic  [2:0] dbg_cpu_fc,         // function codes FC2:FC0 (exception type)
>>>>>>> sim-batch2

    // ── Bus bypass: C++ testbench drives CPU data/DTACK directly ─────────────
    input  logic        bypass_en,
    input  logic [15:0] bypass_data,
    input  logic        bypass_dtack_n,

    // ── Clock enables: driven from C++ testbench ──────────────────────────────
    input  logic        enPhi1,
    input  logic        enPhi2,
    input  logic        z80_cen         // Z80 clock enable (~4 MHz)
);

// =============================================================================
// CPU bus wires (between fx68k and taito_x)
// =============================================================================
logic [23:1] cpu_addr;
logic [15:0] cpu_din;       // CPU write data → taito_x
logic [15:0] cpu_dout;      // taito_x read data → CPU
logic        cpu_rw;
logic        cpu_uds_n;
logic        cpu_lds_n;
logic        cpu_as_n;
logic        cpu_dtack_n;
logic [2:0]  cpu_ipl_n;

// =============================================================================
// fx68k — MC68000 CPU
// =============================================================================
logic fx_FC0, fx_FC1, fx_FC2;
logic inta_n;
// VPAn = IACK detection: ~&{FC2,FC1,FC0,~ASn}
assign inta_n = ~&{fx_FC2, fx_FC1, fx_FC0, ~cpu_as_n};

logic cpu_halted_n_raw;
logic cpu_reset_n_out;

// =============================================================================
// Bus bypass: C++ can drive iEdb and DTACKn directly for ROM reads.
// When bypass_en=1, CPU reads from bypass_data with bypass_dtack_n.
// When bypass_en=0, CPU reads from taito_x's cpu_dout/cpu_dtack_n.
<<<<<<< HEAD
=======
//
// IACK DTACK suppression: during interrupt acknowledge cycles (FC=111, AS#=0),
// force DTACKn HIGH so the CPU uses the autovector path (VPAn → AVEC) instead
// of getting a spurious DTACK from the bus. Without this, fx68k may latch
// random bus data as a vector number instead of autovectoring.
>>>>>>> sim-batch2
// =============================================================================
logic [15:0] cpu_iEdb_mux;
logic        cpu_dtack_mux;

<<<<<<< HEAD
assign cpu_iEdb_mux  = bypass_en ? bypass_data    : cpu_dout;
assign cpu_dtack_mux = bypass_en ? bypass_dtack_n : cpu_dtack_n;
=======
logic iack_cycle;
assign iack_cycle = fx_FC2 & fx_FC1 & fx_FC0 & ~cpu_as_n;

assign cpu_iEdb_mux  = bypass_en ? bypass_data    : cpu_dout;
assign cpu_dtack_mux = bypass_en ? bypass_dtack_n :
                       iack_cycle ? 1'b1 : cpu_dtack_n;
>>>>>>> sim-batch2

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
    .oRESETn    (cpu_reset_n_out),
    .oHALTEDn   (cpu_halted_n_raw),

    // Bus inputs
    .DTACKn     (cpu_dtack_mux),
    .VPAn       (inta_n),
    .BERRn      (1'b1),
    .BRn        (1'b1),
    .BGACKn     (1'b1),

    // Interrupts
    .IPL0n      (cpu_ipl_n[0]),
    .IPL1n      (cpu_ipl_n[1]),
    .IPL2n      (cpu_ipl_n[2]),

    // Data buses
    .iEdb       (cpu_iEdb_mux),    // read data: bypass or taito_x
    .oEdb       (cpu_din),         // write data from CPU → taito_x

    // Address bus
    .eab        (cpu_addr)
);

assign dbg_cpu_halted_n = cpu_halted_n_raw;

// =============================================================================
// Z80 Sound CPU (T80s) + ROM/RAM
// =============================================================================

// Z80 bus signals (from T80s perspective: outputs are addr/ctrl, DI is input)
logic [15:0] z80_addr_w;
logic  [7:0] z80_dout_w;   // data FROM T80s (write to memory)
logic  [7:0] z80_din_w;    // data TO T80s (read from memory)
logic        z80_mreq_n_w;
logic        z80_iorq_n_w;
logic        z80_rd_n_w;
logic        z80_wr_n_w;
logic        z80_m1_n_w;

// Control signals from taito_x
logic        z80_int_n_w;
logic        z80_reset_n_w;
logic        z80_rom_cs_n_w;
logic        z80_ram_cs_n_w;
logic  [7:0] z80_core_dout; // read data TO Z80 from taito_x

// Z80 8KB work RAM (0xC000–0xDFFF)
logic [7:0] z80_ram [0:8191];

// Z80 ROM fetch via SDRAM channel
// We fetch a byte from SDRAM at 0x080000 + z80_addr[14:0] (Z80 ROM is ≤32KB)
// The channel returns a 16-bit word; we select the byte by addr[0].
logic        z80_rom_pending;
logic        z80_rom_last_req;
logic  [7:0] z80_rom_byte;
logic  [7:0] z80_rom_rddata;   // registered read data
logic        z80_rom_valid;    // ROM data ready to present
logic [26:0] z80_rom_pending_addr;

// Toggle-based Z80 ROM fetch state
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        z80_rom_req         <= 1'b0;
        z80_rom_last_req    <= 1'b0;
        z80_rom_pending     <= 1'b0;
        z80_rom_valid       <= 1'b0;
        z80_rom_byte        <= 8'h00;
    end else begin
        // Latch SDRAM ack completion
        if (z80_rom_ack == z80_rom_req && z80_rom_pending) begin
            // Select high or low byte based on pending address bit 0
            z80_rom_byte  <= z80_rom_pending_addr[0]
                             ? z80_rom_data[7:0]
                             : z80_rom_data[15:8];
            z80_rom_valid <= 1'b1;
            z80_rom_pending <= 1'b0;
        end

        // Clear valid after one cycle (byte was consumed)
        if (z80_rom_valid)
            z80_rom_valid <= 1'b0;

        // Issue a new fetch when Z80 reads ROM and no pending fetch
        if (!z80_mreq_n_w && !z80_rd_n_w && !z80_rom_cs_n_w && !z80_rom_pending) begin
            // Byte address in SDRAM: base 0x080000 + z80_addr[14:0]
            // word-align: addr & ~1
            z80_rom_pending_addr <= 27'h080000 + {12'b0, z80_addr_w[14:0]};
            z80_rom_addr         <= (27'h080000 + {12'b0, z80_addr_w[14:0]}) & 27'h7FFFFE;
            z80_rom_req          <= ~z80_rom_req;   // toggle to request
            z80_rom_pending      <= 1'b1;
            z80_rom_valid        <= 1'b0;
        end
    end
end

// Z80 RAM read/write
always_ff @(posedge clk_sys) begin
    if (!z80_mreq_n_w && !z80_wr_n_w && !z80_ram_cs_n_w) begin
        // Write: addr 0xC000–0xDFFF → index [addr - 0xC000]
        z80_ram[z80_addr_w[12:0]] <= z80_dout_w;
    end
end

// Z80 data-in mux: ROM byte, RAM byte, or taito_x I/O
always_comb begin
    if (!z80_rom_cs_n_w)
        z80_din_w = z80_rom_byte;
    else if (!z80_ram_cs_n_w)
        z80_din_w = z80_ram[z80_addr_w[12:0]];
    else
        z80_din_w = z80_core_dout;
end

T80s u_z80 (
    .RESET_n    (z80_reset_n_w),
    .CLK        (clk_sys),
    .CEN        (z80_cen),
    .WAIT_n     (1'b1),
    .INT_n      (z80_int_n_w),
    .NMI_n      (1'b1),
    .BUSRQ_n    (1'b1),
    .OUT0       (1'b0),
    .DI         (z80_din_w),
    .M1_n       (z80_m1_n_w),
    .MREQ_n     (z80_mreq_n_w),
    .IORQ_n     (z80_iorq_n_w),
    .RD_n       (z80_rd_n_w),
    .WR_n       (z80_wr_n_w),
    .RFSH_n     (),
    .HALT_n     (),
    .BUSAK_n    (),
    .A          (z80_addr_w),
    .DOUT       (z80_dout_w)
);

// =============================================================================
// taito_x — full system (GPU, palette, work RAM, I/O, Z80 bus interface)
// =============================================================================
logic [4:0] tx_rgb_r;
logic [4:0] tx_rgb_g;
logic [4:0] tx_rgb_b;

<<<<<<< HEAD
taito_x #(
    // ── Gigandes address map parameters ────────────────────────────────────
    // WRAM: 0xF00000–0xF03FFF (16KB = 8K words, word base 23'h780000)
    .WRAM_BASE  (23'h780000),
    .WRAM_ABITS (13),
    // Palette, Sprite Y/Code, IO same as Superman defaults
    // Sound TC0140SYT: 0x800000 (word base 23'h400000)
    .SND_BASE   (23'h400000)
=======
// Gigandes memory map parameters:
//   WRAM at 0xF00000–0xF03FFF (16KB, word base 0x780000, 13-bit word addr)
//   IPL2 VBlank (level 2, active-low ~3'd2 = 3'b101)
//   FG_NOFLIP_YOFFS = -10 (MAME taito_x.cpp: m_spritegen->set_fg_yoffsets(-0xa, 0xe))
taito_x #(
    .WRAM_BASE       (23'h780000),  // byte 0xF00000 / 2
    .WRAM_ABITS      (13),          // 2^13 = 8K words = 16KB
    .FG_NOFLIP_YOFFS (-10)          // Gigandes: -0x0a (Superman uses -0x12 = -18)
>>>>>>> sim-batch2
) u_taito_x (
    .clk_sys        (clk_sys),
    .clk_pix        (clk_pix),
    .reset_n        (reset_n),

    // 68000 CPU bus
    .cpu_addr       (cpu_addr),
    .cpu_din        (cpu_din),
    .cpu_dout       (cpu_dout),
    .cpu_lds_n      (cpu_lds_n),
    .cpu_uds_n      (cpu_uds_n),
    .cpu_rw         (cpu_rw),
    .cpu_as_n       (cpu_as_n),
    .cpu_dtack_n    (cpu_dtack_n),
    .cpu_ipl_n      (cpu_ipl_n),
<<<<<<< HEAD
=======
    .cpu_fc         ({fx_FC2, fx_FC1, fx_FC0}),
>>>>>>> sim-batch2

    // Z80 Sound CPU bus
    .z80_addr       (z80_addr_w),
    .z80_din        (z80_dout_w),   // data FROM Z80 (Z80's write output)
    .z80_dout       (z80_core_dout),// data TO Z80 (read path)
    .z80_rd_n       (z80_rd_n_w),
    .z80_wr_n       (z80_wr_n_w),
    .z80_mreq_n     (z80_mreq_n_w),
    .z80_iorq_n     (z80_iorq_n_w),
    .z80_int_n      (z80_int_n_w),
    .z80_reset_n    (z80_reset_n_w),
    .z80_rom_cs_n   (z80_rom_cs_n_w),
    .z80_ram_cs_n   (z80_ram_cs_n_w),

    // GFX ROM (X1-001A sprite data)
    .gfx_addr       (gfx_addr),
    .gfx_data       (gfx_data),
    .gfx_req        (gfx_req),
    .gfx_ack        (gfx_ack),

    // SDRAM (68000 program ROM)
    .sdr_addr       (sdr_addr),
    .sdr_data       (sdr_data),
    .sdr_req        (sdr_req),
    .sdr_ack        (sdr_ack),

    // Video output (5-bit)
    .rgb_r          (tx_rgb_r),
    .rgb_g          (tx_rgb_g),
    .rgb_b          (tx_rgb_b),
    .hsync_n        (hsync_n),
    .vsync_n        (vsync_n),
    .hblank         (hblank),
    .vblank         (vblank),

    // Player inputs
    .joystick_p1    (joystick_p1),
    .joystick_p2    (joystick_p2),
    .coin           (coin),
    .service        (service),
    .dipsw1         (dipsw1),
    .dipsw2         (dipsw2)
);

// Expand 5-bit RGB to 8-bit: replicate top 3 bits into low positions
assign rgb_r = {tx_rgb_r, tx_rgb_r[4:2]};
assign rgb_g = {tx_rgb_g, tx_rgb_g[4:2]};
assign rgb_b = {tx_rgb_b, tx_rgb_b[4:2]};

// Debug outputs expose internal CPU bus for testbench diagnostics
assign dbg_cpu_addr    = cpu_addr;
assign dbg_cpu_as_n    = cpu_as_n;
assign dbg_cpu_rw      = cpu_rw;
assign dbg_cpu_din     = cpu_din;
assign dbg_cpu_dtack_n = cpu_dtack_n;
assign dbg_cpu_dout    = cpu_dout;
<<<<<<< HEAD
=======
assign dbg_cpu_fc      = {fx_FC2, fx_FC1, fx_FC0};
>>>>>>> sim-batch2

endmodule
