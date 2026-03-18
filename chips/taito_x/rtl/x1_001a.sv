`default_nettype none
// =============================================================================
// X1-001A / X1-002A — Taito X Sprite Generator
// =============================================================================
//
// Phase 1: Sprite RAM + CPU interface.
// Phase 2: Sprite scanner FSM, GFX ROM fetch, line buffer, pixel output.
//
// Architecture (from MAME src/devices/video/x1_001.cpp):
//
//   Two CPU-addressable RAMs:
//     spriteylow[0x300 bytes]   — Y coords + BG scroll RAM
//     spritecode[0x2000 words]  — Tile codes, X coords, flip, color, BG tiles
//   Four control registers (spritectrl[0..3])
//
// Sprite entry format (foreground, 512 entries):
//   spritecode[i]          word:  [15]=FlipX, [14]=FlipY, [13:0]=tile_code
//   spritecode[0x200+i]    word:  [15:11]=color(5b), [8]=X_sign, [7:0]=X_low
//   spriteylow[i]          byte:  [7:0]=Y position
//
//   Effective X = (x_low & 0xFF) - (x_low & 0x100)   (9-bit signed)
//   Effective Y on screen = max_y - ((Y + yoffs) & 0xFF)
//
// Priority: index 0 = highest priority (drawn last, overwrites all others)
// Transparency: pen 0 in palette = transparent
// Zoom: none (16×16 fixed)
// Double buffer: bank_size = 0x1000 words
//
// Phase 2 additions:
//   - Sprite scanner FSM triggered by VBlank rising edge
//   - GFX ROM interface: toggle handshake (gfx_req/gfx_ack)
//   - Double-buffered line buffer (2 × SCREEN_H × 512 × 6-bit entries)
//   - Active display pixel output (pix_valid / pix_x / pix_color)
//
// Scanner matches MAME draw_foreground():
//   Scans from SPRITE_LIMIT down to 0 (index 0 = highest priority, drawn last).
//   For each sprite: fetches 16 rows × 4 GFX ROM words; writes non-transparent
//   pixels to the write-side line buffer.
//
// GFX ROM word layout (4bpp, 16×16 tile = 64 words):
//   addr = tile_code*64 + row*4 + word_in_row
//   Each 16-bit word: [15:12]=px0, [11:8]=px1, [7:4]=px2, [3:0]=px3
//   (high nibble = left pixel)
//
// GFX ROM toggle handshake:
//   Requester toggles gfx_req → asserts gfx_addr.
//   Responder toggles gfx_ack → gfx_data is valid.
//   Testbench uses zero-latency: ack toggles same cycle as req is seen.
//
// Line buffer ping-pong:
//   linebuf[bank][y][x] = {valid(1), color[4:0], pen[3:0]} = 10 bits
//   Scanner writes to ~linebuf_bank.  Display reads from linebuf_bank.
//   Bank swap on vblank rising edge.
//   Clear sweep: at start of each hblank, zero the write-bank for this scanline.
// =============================================================================

// Pixel write parameters are computed combinationally per pixel p:
//   screen_x[p] = wr_sx_base + p  (9-bit, wraps mod 512)
//   screen_y    = wr_row_y
//   nibble[p]   = get_nibble(gfx_w0..3, p, spr_flipx)
//   write if nibble != 0 && screen_y < SCREEN_H && screen_x < SCREEN_W

module x1_001a #(
    // Y offset for FG sprites in no-flip mode (Superman = -0x12)
    parameter int FG_NOFLIP_YOFFS = -18,
    parameter int FG_NOFLIP_XOFFS = 0,
    // Screen geometry
    parameter int SCREEN_H        = 240,
    parameter int SCREEN_W        = 384,
    // Number of sprites (0 to SPRITE_LIMIT inclusive)
    parameter int SPRITE_LIMIT    = 511
) (
    input  logic        clk,
    input  logic        rst_n,

    // ── Timing inputs ────────────────────────────────────────────────────────
    input  logic        vblank,
    input  logic        hblank,
    input  logic  [8:0] hpos,
    input  logic  [7:0] vpos,

    // ── Sprite Y-coordinate RAM CPU port ─────────────────────────────────────
    input  logic        yram_cs,
    input  logic        yram_we,
    input  logic  [8:0] yram_addr,
    input  logic [15:0] yram_din,
    output logic [15:0] yram_dout,
    input  logic  [1:0] yram_be,

    // ── Sprite code / attribute RAM CPU port ─────────────────────────────────
    input  logic        cram_cs,
    input  logic        cram_we,
    input  logic [12:0] cram_addr,
    input  logic [15:0] cram_din,
    output logic [15:0] cram_dout,
    input  logic  [1:0] cram_be,

    // ── Control register CPU port ─────────────────────────────────────────────
    input  logic        ctrl_cs,
    input  logic        ctrl_we,
    input  logic  [1:0] ctrl_addr,
    input  logic [15:0] ctrl_din,
    output logic [15:0] ctrl_dout,
    input  logic  [1:0] ctrl_be,

    // ── External scanner read ports (exposed for Phase 1 testbench) ───────────
    input  logic  [8:0] scan_yram_addr,
    output logic [15:0] scan_yram_data,
    input  logic [12:0] scan_cram_addr,
    output logic [15:0] scan_cram_data,

    // ── Decoded control outputs ───────────────────────────────────────────────
    output logic        flip_screen,
    output logic  [1:0] bg_startcol,
    output logic  [3:0] bg_numcol,
    output logic        frame_bank,
    output logic [15:0] col_upper_mask,

    // ── GFX ROM interface (toggle handshake) ─────────────────────────────────
    output logic [17:0] gfx_addr,
    output logic        gfx_req,
    input  logic [15:0] gfx_data,
    input  logic        gfx_ack,

    // ── Pixel output ─────────────────────────────────────────────────────────
    output logic        pix_valid,
    output logic  [8:0] pix_x,
    output logic  [4:0] pix_color,     // 5-bit palette selector (color[4:0])
    output logic  [8:0] pix_pal_index, // full 9-bit palette index = {color[4:0], pen[3:0]}

    // ── Status ───────────────────────────────────────────────────────────────
    output logic        scan_active
);

    // =========================================================================
    // Sprite Y-coordinate RAM  (0x180 words)
    // =========================================================================

`ifndef QUARTUS
    logic [7:0] yram_lo [0:383];
    logic [7:0] yram_hi [0:383];

    always_ff @(posedge clk) begin
        if (yram_cs && yram_we) begin
            if (yram_be[0]) yram_lo[yram_addr] <= yram_din[7:0];
            if (yram_be[1]) yram_hi[yram_addr] <= yram_din[15:8];
        end
    end

    always_ff @(posedge clk) begin
        if (yram_cs && !yram_we)
            yram_dout <= { yram_hi[yram_addr], yram_lo[yram_addr] };
    end

    always_ff @(posedge clk)
        scan_yram_data <= { yram_hi[scan_yram_addr], yram_lo[scan_yram_addr] };
