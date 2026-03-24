`default_nettype none
// =============================================================================
// TC0650FDA — Taito F3 Palette RAM + Alpha Blend + DAC
// =============================================================================
// Stores 8192 × 32-bit palette entries (RGB888, bits[23:0] used).
// Two mirrored BRAM copies (src_bram, dst_bram) share every CPU write.
// Step 2: dual-source lookup with 3-stage MAC pipeline for alpha blending.
//
// CPU Interface (32-bit write-only, 68EC020 bus fragment):
//   cpu_addr[12:0] — 13-bit palette index (word-aligned 32-bit access)
//   cpu_din[31:0]  — write data: bits[23:16]=R, [15:8]=G, [7:0]=B
//   cpu_be[3:0]    — byte enables {D31:D24, D23:D16, D15:D8, D7:D0}
//   cpu_we         — write enable
//   cpu_cs         — chip select
//   cpu_dtack_n    — permanently 0 (zero-wait-state BRAM)
//
// Pixel pipeline (3 registered stages, advances on ce_pixel):
//   Stage 0 (combinational): src_bram[src_pal] and dst_bram[dst_pal] addressed
//   Stage 1 (registered)   : BRAM outputs captured; 12-bit mode decode applied
//   Stage 2 (registered)   : multiply — src*src_blend and dst*dst_blend (12-bit products)
//   Stage 3 (registered)   : accumulate, shift-right-3, saturate → video_r/g/b
//   pixel_valid_d[2:0] shift register aligns pixel_valid to match 3-stage depth
//
// Alpha blend formula (section1 §6):
//   out_C = clamp((src_C * src_blend + dst_C * dst_blend) >> 3, 0, 255)
//   When do_blend=0: passthrough src_rgb directly (pipeline depth still 3 stages)
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
    input  logic [12:0] dst_pal,      // Destination palette index (blend destination)
    input  logic [ 3:0] src_blend,    // Source blend factor 0–8
    input  logic [ 3:0] dst_blend,    // Destination blend factor 0–8
    input  logic        do_blend,     // 1=alpha blend, 0=opaque passthrough

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
    // Pixel valid delayed output — 3 ce_pixel cycles behind pixel_valid input.
    // Provided for downstream display interface alignment (HSYNC/VSYNC delay).
    // -------------------------------------------------------------------------
    output logic [2:0]  pixel_valid_d  // [0]=1-cycle, [1]=2-cycle, [2]=3-cycle delay
);

// =============================================================================
// cpu_dtack_n — permanently low (zero-wait-state palette BRAM)
// =============================================================================
assign cpu_dtack_n = 1'b0;

// =============================================================================
// Palette BRAM — 8192 × 32-bit, two mirrored copies.
// src_bram: read port for src_pal (winning pixel)
// dst_bram: read port for dst_pal (blend destination pixel)
// Both receive identical CPU writes.
//
// Physical layout:
//   bits[31:24] — unused (cpu_be[3] accepted, stored, ignored on read path)
//   bits[23:16] — R[7:0]
//   bits[15:8]  — G[7:0]
//   bits[7:0]   — B[7:0]
// =============================================================================
// =============================================================================
// 12-bit mode address masking (outside ifdef — used in both QUARTUS and sim paths)
// In 12-bit mode the effective address is {1'b0, idx[11:0]}.
// =============================================================================
logic [12:0] src_eff_idx;
logic [12:0] dst_eff_idx;
always_comb begin
    src_eff_idx = mode_12bit ? {1'b0, src_pal[11:0]} : src_pal;
    dst_eff_idx = mode_12bit ? {1'b0, dst_pal[11:0]} : dst_pal;
end

`ifdef QUARTUS
// =============================================================================
// Palette BRAM — altsyncram DUAL_PORT instances (Quartus M10K, byteena write)
// src_bram: two instances — one for CPU read-back, one for pixel pipeline read
// dst_bram: one instance — pixel pipeline read only
// All three share the same write port (cpu_addr, cpu_din, bram_we, bram_be).
// =============================================================================

// CPU write path signals
logic        bram_we;
logic [3:0]  bram_be;
assign bram_we = cpu_cs & cpu_we;
assign bram_be = cpu_be;

