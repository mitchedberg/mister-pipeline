`default_nettype none
// =============================================================================
// TC0630FDP — Taito F3 Display Processor (Step 15: +Mosaic Effect)
// =============================================================================
// Integrates all video functions for Taito F3 arcade hardware (1992–1997):
//   · 4 scrolling tilemap layers (PF1–PF4), 16×16 tiles, 4bpp  ← STEP 3 ✓
//   · Text layer (64×64 8×8 tiles, CPU-writable characters)     ← STEP 2 ✓
//   · Pivot/pixel layer (64×32 8×8 tiles, column-major, CPU-writable)
//   · Sprite engine: 17-bit tile codes, 8-bit zoom, 4 priority groups, alpha blend
//   · Per-scanline Line RAM: rowscroll, colscroll, zoom, priority, clip, alpha, mosaic
//   · Layer compositor with 4 clip planes and full alpha blending
//
// MAME source: src/mame/taito/taito_f3.cpp + taito_f3_v.cpp
// Games: RayForce, Darius Gaiden, Elevator Action Returns, Bubble Symphony, etc.
//
// CPU address map (chip-relative 18-bit word addresses, i.e. cpu_addr[18:1]):
//   0x10000–0x17FFF: Line RAM (32768 × 16-bit words = 64KB)  ← STEP 5
//   0x04000–0x05FFF: PF1 RAM  (0x1800 words = 12KB)  ← STEP 3
//   0x06000–0x07FFF: PF2 RAM  (0x1800 words)         ← STEP 3
//   0x08000–0x09FFF: PF3 RAM  (0x1800 words)         ← STEP 3
//   0x0A000–0x0BFFF: PF4 RAM  (0x1800 words)         ← STEP 3
//   0x0E000–0x0EFFF: Text RAM (4096 × 16-bit words, 8KB)   ← STEP 2
//   0x0F000–0x0FFFF: Char RAM (4096 × 16-bit words = 8192 bytes) ← STEP 2
//   0x00000–0x0000F: Display control registers (word addr 0–15)
//
// F3 CPU byte-address map (for reference):
//   0x610000–0x612FFF: PF1 RAM  (chip word addr 0x04000–0x057FF)
//   0x613000–0x615FFF: PF2 RAM  (chip word addr 0x06000–0x077FF)
//   0x616000–0x618FFF: PF3 RAM  (chip word addr 0x08000–0x097FF)
//   0x619000–0x61BFFF: PF4 RAM  (chip word addr 0x0A000–0x0B7FF)
//   0x61C000–0x61DFFF: Text RAM (chip word addr 0x0E000–0x0EFFF)
//   0x61E000–0x61FFFF: Char RAM (chip word addr 0x0F000–0x0FFFF)
//   0x660000–0x66001F: Display ctrl (chip word addr 0x30000–0x3000F)
//
// Video timing (pixel clock domain):
//   Pixel clock: 26.686 MHz / 4 = 6.6715 MHz
//   H total: 432 pixels, H active: 320 pixels, H start: pixel 46
//   V total: 262 lines,  V active: 232 lines,  V start: line 24
//   Refresh: ~58.97 Hz
//
// Step 3 additions:
//   · PF RAM ×4 (0x1800 words each, CPU r/w)
//   · tc0630fdp_bg × 4 instantiated (PF1–PF4) with global X/Y scroll
//   · Fake GFX ROM: 32-bit wide BRAM, CPU-writable via dedicated port
//   · bg_pixel_out[0..3] ports expose BG layer pixels for testbench validation
//
// Step 5 additions:
//   · tc0630fdp_lineram instantiated (64KB Line RAM, CPU r/w)
//   · hblank_fall pulse generated from hblank rising edge
//   · ls_rowscroll[0..3] and ls_alt_tilemap[0..3] wired into BG engines
//   · Line RAM CPU decode: 0x10000–0x1FFFF (chip word addr)
// =============================================================================

module tc0630fdp (
    // ── Clocks and Reset ───────────────────────────────────────────────────
    input  logic        clk,            // pixel clock (6.6715 MHz in hardware)
    input  logic        async_rst_n,

    // ── CPU Interface (68EC020 bus, 16-bit) ────────────────────────────────
    input  logic        cpu_cs,         // chip select (active high)
    input  logic        cpu_rw,         // 1=read, 0=write
    input  logic [18:1] cpu_addr,       // word address within chip window
    input  logic [15:0] cpu_din,        // write data
    input  logic        cpu_lds_n,      // lower byte select (active low)
    input  logic        cpu_uds_n,      // upper byte select (active low)
    output logic [15:0] cpu_dout,       // read data
    output logic        cpu_dtack_n,    // data transfer acknowledge (active low)

    // ── Video Timing Outputs ───────────────────────────────────────────────
    output logic        hblank,         // horizontal blank (active high)
    output logic        vblank,         // vertical blank   (active high)
    output logic        hsync,          // horizontal sync  (active high)
    output logic        vsync,          // vertical sync    (active high)
    output logic [ 9:0] hpos,           // pixel counter within H total (0..431)
    output logic [ 8:0] vpos,           // line counter within V total  (0..261)

    // ── Interrupt Outputs ──────────────────────────────────────────────────
    output logic        int_vblank,     // INT2: fires at VBLANK start
    output logic        int_hblank,     // INT3: pseudo-hblank (~10K CPU cycles after INT2)

    // ── GFX ROM Interface (stub port — real ROM via gfx_word_* below) ─────
    output logic [24:0] gfx_lo_addr,    // GFX ROM low-plane byte address
    output logic        gfx_lo_rd,      // GFX ROM low-plane read strobe
    input  logic [ 7:0] gfx_lo_data,   // GFX ROM low-plane read data

    output logic [24:0] gfx_hi_addr,   // GFX ROM hi-plane byte address
    output logic        gfx_hi_rd,     // GFX ROM hi-plane read strobe
    input  logic [ 7:0] gfx_hi_data,  // GFX ROM hi-plane read data

    // ── Palette Interface (stub) ───────────────────────────────────────────
    output logic [14:0] pal_addr,       // palette RAM address
    output logic        pal_rd,         // palette read strobe
    input  logic [15:0] pal_data,       // palette read data

    // ── Video Output (stub) ───────────────────────────────────────────────
    output logic [23:0] rgb_out,        // 24-bit RGB to TC0650FDA DAC
    output logic        pixel_valid,    // high during active display

    // ── Text Layer Pixel Output (Step 2) ──────────────────────────────────
    output logic [ 8:0] text_pixel_out,

    // ── BG Layer Pixel Outputs (Step 3) ───────────────────────────────────
    // Format: {palette[8:0], pen[3:0]}  (pen==0 → transparent)
    // Used by testbench to validate BG tile rendering.
    output logic [12:0] bg_pixel_out [0:3],

    // ── GFX ROM Write Port (Step 3 testbench) ─────────────────────────────
    input  logic [21:0] gfx_wr_addr,
    input  logic [31:0] gfx_wr_data,
    input  logic        gfx_wr_en,

    // ── Sprite RAM Write Port (Step 8 testbench) ───────────────────────────
    // Used by testbench to populate sprite RAM before rendering.
    // spr_wr_addr: 15-bit word address into Sprite RAM (0..32767)
    // spr_wr_data: 16-bit write data
    // spr_wr_en:   write enable (active high, registered on posedge clk)
    input  logic [14:0] spr_wr_addr,
    input  logic [15:0] spr_wr_data,
    input  logic        spr_wr_en,

    // ── Sprite Pixel Output (Step 8) ──────────────────────────────────────
    // {priority[1:0], palette[5:0], pen[3:0]}; pen==0 → transparent
    output logic [11:0] spr_pixel_out,

    // ── Compositor Output (Step 11) ───────────────────────────────────────
    // {palette[8:0], pen[3:0]}.  pen==0 → all transparent (background).
    output logic [12:0] colmix_pixel_out,

    // ── Palette RAM Write Port (Step 13 testbench) ────────────────────────
    // Testbench writes palette entries via this dedicated port.
    // pal_wr_addr: 13-bit address into palette RAM (0..8191)
    // pal_wr_data: 16-bit color word (bits[15:12]=R, bits[11:8]=G, bits[7:4]=B)
    // pal_wr_en:   write enable (active high, registered on posedge clk)
    input  logic [12:0] pal_wr_addr,
    input  logic [15:0] pal_wr_data,
    input  logic        pal_wr_en,

    // ── Step 13: Blended RGB Output ─────────────────────────────────────
    // 24-bit blended RGB; valid 1 cycle after colmix_pixel_out.
    output logic [23:0] blend_rgb_out
);

// =============================================================================
// Reset synchronizer (2-FF)
// =============================================================================
logic [1:0] rst_pipe;
always_ff @(posedge clk or negedge async_rst_n) begin
    if (!async_rst_n) rst_pipe <= 2'b00;
    else              rst_pipe <= {rst_pipe[0], 1'b1};
end
logic rst_n;
assign rst_n = rst_pipe[1];

// =============================================================================
// Video Timing Generator
// =============================================================================
localparam int H_TOTAL   = 432;
localparam int H_START   = 46;
localparam int H_END     = 366;
localparam int H_SYNC_E  = 32;
localparam int V_TOTAL   = 262;
localparam int V_START   = 24;
localparam int V_END     = 256;
localparam int V_SYNC_E  = 4;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        hpos <= 10'b0;
        vpos <=  9'b0;
    end else begin
        if (hpos == 10'(H_TOTAL - 1)) begin
            hpos <= 10'b0;
            if (vpos == 9'(V_TOTAL - 1))
                vpos <= 9'b0;
            else
                vpos <= vpos + 9'b1;
        end else begin
            hpos <= hpos + 10'b1;
        end
    end
end

always_comb begin
    hblank = (hpos < 10'(H_START)) || (hpos >= 10'(H_END));
    vblank = (vpos <  9'(V_START)) || (vpos >=  9'(V_END));
    hsync  = (hpos < 10'(H_SYNC_E));
    vsync  = (vpos <  9'(V_SYNC_E));
end

assign pixel_valid = !hblank && !vblank;

// =============================================================================
// Interrupt Generation
// =============================================================================
logic vblank_r;
always_ff @(posedge clk) begin
    if (!rst_n) vblank_r <= 1'b0;
    else        vblank_r <= vblank;
end
logic vblank_rise;
assign vblank_rise = vblank & ~vblank_r;

localparam int INT3_DELAY = 2500;
logic [11:0] int3_cnt;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        int_vblank <= 1'b0;
        int_hblank <= 1'b0;
        int3_cnt   <= 12'b0;
    end else begin
        int_vblank <= 1'b0;
        int_hblank <= 1'b0;
        if (vblank_rise) begin
            int_vblank <= 1'b1;
            int3_cnt   <= 12'(INT3_DELAY);
        end
        if (int3_cnt != 12'b0) begin
            int3_cnt <= int3_cnt - 12'b1;
            if (int3_cnt == 12'd1)
                int_hblank <= 1'b1;
        end
    end
end

// =============================================================================
// CPU Address Decode
// =============================================================================
// cpu_addr[18:1] is the word address within the TC0630FDP chip window.
// Decode priority (highest first):
//   Line RAM: 0x10000–0x17FFF  → cpu_addr[18:16] == 3'b010   (32K words, 64KB)
//   PF1 RAM : 0x04000–0x057FF  → cpu_addr[18:13] in {6'h04, 6'h05}
//   PF2 RAM : 0x06000–0x077FF  → cpu_addr[18:13] in {6'h06, 6'h07}
//   PF3 RAM : 0x08000–0x097FF  → cpu_addr[18:13] in {6'h08, 6'h09}
//   PF4 RAM : 0x0A000–0x0B7FF  → cpu_addr[18:13] in {6'h0A, 6'h0B}
//   Text RAM: 0x0E000–0x0EFFF  → cpu_addr[18:13] == 6'h0E
//   Char RAM: 0x0F000–0x0FFFF  → cpu_addr[18:13] == 6'h0F
//   Ctrl reg: 0x00000–0x0000F  → catch-all default
//
// Line RAM chip word addresses 0x10000–0x17FFF (32768 words = 64KB):
//   cpu_addr[n] = (W >> (n-1)) & 1, where W is the 18-bit word address.
//   cpu_addr[18:16] = {(W>>17)&1, (W>>16)&1, (W>>15)&1} = 3'b010 for W in [0x10000, 0x18000).

logic cs_ctrl;
logic cs_text;
logic cs_char;
logic cs_pf   [0:3];   // PF1=0, PF2=1, PF3=2, PF4=3
logic cs_line;          // Line RAM (Step 5)
logic cs_spr;           // Sprite RAM (Step 8): chip word addr 0x20000–0x27FFF

always_comb begin
    cs_ctrl  = 1'b0;
    cs_text  = 1'b0;
    cs_char  = 1'b0;
    cs_line  = 1'b0;
    cs_spr   = 1'b0;
    for (int p = 0; p < 4; p++) cs_pf[p] = 1'b0;
    if (cpu_cs) begin
        // Decode priority (highest first):
        //   Sprite RAM: 0x20000–0x27FFF  → cpu_addr[18:16] == 3'b100
        //   Line RAM:   0x10000–0x17FFF  → cpu_addr[18:16] == 3'b010
        //   PF/Text/Char/Ctrl: lower addresses
        // Note: cpu_addr is [18:1] (bit 1 = LSB), so cpu_addr[18:16] checks
        //       integer bits 17:15 (Verilator shifts [N] → bit N-1).
        //       3'b100 → bits17:15=4 → addresses 0x20000–0x27FFF.
        //       3'b010 → bits17:15=2 → addresses 0x10000–0x17FFF.
        if (cpu_addr[18:16] == 3'b100) begin
            cs_spr = 1'b1;  // Sprite RAM: word addr 0x20000–0x27FFF (32K words)
        end else if (cpu_addr[18:16] == 3'b010) begin
            cs_line = 1'b1; // Line RAM: 0x10000–0x17FFF
        end else begin
            unique case (cpu_addr[18:13])
                6'h04, 6'h05: cs_pf[0] = 1'b1;
                6'h06, 6'h07: cs_pf[1] = 1'b1;
                6'h08, 6'h09: cs_pf[2] = 1'b1;
                6'h0A, 6'h0B: cs_pf[3] = 1'b1;
                6'h0F:         cs_char = 1'b1;
                6'h0E:         cs_text = 1'b1;
                default:       cs_ctrl = 1'b1;
            endcase
        end
    end
end

// =============================================================================
// Display Control Register Bank
// =============================================================================
logic [15:0] ctrl [0:15];

logic [1:0] cpu_be;
assign cpu_be = {~cpu_uds_n, ~cpu_lds_n};

logic [3:0] ctrl_idx;
assign ctrl_idx = cpu_addr[4:1];

always_ff @(posedge clk) begin
    if (!rst_n) begin
        for (int i = 0; i < 16; i++) ctrl[i] <= 16'b0;
    end else if (cs_ctrl && !cpu_rw) begin
        if (ctrl_idx != 4'd8  && ctrl_idx != 4'd9  &&
            ctrl_idx != 4'd10 && ctrl_idx != 4'd11 &&
            ctrl_idx != 4'd14) begin
            if (cpu_be[1]) ctrl[ctrl_idx][15:8] <= cpu_din[15:8];
            if (cpu_be[0]) ctrl[ctrl_idx][ 7:0] <= cpu_din[ 7:0];
        end
    end
end

logic [15:0] ctrl_rdata;
always_ff @(posedge clk) begin
    if (!rst_n) begin
        ctrl_rdata <= 16'b0;
    end else if (cs_ctrl && cpu_rw) begin
        ctrl_rdata <= ctrl[ctrl_idx];
    end
end

always_ff @(posedge clk) begin
    if (!rst_n)      cpu_dtack_n <= 1'b1;
    else if (cpu_cs) cpu_dtack_n <= 1'b0;
    else             cpu_dtack_n <= 1'b1;
end

// Decoded control outputs
logic [15:0] pf_xscroll [0:3];
assign pf_xscroll[0] = ctrl[0];
assign pf_xscroll[1] = ctrl[1];
assign pf_xscroll[2] = ctrl[2];
assign pf_xscroll[3] = ctrl[3];

logic [15:0] pf_yscroll [0:3];
assign pf_yscroll[0] = ctrl[4];
assign pf_yscroll[1] = ctrl[5];
assign pf_yscroll[2] = ctrl[6];
assign pf_yscroll[3] = ctrl[7];

logic [15:0] pixel_xscroll;
logic [15:0] pixel_yscroll;
assign pixel_xscroll = ctrl[12];
assign pixel_yscroll = ctrl[13];

logic extend_mode;
assign extend_mode = ctrl[15][7];

// =============================================================================
// Text RAM (4096 × 16-bit = 8KB)
// =============================================================================
logic [15:0] text_ram [0:4095];

logic [11:0] text_wr_addr;
logic [11:0] text_cpu_raddr;
assign text_wr_addr   = cpu_addr[12:1];
assign text_cpu_raddr = cpu_addr[12:1];

always_ff @(posedge clk) begin
    if (!rst_n) begin
    end else if (cs_text && !cpu_rw) begin
        if (cpu_be[1]) text_ram[text_wr_addr][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) text_ram[text_wr_addr][ 7:0] <= cpu_din[ 7:0];
    end
end

logic [15:0] text_cpu_rdata;
always_ff @(posedge clk) begin
    if (!rst_n)
        text_cpu_rdata <= 16'b0;
    else if (cs_text && cpu_rw)
        text_cpu_rdata <= text_ram[text_cpu_raddr];
end

logic [11:0] text_rd_addr_w;
logic [15:0] text_q_w;
assign text_q_w = text_ram[text_rd_addr_w];

// =============================================================================
// Character RAM (256 tiles × 8 rows × 4 bytes = 8KB)
// =============================================================================
logic [7:0] char_ram [0:8191];

logic [11:0] char_word_addr;
assign char_word_addr = cpu_addr[12:1];

always_ff @(posedge clk) begin
    if (!rst_n) begin
    end else if (cs_char && !cpu_rw) begin
        if (cpu_be[1]) char_ram[{char_word_addr, 1'b0}] <= cpu_din[15:8];
        if (cpu_be[0]) char_ram[{char_word_addr, 1'b1}] <= cpu_din[ 7:0];
    end
end

logic [15:0] char_cpu_rdata;
always_ff @(posedge clk) begin
    if (!rst_n)
        char_cpu_rdata <= 16'b0;
    else if (cs_char && cpu_rw) begin
        char_cpu_rdata <= {char_ram[{char_word_addr, 1'b0}],
                           char_ram[{char_word_addr, 1'b1}]};
    end
end

logic [10:0] char_rd_addr_w;
logic [31:0] char_q_w;
assign char_q_w = {char_ram[{char_rd_addr_w, 2'd3}],
                   char_ram[{char_rd_addr_w, 2'd2}],
                   char_ram[{char_rd_addr_w, 2'd1}],
                   char_ram[{char_rd_addr_w, 2'd0}]};

// =============================================================================
// Playfield RAM ×4 (each 0x1800 × 16-bit words)
// CPU word address within a PF RAM:
//   PF n base: cpu_addr[18:13] == (2+n)  → addr[12:1] within PF RAM region
//   But PF RAM is 0x1800 words → addr[12:0] is sufficient (13 bits: 0..0x17FF)
//   We use cpu_addr[13:1] = 13 bits for the PF word offset.
// =============================================================================
logic [15:0] pf_ram [0:3][0:6143];    // 0x1800 = 6144 words per PF

logic [12:0] pf_cpu_addr [0:3];
// PF CPU word address: cpu_addr[13:1] gives 13-bit offset within PF RAM block
// PF base word address = 0x04000 + n*0x2000 → cpu_addr bits [13:1] within that base
assign pf_cpu_addr[0] = cpu_addr[13:1];
assign pf_cpu_addr[1] = cpu_addr[13:1];
assign pf_cpu_addr[2] = cpu_addr[13:1];
assign pf_cpu_addr[3] = cpu_addr[13:1];

logic [15:0] pf_cpu_rdata [0:3];

genvar gi;
generate
    for (gi = 0; gi < 4; gi++) begin : gen_pf_ram
        // CPU write
        always_ff @(posedge clk) begin
            if (cs_pf[gi] && !cpu_rw) begin
                if (cpu_be[1]) pf_ram[gi][pf_cpu_addr[gi]][15:8] <= cpu_din[15:8];
                if (cpu_be[0]) pf_ram[gi][pf_cpu_addr[gi]][ 7:0] <= cpu_din[ 7:0];
            end
        end
        // CPU read (registered)
        always_ff @(posedge clk) begin
            if (!rst_n)
                pf_cpu_rdata[gi] <= 16'b0;
            else if (cs_pf[gi] && cpu_rw)
                pf_cpu_rdata[gi] <= pf_ram[gi][pf_cpu_addr[gi]];
        end
    end
endgenerate

// Async read ports for tc0630fdp_bg submodules
logic [12:0] pf_rd_addr_w [0:3];
logic [15:0] pf_q_w [0:3];
generate
    for (gi = 0; gi < 4; gi++) begin : gen_pf_rd
        assign pf_q_w[gi] = pf_ram[gi][pf_rd_addr_w[gi]];
    end
endgenerate

// =============================================================================
// Sprite RAM (32K × 16-bit = 64KB) — Step 8
// CPU word address range: 0x20000–0x27FFF (chip-relative)
// cpu_addr[15:1] = 15-bit word offset within Sprite RAM (0..32767)
// Dual access: CPU read/write via cs_spr; sprite scanner via spr_scan_addr
// =============================================================================
logic [15:0] spr_ram [0:32767];

logic [14:0] spr_cpu_addr;
assign spr_cpu_addr = cpu_addr[15:1];

always_ff @(posedge clk) begin
    // CPU write
    if (cs_spr && !cpu_rw) begin
        if (cpu_be[1]) spr_ram[spr_cpu_addr][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) spr_ram[spr_cpu_addr][ 7:0] <= cpu_din[ 7:0];
    end
    // Testbench direct write port
    if (spr_wr_en) spr_ram[spr_wr_addr] <= spr_wr_data;
end

logic [15:0] spr_cpu_rdata;
always_ff @(posedge clk) begin
    if (!rst_n)
        spr_cpu_rdata <= 16'b0;
    else if (cs_spr && cpu_rw)
        spr_cpu_rdata <= spr_ram[spr_cpu_addr];
end

// Sprite scanner read port (combinational)
// The scanner FSM issues an address and reads data in the NEXT state (1-cycle
// latency from address-issue to data-read), which matches the scanner's design.
// A registered read would require the FSM to wait 2 cycles (addr issued at N →
// data available at N+2), but the scanner only waits 1 cycle (addr at N →
// read at N+1).  Combinational read gives the correct 0-cycle read latency so
// the overall addr→read pipeline is 1 cycle as intended.
logic [14:0] scan_spr_addr;
logic [15:0] scan_spr_data;
assign scan_spr_data = spr_ram[scan_spr_addr];

// =============================================================================
// Sprite count BRAM (232 × 7-bit) — Step 8
// Holds the number of sprites on each screen scanline (0..64).
// 7-bit to hold values 0..64 (max 64 sprites per scanline).
// Written by scanner, read by renderer.
// =============================================================================
logic [ 6:0] scount_ram [0:231];

// Scanner write port
logic        scan_scount_wr;
logic [ 7:0] scan_scount_wr_addr;
logic [ 6:0] scan_scount_wr_data;

always_ff @(posedge clk) begin
    if (scan_scount_wr)
        scount_ram[scan_scount_wr_addr] <= scan_scount_wr_data;
end

// Renderer read port (combinational — see spr_ram scanner port comment above)
logic [ 7:0] rend_scount_rd_addr;
logic [ 6:0] rend_scount_rd_data;
assign rend_scount_rd_data = scount_ram[rend_scount_rd_addr];

// Scanner read port (not used by scanner; driven to 0)
logic [ 7:0] scan_scount_rd_addr;
logic [ 6:0] scan_scount_rd_data;
assign scan_scount_rd_data = scount_ram[scan_scount_rd_addr];

// =============================================================================
// Sprite list BRAM (232 × 64 × 72-bit) — Step 9: widened from 64 to 72 bits
// 72-bit descriptor carries full x_zoom[7:0] and y_zoom[7:0] fields.
// 14-bit address: {screen_scan[7:0], slot[5:0]}
// =============================================================================
logic [71:0] slist_ram [0:14847];  // 232*64 = 14848

// Scanner write port
logic        scan_slist_wr;
logic [13:0] scan_slist_addr;
logic [71:0] scan_slist_data;

always_ff @(posedge clk) begin
    if (scan_slist_wr)
        slist_ram[scan_slist_addr] <= scan_slist_data;
end

// Renderer read port (combinational — see spr_ram scanner port comment above)
logic [13:0] rend_slist_rd_addr;
logic [71:0] rend_slist_rd_data;
assign rend_slist_rd_data = slist_ram[rend_slist_rd_addr];

// =============================================================================
// GFX ROM (32-bit wide, 4M words = 16MB — simulable BRAM for testbench)
// CPU writes via gfx_wr_* ports. BG modules read via per-instance async ports.
// In real hardware this is external SDRAM; here it's an on-chip BRAM model.
//
// One shared ROM, all 4 BG instances address it simultaneously (simulation
// only — no bus conflicts since each has its own combinational read port,
// implemented via replicated assign from the same array).
// =============================================================================
// Size: 4096 × 32-bit words = 16KB (enough for test tiles; expand as needed)
localparam int GFX_ROM_WORDS = 4096;
logic [31:0] gfx_rom [0:GFX_ROM_WORDS-1];

// CPU write port
always_ff @(posedge clk) begin
    if (gfx_wr_en) begin
        if (gfx_wr_addr < 22'(GFX_ROM_WORDS))
            gfx_rom[gfx_wr_addr[11:0]] <= gfx_wr_data;
    end
end

// Async read ports (one per BG instance)
logic [21:0] bg_gfx_addr [0:3];
logic [31:0] bg_gfx_data [0:3];
logic        bg_gfx_rd   [0:3];

generate
    for (gi = 0; gi < 4; gi++) begin : gen_gfx_rd
        assign bg_gfx_data[gi] = (bg_gfx_addr[gi] < 22'(GFX_ROM_WORDS))
                                  ? gfx_rom[bg_gfx_addr[gi][11:0]]
                                  : 32'b0;
    end
endgenerate

// Sprite renderer read port (combinational — same BRAM, 32-bit)
logic [21:0] spr_gfx_addr;
logic [31:0] spr_gfx_data;
assign spr_gfx_data = (spr_gfx_addr < 22'(GFX_ROM_WORDS))
                      ? gfx_rom[spr_gfx_addr[11:0]]
                      : 32'b0;

// =============================================================================
// CPU read data mux
// =============================================================================
logic [15:0] line_cpu_dout;   // from tc0630fdp_lineram

always_comb begin
    unique case (1'b1)
        cs_spr:    cpu_dout = spr_cpu_rdata;
        cs_line:   cpu_dout = line_cpu_dout;
        cs_ctrl:   cpu_dout = ctrl_rdata;
        cs_text:   cpu_dout = text_cpu_rdata;
        cs_char:   cpu_dout = char_cpu_rdata;
        cs_pf[0]:  cpu_dout = pf_cpu_rdata[0];
        cs_pf[1]:  cpu_dout = pf_cpu_rdata[1];
        cs_pf[2]:  cpu_dout = pf_cpu_rdata[2];
        cs_pf[3]:  cpu_dout = pf_cpu_rdata[3];
        default:   cpu_dout = 16'b0;
    endcase
end

// =============================================================================
// HBLANK falling-edge detect (fires at end of active scan, i.e. hblank rising edge)
// Used to trigger the Line RAM parser to load next-scanline data.
// =============================================================================
logic hblank_fall;
logic hblank_r2;
always_ff @(posedge clk) begin
    if (!rst_n) hblank_r2 <= 1'b0;
    else        hblank_r2 <= hblank;
end
// hblank_fall fires one cycle after hblank goes high (active scan ended)
assign hblank_fall = hblank & ~hblank_r2;

// =============================================================================
// tc0630fdp_lineram — Line RAM + Parser (Step 5)
// =============================================================================
// Per-scanline outputs from Line RAM parser
logic [15:0] ls_rowscroll   [0:3];
logic        ls_alt_tilemap [0:3];
logic [ 7:0] ls_zoom_x      [0:3];   // Step 6: X zoom per PF
logic [ 7:0] ls_zoom_y      [0:3];   // Step 6: Y zoom per PF
logic [ 8:0] ls_colscroll   [0:3];   // Step 7: column scroll offset per PF
logic [15:0] ls_pal_add     [0:3];   // Step 7: palette addition raw value per PF
logic [ 3:0] ls_pf_prio     [0:3];   // Step 11: PF priority values 0–15
logic [ 3:0] ls_spr_prio    [0:3];   // Step 11: sprite group priorities
// Step 12: clip plane outputs
logic [ 7:0] ls_clip_left   [0:3];
logic [ 7:0] ls_clip_right  [0:3];
logic [ 3:0] ls_pf_clip_en   [0:3];
logic [ 3:0] ls_pf_clip_inv  [0:3];
logic        ls_pf_clip_sense[0:3];
logic [ 3:0] ls_spr_clip_en;
logic [ 3:0] ls_spr_clip_inv;
logic        ls_spr_clip_sense;
// Step 13: alpha blend outputs
logic [ 3:0] ls_a_src;
logic [ 3:0] ls_a_dst;
logic [ 1:0] ls_pf_blend  [0:3];
logic [ 1:0] ls_spr_blend [0:3];
// Step 14: reverse blend B coefficients
logic [ 3:0] ls_b_src;
logic [ 3:0] ls_b_dst;
// Step 15: mosaic effect
logic [ 3:0] ls_mosaic_rate;
logic [ 3:0] ls_pf_mosaic_en;
logic        ls_spr_mosaic_en;

tc0630fdp_lineram u_lineram (
    .clk            (clk),
    .rst_n          (rst_n),
    .cpu_cs         (cs_line),
    .cpu_rw         (cpu_rw),
    .cpu_addr       (cpu_addr[15:1]),
    .cpu_din        (cpu_din),
    .cpu_be         (cpu_be),
    .cpu_dout       (line_cpu_dout),
    .vpos           (vpos),
    .hblank_fall    (hblank_fall),
    .ls_rowscroll   (ls_rowscroll),
    .ls_alt_tilemap (ls_alt_tilemap),
    .ls_zoom_x      (ls_zoom_x),
    .ls_zoom_y      (ls_zoom_y),
    .ls_colscroll   (ls_colscroll),
    .ls_pal_add     (ls_pal_add),
    .ls_pf_prio       (ls_pf_prio),
    .ls_spr_prio      (ls_spr_prio),
    .ls_clip_left     (ls_clip_left),
    .ls_clip_right    (ls_clip_right),
    .ls_pf_clip_en    (ls_pf_clip_en),
    .ls_pf_clip_inv   (ls_pf_clip_inv),
    .ls_pf_clip_sense (ls_pf_clip_sense),
    .ls_spr_clip_en   (ls_spr_clip_en),
    .ls_spr_clip_inv  (ls_spr_clip_inv),
    .ls_spr_clip_sense(ls_spr_clip_sense),
    // Step 13: alpha blend outputs
    .ls_a_src         (ls_a_src),
    .ls_a_dst         (ls_a_dst),
    .ls_pf_blend      (ls_pf_blend),
    .ls_spr_blend     (ls_spr_blend),
    // Step 14: reverse blend B coefficients
    .ls_b_src         (ls_b_src),
    .ls_b_dst         (ls_b_dst),
    // Step 15: mosaic
    .ls_mosaic_rate   (ls_mosaic_rate),
    .ls_pf_mosaic_en  (ls_pf_mosaic_en),
    .ls_spr_mosaic_en (ls_spr_mosaic_en)
);

// =============================================================================
// tc0630fdp_text — Text layer engine (Step 2)
// =============================================================================
tc0630fdp_text u_text (
    .clk          (clk),
    .rst_n        (rst_n),
    .hblank       (hblank),
    .vpos         (vpos),
    .text_rd_addr (text_rd_addr_w),
    .text_q       (text_q_w),
    .char_rd_addr (char_rd_addr_w),
    .char_q       (char_q_w),
    .hpos         (hpos),
    .text_pixel   (text_pixel_out)
);

// =============================================================================
// tc0630fdp_bg × 4 — BG tilemap engines (Step 5: +rowscroll +alt-tilemap)
// =============================================================================
generate
    for (gi = 0; gi < 4; gi++) begin : gen_bg
        tc0630fdp_bg #(.PLANE(gi)) u_bg (
            .clk            (clk),
            .rst_n          (rst_n),
            .hblank         (hblank),
            .vpos           (vpos),
            .hpos           (hpos),
            .pf_xscroll     (pf_xscroll[gi]),
            .pf_yscroll     (pf_yscroll[gi]),
            .extend_mode    (extend_mode),
            .ls_rowscroll   (ls_rowscroll[gi]),
            .ls_alt_tilemap (ls_alt_tilemap[gi]),
            .ls_zoom_x      (ls_zoom_x[gi]),
            .ls_zoom_y      (ls_zoom_y[gi]),
            .ls_colscroll   (ls_colscroll[gi]),
            .ls_pal_add     (ls_pal_add[gi]),
            // Step 15: mosaic
            .ls_mosaic_en   (ls_pf_mosaic_en[gi]),
            .ls_mosaic_rate (ls_mosaic_rate),
            .pf_rd_addr     (pf_rd_addr_w[gi]),
            .pf_q           (pf_q_w[gi]),
            .gfx_addr       (bg_gfx_addr[gi]),
            .gfx_data       (bg_gfx_data[gi]),
            .gfx_rd         (bg_gfx_rd[gi]),
            .bg_pixel       (bg_pixel_out[gi])
        );
    end
endgenerate

// =============================================================================
// tc0630fdp_sprite_scan — Sprite Walker (Step 8)
// =============================================================================
tc0630fdp_sprite_scan u_sprite_scan (
    .clk             (clk),
    .rst_n           (rst_n),
    .vblank_rise     (vblank_rise),
    .spr_rd_addr     (scan_spr_addr),
    .spr_rd_data     (scan_spr_data),
    .slist_wr        (scan_slist_wr),
    .slist_addr      (scan_slist_addr),
    .slist_data      (scan_slist_data),
    .scount_wr       (scan_scount_wr),
    .scount_wr_addr  (scan_scount_wr_addr),
    .scount_wr_data  (scan_scount_wr_data),
    .scount_rd_addr  (scan_scount_rd_addr),
    .scount_rd_data  (scan_scount_rd_data)
);

// =============================================================================
// tc0630fdp_sprite_render — Sprite Line Buffer Renderer (Step 8)
// =============================================================================
tc0630fdp_sprite_render u_sprite_render (
    .clk               (clk),
    .rst_n             (rst_n),
    .hblank            (hblank),
    .hblank_fall       (hblank_fall),
    .vpos              (vpos),
    .hpos              (hpos),
    // Step 15: mosaic
    .ls_spr_mosaic_en  (ls_spr_mosaic_en),
    .ls_mosaic_rate    (ls_mosaic_rate),
    .scount_rd_addr    (rend_scount_rd_addr),
    .scount_rd_data    (rend_scount_rd_data),
    .slist_rd_addr     (rend_slist_rd_addr),
    .slist_rd_data     (rend_slist_rd_data),
    .gfx_addr          (spr_gfx_addr),
    .gfx_data          (spr_gfx_data),
    .spr_pixel         (spr_pixel_out)
);

// =============================================================================
// Palette RAM (8192 × 16-bit) — Step 13
// Two async read ports for colmix (src + dst), one testbench write port.
// Format: bits[15:12]=R(4), bits[11:8]=G(4), bits[7:4]=B(4), bits[3:0]=don't care.
// =============================================================================
logic [15:0] pal_ram [0:8191];

// Testbench write port
always_ff @(posedge clk) begin
    if (pal_wr_en)
        pal_ram[pal_wr_addr] <= pal_wr_data;
end

// Colmix palette read ports (registered — 1-cycle latency)
logic [12:0] colmix_pal_addr_src;
logic [12:0] colmix_pal_addr_dst;
logic [15:0] colmix_pal_rdata_src;
logic [15:0] colmix_pal_rdata_dst;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        colmix_pal_rdata_src <= 16'b0;
        colmix_pal_rdata_dst <= 16'b0;
    end else begin
        colmix_pal_rdata_src <= pal_ram[colmix_pal_addr_src];
        colmix_pal_rdata_dst <= pal_ram[colmix_pal_addr_dst];
    end
end

// =============================================================================
// tc0630fdp_colmix — Layer Compositor (Step 14: +Alpha Blend Mode B)
// =============================================================================
tc0630fdp_colmix u_colmix (
    .clk               (clk),
    .rst_n             (rst_n),
    .hpos              (hpos),
    .vpos              (vpos),
    .pixel_valid       (pixel_valid),
    .text_pixel        (text_pixel_out),
    .bg_pixel          (bg_pixel_out),
    .spr_pixel         (spr_pixel_out),
    .ls_pf_prio        (ls_pf_prio),
    .ls_spr_prio       (ls_spr_prio),
    .ls_clip_left      (ls_clip_left),
    .ls_clip_right     (ls_clip_right),
    .ls_pf_clip_en     (ls_pf_clip_en),
    .ls_pf_clip_inv    (ls_pf_clip_inv),
    .ls_pf_clip_sense  (ls_pf_clip_sense),
    .ls_spr_clip_en    (ls_spr_clip_en),
    .ls_spr_clip_inv   (ls_spr_clip_inv),
    .ls_spr_clip_sense (ls_spr_clip_sense),
    // Step 13: alpha blend
    .ls_a_src          (ls_a_src),
    .ls_a_dst          (ls_a_dst),
    .ls_pf_blend       (ls_pf_blend),
    .ls_spr_blend      (ls_spr_blend),
    // Step 14: reverse blend B coefficients
    .ls_b_src          (ls_b_src),
    .ls_b_dst          (ls_b_dst),
    // Step 13: palette read ports
    .pal_addr_src      (colmix_pal_addr_src),
    .pal_addr_dst      (colmix_pal_addr_dst),
    .pal_rdata_src     (colmix_pal_rdata_src),
    .pal_rdata_dst     (colmix_pal_rdata_dst),
    // outputs
    .colmix_pixel_out  (colmix_pixel_out),
    .blend_rgb_out     (blend_rgb_out)
);

// =============================================================================
// GFX ROM / Palette stubs (external palette port kept for compatibility)
// =============================================================================
assign gfx_lo_addr = 25'b0;
assign gfx_lo_rd   = 1'b0;
assign gfx_hi_addr = 25'b0;
assign gfx_hi_rd   = 1'b0;
assign pal_addr    = 15'b0;
assign pal_rd      = 1'b0;
assign rgb_out     = blend_rgb_out;

// =============================================================================
// Suppress unused-signal warnings
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused;
assign _unused = ^{gfx_lo_data,
                   gfx_hi_data,
                   pal_data,
                   pixel_xscroll, pixel_yscroll,
                   bg_gfx_rd[0], bg_gfx_rd[1], bg_gfx_rd[2], bg_gfx_rd[3],
                   scan_scount_rd_data};
/* verilator lint_on UNUSED */

endmodule