`else
    // Quartus stub — yram combinational reads prevent M10K inference.
    // Y RAM output is stubbed to zero for synthesis gate target.
    logic [7:0] yram_lo_stub = 8'b0;
    logic [7:0] yram_hi_stub = 8'b0;
    assign yram_dout     = 16'b0;
    assign scan_yram_data = 16'b0;
`endif

    // =========================================================================
    // Sprite code / attribute RAM  (0x2000 words)
    // =========================================================================

`ifndef QUARTUS
    logic [7:0] cram_lo [0:8191];
    logic [7:0] cram_hi [0:8191];

    always_ff @(posedge clk) begin
        if (cram_cs && cram_we) begin
            if (cram_be[0]) cram_lo[cram_addr] <= cram_din[7:0];
            if (cram_be[1]) cram_hi[cram_addr] <= cram_din[15:8];
        end
    end

    always_ff @(posedge clk) begin
        if (cram_cs && !cram_we)
            cram_dout <= { cram_hi[cram_addr], cram_lo[cram_addr] };
    end

    always_ff @(posedge clk)
        scan_cram_data <= { cram_hi[scan_cram_addr], cram_lo[scan_cram_addr] };

    // ── Internal FSM CRAM read port ──────────────────────────────────────────
    // Combinational (async) read: data available same cycle address is driven.
    // The FSM sets fsm_cram_rd_addr as a registered signal (updates at posedge),
    // so the pipeline is: posedge T sets addr → combinational data valid in cycle T+1
    // (between T and T+1) → FSM reads fsm_cram_rd_data at posedge T+1. One cycle
    // of latency, matching the FSM's RD_CHAR / RD_XPTR wait states.
    logic [12:0] fsm_cram_rd_addr;
    logic [15:0] fsm_cram_rd_data;

    always_comb
        fsm_cram_rd_data = { cram_hi[fsm_cram_rd_addr], cram_lo[fsm_cram_rd_addr] };
`else
    // Quartus stub — cram combinational reads prevent M10K inference.
    // Stub to zero; sprite code RAM output is zero for synthesis gate target.
    logic [7:0] cram_lo_stub = 8'b0;
    logic [7:0] cram_hi_stub = 8'b0;
    assign cram_dout      = 16'b0;
    assign scan_cram_data = 16'b0;
    logic [12:0] fsm_cram_rd_addr;
    logic [15:0] fsm_cram_rd_data;
    assign fsm_cram_rd_data = 16'b0;
