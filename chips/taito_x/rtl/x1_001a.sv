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
    // Y offset for FG sprites in no-flip mode (Superman = -0x12 = -18, Gigandes = -0x0a = -10)
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
    logic [7:0] yram_lo [0:511];
    logic [7:0] yram_hi [0:511];

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

    typedef enum logic [4:0] {
        ST_IDLE      = 5'd0,
        // ── BG scan states (run before FG, so FG overwrites) ──
        ST_BG_INIT   = 5'd16,  // initialize BG column/row counters
        ST_BG_RD_TILE= 5'd17,  // issue CRAM read for BG tile code; wait 1 cycle
        ST_BG_RD_CLR = 5'd18,  // tile arrives; issue CRAM read for BG color; wait 1 cycle
        ST_BG_DECODE = 5'd19,  // color arrives; decode tile attributes
        ST_BG_FETCH0 = 5'd20,  // fetch GFX ROM word 0 for BG tile row
        ST_BG_FETCH1 = 5'd21,
        ST_BG_FETCH2 = 5'd22,
        ST_BG_FETCH3 = 5'd23,
        ST_BG_WRITE  = 5'd24,  // write 16 BG pixels to line buffer
        ST_BG_NEXT   = 5'd25,  // advance to next tile/column
        ST_BG_DONE   = 5'd26,  // BG scan complete → start FG scan
        // ── FG sprite scan states ──
        ST_RD_CHAR   = 5'd1,   // issued CRAM read for char_pointer; wait 1 cycle
        ST_RD_XPTR   = 5'd2,   // char arrives; issue x_pointer read; wait 1 cycle
        ST_DECODE    = 5'd3,   // x_ptr arrives; decode all attributes; prime row loop
        ST_FETCH0    = 5'd4,   // fetch GFX ROM word 0 of current row
        ST_FETCH1    = 5'd5,
        ST_FETCH2    = 5'd6,
        ST_FETCH3    = 5'd7,   // fetch word 3; trigger pixel write on ack
        ST_WRITE_ROW = 5'd8,   // pixel write pulse active this cycle
        ST_NEXT_ROW  = 5'd9,   // advance row_cnt or sprite index
        ST_DONE      = 5'd10
    } fsm_t;

    fsm_t fsm_state;

    // Edge detects
    logic vblank_r;
    wire  vblank_rise = vblank & ~vblank_r;

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) vblank_r <= 1'b0;
        else        vblank_r <= vblank;

    // Bank base addresses: latch frame_bank at vblank_rise to hold constant
    // during the entire sprite scan. Without latching, a CPU write to spritectrl[1]
    // during VBlank would corrupt the scan midway. The FBNeo reference latches
    // Ctrl2 at frame-render time (end of VBLANK), so we must do the same.
    logic frame_bank_latch;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) frame_bank_latch <= 1'b0;
        else if (vblank_rise) frame_bank_latch <= frame_bank;

    wire [12:0] bank_base = frame_bank_latch ? 13'h1000 : 13'h0000;
    // xptr_base — matches MAME x1_001.cpp draw_foreground():
    //   x_pointer = &m_spritecode[0x0200];
    //   if bank_toggle: x_pointer += bank_size (0x1000)
    //   bank=0: xptr at spritecode[0x0200]
    //   bank=1: xptr at spritecode[0x0200 + 0x1000] = spritecode[0x1200]
    wire [12:0] xptr_base = frame_bank_latch ? 13'h1200 : 13'h0200;

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

    // ── BG scan variables ──────────────────────────────────────────────────
    // BG is rendered as columns of tile pairs (2 wide × 16 tall = 32 tiles/col)
    // From FBNeo TaitoXDrawBgSprites():
    //   NumCol = spritectrl[1] & 0xF (0 means 16)
    //   Col0 from spritectrl[0] & 0xF
    //   Column X/Y from YRAM words at col*16+512
    //   Tile codes from CRAM[0x0400 + ((col+col0)&0xF)*0x20 + offs]
    //   Colors from CRAM[0x0600 + ((col+col0)&0xF)*0x20 + offs]
    logic [3:0]  bg_col;          // current column (0..NumCol-1)
    logic [4:0]  bg_offs;         // tile offset within column (0..31)
    logic [3:0]  bg_num_col;      // number of active columns
    logic [3:0]  bg_col0;         // starting column offset
    logic [7:0]  bg_col_x;        // column X position
    logic [7:0]  bg_col_y;        // column Y scroll
    logic [13:0] bg_tile;         // current tile code
    logic        bg_flipx, bg_flipy;
    logic [4:0]  bg_color;        // current tile color
    logic [8:0]  bg_sx;           // screen X for current tile
    logic [7:0]  bg_sy;           // screen Y for current tile
    logic [3:0]  bg_row;          // row within tile (0..15)
    logic [15:0] bg_upper;        // column upper bits (adds 256 to X)
    logic        bg_flip;         // screen flip from ctrl

    // BG CRAM source bank (matches FBNeo: src = SpriteRam2 + bank_offset)
    wire [12:0] bg_src_base = (spritectrl[1] ^ (~spritectrl[1] << 1)) & 16'h0040
                              ? 13'h1000 : 13'h0000;

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
    // Bank swap at VBlank FALL (end of VBlank / start of active display):
    //   During VBlank: scanner fills ~linebuf_bank (old display bank).
    //   At VBlank fall: swap → linebuf_bank = what scanner just filled.
    //   During active display: display reads linebuf_bank (scanner's output). ✓
    //   Clear erases ~linebuf_bank (old display buffer → next frame's write target). ✓
    // Swapping at VBlank RISE was wrong: it caused display to always read the
    // just-cleared buffer, and the clear to always erase the scanner's fresh output.
    logic linebuf_bank;
    // vblank_fall derived from vblank_r (already declared above for vblank_rise)
    wire  vblank_fall = ~vblank & vblank_r;

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) linebuf_bank <= 1'b0;
        else if (vblank_fall) begin
            linebuf_bank <= ~linebuf_bank;
