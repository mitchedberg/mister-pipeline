`default_nettype none
// =============================================================================
// TC0630FDP — Line RAM Parser  (Step 13: +alpha blend coefficients + blend modes)
// =============================================================================
// The Line RAM is 64 KB (32768 × 16-bit words) that provides per-scanline
// override of virtually every display parameter.  This module:
//   · Owns the Line RAM BRAM (32K words).
//   · Handles CPU reads and writes.
//   · At every HBLANK falling-edge (hblank_fall), reads the next scanline's
//     rowscroll values (PF1–PF4) and their enable bits, and registers them
//     so that the BG tilemap engines can consume them during the next active
//     scan.
//
// Step 5 implementation: rowscroll + rowscroll-enable + alt-tilemap enable.
// Step 6 addition: per-scanline zoom (X and Y) for PF1–PF4 (section1 §9.9).
//   PF2/PF4 Y-zoom are physically swapped in hardware — corrected here.
// Step 7 addition: per-scanline colscroll (§9.2 bits[8:0]) and palette
//   addition (§9.10) for PF1–PF4.
// Step 11 addition: per-scanline PF priority (§9.12 bits[3:0]) and sprite
//   group priority (§9.8 bits[15:0]) for the compositor.
// Step 12 addition: per-scanline clip plane boundaries (§9.3) and per-layer
//   clip enable/invert flags from §9.12 (PF layers) and §9.7 (sprite layer).
// Step 13 addition: per-scanline alpha blend coefficients (§9.5) and blend
//   mode bits from §9.12 (PF layers, bits[15:14]) and §9.4 (sprite/pivot layer).
//
// §9.5 Alpha blend values: byte 0x6200–0x63FF → word 0x3100 + scan
//   bits[15:12] = B_src (reverse blend source coeff)
//   bits[11:8]  = A_src (normal blend source coeff)
//   bits[7:4]   = B_dst (reverse blend destination coeff)
//   bits[3:0]   = A_dst (normal blend destination coeff)
//   Range 0–8: 0=transparent, 8=fully opaque.
//
// §9.4 Pivot/Sprite blend control: byte 0x6000–0x61FF → word 0x3000 + scan
//   bits[7:6] = blend mode for sprite group 0xC0 (00=opaque,01=blendA,10=blendB,11=opaque)
//   bits[5:4] = blend mode for sprite group 0x80
//   bits[3:2] = blend mode for sprite group 0x40
//   bits[1:0] = blend mode for sprite group 0x00
//
// §9.12 pp_word bits[15:14]: PF blend mode
//   00 = opaque   01 = normal blend A   10 = reverse blend B   11 = opaque (layer mode)
//
// Clip plane data addresses (byte addr → word addr by /2):
//   §9.3 Plane 0: byte 0x5000–0x51FE → word 0x2800 + scan
//   §9.3 Plane 1: byte 0x5200–0x53FE → word 0x2900 + scan
//   §9.3 Plane 2: byte 0x5400–0x55FE → word 0x2A00 + scan
//   §9.3 Plane 3: byte 0x5600–0x57FE → word 0x2B00 + scan
//   Word format: bits[15:8]=right, bits[7:0]=left  (8-bit coordinates)
//
// §9.7 Sprite mix/clip: byte 0x7400–0x75FF → word 0x3A00 + scan
//   bits[11:8]=clip_enable, bits[7:4]=clip_invert, bit[0]=clip_invert_sense
//
// §9.12 PF mix/priority (already in pp_word, extract extra bits):
//   bits[11:8]=clip_enable, bits[7:4]=clip_invert, bit[12]=clip_invert_sense
//   PF1=0x5800, PF2=0x5900, PF3=0x5A00, PF4=0x5B00
//
// Address layout — chip-relative 16-bit WORD addresses within Line RAM BRAM
// (convert from section1 byte addresses by dividing by 2):
//
//   Enable/latch control (lower half, word addrs 0x0000–0x1FFF):
//     Rowscroll enable base  : byte 0x0C00 → word 0x0600  (256 scanlines)
//     Colscroll/alt-tmap en  : byte 0x0000 → word 0x0000  (256 scanlines)
//     Zoom enable base       : byte 0x0800 → word 0x0400  (256 scanlines)
//     Pal-add enable base    : byte 0x0A00 → word 0x0500  (256 scanlines)
//
//   Per-scanline data (upper half, word addrs 0x2000–0x7FFF):
//     Colscroll PF1–PF4 base : byte 0x4000 → word 0x2000  (stride 0x100 per PF)
//     Rowscroll PF1–PF4 base : byte 0xA000 → word 0x5000  (stride 0x100 per PF)
//     Zoom PF1               : byte 0x8000 → word 0x4000  (256 scanlines)
//     Zoom PF3               : byte 0x8200 → word 0x4100  (256 scanlines)
//     Zoom PF2               : byte 0x8400 → word 0x4200  (256 scanlines, PF4 Y-zoom here)
//     Zoom PF4               : byte 0x8600 → word 0x4300  (256 scanlines, PF2 Y-zoom here)
//     Pal-add PF1–PF4 base   : byte 0x9000 → word 0x4800  (stride 0x100 per PF)
//
// section1 §9.1 rowscroll enable:
//   word_addr = 0x0600 + scan,  bits[3:0] = enable per PF (PF1=bit0..PF4=bit3)
//
// section1 §9.1 colscroll/alt-tilemap enable:
//   word_addr = 0x0000 + scan,  bits[7:4] = alt-tmap enable per PF
//   bits[3:0] of same word also used for colscroll enable (§9.1 §9.2 interaction)
//   Note: colscroll enable shares the same enable word as alt-tilemap (bits[3:0])
//
// section1 §9.1 zoom enable:
//   word_addr = 0x0400 + scan,  bits[3:0] = enable per PF (PF1=bit0..PF4=bit3)
//
// section1 §9.1 pal-add enable:
//   word_addr = 0x0500 + scan,  bits[3:0] = enable per PF (PF1=bit0..PF4=bit3)
//
// section1 §9.1 priority enable (for playfield mix §9.12):
//   word_addr = 0x0700 + scan,  bits[3:0] = enable per PF (PF1=bit0..PF4=bit3)
//
// section1 §9.11 rowscroll data:
//   PFn (n=0..3): word_addr = 0x5000 + n*0x100 + scan
//
// section1 §9.2 colscroll data (bits[8:0] = colscroll offset; bit[9] = alt-tilemap flag):
//   PFn (n=0..3): word_addr = 0x2000 + n*0x100 + scan
//   colscroll enable: en_col_word[n] (bit[n] of 0x0000+scan)
//
// section1 §9.9 zoom data (format: bits[15:8]=Y_scale, bits[7:0]=X_scale):
//   PF1: word_addr = 0x4000 + scan
//   PF3: word_addr = 0x4100 + scan
//   PF2: word_addr = 0x4200 + scan  (NOTE: PF4 Y-zoom stored here in hardware)
//   PF4: word_addr = 0x4300 + scan  (NOTE: PF2 Y-zoom stored here in hardware)
//   PF2/PF4 Y-zoom swap: when outputting ls_zoom_y[1] (PF2), read from 0x4300+scan.
//                        when outputting ls_zoom_y[3] (PF4), read from 0x4200+scan.
//   X-zoom is NOT swapped: ls_zoom_x[1] from 0x4200+scan, ls_zoom_x[3] from 0x4300+scan.
//
// section1 §9.10 palette addition data:
//   PFn (n=0..3): word_addr = 0x4800 + n*0x100 + scan
//   Format: raw 16-bit value; the palette-line offset = value / 16 (i.e., divide by 16).
//   Output ls_pal_add[n] passes the raw 16-bit word; BG engine divides by 16.
//
// section1 §9.12 PF mix/priority data:
//   PFn (n=0..3): word_addr = 0x5800 + n*0x100 + scan
//   bits[3:0] = priority value (0–15)
//   Enable: bit[n] of word at 0x0700 + scan
//   Default (disabled): priority = 0.
//
// section1 §9.8 Sprite priority groups:
//   word_addr = 0x3B00 + scan
//   bits[15:12] = priority for group 0xC0
//   bits[11:8]  = priority for group 0x80
//   bits[7:4]   = priority for group 0x40
//   bits[3:0]   = priority for group 0x00
//   Enable: always active (no separate enable bit for sprite priority in §9.1).
// =============================================================================

module tc0630fdp_lineram (
    input  logic        clk,
    input  logic        rst_n,

    // ── CPU Interface ─────────────────────────────────────────────────────────
    input  logic        cpu_cs,         // chip-select (active high)
    input  logic        cpu_rw,         // 1=read, 0=write
    input  logic [15:1] cpu_addr,       // 15-bit word address within Line RAM
    input  logic [15:0] cpu_din,        // write data
    input  logic [ 1:0] cpu_be,         // byte enables [1]=upper, [0]=lower
    output logic [15:0] cpu_dout,       // read data

    // ── Video Timing ──────────────────────────────────────────────────────────
    input  logic [ 8:0] vpos,           // current scanline (0..261)
    input  logic        hblank_fall,    // single-cycle pulse at end of active scan

    // ── Per-scanline outputs (registered at hblank_fall, valid for vpos+1) ─────
    // rowscroll[n]: X-scroll addition for PF(n+1) on the next scanline.
    // Zero when rowscroll is disabled for that PF.
    output logic [15:0] ls_rowscroll   [0:3],
    // alt_tilemap[n]: 1 → PF(n+1) reads tile data from +0x1800 offset in PF RAM.
    output logic        ls_alt_tilemap [0:3],
    // zoom_x[n]: X zoom factor for PF(n+1).  0x00 = no zoom (1:1).
    // Zero (no zoom) when zoom is disabled for that PF.
    output logic [ 7:0] ls_zoom_x      [0:3],
    // zoom_y[n]: Y zoom factor for PF(n+1).  0x80 = no zoom (1:1).
    // 0x80 (no zoom) when zoom is disabled for that PF.
    output logic [ 7:0] ls_zoom_y      [0:3],
    // colscroll[n]: 9-bit column scroll offset for PF(n+1) (§9.2 bits[8:0]).
    // Zero when colscroll is disabled for that PF.
    output logic [ 8:0] ls_colscroll   [0:3],
    // pal_add[n]: raw 16-bit palette addition word for PF(n+1) (§9.10).
    // Zero when pal_add is disabled.  BG engine divides by 16 to get palette-line offset.
    output logic [15:0] ls_pal_add     [0:3],
    // pf_prio[n]: priority value 0–15 for PF(n+1) from §9.12 bits[3:0].
    // Zero (lowest) when priority enable is not asserted for this PF/scanline.
    output logic [ 3:0] ls_pf_prio     [0:3],
    // spr_prio[n]: priority for sprite group n (0=0x00, 1=0x40, 2=0x80, 3=0xC0)
    // from §9.8.  Always latched (no separate enable bit).
    output logic [ 3:0] ls_spr_prio    [0:3],

    // ── Step 12: Clip plane outputs ──────────────────────────────────────────
    // clip_left[p] / clip_right[p]: 8-bit left/right boundary for clip plane p (0–3).
    // Latched at hblank_fall from §9.3 data words.
    output logic [ 7:0] ls_clip_left   [0:3],
    output logic [ 7:0] ls_clip_right  [0:3],

    // PF clip configuration from §9.12 pp_word:
    //   ls_pf_clip_en[n]     = bits[11:8] — 4-bit enable mask (one bit per clip plane)
    //   ls_pf_clip_inv[n]    = bits[7:4]  — 4-bit invert mask (per clip plane)
    //   ls_pf_clip_sense[n]  = bit[12]    — inversion sense: 1=invert the invert
    output logic [ 3:0] ls_pf_clip_en   [0:3],
    output logic [ 3:0] ls_pf_clip_inv  [0:3],
    output logic        ls_pf_clip_sense[0:3],

    // Sprite clip configuration from §9.7:
    //   ls_spr_clip_en    = bits[11:8] — 4-bit enable mask
    //   ls_spr_clip_inv   = bits[7:4]  — 4-bit invert mask
    //   ls_spr_clip_sense = bit[0]     — inversion sense
    output logic [ 3:0] ls_spr_clip_en,
    output logic [ 3:0] ls_spr_clip_inv,
    output logic        ls_spr_clip_sense,

    // ── Step 13: Alpha blend outputs ─────────────────────────────────────────
    // Alpha coefficients from §9.5 (latched per scanline):
    //   A_src: source contribution for normal blend mode A (0=transparent, 8=opaque)
    //   A_dst: destination contribution for normal blend mode A
    output logic [ 3:0] ls_a_src,
    output logic [ 3:0] ls_a_dst,
    // PF blend modes from §9.12 pp_word bits[15:14]:
    //   00=opaque  01=normal blend A  10=reverse blend B  11=opaque-layer
    output logic [ 1:0] ls_pf_blend  [0:3],
    // Sprite blend modes from §9.4 bits[7:0] (2 bits per group):
    //   bits[7:6]=group0xC0, bits[5:4]=group0x80, bits[3:2]=group0x40, bits[1:0]=group0x00
    output logic [ 1:0] ls_spr_blend [0:3],

    // ── Step 14: Reverse blend B coefficients ────────────────────────────────
    // B_src: source contribution for reverse blend mode B (0=transparent, 8=opaque)
    // B_dst: destination contribution for reverse blend mode B
    // From §9.5 ab_word bits[15:12]=B_src, bits[7:4]=B_dst
    output logic [ 3:0] ls_b_src,
    output logic [ 3:0] ls_b_dst
);

// =============================================================================
// Line RAM: 32768 × 16-bit words (64 KB simulation BRAM)
// =============================================================================
logic [15:0] line_ram [0:32767];

// =============================================================================
// CPU write port
// =============================================================================
always_ff @(posedge clk) begin
    if (cpu_cs && !cpu_rw) begin
        if (cpu_be[1]) line_ram[cpu_addr[15:1]][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) line_ram[cpu_addr[15:1]][ 7:0] <= cpu_din[ 7:0];
    end
end

// =============================================================================
// CPU read port (registered, one-cycle latency)
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n)
        cpu_dout <= 16'b0;
    else if (cpu_cs && cpu_rw)
        cpu_dout <= line_ram[cpu_addr[15:1]];
end

// =============================================================================
// HBLANK parser
// =============================================================================
// Scanline index for the NEXT visible line (8-bit; sections have 256 entries).
// vpos is 9-bit (0–261); next_scan = (vpos+1)[7:0] wraps mod 256.
// vpos[8] is intentionally unused — sections only have 256 entries.
/* verilator lint_off UNUSEDSIGNAL */
logic [7:0] next_scan;
/* verilator lint_on UNUSEDSIGNAL */
assign next_scan = vpos[7:0] + 8'd1;

// Intermediate wires for enable and data words read from BRAM.
// These are registered combinationally from the BRAM array inside the
// always_ff block; the array reads are effectively asynchronous in simulation.
logic [15:0] en_row_word;    // rowscroll enable word
logic [15:0] en_col_word;    // colscroll/alt-tilemap enable word
/* verilator lint_off UNUSEDSIGNAL */
logic [15:0] en_zoom_word;   // zoom enable word (Step 6) — only bits[3:0] used
logic [15:0] en_pal_word;    // pal-add enable word (Step 7) — only bits[3:0] used
logic [15:0] en_prio_word;   // pf priority enable word (Step 11) — only bits[3:0] used
/* verilator lint_on UNUSEDSIGNAL */
logic [15:0] rs_word  [0:3]; // rowscroll data per PF
logic [15:0] cs_word  [0:3]; // colscroll data per PF (bits[8:0]=colscroll, bit[9]=alt-tilemap)
logic [15:0] zm_word  [0:3]; // zoom data per PF (bits[15:8]=Y, bits[7:0]=X)
logic [15:0] pa_word  [0:3]; // palette addition data per PF (§9.10)
logic [15:0] pp_word  [0:3]; // pf priority data per PF (§9.12, bits[3:0]=prio)
logic [15:0] sp_word;        // sprite group priority word (§9.8)

// Combinational reads from line_ram (one address per wire).
// Address arithmetic: 15-bit = base + {7'b0, next_scan}
assign en_row_word   = line_ram[15'h0600 + {7'b0, next_scan}];
assign en_col_word   = line_ram[15'h0000 + {7'b0, next_scan}];
assign en_zoom_word  = line_ram[15'h0400 + {7'b0, next_scan}];  // §9.1 zoom enable
assign en_pal_word   = line_ram[15'h0500 + {7'b0, next_scan}];  // §9.1 pal-add enable
assign en_prio_word  = line_ram[15'h0700 + {7'b0, next_scan}];  // §9.1 pf-prio enable
assign rs_word[0]    = line_ram[15'h5000 + {7'b0, next_scan}];
assign rs_word[1]    = line_ram[15'h5100 + {7'b0, next_scan}];
assign rs_word[2]    = line_ram[15'h5200 + {7'b0, next_scan}];
assign rs_word[3]    = line_ram[15'h5300 + {7'b0, next_scan}];
assign cs_word[0]    = line_ram[15'h2000 + {7'b0, next_scan}];
assign cs_word[1]    = line_ram[15'h2100 + {7'b0, next_scan}];
assign cs_word[2]    = line_ram[15'h2200 + {7'b0, next_scan}];
assign cs_word[3]    = line_ram[15'h2300 + {7'b0, next_scan}];
// Zoom data: PF1=0x4000, PF3=0x4100, PF2=0x4200, PF4=0x4300  (§9.9)
assign zm_word[0]    = line_ram[15'h4000 + {7'b0, next_scan}];  // PF1
assign zm_word[1]    = line_ram[15'h4200 + {7'b0, next_scan}];  // PF2 (X here; Y physically at PF4 addr)
assign zm_word[2]    = line_ram[15'h4100 + {7'b0, next_scan}];  // PF3
assign zm_word[3]    = line_ram[15'h4300 + {7'b0, next_scan}];  // PF4 (X here; Y physically at PF2 addr)
// Palette addition data: §9.10  PF1=0x4800, PF2=0x4900, PF3=0x4A00, PF4=0x4B00
assign pa_word[0]    = line_ram[15'h4800 + {7'b0, next_scan}];  // PF1
assign pa_word[1]    = line_ram[15'h4900 + {7'b0, next_scan}];  // PF2
assign pa_word[2]    = line_ram[15'h4A00 + {7'b0, next_scan}];  // PF3
assign pa_word[3]    = line_ram[15'h4B00 + {7'b0, next_scan}];  // PF4
// PF mix/priority data: §9.12  PF1=0x5800, PF2=0x5900, PF3=0x5A00, PF4=0x5B00
assign pp_word[0]    = line_ram[15'h5800 + {7'b0, next_scan}];  // PF1
assign pp_word[1]    = line_ram[15'h5900 + {7'b0, next_scan}];  // PF2
assign pp_word[2]    = line_ram[15'h5A00 + {7'b0, next_scan}];  // PF3
assign pp_word[3]    = line_ram[15'h5B00 + {7'b0, next_scan}];  // PF4
// Sprite group priority: §9.8  word_addr=0x3B00+scan
assign sp_word       = line_ram[15'h3B00 + {7'b0, next_scan}];

// Clip plane boundary data: §9.3
// Plane 0: byte 0x5000 → word 0x2800; plane 1: 0x2900; plane 2: 0x2A00; plane 3: 0x2B00
logic [15:0] cp_word [0:3];  // clip plane data words
assign cp_word[0]    = line_ram[15'h2800 + {7'b0, next_scan}];
assign cp_word[1]    = line_ram[15'h2900 + {7'b0, next_scan}];
assign cp_word[2]    = line_ram[15'h2A00 + {7'b0, next_scan}];
assign cp_word[3]    = line_ram[15'h2B00 + {7'b0, next_scan}];

// Sprite mix/clip: §9.7  byte 0x7400 → word 0x3A00
/* verilator lint_off UNUSEDSIGNAL */
logic [15:0] sm_word;  // sprite mix word (bits[15:12,3:1] unused in Step 12)
/* verilator lint_on UNUSEDSIGNAL */
assign sm_word       = line_ram[15'h3A00 + {7'b0, next_scan}];

// Step 13: Alpha blend coefficients §9.5  byte 0x6200 → word 0x3100
// bits[11:8]=A_src (normal blend), bits[3:0]=A_dst; bits[15:12]=B_src, bits[7:4]=B_dst (Step 14)
/* verilator lint_off UNUSEDSIGNAL */
logic [15:0] ab_word;  // alpha blend word: bits[11:8]=A_src, bits[3:0]=A_dst
/* verilator lint_on UNUSEDSIGNAL */
assign ab_word       = line_ram[15'h3100 + {7'b0, next_scan}];

// Step 13: Pivot/sprite blend control §9.4  byte 0x6000 → word 0x3000
// bits[7:0] = blend mode per group (2 bits each); bits[15:8] reserved for Step 14
/* verilator lint_off UNUSEDSIGNAL */
logic [15:0] sb_word;  // sprite blend word: bits[7:0] = blend mode per group
/* verilator lint_on UNUSEDSIGNAL */
assign sb_word       = line_ram[15'h3000 + {7'b0, next_scan}];

// PF2/PF4 Y-zoom cross-read wires (hardware swap, §9.9):
// PF2 Y-zoom is stored at PF4's RAM address (0x4300+scan).
// PF4 Y-zoom is stored at PF2's RAM address (0x4200+scan).
// Only the Y byte [15:8] is used from each swap wire; X byte [7:0] is unused.
/* verilator lint_off UNUSEDSIGNAL */
logic [15:0] zm_word_pf2_yswap;   // contains PF2 Y-zoom (from PF4's address)
logic [15:0] zm_word_pf4_yswap;   // contains PF4 Y-zoom (from PF2's address)
/* verilator lint_on UNUSEDSIGNAL */
assign zm_word_pf2_yswap = line_ram[15'h4300 + {7'b0, next_scan}];  // PF2 Y from PF4 addr
assign zm_word_pf4_yswap = line_ram[15'h4200 + {7'b0, next_scan}];  // PF4 Y from PF2 addr

// Register outputs at hblank_fall
always_ff @(posedge clk) begin
    if (!rst_n) begin
        for (int i = 0; i < 4; i++) begin
            ls_rowscroll[i]    <= 16'b0;
            ls_alt_tilemap[i]  <= 1'b0;
            ls_zoom_x[i]       <= 8'h00;
            ls_zoom_y[i]       <= 8'h80;
            ls_colscroll[i]    <= 9'b0;
            ls_pal_add[i]      <= 16'b0;
            ls_pf_prio[i]      <= 4'b0;
            ls_pf_clip_en[i]   <= 4'b0;
            ls_pf_clip_inv[i]  <= 4'b0;
            ls_pf_clip_sense[i]<= 1'b0;
        end
        for (int j = 0; j < 4; j++) ls_spr_prio[j] <= 4'b0;
        for (int k = 0; k < 4; k++) begin
            ls_clip_left[k]  <= 8'h00;
            ls_clip_right[k] <= 8'hFF;
        end
        ls_spr_clip_en    <= 4'b0;
        ls_spr_clip_inv   <= 4'b0;
        ls_spr_clip_sense <= 1'b0;
        // Step 13: alpha blend defaults
        ls_a_src          <= 4'd8;  // default: fully opaque source
        ls_a_dst          <= 4'd0;  // default: no destination contribution
        for (int n = 0; n < 4; n++) begin
            ls_pf_blend[n]  <= 2'b00;  // default: opaque
            ls_spr_blend[n] <= 2'b00;  // default: opaque
        end
        // Step 14: reverse blend B defaults
        ls_b_src          <= 4'd8;  // default: fully opaque source
        ls_b_dst          <= 4'd0;  // default: no destination contribution
    end else if (hblank_fall) begin
        for (int n = 0; n < 4; n++) begin
            // Rowscroll: enable bit n of en_row_word[3:0]
            ls_rowscroll[n]   <= en_row_word[n] ? rs_word[n] : 16'b0;
            // Alt-tilemap: enable bit n of en_col_word[7:4], data bit[9] of cs_word
            ls_alt_tilemap[n] <= en_col_word[4+n] ? cs_word[n][9] : 1'b0;
            // Colscroll: enable bit n of en_col_word[3:0], data bits[8:0] of cs_word
            ls_colscroll[n]   <= en_col_word[n] ? cs_word[n][8:0] : 9'b0;
            // Palette addition: enable bit n of en_pal_word[3:0], full 16-bit raw value
            ls_pal_add[n]     <= en_pal_word[n] ? pa_word[n] : 16'b0;
            // PF priority: enable bit n of en_prio_word[3:0], data bits[3:0] of pp_word
            ls_pf_prio[n]     <= en_prio_word[n] ? pp_word[n][3:0] : 4'b0;
        end
        // Sprite group priority: always latched from §9.8 word (no separate enable)
        ls_spr_prio[0]  <= sp_word[3:0];    // group 0x00
        ls_spr_prio[1]  <= sp_word[7:4];    // group 0x40
        ls_spr_prio[2]  <= sp_word[11:8];   // group 0x80
        ls_spr_prio[3]  <= sp_word[15:12];  // group 0xC0
        // Zoom X and Y: enable bit n of en_zoom_word[3:0]
        // X-zoom: not swapped — read from each PF's own address
        // Y-zoom: PF2 and PF4 are physically swapped — use cross-read wires
        if (en_zoom_word[0]) begin
            ls_zoom_x[0] <= zm_word[0][7:0];    // PF1 X: from 0x4000+scan
            ls_zoom_y[0] <= zm_word[0][15:8];   // PF1 Y: from 0x4000+scan (no swap)
        end else begin
            ls_zoom_x[0] <= 8'h00;
            ls_zoom_y[0] <= 8'h80;
        end
        if (en_zoom_word[1]) begin
            ls_zoom_x[1] <= zm_word[1][7:0];           // PF2 X: from 0x4200+scan
            ls_zoom_y[1] <= zm_word_pf2_yswap[15:8];   // PF2 Y: from 0x4300+scan (swap)
        end else begin
            ls_zoom_x[1] <= 8'h00;
            ls_zoom_y[1] <= 8'h80;
        end
        if (en_zoom_word[2]) begin
            ls_zoom_x[2] <= zm_word[2][7:0];    // PF3 X: from 0x4100+scan
            ls_zoom_y[2] <= zm_word[2][15:8];   // PF3 Y: from 0x4100+scan (no swap)
        end else begin
            ls_zoom_x[2] <= 8'h00;
            ls_zoom_y[2] <= 8'h80;
        end
        if (en_zoom_word[3]) begin
            ls_zoom_x[3] <= zm_word[3][7:0];           // PF4 X: from 0x4300+scan
            ls_zoom_y[3] <= zm_word_pf4_yswap[15:8];   // PF4 Y: from 0x4200+scan (swap)
        end else begin
            ls_zoom_x[3] <= 8'h00;
            ls_zoom_y[3] <= 8'h80;
        end

        // ── Step 12: Clip plane boundaries (§9.3) ────────────────────────────
        // Each cp_word: bits[15:8]=right, bits[7:0]=left  (8-bit coordinates)
        for (int k = 0; k < 4; k++) begin
            ls_clip_left[k]  <= cp_word[k][7:0];
            ls_clip_right[k] <= cp_word[k][15:8];
        end

        // ── Step 12: PF clip config from §9.12 pp_word ────────────────────────
        // pp_word bits[11:8]=clip_enable, bits[7:4]=clip_invert, bit[12]=sense
        for (int n = 0; n < 4; n++) begin
            ls_pf_clip_en[n]    <= pp_word[n][11:8];
            ls_pf_clip_inv[n]   <= pp_word[n][7:4];
            ls_pf_clip_sense[n] <= pp_word[n][12];
        end

        // ── Step 12: Sprite clip config from §9.7 sm_word ─────────────────────
        // sm_word bits[11:8]=clip_enable, bits[7:4]=clip_invert, bit[0]=sense
        ls_spr_clip_en    <= sm_word[11:8];
        ls_spr_clip_inv   <= sm_word[7:4];
        ls_spr_clip_sense <= sm_word[0];

        // ── Step 13: Alpha blend coefficients from §9.5 ab_word ───────────────
        // ab_word bits[11:8]=A_src, bits[3:0]=A_dst
        ls_a_src <= ab_word[11:8];
        ls_a_dst <= ab_word[3:0];
        // ── Step 14: Reverse blend B coefficients from §9.5 ab_word ──────────
        // ab_word bits[15:12]=B_src, bits[7:4]=B_dst
        ls_b_src <= ab_word[15:12];
        ls_b_dst <= ab_word[7:4];

        // ── Step 13: PF blend modes from §9.12 pp_word bits[15:14] ───────────
        for (int n = 0; n < 4; n++) begin
            ls_pf_blend[n] <= pp_word[n][15:14];
        end

        // ── Step 13: Sprite blend modes from §9.4 sb_word bits[7:0] ──────────
        // bits[1:0]=group0x00, bits[3:2]=group0x40, bits[5:4]=group0x80, bits[7:6]=group0xC0
        ls_spr_blend[0] <= sb_word[1:0];   // group 0x00
        ls_spr_blend[1] <= sb_word[3:2];   // group 0x40
        ls_spr_blend[2] <= sb_word[5:4];   // group 0x80
        ls_spr_blend[3] <= sb_word[7:6];   // group 0xC0
    end
end

// Suppress vpos[8] unused: Line RAM sections have 256 entries, only vpos[7:0] needed.
/* verilator lint_off UNUSEDSIGNAL */
logic _unused_vpos;
assign _unused_vpos = vpos[8];
/* verilator lint_on UNUSEDSIGNAL */

endmodule