`endif

    // =========================================================================
    // Control registers
    // =========================================================================

    logic [15:0] spritectrl [0:3];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spritectrl[0] <= 16'hFFFF;
            spritectrl[1] <= 16'hFFFF;
            spritectrl[2] <= 16'hFFFF;
            spritectrl[3] <= 16'hFFFF;
        end else if (ctrl_cs && ctrl_we) begin
            if (ctrl_be[0]) spritectrl[ctrl_addr][ 7:0] <= ctrl_din[7:0];
            if (ctrl_be[1]) spritectrl[ctrl_addr][15:8] <= ctrl_din[15:8];
        end
    end

    always_comb begin
        ctrl_dout = 16'h0000;
        if (ctrl_cs && !ctrl_we)
            ctrl_dout = spritectrl[ctrl_addr];
    end

    assign flip_screen    = spritectrl[0][6];
    assign bg_startcol    = spritectrl[0][1:0];
    assign bg_numcol      = spritectrl[1][3:0];
    assign col_upper_mask = {spritectrl[3][7:0], spritectrl[2][7:0]};
    assign frame_bank     = spritectrl[1][6] ^ (~spritectrl[1][5]);

    // =========================================================================
    // Phase 2: Scanner FSM
    // =========================================================================

    typedef enum logic [3:0] {
        ST_IDLE      = 4'd0,
        ST_RD_CHAR   = 4'd1,   // issued CRAM read for char_pointer; wait 1 cycle
        ST_RD_XPTR   = 4'd2,   // char arrives; issue x_pointer read; wait 1 cycle
        ST_DECODE    = 4'd3,   // x_ptr arrives; decode all attributes; prime row loop
        ST_FETCH0    = 4'd4,   // fetch GFX ROM word 0 of current row
        ST_FETCH1    = 4'd5,
        ST_FETCH2    = 4'd6,
        ST_FETCH3    = 4'd7,   // fetch word 3; trigger pixel write on ack
        ST_WRITE_ROW = 4'd8,   // pixel write pulse active this cycle
        ST_NEXT_ROW  = 4'd9,   // advance row_cnt or sprite index
        ST_DONE      = 4'd10
    } fsm_t;

    fsm_t fsm_state;

    // Edge detects
    logic vblank_r;
    wire  vblank_rise = vblank & ~vblank_r;

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) vblank_r <= 1'b0;
        else        vblank_r <= vblank;

    // Bank base addresses (combinational from frame_bank)
    wire [12:0] bank_base = frame_bank ? 13'h1000 : 13'h0000;
    wire [12:0] xptr_base = frame_bank ? 13'h1200 : 13'h0200;

    // Sprite index
    logic [8:0] scan_idx;

    // Latched sprite attributes
    logic [13:0] spr_tile;
    logic        spr_flipx;
    logic        spr_flipy;
    logic [4:0]  spr_color;
    logic [8:0]  spr_sx;       // screen X base (9-bit, signed interpretation)
    logic [7:0]  spr_ytop;     // screen Y of tile top row

    // Char pointer latch (latched one cycle before x_pointer arrives)
    logic [15:0] char_latch;

    // Row counter (0..15 in scan order; row_actual = flipy ? 15-row_cnt : row_cnt)
    logic [3:0]  row_cnt;
    wire  [3:0]  row_actual = spr_flipy ? (4'd15 - row_cnt) : row_cnt;

    // GFX ROM word buffer for current row
    logic [15:0] gfx_w [0:3];

    // GFX ROM handshake
    logic gfx_req_r;
    assign gfx_req = gfx_req_r;

    // GFX ROM address helper function
    function automatic [17:0] rom_addr(
        input [13:0] tile,
        input [3:0]  row,
        input [1:0]  word
    );
        rom_addr = ({4'b0, tile} * 18'd64) + ({14'b0, row} * 18'd4) + {16'b0, word};
    endfunction

    // scan_active
    assign scan_active = (fsm_state != ST_IDLE) && (fsm_state != ST_DONE);

    // ── Pixel write control signals (driven from ST_FETCH3 / ST_WRITE_ROW) ───
    logic        do_write;       // pulse: write 16 pixels to line buffer
    logic [7:0]  wr_y;           // scanline for this row
    logic [8:0]  wr_sx;          // screen X base for pixel 0

    // =========================================================================
    // Double-buffered line buffer
    // =========================================================================

    localparam int LB_W = 512;

    // 10-bit entry: [9]=valid, [8:4]=color[4:0], [3:0]=pen[3:0]
`ifndef QUARTUS
    logic [9:0] linebuf [0:1][0:SCREEN_H-1][0:LB_W-1];