`ifndef QUARTUS
            $display("[X1-001A] LINEBUF SWAP: vblank_fall linebuf_bank %0d->%0d", linebuf_bank, ~linebuf_bank);
`endif
        end

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
                        // Start with BG scan, then FG scan
                        bg_num_col <= (spritectrl[1][3:0] == 4'd0) ? 4'd15 : spritectrl[1][3:0] - 4'd1;
                        bg_col0    <= (spritectrl[0][3:0] == 4'h1) ? 4'h4 :
                                      (spritectrl[0][3:0] == 4'h6) ? 4'h8 : 4'h0;
                        bg_flip    <= spritectrl[0][6];
                        bg_upper   <= {spritectrl[3][7:0], spritectrl[2][7:0]};
                        bg_col     <= 4'd0;
                        bg_offs    <= 5'd0;
                        bg_row     <= 4'd0;
                        fsm_state  <= ST_BG_INIT;
`ifndef QUARTUS
                        $display("[X1-001A] SCAN START (BG+FG): vblank_rise ctrl0=0x%04x ctrl1=0x%04x bank=%0d lbk=%0d",
                                 spritectrl[0], spritectrl[1], frame_bank_latch, linebuf_bank);
`endif
                    end
                end

                // ═══════════════════════════════════════════════════════════
                // BG tilemap scan states
                // ═══════════════════════════════════════════════════════════

                ST_BG_INIT: begin
                    // Read column Y scroll from YRAM: word at col*16 + 512
`ifndef QUARTUS
                    begin
                        logic [9:0] yram_idx;
                        yram_idx = 10'(bg_col * 16 + 512);
                        bg_col_y <= yram_lo[yram_idx];
                        // Column X: word at col*16 + 516
                        bg_col_x <= yram_lo[10'(bg_col * 16 + 516)];
                    end
`else
                    bg_col_y <= 8'd0;
                    bg_col_x <= 8'd0;
`endif
                    bg_offs  <= 5'd0;
                    // Issue CRAM read for first tile code
                    fsm_cram_rd_addr <= bg_src_base + {1'b0, ((bg_col + bg_col0) & 4'hF), 5'd0} + 13'h0400;
                    fsm_state <= ST_BG_RD_TILE;
                end

                ST_BG_RD_TILE: begin
                    // Tile code arrives; latch it and issue color read
                    begin
                        logic [15:0] tw;
                        tw = fsm_cram_rd_data;
                        bg_tile  <= tw[13:0];
                        bg_flipx <= tw[15];
                        bg_flipy <= tw[14];
                    end
                    // Issue color read at cram[0x0600 + same offset]
                    fsm_cram_rd_addr <= bg_src_base + {1'b0, ((bg_col + bg_col0) & 4'hF), 5'd0} + {8'b0, bg_offs} + 13'h0600;
                    fsm_state <= ST_BG_RD_CLR;
                end

                ST_BG_RD_CLR: begin
                    // Color arrives; decode attributes and compute screen position
                    bg_color <= fsm_cram_rd_data[15:11];

                    // Screen X = col_x + (offs & 1) * 16
                    begin
                        logic [8:0] sx9;
                        sx9 = {1'b0, bg_col_x} + (bg_offs[0] ? 9'd16 : 9'd0);
                        if (bg_upper[bg_col]) sx9 = sx9 + 9'd256;
                        bg_sx <= sx9;
                    end

                    // Screen Y = -(col_y + yoffs) + (offs / 2) * 16
                    begin
                        logic [8:0] sy9;
                        sy9 = -(9'(bg_col_y) + (bg_flip ? 9'd1 : -9'd1))
                              + {4'b0, bg_offs[4:1]} * 9'd16;
                        bg_sy <= sy9[7:0];
                    end

                    bg_row    <= 4'd0;
                    fsm_state <= ST_BG_DECODE;
                end

                ST_BG_DECODE: begin
                    // Start GFX ROM fetch for row 0 of current BG tile
                    gfx_addr  <= rom_addr(bg_tile,
                                          bg_flipy ? (4'd15 - bg_row) : bg_row,
                                          2'd0);
                    gfx_req_r <= ~gfx_req_r;
                    fsm_state <= ST_BG_FETCH0;
                end

                ST_BG_FETCH0: begin
                    if (gfx_ack == gfx_req_r) begin
                        gfx_w[0]  <= gfx_data;
                        gfx_addr  <= rom_addr(bg_tile,
                                              bg_flipy ? (4'd15 - bg_row) : bg_row,
                                              2'd1);
                        gfx_req_r <= ~gfx_req_r;
                        fsm_state <= ST_BG_FETCH1;
                    end
                end

                ST_BG_FETCH1: begin
                    if (gfx_ack == gfx_req_r) begin
                        gfx_w[1]  <= gfx_data;
                        gfx_addr  <= rom_addr(bg_tile,
                                              bg_flipy ? (4'd15 - bg_row) : bg_row,
                                              2'd2);
                        gfx_req_r <= ~gfx_req_r;
                        fsm_state <= ST_BG_FETCH2;
                    end
                end

                ST_BG_FETCH2: begin
                    if (gfx_ack == gfx_req_r) begin
                        gfx_w[2]  <= gfx_data;
                        gfx_addr  <= rom_addr(bg_tile,
                                              bg_flipy ? (4'd15 - bg_row) : bg_row,
                                              2'd3);
                        gfx_req_r <= ~gfx_req_r;
                        fsm_state <= ST_BG_FETCH3;
                    end
                end

                ST_BG_FETCH3: begin
                    if (gfx_ack == gfx_req_r) begin
                        gfx_w[3] <= gfx_data;
                        // Write BG pixels using the FG write machinery
                        // Reuse spr_* latches for the pixel writer
                        spr_color <= bg_color;
                        spr_flipx <= bg_flipx;
                        wr_y      <= bg_sy + {4'b0, bg_row};
                        wr_sx     <= bg_sx;
                        do_write  <= 1'b1;
                        fsm_state <= ST_BG_WRITE;
                    end
                end

                ST_BG_WRITE: begin
                    // Write pulse was issued; advance row or tile
                    fsm_state <= ST_BG_NEXT;
                end

                ST_BG_NEXT: begin
                    if (bg_row == 4'd15) begin
                        // This tile is done; move to next tile in column
                        if (bg_offs == 5'd31) begin
                            // Column done; move to next column
                            if (bg_col >= bg_num_col) begin
                                // All columns done → start FG scan
                                fsm_state <= ST_BG_DONE;
                            end else begin
                                bg_col    <= bg_col + 4'd1;
                                fsm_state <= ST_BG_INIT;
                            end
                        end else begin
                            bg_offs <= bg_offs + 5'd1;
                            // Issue CRAM read for next tile
                            fsm_cram_rd_addr <= bg_src_base
                                              + {1'b0, ((bg_col + bg_col0) & 4'hF), 5'd0}
                                              + {8'b0, bg_offs + 5'd1}
                                              + 13'h0400;
                            fsm_state <= ST_BG_RD_TILE;
                        end
                    end else begin
                        bg_row    <= bg_row + 4'd1;
                        // Fetch next row of same tile
                        gfx_addr  <= rom_addr(bg_tile,
                                              bg_flipy ? (4'd15 - (bg_row + 4'd1)) : (bg_row + 4'd1),
                                              2'd0);
                        gfx_req_r <= ~gfx_req_r;
                        fsm_state <= ST_BG_FETCH0;
                    end
                end

                ST_BG_DONE: begin
                    // BG scan complete → start FG sprite scan
                    scan_idx         <= 9'(SPRITE_LIMIT);
                    fsm_cram_rd_addr <= bank_base + 13'(SPRITE_LIMIT);
                    fsm_state        <= ST_RD_CHAR;
`ifndef QUARTUS
                    $display("[X1-001A] BG DONE → FG START: bank_base=0x%04x xptr_base=0x%04x", bank_base, xptr_base);
`endif
                end

                // ═══════════════════════════════════════════════════════════
                // FG sprite scan states (existing)
                // ═══════════════════════════════════════════════════════════

                // BRAM 1-cycle latency: char_pointer data arrives this cycle
                ST_RD_CHAR: begin
                    char_latch       <= fsm_cram_rd_data;
                    fsm_cram_rd_addr <= xptr_base + {4'b0, scan_idx};
                    fsm_state        <= ST_RD_XPTR;
                    // DBG: trace CRAM read for first and last few sprites (disabled for perf)
`ifndef QUARTUS
                    //if (scan_idx >= 9'd509 || scan_idx <= 9'd3)
                    //    $display("[X1-001A] ST_RD_CHAR: ...", scan_idx, fsm_cram_rd_addr, fsm_cram_rd_data, bank_base);
`endif
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

`ifndef QUARTUS
                        // DBG: trace sprites with non-zero tile or xptr (first 10 per scan)
                        if (cw != 16'd0 || xw != 16'd0)
                            $display("[X1-001A] ST_RD_XPTR: idx=%0d cw=0x%04x xw=0x%04x bank=%0d", scan_idx, cw, xw, frame_bank_latch);
`endif

                        spr_tile  <= cw[13:0];
                        spr_flipx <= cw[15];
                        spr_flipy <= cw[14];
                        spr_color <= xw[15:11];

                        // sx = xw[7:0] - (xw[8] ? 256 : 0)
                        // xw[8] in bit position 8 = value 256; pad to 10-bit
                        sx_10  = {2'b00, xw[7:0]} - {1'b0, xw[8], 8'b0};
                        spr_sx <= sx_10[8:0];

                        // screen_y_top = SCREEN_H - ((yraw + yoffs) & 0xFF)
                        // MAME x1_001.cpp: spriteylow_w16 writes data[7:0] to spriteylow[offset]
                        // where offset = word_index. So sprite i's Y = low byte of word at
                        // YRAM word address i. In our RTL: yram_lo[i] = sprite i's Y.
                        // The high byte (yram_hi) is never used for sprite coordinates.
                        begin
                            logic [7:0] sy_byte;
`ifndef QUARTUS
                            sy_byte = yram_lo[scan_idx];   // sprite i's Y = yram_lo[i]
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
`ifndef QUARTUS
                        // DBG: trace first row of every sprite with non-zero GFX data
                        if (row_cnt == 4'd0 && (gfx_w[0] != 0 || gfx_w[1] != 0 || gfx_w[2] != 0 || gfx_data != 0))
                            $display("[X1-001A] WRITE_ROW0: scan_idx=%0d tile=%0d sx=%0d ytop=%0d color=%0d gfx_w0=0x%04x gfx_w1=0x%04x gfx_w2=0x%04x gfx_w3=0x%04x bank=%0d lbk=%0d", scan_idx, spr_tile, spr_sx, spr_ytop, spr_color, gfx_w[0], gfx_w[1], gfx_w[2], gfx_data, frame_bank_latch, linebuf_bank);
`endif
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
                    // Next vblank_rise restarts from BG scan
                    if (vblank_rise) begin
                        bg_num_col <= (spritectrl[1][3:0] == 4'd0) ? 4'd15 : spritectrl[1][3:0] - 4'd1;
                        bg_col0    <= (spritectrl[0][3:0] == 4'h1) ? 4'h4 :
                                      (spritectrl[0][3:0] == 4'h6) ? 4'h8 : 4'h0;
                        bg_flip    <= spritectrl[0][6];
                        bg_upper   <= {spritectrl[3][7:0], spritectrl[2][7:0]};
                        bg_col     <= 4'd0;
                        bg_offs    <= 5'd0;
                        bg_row     <= 4'd0;
                        fsm_state  <= ST_BG_INIT;
`ifndef QUARTUS
                        $display("[X1-001A] SCAN RESTART (BG+FG): ctrl0=0x%04x ctrl1=0x%04x", spritectrl[0], spritectrl[1]);
`endif
                    end
                end

                default: fsm_state <= ST_IDLE;
            endcase
        end
    end

endmodule
