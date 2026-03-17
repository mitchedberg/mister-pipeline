`default_nettype none
// =============================================================================
// Frame-buffer submodule: 256 scanlines × 320 pixels × 13-bit.
// Lives in its own module so the simulator treats it as an opaque BRAM
// and does not constant-fold the combinational read port to zero.
// =============================================================================
/* verilator lint_off DECLFILENAME */
module tc0370mso_fbuf (
/* verilator lint_on DECLFILENAME */
    input  logic        clk,
    // Write port (scanner fills during VBlank)
    input  logic        wr_en,
    input  logic  [7:0] wr_y,
    input  logic  [8:0] wr_x,
    input  logic [12:0] wr_data,
    // Combinational read port (output stage during active display)
    input  logic  [7:0] rd_y,
    input  logic  [8:0] rd_x,
    output logic [12:0] rd_data
);
    /* verilator no_inline_module */
    logic [12:0] mem [0:255][0:319];

    always_ff @(posedge clk) begin
        if (wr_en)
            mem[wr_y][wr_x] <= wr_data;
    end

    assign rd_data = mem[rd_y][rd_x];
endmodule

// =============================================================================
// TC0370MSO — Taito Z Sprite Scanner + TC0300FLA Line Buffer
// =============================================================================
// Step 1: Sprite RAM (0x2000 × 16-bit) + CPU interface.
// Step 2: VBlank entry scanner + spritemap (STYM) ROM fetch FSM.
// Step 3: Line buffer (double-buffered, 320 × 13-bit) + back-to-front writes.
// Step 4: Zoom pixel renderer — maps 16 source pixels into zx output pixels.
// Step 5: Scanline output stage — reads line buffer during active display.
// Step 6: SDRAM bandwidth optimisation — off-screen Y skip + OBJ row cache.
//
// Sprite entry layout (4 words):
//   Word +0: [15:9]=ZoomY raw, [8:0]=Y raw
//   Word +1: [15]=Priority, [14:7]=Color bank, [5:0]=ZoomX raw
//   Word +2: [15]=FlipY, [14]=FlipX, [8:0]=X raw
//   Word +3: [12:0]=TileNum (0=skip)
//
// Scan order: back-to-front (last entry first, entry 0 = highest priority)
// Line buffer: transparent sentinel = palette_index == 0
//
// MAME source: src/mame/taito/taito_z_v.cpp bshark_draw_sprites_16x8
// =============================================================================

module tc0370mso (
    input  logic        clk,
    input  logic        rst_n,

    // ── Sprite RAM CPU interface ─────────────────────────────────────────────
    input  logic        spr_cs,
    input  logic        spr_we,
    input  logic [12:0] spr_addr,
    input  logic [15:0] spr_din,
    output logic [15:0] spr_dout,
    input  logic  [1:0] spr_be,
    output logic        spr_dtack_n,

    // ── Spritemap ROM (STYM) SDRAM port ─────────────────────────────────────
    output logic [17:0] stym_addr,
    input  logic [15:0] stym_data,
    output logic        stym_req,
    input  logic        stym_ack,

    // ── OBJ GFX ROM SDRAM port ───────────────────────────────────────────────
    output logic [22:0] obj_addr,
    input  logic [63:0] obj_data,
    output logic        obj_req,
    input  logic        obj_ack,

    // ── Video timing ─────────────────────────────────────────────────────────
    input  logic        vblank,
    input  logic        hblank,
    input  logic  [8:0] hpos,
    input  logic  [7:0] vpos,

    // ── Game-specific parameters ─────────────────────────────────────────────
    input  logic signed [3:0] y_offs,
    input  logic        frame_sel,

    // ── Pixel output ─────────────────────────────────────────────────────────
    output logic [11:0] pix_out,
    output logic        pix_valid,
    output logic        pix_priority,

    // ── Screen flip ──────────────────────────────────────────────────────────
    input  logic        flip_screen
);

// =============================================================================
// Video timing constants
// =============================================================================
localparam int H_END   = 320;
localparam int V_START = 16;
localparam int V_END   = 256;

// =============================================================================
// Step 1 — Sprite RAM (0x2000 × 16-bit dual-port)
// =============================================================================

logic [15:0] spr_ram [0:8191];

// CPU write port, byte-enable, 1-cycle DTACK
always_ff @(posedge clk) begin
    spr_dtack_n <= 1'b0;
    if (spr_cs && spr_we) begin
        if (spr_be[1]) spr_ram[spr_addr][15:8] <= spr_din[15:8];
        if (spr_be[0]) spr_ram[spr_addr][ 7:0] <= spr_din[ 7:0];
    end
end

always_ff @(posedge clk) begin
    if (spr_cs && !spr_we)
        spr_dout <= spr_ram[spr_addr];
end

// Scanner read port (combinational; FSM latches result one state later)
logic [12:0] scan_rd_addr;
wire  [15:0] scan_rd_data = spr_ram[scan_rd_addr];

// =============================================================================
// VBlank edge detect
// =============================================================================
logic vblank_d;
wire  vblank_rise = vblank && !vblank_d;

// =============================================================================
// Step 3 — Frame buffer (256 scanlines × 320 pixels × 13-bit)
// =============================================================================
// {priority[12], palette_index[11:0]}; palette_index==0 = transparent
//
// Implemented as a submodule so the simulator treats it as an opaque BRAM
// and preserves data flow from write to read.

// Unified write port: driven by FSM (pixel writes) and clear sub-machine
logic  [7:0] lb_wr_y;
logic  [8:0] lb_wr_x;
logic [12:0] lb_wr_data;
logic        lb_wr_en;

// Output read address: driven combinationally by output stage
logic  [7:0]  out_rd_y;
logic  [8:0]  out_rd_x;
logic [12:0]  out_rd_data;

tc0370mso_fbuf u_fbuf (
    .clk     (clk),
    .wr_en   (lb_wr_en),
    .wr_y    (lb_wr_y),
    .wr_x    (lb_wr_x),
    .wr_data (lb_wr_data),
    .rd_y    (out_rd_y),
    .rd_x    (out_rd_x),
    .rd_data (out_rd_data)
);

// =============================================================================
// Step 6 — OBJ tile row cache (4-entry round-robin)
// =============================================================================
localparam int CACHE_DEPTH = 4;

logic        cache_valid [0:CACHE_DEPTH-1];
logic [15:0] cache_tcode [0:CACHE_DEPTH-1];
logic  [2:0] cache_row   [0:CACHE_DEPTH-1];
logic [63:0] cache_data  [0:CACHE_DEPTH-1];
logic  [1:0] cache_lru;

// =============================================================================
// 4bpp pixel extraction from 64-bit tile row
// =============================================================================
// section1 §4: plane0=[15:0], plane1=[31:16], plane2=[47:32], plane3=[63:48]
// pixel x=0 at bit 0 (LSB), x=15 at bit 15.

function automatic logic [3:0] extract_4bpp(
    input logic [63:0] row_data,
    input logic  [3:0] src_x
);
    /* verilator lint_off WIDTHEXPAND */
    logic p0, p1, p2, p3;
    p0 = row_data[ 0 + {2'b00, src_x}];
    p1 = row_data[16 + {2'b00, src_x}];
    p2 = row_data[32 + {2'b00, src_x}];
    p3 = row_data[48 + {2'b00, src_x}];
    /* verilator lint_on WIDTHEXPAND */
    return {p3, p2, p1, p0};
endfunction

// =============================================================================
// Chunk screen geometry helpers
// =============================================================================
// curx = x + ((k * zoomx_eff) / 4)    k=0..3, zoomx_eff=1..64
// cury = y + ((j * zoomy_eff) / 8)    j=0..7, zoomy_eff=1..64
// zx   = (x + (((k+1)*zoomx_eff)/4)) - curx
// zy   = (y + (((j+1)*zoomy_eff)/8)) - cury

function automatic logic signed [9:0] chunk_curx_fn(
    input logic signed [9:0] x,
    input logic  [1:0] k,
    input logic  [6:0] zx_eff
);
    // k * zx_eff: max 3*64=192 → 8 bits. Use explicit 8-bit multiply to avoid width mismatch.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [7:0] prod8;
    /* verilator lint_on UNUSEDSIGNAL */
    prod8 = 8'(8'({1'b0, k}) * 8'({1'b0, zx_eff}));
    // /4 = prod8[7:2]; extend to 6 bits unsigned then sign-extend to 10-bit signed
    return 10'($signed(x) + $signed({4'b0000, prod8[7:2]}));
endfunction

function automatic logic signed [9:0] chunk_cury_fn(
    input logic signed [9:0] y,
    input logic  [2:0] j,
    input logic  [6:0] zy_eff
);
    // j * zy_eff: max 7*64=448 → 9 bits.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [9:0] prod10_y;
    /* verilator lint_on UNUSEDSIGNAL */
    prod10_y = 10'(10'({1'b0, j}) * 10'({3'b000, zy_eff}));
    // /8 = prod10_y[9:3]; extend to 7 bits unsigned then sign-extend
    return 10'($signed(y) + $signed({3'b000, prod10_y[9:3]}));
endfunction

function automatic logic [5:0] chunk_zx_fn(
    input logic signed [9:0] x,
    input logic  [1:0] k,
    input logic  [6:0] zx_eff
);
    // k*zx_eff and (k+1)*zx_eff: max 4*64=256 → 9 bits.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [8:0] p0_9, p1_9;
    /* verilator lint_on UNUSEDSIGNAL */
    logic signed [9:0] c0, c1;
    p0_9 = 9'(9'({1'b0, k}) * 9'({2'b00, zx_eff}));
    p1_9 = 9'((9'({1'b0, k}) + 9'd1) * 9'({2'b00, zx_eff}));
    c0   = 10'($signed(x) + $signed({4'b0000, p0_9[8:2]}));
    c1   = 10'($signed(x) + $signed({4'b0000, p1_9[8:2]}));
    return 6'(c1 - c0);
endfunction

function automatic logic [5:0] chunk_zy_fn(
    input logic signed [9:0] y,
    input logic  [2:0] j,
    input logic  [6:0] zy_eff
);
    // j*zy_eff and (j+1)*zy_eff: max 8*64=512 → 10 bits.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [9:0] p0_10, p1_10;
    /* verilator lint_on UNUSEDSIGNAL */
    logic signed [10:0] c0, c1;
    p0_10 = 10'(10'({1'b0, j}) * 10'({3'b000, zy_eff}));
    p1_10 = 10'((10'({1'b0, j}) + 10'd1) * 10'({3'b000, zy_eff}));
    c0    = 11'($signed({1'b0, y}) + $signed({4'b0000, p0_10[9:3]}));
    c1    = 11'($signed({1'b0, y}) + $signed({4'b0000, p1_10[9:3]}));
    return 6'(c1 - c0);
endfunction

// =============================================================================
// FSM state encoding
// =============================================================================

typedef enum logic [4:0] {
    ST_IDLE        = 5'd0,
    ST_LOAD_W0     = 5'd1,
    ST_LOAD_W1     = 5'd2,
    ST_LOAD_W2     = 5'd3,
    ST_LOAD_W3     = 5'd4,
    ST_DECODE      = 5'd5,
    ST_CHUNK_START = 5'd6,
    ST_STYM_REQ    = 5'd7,
    ST_STYM_WAIT   = 5'd8,
    ST_CHUNK_GEOM  = 5'd9,
    ST_ROW_START   = 5'd10,
    ST_OBJ_WAIT    = 5'd11,
    ST_CLEAR_WAIT  = 5'd12,
    ST_PIXEL_LOOP  = 5'd13,
    ST_NEXT_ROW    = 5'd14,
    ST_NEXT_CHUNK  = 5'd15,
    ST_NEXT_ENTRY  = 5'd16,
    ST_UNUSED17    = 5'd17   // keeps enum dense; never entered
} fsm_t;

fsm_t fsm;

// ── Sprite entry latches ──────────────────────────────────────────────────────
logic  [6:0] e_zoomy;
logic  [8:0] e_y;
logic        e_priority;
logic  [7:0] e_color;
logic  [5:0] e_zoomx;
logic        e_flipy;
logic        e_flipx;
logic  [8:0] e_x;

// Derived geometry (sign-extended, zoom-adjusted)
logic signed [9:0] e_xs;
logic signed [9:0] e_ys;
logic  [6:0]       e_zoomx_eff;
logic  [6:0]       e_zoomy_eff;

// ── Scan state ────────────────────────────────────────────────────────────────
logic [12:0] entry_addr;
logic [12:0] frame_base;
logic [17:0] map_offset;

// ── Chunk state ───────────────────────────────────────────────────────────────
logic  [4:0] chunk_idx;
wire   [1:0] chunk_k = chunk_idx[1:0];
wire   [2:0] chunk_j = chunk_idx[4:2];
logic [15:0] chunk_code;
logic signed [9:0] chunk_curx;
logic signed [9:0] chunk_cury;
logic  [5:0] chunk_zx;
logic  [5:0] chunk_zy;   // used for row-count bound

// ── Tile row state ────────────────────────────────────────────────────────────
logic [2:0]  tile_row;
logic [63:0] tile_row_data;

// ── Pixel loop state ─────────────────────────────────────────────────────────
logic [5:0]  px_out;    // output column index 0..zx-1

// ── Scanline cleared bitmap ───────────────────────────────────────────────────
logic [255:0] scanline_cleared;

// ── Clear sub-machine ─────────────────────────────────────────────────────────
logic        clr_running;     // clear sub-machine active
logic  [8:0] clr_ctr;         // clear counter 0..319
logic  [7:0] clr_target_vpos; // vpos being cleared

// ── SDRAM request toggles ─────────────────────────────────────────────────────
logic stym_req_r;
logic obj_req_r;
assign stym_req = stym_req_r;
assign obj_req  = obj_req_r;

// =============================================================================
// Helper: get the row's screen Y from current chunk state
// =============================================================================
function automatic logic signed [9:0] row_screen_y(
    input logic signed [9:0] cury,
    input logic  [2:0] row
);
    return 10'($signed(cury) + $signed({7'd0, row}));
endfunction

// =============================================================================
// Helper: get OBJ ROM byte address for a chunk row
// =============================================================================
// byte_addr = code * 64 + src_row * 8
// code[15:0] << 6 = 22 bits; src_row * 8 (6 bits) → 23 bits max.
function automatic logic [22:0] obj_row_addr(
    input logic [15:0] code,
    input logic        flipy,
    input logic  [2:0] tr
);
    logic [2:0]  src_row;
    logic [22:0] base;
    logic [22:0] off;
    src_row = flipy ? (3'd7 - tr) : tr;
    base    = {1'b0, code, 6'd0};     // code * 64
    off     = {17'd0, src_row, 3'd0}; // src_row * 8, padded to 23 bits
    return base + off;
endfunction

// =============================================================================
// Main FSM (Steps 2–6)
// =============================================================================

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        fsm              <= ST_IDLE;
        vblank_d         <= 1'b0;
        entry_addr       <= 13'd0;
        frame_base       <= 13'd0;
        map_offset       <= 18'd0;
        stym_req_r       <= 1'b0;
        obj_req_r        <= 1'b0;
        scan_rd_addr     <= 13'd0;
        e_zoomy          <= 7'd0;
        e_y              <= 9'd0;
        e_priority       <= 1'b0;
        e_color          <= 8'd0;
        e_zoomx          <= 6'd0;
        e_flipy          <= 1'b0;
        e_flipx          <= 1'b0;
        e_x              <= 9'd0;
        e_xs             <= 10'sd0;
        e_ys             <= 10'sd0;
        e_zoomx_eff      <= 7'd0;
        e_zoomy_eff      <= 7'd0;
        chunk_idx        <= 5'd0;
        chunk_code       <= 16'd0;
        chunk_curx       <= 10'sd0;
        chunk_cury       <= 10'sd0;
        chunk_zx         <= 6'd0;
        chunk_zy         <= 6'd0;
        tile_row         <= 3'd0;
        tile_row_data    <= 64'd0;
        px_out           <= 6'd0;
        lb_wr_en         <= 1'b0;
        lb_wr_y          <= 8'd0;
        lb_wr_x          <= 9'd0;
        lb_wr_data       <= 13'd0;
        clr_running      <= 1'b0;
        clr_ctr          <= 9'd0;
        clr_target_vpos  <= 8'd0;
        scanline_cleared <= 256'd0;
        for (int i = 0; i < CACHE_DEPTH; i++) begin
            cache_valid[i] <= 1'b0;
            cache_tcode[i] <= 16'd0;
            cache_row[i]   <= 3'd0;
            cache_data[i]  <= 64'd0;
        end
        cache_lru   <= 2'd0;
        stym_addr   <= 18'd0;
        obj_addr    <= 23'd0;
    end else begin
        // ── Sample VBlank ─────────────────────────────────────────────────
        vblank_d <= vblank;

        // ── Default: de-assert unified write enable ───────────────────────
        lb_wr_en <= 1'b0;

        // ── Concurrent clear sub-machine ──────────────────────────────────
        // Clears one pixel per cycle into the write buffer.
        // Uses lb_wr_en/lb_wr_x/lb_wr_data shared port.
        // Note: If FSM also asserts lb_wr_en in the same cycle (pixel write),
        // the clear takes precedence (last NBA wins if both in same block — but
        // since only one will run, the clear sub-machine guards against overlap
        // by only running when the FSM is not in ST_PIXEL_LOOP state).
        if (clr_running && fsm != ST_PIXEL_LOOP) begin
            lb_wr_en   <= 1'b1;
            lb_wr_y    <= clr_target_vpos;
            lb_wr_x    <= clr_ctr[8:0];
            lb_wr_data <= 13'd0;
            if (clr_ctr == 9'd319) begin
                clr_running                        <= 1'b0;
                scanline_cleared[clr_target_vpos]  <= 1'b1;
            end else begin
                clr_ctr <= clr_ctr + 9'd1;
            end
        end

        // ── Main FSM ──────────────────────────────────────────────────────
        case (fsm)

            // ── ST_IDLE: wait for VBlank rising edge ─────────────────────
            ST_IDLE: begin
                if (vblank_rise) begin
                    scanline_cleared <= 256'd0;
                    for (int i = 0; i < CACHE_DEPTH; i++)
                        cache_valid[i] <= 1'b0;
                    cache_lru  <= 2'd0;
                    frame_base <= frame_sel ? 13'h0800 : 13'h0000;
                    entry_addr <= frame_sel ? 13'h0FFC : 13'h07FC;
                    fsm        <= ST_LOAD_W0;
                end
            end

            // ── ST_LOAD_W0: set scanner addr for word 0 ──────────────────
            ST_LOAD_W0: begin
                scan_rd_addr <= entry_addr;
                fsm <= ST_LOAD_W1;
            end

            // ── ST_LOAD_W1: latch word 0; addr → word 1 ──────────────────
            ST_LOAD_W1: begin
                e_zoomy      <= scan_rd_data[15:9];
                e_y          <= scan_rd_data[8:0];
                scan_rd_addr <= entry_addr + 13'd1;
                fsm <= ST_LOAD_W2;
            end

            // ── ST_LOAD_W2: latch word 1; addr → word 2 ──────────────────
            ST_LOAD_W2: begin
                e_priority   <= scan_rd_data[15];
                e_color      <= scan_rd_data[14:7];
                e_zoomx      <= scan_rd_data[5:0];
                scan_rd_addr <= entry_addr + 13'd2;
                fsm <= ST_LOAD_W3;
            end

            // ── ST_LOAD_W3: latch word 2; addr → word 3 ──────────────────
            ST_LOAD_W3: begin
                e_flipy      <= scan_rd_data[15];
                e_flipx      <= scan_rd_data[14];
                e_x          <= scan_rd_data[8:0];
                scan_rd_addr <= entry_addr + 13'd3;
                fsm <= ST_DECODE;
            end

            // ── ST_DECODE: latch word 3, compute geometry ─────────────────
            ST_DECODE: begin
                if (scan_rd_data[12:0] == 13'd0) begin
                    fsm <= ST_NEXT_ENTRY;
                end else begin
                    begin
                        logic  [6:0] zx_eff, zy_eff;
                        logic signed [9:0] raw_x, raw_y, y_adj;
                        // zoom effective = raw + 1, max = 64 (7 bits)
                        zx_eff = 7'({1'b0, e_zoomx}) + 7'd1;
                        zy_eff = 7'({1'b0, e_zoomy}) + 7'd1;
                        raw_x  = $signed({1'b0, e_x});
                        raw_y  = $signed({1'b0, e_y});
                        // sign extend if > 0x140
                        if (e_x > 9'h140) raw_x = raw_x - 10'sh200;
                        if (e_y > 9'h140) raw_y = raw_y - 10'sh200;
                        // y += y_offs + (64 - zoomy_eff)
                        y_adj = raw_y
                                + $signed({{6{y_offs[3]}}, y_offs})
                                + $signed(10'(7'd64 - zy_eff));
                        e_xs        <= raw_x;
                        e_ys        <= y_adj;
                        e_zoomx_eff <= zx_eff;
                        e_zoomy_eff <= zy_eff;
                    end
                    map_offset <= 18'({5'd0, scan_rd_data[12:0]} << 5);
                    fsm <= ST_CHUNK_START;
                end
            end

            // ── ST_CHUNK_START: init chunk counter ────────────────────────
            ST_CHUNK_START: begin
                chunk_idx <= 5'd0;
                fsm <= ST_STYM_REQ;
            end

            // ── ST_STYM_REQ: compute spritemap addr; issue request ────────
            ST_STYM_REQ: begin
                begin
                    logic [1:0] cur_px;
                    logic [2:0] cur_py;
                    logic [5:0] chunk_off;
                    cur_px    = e_flipx ? (2'd3 - chunk_k) : chunk_k;
                    cur_py    = e_flipy ? (3'd7 - chunk_j) : chunk_j;
                    chunk_off = 6'({1'b0, cur_py, cur_px[1:0]});  // py*4 + px = {py,px} (5 bits → 6)
                    stym_addr    <= 18'(map_offset + {12'd0, chunk_off});
                    stym_req_r   <= ~stym_req_r;
                end
                fsm <= ST_STYM_WAIT;
            end

            // ── ST_STYM_WAIT: wait for STYM ack ──────────────────────────
            ST_STYM_WAIT: begin
                if (stym_ack == stym_req_r) begin
                    chunk_code <= stym_data;
                    if (stym_data == 16'hFFFF)
                        fsm <= ST_NEXT_CHUNK;
                    else
                        fsm <= ST_CHUNK_GEOM;
                end
            end

            // ── ST_CHUNK_GEOM: compute per-chunk geometry ─────────────────
            ST_CHUNK_GEOM: begin
                chunk_curx <= chunk_curx_fn(e_xs, chunk_k, e_zoomx_eff);
                chunk_cury <= chunk_cury_fn(e_ys, chunk_j, e_zoomy_eff);
                chunk_zx   <= chunk_zx_fn(e_xs, chunk_k, e_zoomx_eff);
                chunk_zy   <= chunk_zy_fn(e_ys, chunk_j, e_zoomy_eff);
                tile_row   <= 3'd0;
                fsm <= ST_ROW_START;
            end

            // ── ST_ROW_START: check on-screen, cache lookup, OBJ fetch ───
            ST_ROW_START: begin
                begin
                    logic [7:0] sy8;
                    logic  [2:0] src_row;
                    logic signed [9:0] sy_full;
                    sy_full = row_screen_y(chunk_cury, tile_row);
                    sy8     = sy_full[7:0];
                    src_row = e_flipy ? (3'd7 - tile_row) : tile_row;

                    // Step 6: skip rows off-screen in Y
                    if ($signed(sy_full) < 10'sd0 || $signed(sy_full) >= 10'sd256) begin
                        fsm <= ST_NEXT_ROW;
                    end else begin
                        // Cache lookup
                        begin
                            logic       hit;
                            logic [63:0] hit_data;
                            hit      = 1'b0;
                            hit_data = 64'd0;
                            for (int ci = 0; ci < CACHE_DEPTH; ci++) begin
                                if (cache_valid[ci] &&
                                    cache_tcode[ci] == chunk_code &&
                                    cache_row[ci]   == src_row) begin
                                    hit      = 1'b1;
                                    hit_data = cache_data[ci];
                                end
                            end

                            if (hit) begin
                                tile_row_data <= hit_data;
                                // Ensure scanline is cleared
                                if (!scanline_cleared[sy8]) begin
                                    if (!clr_running) begin
                                        clr_target_vpos <= sy8;
                                        clr_running     <= 1'b1;
                                        clr_ctr         <= 9'd0;
                                    end
                                    fsm <= ST_CLEAR_WAIT;
                                end else begin
                                    px_out <= 6'd0;
                                    fsm    <= ST_PIXEL_LOOP;
                                end
                            end else begin
                                // Issue OBJ ROM fetch
                                obj_addr  <= obj_row_addr(chunk_code, e_flipy, tile_row);
                                obj_req_r <= ~obj_req_r;
                                fsm <= ST_OBJ_WAIT;
                            end
                        end
                    end
                end
            end

            // ── ST_OBJ_WAIT: wait for OBJ ROM ack ────────────────────────
            ST_OBJ_WAIT: begin
                if (obj_ack == obj_req_r) begin
                    tile_row_data <= obj_data;
                    // Update cache
                    begin
                        logic [2:0] src_row;
                        src_row = e_flipy ? (3'd7 - tile_row) : tile_row;
                        cache_valid[cache_lru] <= 1'b1;
                        cache_tcode[cache_lru] <= chunk_code;
                        cache_row[cache_lru]   <= src_row;
                        cache_data[cache_lru]  <= obj_data;
                        cache_lru              <= cache_lru + 2'd1;
                    end
                    // Ensure scanline is cleared
                    begin
                        logic [7:0] sy8_obj;
                        /* verilator lint_off UNUSEDSIGNAL */
                        logic signed [9:0] sy_obj;
                        /* verilator lint_on UNUSEDSIGNAL */
                        sy_obj  = row_screen_y(chunk_cury, tile_row);
                        sy8_obj = sy_obj[7:0];
                        if (!scanline_cleared[sy8_obj]) begin
                            if (!clr_running) begin
                                clr_target_vpos <= sy8_obj;
                                clr_running     <= 1'b1;
                                clr_ctr         <= 9'd0;
                            end
                            fsm <= ST_CLEAR_WAIT;
                        end else begin
                            px_out <= 6'd0;
                            fsm    <= ST_PIXEL_LOOP;
                        end
                    end
                end
            end

            // ── ST_CLEAR_WAIT: wait for scanline clear to finish ──────────
            ST_CLEAR_WAIT: begin
                begin
                    logic [7:0] sy8_clw;
                    /* verilator lint_off UNUSEDSIGNAL */
                    logic signed [9:0] sy_clw;
                    /* verilator lint_on UNUSEDSIGNAL */
                    sy_clw  = row_screen_y(chunk_cury, tile_row);
                    sy8_clw = sy_clw[7:0];
                    if (scanline_cleared[sy8_clw]) begin
                        px_out <= 6'd0;
                        fsm    <= ST_PIXEL_LOOP;
                    end
                end
            end

            // ── ST_PIXEL_LOOP: render one zoomed pixel per cycle ──────────
            // For each output column ox ∈ [0..zx-1]:
            //   src_x = (ox * 16) / zx  (zoom scaling, integer floor)
            //   actual_src_x = flipx ? (15 - src_x) : src_x
            //   pixel = extract_4bpp(tile_row_data, actual_src_x)
            //   screen_x = chunk_curx + ox
            ST_PIXEL_LOOP: begin
                begin
                    logic [10:0] ox16;       // ox * 16 (max 63*16=1008, 10 bits)
                    logic  [3:0] src_x_raw;  // (ox * 16) / zx → 0..15
                    logic  [3:0] src_x_flip;
                    logic  [3:0] pix;
                    logic signed [10:0] sx;
                    /* verilator lint_off UNUSEDSIGNAL */
                    logic [10:0] div_q;
                    /* verilator lint_on UNUSEDSIGNAL */

                    ox16  = 11'({5'd0, px_out} * 6'd16);
                    // Division by chunk_zx (1..64).
                    if (chunk_zx == 6'd0) begin
                        div_q     = 11'd0;
                        src_x_raw = 4'd0;
                    end else begin
                        div_q     = ox16 / {5'd0, chunk_zx};
                        src_x_raw = div_q[3:0];
                    end

                    src_x_flip = e_flipx ? (4'd15 - src_x_raw) : src_x_raw;
                    pix        = extract_4bpp(tile_row_data, src_x_flip);

                    // screen_x = chunk_curx + px_out
                    // screen_y = row_screen_y(chunk_cury, tile_row) — computed once
                    sx = $signed({chunk_curx[9], chunk_curx}) + $signed({5'b0, px_out});

                    if (pix != 4'd0 && sx >= 11'sd0 && sx < 11'sd320) begin
                        lb_wr_y    <= row_screen_y(chunk_cury, tile_row)[7:0];
                        lb_wr_x    <= sx[8:0];
                        lb_wr_data <= {e_priority, e_color, pix};
                        lb_wr_en   <= 1'b1;
                    end
                end

                // Advance pixel counter or finish row
                if (chunk_zx == 6'd0 || (px_out + 6'd1 >= chunk_zx)) begin
                    fsm <= ST_NEXT_ROW;
                end else begin
                    px_out <= px_out + 6'd1;
                end
            end

            // ── ST_NEXT_ROW: advance tile row or finish chunk ─────────────
            ST_NEXT_ROW: begin
                if (tile_row == 3'd7) begin
                    fsm <= ST_NEXT_CHUNK;
                end else begin
                    tile_row <= tile_row + 3'd1;
                    fsm <= ST_ROW_START;
                end
            end

            // ── ST_NEXT_CHUNK: advance chunk or finish entry ──────────────
            ST_NEXT_CHUNK: begin
                if (chunk_idx == 5'd31)
                    fsm <= ST_NEXT_ENTRY;
                else begin
                    chunk_idx <= chunk_idx + 5'd1;
                    fsm <= ST_STYM_REQ;
                end
            end

            // ── ST_NEXT_ENTRY: step back to previous entry (back-to-front)
            ST_NEXT_ENTRY: begin
                if (entry_addr <= frame_base)
                    fsm <= ST_IDLE;
                else begin
                    entry_addr <= entry_addr - 13'd4;
                    fsm <= ST_LOAD_W0;
                end
            end

            default: fsm <= ST_IDLE;
        endcase
    end
end

// =============================================================================
// Step 5 — Scanline output during active display
// =============================================================================
// out_rd_x/out_rd_y are updated combinationally; out_rd_data reads the line
// buffer combinationally so pixel data is available immediately.
// pix_* outputs are driven combinationally from out_rd_data.
// This avoids a simulation scheduling issue: fbuf rd_data is a combinational
// output of a sub-module; reading it inside always_ff can cause the logic
// to be optimized away. Combinational output reads rd_data correctly after
// the sub-module's NBA phase updates out_rd_data.

always_comb begin
    /* verilator lint_off UNSIGNED */
    if (!hblank && !vblank
                && vpos >= 8'(V_START)
                && vpos < 8'(V_END)
                && hpos < 9'(H_END)) begin
    /* verilator lint_on UNSIGNED */
        out_rd_y = vpos;
        out_rd_x = hpos[8:0];
    end else begin
        out_rd_y = 8'd0;
        out_rd_x = 9'd0;
    end
end

always_comb begin
    /* verilator lint_off UNSIGNED */
    if (!rst_n) begin
        pix_out      = 12'd0;
        pix_valid    = 1'b0;
        pix_priority = 1'b0;
    end else if (!hblank && !vblank
                         && vpos >= 8'(V_START)
                         && vpos < 8'(V_END)
                         && hpos < 9'(H_END)) begin
    /* verilator lint_on UNSIGNED */
        pix_priority = out_rd_data[12];
        pix_out      = out_rd_data[11:0];
        pix_valid    = (out_rd_data[11:0] != 12'd0);
    end else begin
        pix_valid    = 1'b0;
        pix_out      = 12'd0;
        pix_priority = 1'b0;
    end
end

// =============================================================================
// Suppress unused warnings
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused;
assign _unused = ^{flip_screen, chunk_zy};
/* verilator lint_on UNUSED */

endmodule