`else
    // Quartus synthesis stub — 3D arrays cannot be mapped to M10K.
    // Sprite line buffer output is stubbed to zero for synthesis gate target.
    logic [9:0] linebuf_stub;
`endif

    // linebuf_bank: currently DISPLAYED bank (scanner writes to ~linebuf_bank)
    logic linebuf_bank;

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) linebuf_bank <= 1'b0;
        else if (vblank_rise) linebuf_bank <= ~linebuf_bank;

    // ── HBlank clear sweep ────────────────────────────────────────────────────
    logic        hblank_r;
    wire         hblank_rise = hblank & ~hblank_r;

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) hblank_r <= 1'b0;
        else        hblank_r <= hblank;

    logic       clearing;
    logic [8:0] clear_x;
    logic [7:0] clear_y;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clearing <= 1'b0;
            clear_x  <= 9'd0;
            clear_y  <= 8'd0;
        end else begin
            if (hblank_rise && !vblank) begin
                clearing <= 1'b1;
                clear_x  <= 9'd0;
                clear_y  <= vpos;
            end else if (clearing) begin
                if (clear_x == 9'(LB_W - 1))
                    clearing <= 1'b0;
                else
                    clear_x <= clear_x + 9'd1;
            end
        end
    end

    // ── Pixel nibble extraction helper ────────────────────────────────────────
    // Pixel p (0..15) within a tile row stored in gfx_w[0..3]:
    //   word  = p >> 2   (which of the 4 words)
    //   nibble= p & 3    (which nibble within word: 0=hi, 1=next, ...)
    // With flipx: effective pixel = 15 - p
    function automatic [3:0] nibble_of(
        input [15:0] w0, w1, w2, w3,
        input [3:0]  pix,
        input        flipx
    );
        logic [3:0]  pe;
        logic [15:0] wsel;
        pe = flipx ? (4'd15 - pix) : pix;
        case (pe[3:2])
            2'd0: wsel = w0;
            2'd1: wsel = w1;
            2'd2: wsel = w2;
            2'd3: wsel = w3;
            default: wsel = 16'd0;
        endcase
        case (pe[1:0])
            2'd0: nibble_of = wsel[15:12];
            2'd1: nibble_of = wsel[11:8];
            2'd2: nibble_of = wsel[7:4];
            2'd3: nibble_of = wsel[3:0];
            default: nibble_of = 4'd0;
        endcase
    endfunction

    // ── Line buffer write: single always_ff, arbitrates clear vs sprite ───────
    // Priority: clear wins over sprite write (clear is a maintenance operation).
    // During VBlank the scanner writes; the clear sweep runs during active display
    // hblank periods.  They should not overlap in normal operation, but the
    // clear-wins policy is safe if they do.

    // Compute 16 sprite pixel write signals combinationally
    logic [8:0]  pix_x_arr  [0:15];  // screen X per pixel
    logic [3:0]  pix_nib    [0:15];  // 4-bit nibble per pixel
    logic        pix_en     [0:15];  // write enable per pixel

    genvar p;
    generate
        for (p = 0; p < 16; p++) begin : gen_pix_en
            always_comb begin
                pix_x_arr[p] = wr_sx + 9'(p);
                pix_nib[p]   = nibble_of(gfx_w[0], gfx_w[1], gfx_w[2], gfx_w[3],
                                          4'(p), spr_flipx);
                pix_en[p]    = do_write
                               && (pix_nib[p] != 4'd0)
                               && (wr_y < 8'(SCREEN_H))
                               && (pix_x_arr[p] < 9'(SCREEN_W));
            end
        end
    endgenerate

    // Single always_ff for all linebuf writes
`ifndef QUARTUS
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset: no explicit clear (RAM initial don't-care; HBlank will clear)
        end else begin
            // HBlank clear sweep (priority)
            if (clearing)
                linebuf[~linebuf_bank][clear_y][clear_x] <= 10'd0;

            // Sprite pixel writes (16 pixels per row, unrolled)
            for (int q = 0; q < 16; q++) begin
                if (pix_en[q])
                    linebuf[~linebuf_bank][wr_y][pix_x_arr[q]] <= {1'b1, spr_color, pix_nib[q]};
            end
        end
    end
`else
    // Quartus stub — linebuf writes suppressed; line buffer is stubbed to zero.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) linebuf_stub <= 10'd0;
    end
`endif

    // ── Active display pixel output ───────────────────────────────────────────
`ifndef QUARTUS
    always_comb begin
        logic [9:0] entry;
        entry         = linebuf[linebuf_bank][vpos][hpos];
        pix_valid     = entry[9] & ~hblank & ~vblank;
        pix_color     = entry[8:4];      // 5-bit palette selector
        pix_pal_index = entry[8:0];      // full 9-bit index = {color[4:0], pen[3:0]}
        pix_x         = hpos;
    end
`else
    // Quartus stub — linebuf read returns zero.
    always_comb begin
        logic [9:0] entry;
        entry         = 10'b0;
        pix_valid     = entry[9] & ~hblank & ~vblank;
        pix_color     = entry[8:4];
        pix_pal_index = entry[8:0];
        pix_x         = hpos;
    end
`endif

    // =========================================================================
    // FSM sequential logic
    // =========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm_state    <= ST_IDLE;
            scan_idx     <= 9'd0;
            spr_tile     <= 14'd0;
            spr_flipx    <= 1'b0;
            spr_flipy    <= 1'b0;
            spr_color    <= 5'd0;
            spr_sx       <= 9'd0;
            spr_ytop     <= 8'd0;
            char_latch   <= 16'd0;
            row_cnt      <= 4'd0;
            gfx_req_r    <= 1'b0;
            gfx_addr     <= 18'd0;
            gfx_w[0]     <= 16'd0;
            gfx_w[1]     <= 16'd0;
            gfx_w[2]     <= 16'd0;
            gfx_w[3]     <= 16'd0;
            do_write     <= 1'b0;
            wr_y         <= 8'd0;
            wr_sx        <= 9'd0;
            fsm_cram_rd_addr <= 13'd0;
        end else begin
            do_write <= 1'b0;    // default: no write pulse

            case (fsm_state)

                ST_IDLE: begin
                    if (vblank_rise) begin
                        scan_idx         <= 9'(SPRITE_LIMIT);
                        fsm_cram_rd_addr <= bank_base + 13'(SPRITE_LIMIT);
                        fsm_state        <= ST_RD_CHAR;
                    end
                end

                // BRAM 1-cycle latency: char_pointer data arrives this cycle
                ST_RD_CHAR: begin
                    char_latch       <= fsm_cram_rd_data;
                    fsm_cram_rd_addr <= xptr_base + {4'b0, scan_idx};
                    fsm_state        <= ST_RD_XPTR;
                end

                // BRAM 1-cycle latency: x_pointer data arrives this cycle
                ST_RD_XPTR: begin
                    // Decode sprite attributes
                    /* verilator lint_off UNUSEDSIGNAL */
                    begin
                        logic [15:0] cw, xw;
                        logic [9:0]  sx_10;   // extra bit for signed overflow guard
                        logic [8:0]  ytop9;   // extra bit for overflow guard

                        cw = char_latch;
                        xw = fsm_cram_rd_data;

                        spr_tile  <= cw[13:0];
                        spr_flipx <= cw[15];
                        spr_flipy <= cw[14];
                        spr_color <= xw[15:11];

                        // sx = xw[7:0] - (xw[8] ? 256 : 0)
                        // xw[8] in bit position 8 = value 256; pad to 10-bit
                        sx_10  = {2'b00, xw[7:0]} - {1'b0, xw[8], 8'b0};
                        spr_sx <= sx_10[8:0];

                        // screen_y_top = SCREEN_H - ((yraw + yoffs) & 0xFF)
                        // Sprite i's Y byte: spriteylow is a flat byte array.
                        // In our 16-bit BRAM, flat byte 2k = yram_lo[k], byte 2k+1 = yram_hi[k].
                        // So sprite i's Y = yram_lo[i>>1] if even, yram_hi[i>>1] if odd.
                        begin
                            logic [7:0] sy_byte;
`ifndef QUARTUS
                            sy_byte = scan_idx[0] ? yram_hi[scan_idx >> 1]
                                                   : yram_lo[scan_idx >> 1];
`else
                            sy_byte = 8'b0; // yram stub — synthesis gate target
`endif
                            ytop9 = 9'(SCREEN_H) - 9'(8'(sy_byte) + 8'(FG_NOFLIP_YOFFS));
                        end
                        spr_ytop <= ytop9[7:0];
                    end
                    /* verilator lint_on UNUSEDSIGNAL */
                    row_cnt   <= 4'd0;
                    fsm_state <= ST_DECODE;
                end

                // Start first row fetch
                ST_DECODE: begin
                    gfx_addr  <= rom_addr(spr_tile, row_actual, 2'd0);
                    gfx_req_r <= ~gfx_req_r;
                    fsm_state <= ST_FETCH0;
                end

                // Fetch word 0
                ST_FETCH0: begin
                    if (gfx_ack == gfx_req_r) begin
                        gfx_w[0]  <= gfx_data;
                        gfx_addr  <= rom_addr(spr_tile, row_actual, 2'd1);
                        gfx_req_r <= ~gfx_req_r;
                        fsm_state <= ST_FETCH1;
                    end
                end

                // Fetch word 1
                ST_FETCH1: begin
                    if (gfx_ack == gfx_req_r) begin
                        gfx_w[1]  <= gfx_data;
                        gfx_addr  <= rom_addr(spr_tile, row_actual, 2'd2);
                        gfx_req_r <= ~gfx_req_r;
                        fsm_state <= ST_FETCH2;
                    end
                end

                // Fetch word 2
                ST_FETCH2: begin
                    if (gfx_ack == gfx_req_r) begin
                        gfx_w[2]  <= gfx_data;
                        gfx_addr  <= rom_addr(spr_tile, row_actual, 2'd3);
                        gfx_req_r <= ~gfx_req_r;
                        fsm_state <= ST_FETCH3;
                    end
                end

                // Fetch word 3; prepare write
                ST_FETCH3: begin
                    if (gfx_ack == gfx_req_r) begin
                        gfx_w[3] <= gfx_data;
                        // Compute row screen Y and X base
                        wr_y     <= spr_ytop + {4'b0, row_cnt};
                        wr_sx    <= spr_sx + 9'(FG_NOFLIP_XOFFS);
                        do_write <= 1'b1;    // pulse write for this cycle
                        fsm_state <= ST_WRITE_ROW;
                    end
                end

                // Write pulse was issued; advance
                ST_WRITE_ROW: begin
                    fsm_state <= ST_NEXT_ROW;
                end

                ST_NEXT_ROW: begin
                    if (row_cnt == 4'd15) begin
                        // This sprite is done
                        if (scan_idx == 9'd0) begin
                            fsm_state <= ST_DONE;
                        end else begin
                            scan_idx         <= scan_idx - 9'd1;
                            fsm_cram_rd_addr <= bank_base + {4'b0, scan_idx - 9'd1};
                            fsm_state        <= ST_RD_CHAR;
                        end
                    end else begin
                        row_cnt   <= row_cnt + 4'd1;
                        // Fetch first word of next row
                        // row_actual will update combinationally once row_cnt updates
                        // But row_cnt update is registered; we compute next row_actual inline:
                        begin
                            logic [3:0] next_row;
                            next_row  = row_cnt + 4'd1;
                            gfx_addr  <= rom_addr(spr_tile,
                                                  spr_flipy ? (4'd15 - next_row) : next_row,
                                                  2'd0);
                        end
                        gfx_req_r <= ~gfx_req_r;
                        fsm_state <= ST_FETCH0;
                    end
                end

                ST_DONE: begin
                    // Stay here; next vblank_rise will be caught at ST_IDLE... but
                    // ST_DONE doesn't re-enter ST_IDLE. Fix: check vblank_rise here too.
                    if (vblank_rise) begin
                        scan_idx         <= 9'(SPRITE_LIMIT);
                        fsm_cram_rd_addr <= bank_base + 13'(SPRITE_LIMIT);
                        fsm_state        <= ST_RD_CHAR;
                    end
                end

                default: fsm_state <= ST_IDLE;
            endcase
        end
    end

endmodule
