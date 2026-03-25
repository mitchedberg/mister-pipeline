`ifndef JTFRAME_SDRAM96
`define JTFRAME_SDRAM96
`endif

`ifndef JTFRAME_RFSH_WC
`define JTFRAME_RFSH_WC 14
`endif

`ifndef JTFRAME_RFSH_N
`define JTFRAME_RFSH_N 14'd1
`endif

`ifndef JTFRAME_RFSH_M
`define JTFRAME_RFSH_M 14'd8533
`endif

`default_nettype none
// =============================================================================
// sdram_b.sv — Taito B SDRAM frontend built on JTFRAME community SDRAM logic
// =============================================================================
//
// Architecture:
//   - `jtframe_board_sdram` provides the low-level MiSTer SDRAM controller
//   - one `jtframe_rom_1slot` runtime reader is used per ROM client:
//       ba0 = 68000 program ROM
//       ba1 = TC0180VCU GFX ROM
//       ba2 = ADPCM ROM
//       ba3 = Z80 ROM
//   - HPS ROM download uses the JTFRAME programming path (`prog_*`)
//
// The surrounding Taito B RTL still uses toggle/ack request semantics on the
// CPU/audio/Z80 side, so this module adapts those requests into JTFRAME's
// `slot_cs/slot_ok` contract while keeping the actual SDRAM engine community-
// grounded.
// =============================================================================

module sdram_b (
    input  logic        clk,        // SDRAM clock
    input  logic        clk_sys,    // system clock
    input  logic        rst_n,

    output logic [12:0] SDRAM_A,
    output logic  [1:0] SDRAM_BA,
    inout  wire  [15:0] SDRAM_DQ,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nWE,
    output logic        SDRAM_nCS,
    output logic  [1:0] SDRAM_DQM,
    output logic        SDRAM_CKE,

    // HPS ROM download path: local byte address within the selected bank
    input  logic        ioctl_wr,
    input  logic  [1:0] ioctl_ba,
    input  logic [26:0] ioctl_addr,
    input  logic  [7:0] ioctl_dout,

    // CH1: 68000 program ROM (local byte address)
    input  logic [26:0] cpu_addr,
    input  logic        cpu_req,
    output logic [15:0] cpu_data,
    output logic        cpu_ack,

    // CH2: GFX ROM (local byte address)
    input  logic [26:0] gfx_addr,
    input  logic        gfx_req,
    output logic  [7:0] gfx_data,
    output logic        gfx_ack,

    // CH3: ADPCM ROM (local byte address)
    input  logic [26:0] adpcm_addr,
    input  logic        adpcm_req,
    output logic [15:0] adpcm_data,
    output logic        adpcm_ack,

    // CH4: Z80 ROM (local byte address)
    input  logic [26:0] z80_addr,
    input  logic        z80_req,
    output logic [15:0] z80_data,
    output logic        z80_ack
);

localparam int SDRAMW = 23;
localparam int FIFO_DEPTH = 4;
localparam int FIFO_AW = 2;

// Download FIFO entry: {ba[1:0], word_addr[22:0], data[15:0]}
logic [40:0]         wr_fifo [0:FIFO_DEPTH-1];
logic [FIFO_AW-1:0]  wr_wptr, wr_rptr;
logic                wr_fifo_full, wr_fifo_empty;
logic  [7:0]         ioctl_lo_byte;
logic                ioctl_lo_valid;
logic  [1:0]         ioctl_lo_ba;
logic [26:0]         ioctl_lo_addr;

// Request CDC into clk domain
logic [1:0] cpu_req_sync,   gfx_req_sync,   adpcm_req_sync,   z80_req_sync;
logic       cpu_req_clk,    gfx_req_clk,    adpcm_req_clk,    z80_req_clk;
logic       cpu_req_prev,   gfx_req_prev,   adpcm_req_prev,   z80_req_prev;
logic       cpu_req_pend,   gfx_req_pend,   adpcm_req_pend,   z80_req_pend;
logic [26:0] cpu_addr_lat,  gfx_addr_lat,   adpcm_addr_lat,   z80_addr_lat;

// Runtime data returned to clk_sys domain consumers
logic [15:0] cpu_data_r, adpcm_data_r, z80_data_r;
logic  [7:0] gfx_data_r;
logic        cpu_ack_r, gfx_ack_r, adpcm_ack_r, z80_ack_r;

// JTFRAME runtime ports
logic [SDRAMW-1:0] ba0_addr, ba1_addr, ba2_addr, ba3_addr;
logic [3:0]        ba_rd, ba_wr, ba_ack, ba_dst, ba_dok, ba_rdy;
logic [15:0]       sdram_dout;

logic [15:0] cpu_slot_data, adpcm_slot_data, z80_slot_data;
logic  [7:0] gfx_slot_data;
logic        cpu_slot_ok, gfx_slot_ok, adpcm_slot_ok, z80_slot_ok;

// JTFRAME programming path
logic [SDRAMW-1:0] prog_addr_r;
logic [15:0]       prog_data_r;
logic  [1:0]       prog_ba_r;
logic               prog_we_r;
logic               prog_en_r;
logic               prog_rdy, prog_dok, prog_dst, prog_ack_unused;

assign wr_fifo_empty = (wr_wptr == wr_rptr);
assign wr_fifo_full  = ((wr_wptr + 1'b1) == wr_rptr);
assign ba_wr         = 4'b0000;

// -----------------------------------------------------------------------------
// Download path: pair HPS bytes into 16-bit JTFRAME programming writes.
// -----------------------------------------------------------------------------
always_ff @(posedge clk_sys or negedge rst_n) begin
    if (!rst_n) begin
        ioctl_lo_byte  <= 8'h00;
        ioctl_lo_valid <= 1'b0;
        ioctl_lo_ba    <= 2'b00;
        ioctl_lo_addr  <= '0;
        wr_wptr        <= '0;
    end else if (ioctl_wr) begin
        if (!ioctl_addr[0]) begin
            ioctl_lo_byte  <= ioctl_dout;
            ioctl_lo_valid <= 1'b1;
            ioctl_lo_ba    <= ioctl_ba;
            ioctl_lo_addr  <= ioctl_addr;
        end else if (!wr_fifo_full) begin
            wr_fifo[wr_wptr] <= {
                ioctl_lo_valid ? ioctl_lo_ba : ioctl_ba,
                ioctl_lo_valid ? ioctl_lo_addr[23:1] : ioctl_addr[23:1],
                ioctl_dout,
                ioctl_lo_valid ? ioctl_lo_byte : 8'h00
            };
            wr_wptr        <= wr_wptr + 1'b1;
            ioctl_lo_valid <= 1'b0;
        end
    end
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        prog_we_r <= 1'b0;
        prog_en_r <= 1'b0;
        prog_addr_r <= '0;
        prog_data_r <= '0;
        prog_ba_r   <= 2'b00;
        wr_rptr     <= '0;
    end else begin
        prog_en_r <= prog_we_r | ~wr_fifo_empty;

        if (prog_we_r && prog_rdy) begin
            prog_we_r <= 1'b0;
            wr_rptr   <= wr_rptr + 1'b1;
        end else if (!prog_we_r && !wr_fifo_empty) begin
            prog_ba_r   <= wr_fifo[wr_rptr][40:39];
            prog_addr_r <= wr_fifo[wr_rptr][38:16];
            prog_data_r <= wr_fifo[wr_rptr][15:0];
            prog_we_r   <= 1'b1;
        end
    end
end

// -----------------------------------------------------------------------------
// Toggle request synchronizers into the SDRAM clock domain.
// -----------------------------------------------------------------------------
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cpu_req_sync   <= 2'b00;
        gfx_req_sync   <= 2'b00;
        adpcm_req_sync <= 2'b00;
        z80_req_sync   <= 2'b00;
    end else begin
        cpu_req_sync   <= {cpu_req_sync[0],   cpu_req};
        gfx_req_sync   <= {gfx_req_sync[0],   gfx_req};
        adpcm_req_sync <= {adpcm_req_sync[0], adpcm_req};
        z80_req_sync   <= {z80_req_sync[0],   z80_req};
    end
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cpu_req_clk    <= 1'b0;
        gfx_req_clk    <= 1'b0;
        adpcm_req_clk  <= 1'b0;
        z80_req_clk    <= 1'b0;
        cpu_req_prev   <= 1'b0;
        gfx_req_prev   <= 1'b0;
        adpcm_req_prev <= 1'b0;
        z80_req_prev   <= 1'b0;
        cpu_req_pend   <= 1'b0;
        gfx_req_pend   <= 1'b0;
        adpcm_req_pend <= 1'b0;
        z80_req_pend   <= 1'b0;
        cpu_addr_lat   <= '0;
        gfx_addr_lat   <= '0;
        adpcm_addr_lat <= '0;
        z80_addr_lat   <= '0;
    end else begin
        cpu_req_clk    <= cpu_req_sync[1];
        gfx_req_clk    <= gfx_req_sync[1];
        adpcm_req_clk  <= adpcm_req_sync[1];
        z80_req_clk    <= z80_req_sync[1];
        cpu_req_prev   <= cpu_req_clk;
        gfx_req_prev   <= gfx_req_clk;
        adpcm_req_prev <= adpcm_req_clk;
        z80_req_prev   <= z80_req_clk;

        if (cpu_req_clk != cpu_req_prev) begin
            cpu_req_pend <= 1'b1;
            cpu_addr_lat <= cpu_addr;
        end else if (cpu_slot_ok) begin
            cpu_req_pend <= 1'b0;
        end

        if (gfx_req_clk != gfx_req_prev) begin
            gfx_req_pend <= 1'b1;
            gfx_addr_lat <= gfx_addr;
        end else if (gfx_slot_ok) begin
            gfx_req_pend <= 1'b0;
        end

        if (adpcm_req_clk != adpcm_req_prev) begin
            adpcm_req_pend <= 1'b1;
            adpcm_addr_lat <= adpcm_addr;
        end else if (adpcm_slot_ok) begin
            adpcm_req_pend <= 1'b0;
        end

        if (z80_req_clk != z80_req_prev) begin
            z80_req_pend <= 1'b1;
            z80_addr_lat <= z80_addr;
        end else if (z80_slot_ok) begin
            z80_req_pend <= 1'b0;
        end
    end
end

// -----------------------------------------------------------------------------
// JTFRAME runtime slot adapters: one bank per ROM client.
// -----------------------------------------------------------------------------
jtframe_rom_1slot #(
    .SDRAMW      (SDRAMW),
    .SLOT0_AW    (23),
    .SLOT0_DW    (16),
    .SLOT0_LATCH (1),
    .SLOT0_DOUBLE(1),
    .SLOT0_OKLATCH(0)
) u_cpu_rom (
    .rst         (~rst_n),
    .clk         (clk),
    .slot0_addr  (cpu_addr_lat[23:1]),
    .slot0_dout  (cpu_slot_data),
    .slot0_cs    (cpu_req_pend),
    .slot0_ok    (cpu_slot_ok),
    .sdram_ack   (ba_ack[0]),
    .sdram_rd    (ba_rd[0]),
    .sdram_addr  (ba0_addr),
    .data_dst    (ba_dst[0]),
    .data_rdy    (ba_rdy[0]),
    .data_read   (sdram_dout)
);

jtframe_rom_1slot #(
    .SDRAMW      (SDRAMW),
    .SLOT0_AW    (23),
    .SLOT0_DW    (8),
    .SLOT0_LATCH (0),
    .SLOT0_DOUBLE(0),
    .SLOT0_OKLATCH(0)
) u_gfx_rom (
    .rst         (~rst_n),
    .clk         (clk),
    .slot0_addr  (gfx_addr_lat[22:0]),
    .slot0_dout  (gfx_slot_data),
    .slot0_cs    (gfx_req_pend),
    .slot0_ok    (gfx_slot_ok),
    .sdram_ack   (ba_ack[1]),
    .sdram_rd    (ba_rd[1]),
    .sdram_addr  (ba1_addr),
    .data_dst    (ba_dst[1]),
    .data_rdy    (ba_rdy[1]),
    .data_read   (sdram_dout)
);

jtframe_rom_1slot #(
    .SDRAMW      (SDRAMW),
    .SLOT0_AW    (23),
    .SLOT0_DW    (16),
    .SLOT0_LATCH (1),
    .SLOT0_DOUBLE(1),
    .SLOT0_OKLATCH(0)
) u_adpcm_rom (
    .rst         (~rst_n),
    .clk         (clk),
    .slot0_addr  (adpcm_addr_lat[23:1]),
    .slot0_dout  (adpcm_slot_data),
    .slot0_cs    (adpcm_req_pend),
    .slot0_ok    (adpcm_slot_ok),
    .sdram_ack   (ba_ack[2]),
    .sdram_rd    (ba_rd[2]),
    .sdram_addr  (ba2_addr),
    .data_dst    (ba_dst[2]),
    .data_rdy    (ba_rdy[2]),
    .data_read   (sdram_dout)
);

jtframe_rom_1slot #(
    .SDRAMW      (SDRAMW),
    .SLOT0_AW    (23),
    .SLOT0_DW    (16),
    .SLOT0_LATCH (1),
    .SLOT0_DOUBLE(1),
    .SLOT0_OKLATCH(0)
) u_z80_rom (
    .rst         (~rst_n),
    .clk         (clk),
    .slot0_addr  (z80_addr_lat[23:1]),
    .slot0_dout  (z80_slot_data),
    .slot0_cs    (z80_req_pend),
    .slot0_ok    (z80_slot_ok),
    .sdram_ack   (ba_ack[3]),
    .sdram_rd    (ba_rd[3]),
    .sdram_addr  (ba3_addr),
    .data_dst    (ba_dst[3]),
    .data_rdy    (ba_rdy[3]),
    .data_read   (sdram_dout)
);

// -----------------------------------------------------------------------------
// Low-level community SDRAM controller.
// -----------------------------------------------------------------------------
jtframe_board_sdram #(
    .SDRAMW (SDRAMW),
    .MISTER (1)
) u_board_sdram (
    .rst        (~rst_n),
    .clk        (clk),
    .init       (),
    .prog_en    (prog_en_r),

    .ba0_addr   (ba0_addr),
    .ba1_addr   (ba1_addr),
    .ba2_addr   (ba2_addr),
    .ba3_addr   (ba3_addr),
    .burst_addr ('0),
    .burst_ba   (2'b00),
    .burst_rd   (1'b0),
    .burst_wr   (1'b0),
    .ba_rd      (ba_rd),
    .ba_wr      (ba_wr),
    .ba0_din    (16'h0000),
    .ba0_dsn    (2'b11),
    .ba1_din    (16'h0000),
    .ba1_dsn    (2'b11),
    .ba2_din    (16'h0000),
    .ba2_dsn    (2'b11),
    .ba3_din    (16'h0000),
    .ba3_dsn    (2'b11),
    .burst_din  (16'h0000),
    .burst_ack  (),
    .burst_rdy  (),
    .burst_dst  (),
    .burst_dok  (),
    .ba_ack     (ba_ack),
    .ba_rdy     (ba_rdy),
    .ba_dst     (ba_dst),
    .ba_dok     (ba_dok),
    .dout       (sdram_dout),

    .prog_addr  (prog_addr_r),
    .prog_data  (prog_data_r),
    .prog_dsn   (2'b00),
    .prog_ba    (prog_ba_r),
    .prog_we    (prog_we_r),
    .prog_rd    (1'b0),
    .prog_dok   (prog_dok),
    .prog_rdy   (prog_rdy),
    .prog_dst   (prog_dst),
    .prog_ack   (prog_ack_unused),

    .sdram_dq   (SDRAM_DQ),
    .sdram_a    (SDRAM_A),
    .sdram_dqml (SDRAM_DQM[0]),
    .sdram_dqmh (SDRAM_DQM[1]),
    .sdram_nwe  (SDRAM_nWE),
    .sdram_ncas (SDRAM_nCAS),
    .sdram_nras (SDRAM_nRAS),
    .sdram_ncs  (SDRAM_nCS),
    .sdram_ba   (SDRAM_BA),
    .sdram_cke  (SDRAM_CKE)
);

// -----------------------------------------------------------------------------
// Capture returned data in the SDRAM clock domain. Acks mirror the synced req
// toggle, so the clk_sys-side client sees stable data before the toggle changes.
// -----------------------------------------------------------------------------
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cpu_data_r   <= 16'hFFFF;
        gfx_data_r   <= 8'hFF;
        adpcm_data_r <= 16'hFFFF;
        z80_data_r   <= 16'hFFFF;
        cpu_ack_r    <= 1'b0;
        gfx_ack_r    <= 1'b0;
        adpcm_ack_r  <= 1'b0;
        z80_ack_r    <= 1'b0;
    end else begin
        if (cpu_slot_ok) begin
            cpu_data_r <= cpu_slot_data;
            cpu_ack_r  <= cpu_req_clk;
        end
        if (gfx_slot_ok) begin
            gfx_data_r <= gfx_slot_data;
            gfx_ack_r  <= gfx_req_clk;
        end
        if (adpcm_slot_ok) begin
            adpcm_data_r <= adpcm_slot_data;
            adpcm_ack_r  <= adpcm_req_clk;
        end
        if (z80_slot_ok) begin
            z80_data_r <= z80_slot_data;
            z80_ack_r  <= z80_req_clk;
        end
    end
end

assign cpu_data   = cpu_data_r;
assign cpu_ack    = cpu_ack_r;
assign gfx_data   = gfx_data_r;
assign gfx_ack    = gfx_ack_r;
assign adpcm_data = adpcm_data_r;
assign adpcm_ack  = adpcm_ack_r;
assign z80_data   = z80_data_r;
assign z80_ack    = z80_ack_r;

endmodule