// src_bram instance 1: CPU read-back
altsyncram #(
    .operation_mode            ("DUAL_PORT"),
    .width_a                   (32), .widthad_a (13), .numwords_a (8192),
    .width_b                   (32), .widthad_b (13), .numwords_b (8192),
    .outdata_reg_b             ("CLOCK1"), .address_reg_b ("CLOCK1"),
    .clock_enable_input_a      ("BYPASS"), .clock_enable_input_b ("BYPASS"),
    .clock_enable_output_b     ("BYPASS"),
    .intended_device_family    ("Cyclone V"),
    .lpm_type                  ("altsyncram"), .ram_block_type ("M10K"),
    .width_byteena_a           (4), .power_up_uninitialized ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) src_cpu_inst (
    .clock0(clk), .clock1(clk),
    .address_a(cpu_addr[12:0]), .data_a(cpu_din),
    .wren_a(bram_we), .byteena_a(bram_be),
    .address_b(cpu_addr[12:0]), .q_b(cpu_rd_raw),
    .wren_b(1'b0), .data_b(32'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);

// src_bram instance 2: pixel pipeline read
logic [31:0] src_pix_q;
altsyncram #(
    .operation_mode            ("DUAL_PORT"),
    .width_a                   (32), .widthad_a (13), .numwords_a (8192),
    .width_b                   (32), .widthad_b (13), .numwords_b (8192),
    .outdata_reg_b             ("CLOCK1"), .address_reg_b ("CLOCK1"),
    .clock_enable_input_a      ("BYPASS"), .clock_enable_input_b ("BYPASS"),
    .clock_enable_output_b     ("BYPASS"),
    .intended_device_family    ("Cyclone V"),
    .lpm_type                  ("altsyncram"), .ram_block_type ("M10K"),
    .width_byteena_a           (4), .power_up_uninitialized ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) src_pix_inst (
    .clock0(clk), .clock1(clk),
    .address_a(cpu_addr[12:0]), .data_a(cpu_din),
    .wren_a(bram_we), .byteena_a(bram_be),
    .address_b(src_eff_idx[12:0]), .q_b(src_pix_q),
    .wren_b(1'b0), .data_b(32'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);

// dst_bram instance: pixel pipeline read
logic [31:0] dst_pix_q;
altsyncram #(
    .operation_mode            ("DUAL_PORT"),
    .width_a                   (32), .widthad_a (13), .numwords_a (8192),
    .width_b                   (32), .widthad_b (13), .numwords_b (8192),
    .outdata_reg_b             ("CLOCK1"), .address_reg_b ("CLOCK1"),
    .clock_enable_input_a      ("BYPASS"), .clock_enable_input_b ("BYPASS"),
    .clock_enable_output_b     ("BYPASS"),
    .intended_device_family    ("Cyclone V"),
    .lpm_type                  ("altsyncram"), .ram_block_type ("M10K"),
    .width_byteena_a           (4), .power_up_uninitialized ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) dst_pix_inst (
    .clock0(clk), .clock1(clk),
    .address_a(cpu_addr[12:0]), .data_a(cpu_din),
    .wren_a(bram_we), .byteena_a(bram_be),
    .address_b(dst_eff_idx[12:0]), .q_b(dst_pix_q),
    .wren_b(1'b0), .data_b(32'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);

`else
logic [31:0] src_bram [0:8191];
logic [31:0] dst_bram [0:8191];

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
// Exposed for testbench write-integrity verification without going through
// the pixel pipeline. Read latency: 1 cycle (BRAM registered output).
// =============================================================================
always_ff @(posedge clk) begin
    cpu_rd_raw <= src_bram[cpu_addr];
end
`endif

// =============================================================================
// 3-Stage MAC Pipeline
//
// Stage 1: BRAM reads (src_bram[src_eff_idx], dst_bram[dst_eff_idx]) registered.
//          mode_12bit decode applied. src_blend/dst_blend/do_blend pipelined.
// Stage 2: Multiply — 8-bit × 4-bit = 12-bit products for each channel.
//          (When do_blend=0, pass src_rgb directly through multiplier stage.)
// Stage 3: Accumulate + shift-right-3 + saturate → video_r/g/b.
// =============================================================================

// ── Stage 1 registers ────────────────────────────────────────────────────────
logic [23:0] src_rgb_s1;       // decoded RGB from src_bram
logic [23:0] dst_rgb_s1;       // decoded RGB from dst_bram
logic [ 3:0] src_blend_s1;
logic [ 3:0] dst_blend_s1;
logic        do_blend_s1;
logic        pv_s1;

`ifdef QUARTUS
// Under QUARTUS: altsyncram q_b outputs are already registered (CLOCK1 domain).
// Use src_pix_q / dst_pix_q directly; still gate pipeline advance by ce_pixel.
always_ff @(posedge clk) begin
    if (ce_pixel) begin
        if (!mode_12bit) begin
            src_rgb_s1 <= src_pix_q[23:0];
            dst_rgb_s1 <= dst_pix_q[23:0];
        end else begin
            // 12-bit nibble-repeat decode: bits[15:12]=R, [11:8]=G, [7:4]=B
            src_rgb_s1 <= {src_pix_q[15:12], src_pix_q[15:12],
                           src_pix_q[11:8],  src_pix_q[11:8],
                           src_pix_q[7:4],   src_pix_q[7:4]};
            dst_rgb_s1 <= {dst_pix_q[15:12], dst_pix_q[15:12],
                           dst_pix_q[11:8],  dst_pix_q[11:8],
                           dst_pix_q[7:4],   dst_pix_q[7:4]};
        end
        src_blend_s1 <= src_blend;
        dst_blend_s1 <= dst_blend;
        do_blend_s1  <= do_blend;
        pv_s1        <= pixel_valid;
    end
end
`else
always_ff @(posedge clk) begin
    if (ce_pixel) begin
        // Read both BRAMs and decode 12-bit or standard
        if (!mode_12bit) begin
            src_rgb_s1 <= src_bram[src_eff_idx][23:0];
            dst_rgb_s1 <= dst_bram[dst_eff_idx][23:0];
        end else begin
            // 12-bit nibble-repeat decode: bits[15:12]=R, [11:8]=G, [7:4]=B
            src_rgb_s1 <= {src_bram[src_eff_idx][15:12], src_bram[src_eff_idx][15:12],
                           src_bram[src_eff_idx][11:8],  src_bram[src_eff_idx][11:8],
                           src_bram[src_eff_idx][7:4],   src_bram[src_eff_idx][7:4]};
            dst_rgb_s1 <= {dst_bram[dst_eff_idx][15:12], dst_bram[dst_eff_idx][15:12],
                           dst_bram[dst_eff_idx][11:8],  dst_bram[dst_eff_idx][11:8],
                           dst_bram[dst_eff_idx][7:4],   dst_bram[dst_eff_idx][7:4]};
        end
        src_blend_s1 <= src_blend;
        dst_blend_s1 <= dst_blend;
        do_blend_s1  <= do_blend;
        pv_s1        <= pixel_valid;
    end
end
`endif

// ── Stage 2 registers — multiply ─────────────────────────────────────────────
// 8-bit × 4-bit products: max 255×8 = 2040, fits in 12 bits.
// When do_blend=0: pass src_rgb[channel] directly (multiply-by-8 not needed
// because we bypass by storing the decoded RGB in the mul registers directly).
// Under QUARTUS: force DSP blocks for the blend multiplies (saves ~3 DSPs,
// each replacing ~200 ALMs of combinational fabric per multiply instance).
`ifdef QUARTUS
(* multstyle = "dsp" *) logic [11:0] mul_r_src_s2;
(* multstyle = "dsp" *) logic [11:0] mul_g_src_s2;
(* multstyle = "dsp" *) logic [11:0] mul_b_src_s2;
(* multstyle = "dsp" *) logic [11:0] mul_r_dst_s2;
(* multstyle = "dsp" *) logic [11:0] mul_g_dst_s2;
(* multstyle = "dsp" *) logic [11:0] mul_b_dst_s2;
`else
logic [11:0] mul_r_src_s2, mul_g_src_s2, mul_b_src_s2;
logic [11:0] mul_r_dst_s2, mul_g_dst_s2, mul_b_dst_s2;
`endif
logic        do_blend_s2;
logic        pv_s2;

always_ff @(posedge clk) begin
    if (ce_pixel) begin
        if (!do_blend_s1) begin
            // Opaque passthrough: treat as src_blend=8, dst_blend=0 without MAC.
            // Store src_rgb scaled to <<3 equivalent: src * 8 = {src, 3'b0}
            // so that stage 3 shift-right-3 recovers src exactly.
            mul_r_src_s2 <= {4'b0, src_rgb_s1[23:16]};  // = src_r (will be <<3/>>3 = identity)
            mul_g_src_s2 <= {4'b0, src_rgb_s1[15:8]};
            mul_b_src_s2 <= {4'b0, src_rgb_s1[7:0]};
            mul_r_dst_s2 <= 12'd0;
            mul_g_dst_s2 <= 12'd0;
            mul_b_dst_s2 <= 12'd0;
        end else begin
            // Full MAC: 8-bit × 4-bit = 12-bit
            mul_r_src_s2 <= 12'(src_rgb_s1[23:16]) * 12'(src_blend_s1);
            mul_g_src_s2 <= 12'(src_rgb_s1[15:8])  * 12'(src_blend_s1);
            mul_b_src_s2 <= 12'(src_rgb_s1[7:0])   * 12'(src_blend_s1);
            mul_r_dst_s2 <= 12'(dst_rgb_s1[23:16]) * 12'(dst_blend_s1);
            mul_g_dst_s2 <= 12'(dst_rgb_s1[15:8])  * 12'(dst_blend_s1);
            mul_b_dst_s2 <= 12'(dst_rgb_s1[7:0])   * 12'(dst_blend_s1);
        end
        do_blend_s2 <= do_blend_s1;
        pv_s2       <= pv_s1;
    end
end

// ── Stage 3 registers — accumulate, shift, saturate, output ─────────────────
// Sum is 13-bit (12+12+1 carry): max 2040+2040 = 4080.
// Shift right by 3: 4080>>3 = 510, fits in 9 bits.
// Saturate: if result > 255, output 0xFF.
//
// Opaque path: sum = src_r (stored in mul_r_src) + 0 = src_r.
//   sum >> 3 would give src_r>>3 which is wrong. For do_blend=0 we instead
//   output mul_r_src_s2[7:0] directly (the raw 8-bit value stored at [7:0]).
//   This is the passthrough fast path.

always_ff @(posedge clk) begin
    if (!rst_n) begin
        video_r <= 8'd0;
        video_g <= 8'd0;
        video_b <= 8'd0;
    end else if (ce_pixel && pv_s2) begin
        if (!do_blend_s2) begin
            // Opaque passthrough: output the raw src RGB stored in mul_r_src_s2[7:0]
            video_r <= mul_r_src_s2[7:0];
            video_g <= mul_g_src_s2[7:0];
            video_b <= mul_b_src_s2[7:0];
        end else begin
            // Blend: sum = (src * src_blend + dst * dst_blend) >> 3, saturated.
            // Sum is 13-bit (max 4080); after >>3 the result is 10-bit (max 510).
            // Compute shifted sum directly as 10-bit to avoid unused-bits warnings.
            begin
                logic [9:0] shifted_r, shifted_g, shifted_b;
                shifted_r = 10'((13'(mul_r_src_s2) + 13'(mul_r_dst_s2)) >> 3);
                shifted_g = 10'((13'(mul_g_src_s2) + 13'(mul_g_dst_s2)) >> 3);
                shifted_b = 10'((13'(mul_b_src_s2) + 13'(mul_b_dst_s2)) >> 3);
                video_r <= (shifted_r > 10'd255) ? 8'hFF : 8'(shifted_r);
                video_g <= (shifted_g > 10'd255) ? 8'hFF : 8'(shifted_g);
                video_b <= (shifted_b > 10'd255) ? 8'hFF : 8'(shifted_b);
            end
        end
    end
end

// =============================================================================
// pixel_valid_d — 3-stage shift register tracking pixel_valid through the
// 3-stage pixel pipeline so downstream display logic can align HSYNC/VSYNC.
//   pixel_valid_d[0] = 1 ce_pixel cycle behind pixel_valid
//   pixel_valid_d[1] = 2 ce_pixel cycles behind pixel_valid
//   pixel_valid_d[2] = 3 ce_pixel cycles behind pixel_valid  (matches video_r/g/b)
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n) begin
        pixel_valid_d <= 3'b000;
    end else if (ce_pixel) begin
        pixel_valid_d <= {pixel_valid_d[1:0], pixel_valid};
    end
end

endmodule
