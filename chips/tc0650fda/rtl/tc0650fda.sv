`default_nettype none
// =============================================================================
// TC0650FDA — Taito F3 Palette RAM + Alpha Blend + DAC
// =============================================================================
// Stores 8192 × 32-bit palette entries (RGB888, bits[23:0] used).
// Two mirrored BRAM copies (src_bram, dst_bram) share every CPU write.
// Step 1: single src_pal lookup only — dst_pal/blend inputs are wired but
// not yet used; video output is direct palette lookup with 2-cycle pipeline.
//
// CPU Interface (32-bit write-only, 68EC020 bus fragment):
//   cpu_addr[12:0] — 13-bit palette index (word-aligned 32-bit access)
//   cpu_din[31:0]  — write data: bits[23:16]=R, [15:8]=G, [7:0]=B
//   cpu_be[3:0]    — byte enables {D31:D24, D23:D16, D15:D8, D7:D0}
//   cpu_we         — write enable
//   cpu_cs         — chip select
//   cpu_dtack_n    — permanently 0 (zero-wait-state BRAM)
//
// Pixel pipeline (2 registered stages, advances on ce_pixel):
//   Cycle 0 : pal_idx latched, BRAM addressed
//   Cycle 1 : BRAM data registered (pal_rd_data)
//   Cycle 2 : RGB output registered → video_r/g/b
//   pixel_valid_d[2:0] shift register aligns pixel_valid to match
//
// 12-bit legacy mode (mode_12bit = 1):
//   Palette entry bits[15:12]=R[3:0], [11:8]=G[3:0], [7:4]=B[3:0]
//   4→8-bit expansion by nibble repeat: {nib,nib} → linear 0..255 mapping
//
// Anti-patterns enforced: no reg/wire, always_ff/always_comb/logic only,
//   default_nettype none, zero Verilator --Wall warnings.
// =============================================================================

module tc0650fda (
    // -------------------------------------------------------------------------
    // Clock / Reset
    // -------------------------------------------------------------------------
    input  logic        clk,          // System clock (26.686 MHz)
    input  logic        ce_pixel,     // Pixel clock enable (÷4 ≈ 6.67 MHz)
    input  logic        rst_n,        // Active-low synchronous reset

    // -------------------------------------------------------------------------
    // CPU Interface — 32-bit write-only (68EC020 bus fragment)
    // -------------------------------------------------------------------------
    input  logic        cpu_cs,       // Chip select
    input  logic        cpu_we,       // Write enable
    input  logic [12:0] cpu_addr,     // Palette index 0x0000–0x1FFF
    input  logic [31:0] cpu_din,      // Write data: {unused[31:24], R[23:16], G[15:8], B[7:0]}
    input  logic [ 3:0] cpu_be,       // Byte enables [3]=D31:D24 [2]=D23:D16 [1]=D15:D8 [0]=D7:D0
    output logic        cpu_dtack_n,  // Bus acknowledge — permanently 0
    output logic [31:0] cpu_rd_raw,   // BRAM read-back (1-cycle latency after cpu_addr)

    // -------------------------------------------------------------------------
    // Video Input — per-pixel, in pixel clock domain
    // -------------------------------------------------------------------------
    input  logic        pixel_valid,  // High during active display pixels
    input  logic [12:0] src_pal,      // Source palette index (13-bit)
    input  logic [12:0] dst_pal,      // Destination palette index (Step 2)
    input  logic [ 3:0] src_blend,    // Source blend factor 0–8 (Step 2)
    input  logic [ 3:0] dst_blend,    // Destination blend factor 0–8 (Step 2)

    // -------------------------------------------------------------------------
    // Mode Control
    // -------------------------------------------------------------------------
    input  logic        mode_12bit,   // 0 = RGB888; 1 = 12-bit legacy (4 early games)

    // -------------------------------------------------------------------------
    // Video Output — RGB888 DAC
    // -------------------------------------------------------------------------
    output logic [7:0]  video_r,
    output logic [7:0]  video_g,
    output logic [7:0]  video_b,

    // -------------------------------------------------------------------------
    // Pixel valid delayed output — 2 ce_pixel cycles behind pixel_valid input.
    // Provided for downstream display interface alignment (HSYNC/VSYNC delay).
    // -------------------------------------------------------------------------
    output logic [1:0]  pixel_valid_d  // [0]=1-cycle delay, [1]=2-cycle delay
);

// =============================================================================
// Unused Step-2 inputs suppressed (kept on port for interface stability)
// =============================================================================
/* verilator lint_off UNUSEDSIGNAL */
logic [12:0] dst_pal_unused;
logic [ 3:0] src_blend_unused;
logic [ 3:0] dst_blend_unused;
assign dst_pal_unused    = dst_pal;
assign src_blend_unused  = src_blend;
assign dst_blend_unused  = dst_blend;
/* verilator lint_on UNUSEDSIGNAL */

// =============================================================================
// cpu_dtack_n — permanently low (zero-wait-state palette BRAM)
// =============================================================================
assign cpu_dtack_n = 1'b0;

// =============================================================================
// Palette BRAM — 8192 × 32-bit
// Two mirrored copies (src_bram / dst_bram).  Every CPU write hits both.
// Step 1: only src_bram is read by the video path.
// Step 2 will add the dst_bram read for the dual-lookup blend pipeline.
//
// Physical layout:
//   bits[31:24] — unused (cpu_be[3] accepted, stored, ignored on read path)
//   bits[23:16] — R[7:0]
//   bits[15:8]  — G[7:0]
//   bits[7:0]   — B[7:0]
// =============================================================================
logic [31:0] src_bram [0:8191];
// dst_bram mirrors src_bram so Step 2 can add a second read port without
// changing the write logic.  It is written here but read only in Step 2.
/* verilator lint_off UNUSEDSIGNAL */
logic [31:0] dst_bram [0:8191];
/* verilator lint_on UNUSEDSIGNAL */

// ── CPU write port (system clock, no pixel-clock gating) ──────────────────
always_ff @(posedge clk) begin
    if (cpu_cs && cpu_we) begin
        // Byte enable [3] → bits[31:24] (unused channel, stored silently)
        if (cpu_be[3]) begin
            src_bram[cpu_addr][31:24] <= cpu_din[31:24];
            dst_bram[cpu_addr][31:24] <= cpu_din[31:24];
        end
        // Byte enable [2] → bits[23:16] = R
        if (cpu_be[2]) begin
            src_bram[cpu_addr][23:16] <= cpu_din[23:16];
            dst_bram[cpu_addr][23:16] <= cpu_din[23:16];
        end
        // Byte enable [1] → bits[15:8] = G
        if (cpu_be[1]) begin
            src_bram[cpu_addr][15:8]  <= cpu_din[15:8];
            dst_bram[cpu_addr][15:8]  <= cpu_din[15:8];
        end
        // Byte enable [0] → bits[7:0] = B
        if (cpu_be[0]) begin
            src_bram[cpu_addr][7:0]   <= cpu_din[7:0];
            dst_bram[cpu_addr][7:0]   <= cpu_din[7:0];
        end
    end
end

// =============================================================================
// CPU read-back path
// Section1 §1 notes no documented CPU read; cpu_rd_raw is an output port
// exposed for testbench write-integrity verification without going through
// the pixel pipeline.  Read latency: 1 cycle (BRAM registered output).
// =============================================================================
always_ff @(posedge clk) begin
    cpu_rd_raw <= src_bram[cpu_addr];
end

// =============================================================================
// Pixel output pipeline
//
// Stage 0 (this block): effective_idx computed → BRAM addressed
// Stage 1 (registered): BRAM output captured in pal_rd_data
// Stage 2 (registered): RGB decode + output registered → video_r/g/b
//
// pixel_valid_d shifts pixel_valid through 2 stages (matching 2 registered
// pipeline stages so the output enable is correctly aligned).
// =============================================================================

// 12-bit mode: zero-extend upper bit of index to map 4096 → 8192 address space
logic [12:0] effective_idx;
always_comb begin
    effective_idx = mode_12bit ? {1'b0, src_pal[11:0]} : src_pal;
end

// Stage 1 register: BRAM output (bits[23:0] only — bits[31:24] are the
// unused channel and are never needed in the decode path)
logic [23:0] pal_rd_data;
// Stage 1 valid
logic        pv_s1;

always_ff @(posedge clk) begin
    if (ce_pixel) begin
        pal_rd_data <= src_bram[effective_idx][23:0];
        pv_s1       <= pixel_valid;
    end
end

// Stage 2 register: RGB decode + output
// mode_12bit sampled one cycle late (aligned to BRAM output stage)
logic mode_12bit_s1;

always_ff @(posedge clk) begin
    if (ce_pixel) begin
        mode_12bit_s1 <= mode_12bit;
    end
end

always_ff @(posedge clk) begin
    if (!rst_n) begin
        video_r <= 8'd0;
        video_g <= 8'd0;
        video_b <= 8'd0;
    end else if (ce_pixel && pv_s1) begin
        if (!mode_12bit_s1) begin
            // Standard RGB888: bits[23:16]=R, [15:8]=G, [7:0]=B
            video_r <= pal_rd_data[23:16];
            video_g <= pal_rd_data[15:8];
            video_b <= pal_rd_data[7:0];
        end else begin
            // 12-bit legacy: bits[15:12]=R[3:0], [11:8]=G[3:0], [7:4]=B[3:0]
            // Expand 4→8 by nibble-repeat: 0x0→0x00, 0xF→0xFF (linear 0..255)
            video_r <= {pal_rd_data[15:12], pal_rd_data[15:12]};
            video_g <= {pal_rd_data[11:8],  pal_rd_data[11:8]};
            video_b <= {pal_rd_data[7:4],   pal_rd_data[7:4]};
        end
    end
end

// =============================================================================
// pixel_valid_d — 2-stage shift register tracking pixel_valid through the
// pixel pipeline so downstream display logic can align HSYNC/VSYNC.
//   pixel_valid_d[0] = 1 ce_pixel cycle behind pixel_valid
//   pixel_valid_d[1] = 2 ce_pixel cycles behind pixel_valid  (matches video_r/g/b)
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n) begin
        pixel_valid_d <= 2'b00;
    end else if (ce_pixel) begin
        pixel_valid_d <= {pixel_valid_d[0], pixel_valid};
    end
end

endmodule
