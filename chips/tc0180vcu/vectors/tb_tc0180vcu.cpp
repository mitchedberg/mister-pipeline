// =============================================================================
// Gate 4: Verilator testbench for tc0180vcu.sv
//
// Reads tier1_vectors.jsonl. Each line:
//   {"op": "write"|"read", "addr": N, "data": N, "be": N,
//    "exp_dout": N, "note": "..."}
//
// Per-vector sequence:
//   write: drive cpu_cs=1, cpu_we=1, addr, data, be → tick → cpu_we=0
//   read:  drive cpu_cs=1, cpu_we=0, addr → tick → sample cpu_dout
//          (registered read: data available cycle after address presented)
//
// Additional TX render test:
//   Programs VRAM with known tile words, drives HBLANK, checks pixel output.
//   Uses a deterministic GFX ROM model: gfx_rom[addr] = (addr*37+13)^(addr>>8)
//
// BG/FG render test (step 3 — global scroll):
//   Programs BG and FG VRAM + scroll RAM, drives HBLANK, checks pixel_out.
//   BG starts after TX (321 cycles), FG starts after BG (321+224=545 cycles).
//   Total HBLANK required: 545+224 = 769 cycles (driven for 800 cycles).
// =============================================================================

#include "Vtc0180vcu.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdint.h>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// GFX ROM model: 8MB deterministic ROM
// ---------------------------------------------------------------------------
static uint8_t gfx_rom[1 << 23];

static void init_gfx_rom() {
    for (int i = 0; i < (1 << 23); i++)
        gfx_rom[i] = (uint8_t)((i * 37 + 13) ^ (i >> 8));
    // Tile code 0 (bytes 0-127) = all zeros → transparent sentinel.
    // This ensures uninitialised tile slots (tile_code=0) are transparent
    // and don't contaminate compositing tests.
    for (int i = 0; i < 128; i++)
        gfx_rom[i] = 0;
}

// ---------------------------------------------------------------------------
// Minimal JSON helpers
// ---------------------------------------------------------------------------
static size_t jfind(const std::string& s, const std::string& key) {
    std::string pat = "\"" + key + "\"";
    auto p = s.find(pat);
    if (p == std::string::npos) return std::string::npos;
    p += pat.size();
    while (p < s.size() && (s[p]==' '||s[p]==':')) ++p;
    return p;
}
static int jint(const std::string& s, const std::string& key, int dflt=0) {
    auto p = jfind(s, key);
    if (p == std::string::npos) return dflt;
    return (int)strtol(s.c_str()+p, nullptr, 0);
}
static std::string jstr(const std::string& s, const std::string& key) {
    auto p = jfind(s, key);
    if (p == std::string::npos || s[p]!='"') return "";
    ++p; auto e = s.find('"', p);
    return (e==std::string::npos) ? "" : s.substr(p, e-p);
}

// ---------------------------------------------------------------------------
struct Vec {
    bool   is_write;
    int    addr;
    int    data;
    int    be;
    int    exp_dout;
    std::string note;
};

static Vtc0180vcu* dut = nullptr;
static void tick() {
    dut->clk=0; dut->eval();
    // Combinational GFX ROM model: drive gfx_data from address before rising edge
    if (dut->gfx_rd)
        dut->gfx_data = gfx_rom[dut->gfx_addr & 0x7FFFFFu];
    else
        dut->gfx_data = 0;
    dut->clk=1; dut->eval();
}

static void reset() {
    dut->async_rst_n = 0;
    dut->cpu_cs   = 0; dut->cpu_we = 0;
    dut->cpu_addr = 0; dut->cpu_din = 0; dut->cpu_be = 0;
    dut->hblank_n = 1; dut->vblank_n = 1;
    dut->hpos = 0; dut->vpos = 0;
    dut->gfx_data = 0;
    for (int i=0; i<4; i++) tick();
    dut->async_rst_n = 1;
    for (int i=0; i<2; i++) tick();
}

// ---------------------------------------------------------------------------
// TX expected pixel: compute what the TX module should produce
//   gfx_code = (bank_sel ? tx_bank1 : tx_bank0) << 11 | tile_idx
//   gfx_base = gfx_code*32 + fetch_py*2
//   linebuf[col*8+px] = {color[3:0], plane3[7-px], plane2[7-px], plane1[7-px], plane0[7-px]}
// ---------------------------------------------------------------------------
static uint8_t tx_expected_pixel(int col, int px,
                                 int tile_word,
                                 int tx_bank0, int tx_bank1,
                                 int fetch_py) {
    int color    = (tile_word >> 12) & 0xF;
    int bank_sel = (tile_word >> 11) & 0x1;
    int tile_idx = tile_word & 0x7FF;
    int gfx_code = (bank_sel ? tx_bank1 : tx_bank0) << 11 | tile_idx;
    int gfx_base = (gfx_code << 5) + fetch_py * 2;
    uint8_t b0 = gfx_rom[gfx_base + 0];   // plane 0
    uint8_t b1 = gfx_rom[gfx_base + 1];   // plane 1
    uint8_t b2 = gfx_rom[gfx_base + 16];  // plane 2
    uint8_t b3 = gfx_rom[gfx_base + 17];  // plane 3
    int bit = 7 - px;
    int pixel_idx = ((b3 >> bit) & 1) << 3 |
                    ((b2 >> bit) & 1) << 2 |
                    ((b1 >> bit) & 1) << 1 |
                    ((b0 >> bit) & 1);
    return (uint8_t)((color << 4) | pixel_idx);
}

// ---------------------------------------------------------------------------
// BG/FG expected pixel for a 16×16 tile layer.
//
// Parameters:
//   screen_x     : screen column (0-based pixel column)
//   tile_code    : 15-bit tile code from VRAM bank0
//   color        : 6-bit color attribute (attr[5:0])
//   flipx, flipy : from attr[14], attr[15]
//   fetch_py     : pixel row within tile (0..15), = canvas_y & 0xF
//
// Returns composited pixel value: {color[5:0], pix_idx[3:0]} (10-bit packed
// in low 10 bits of uint16_t).  Returns 0 if pix_idx==0 (transparent).
// ---------------------------------------------------------------------------
static uint16_t bg_expected_pixel(int screen_x, int tile_code, int color,
                                  bool flipx, bool flipy, int fetch_py) {
    // Effective py
    int py_eff  = flipy ? (15 - fetch_py) : fetch_py;
    int tile_row = (py_eff >> 3) & 1;    // 0=top, 1=bottom
    int char_row = py_eff & 7;

    // px within the 16-px tile = screen_x & 15 (with scroll=0)
    int px       = screen_x & 15;
    int half     = (px >> 3) & 1;        // 0=left, 1=right
    int lx       = px & 7;

    // char_block: 0=top-left, 1=top-right, 2=bot-left, 3=bot-right
    // flipX swaps left/right char-blocks
    int cb_left  = tile_row * 2 + 0;
    int cb_right = tile_row * 2 + 1;
    int char_block;
    if (!flipx) {
        char_block = (half == 0) ? cb_left : cb_right;
    } else {
        char_block = (half == 0) ? cb_right : cb_left;  // swapped
    }

    // GFX byte addresses
    int char_base = tile_code * 128 + char_block * 32 + char_row * 2;
    uint8_t p0 = gfx_rom[char_base + 0];
    uint8_t p1 = gfx_rom[char_base + 1];
    uint8_t p2 = gfx_rom[char_base + 16];
    uint8_t p3 = gfx_rom[char_base + 17];

    // Bit selection: flipX reverses pixel order within the 8-px half
    int bit = flipx ? lx : (7 - lx);
    int pix_idx = (((p3 >> bit) & 1) << 3) |
                  (((p2 >> bit) & 1) << 2) |
                  (((p1 >> bit) & 1) << 1) |
                  (((p0 >> bit) & 1));

    if (pix_idx == 0) return 0;  // transparent → compositor shows 0 (or lower layer)
    return (uint16_t)((color << 4) | pix_idx);
}

// ---------------------------------------------------------------------------
// CPU write helper (used in render tests)
// ---------------------------------------------------------------------------
static void cpu_write(int addr, int data, int be = 3) {
    dut->cpu_cs   = 1;
    dut->cpu_we   = 1;
    dut->cpu_addr = (uint32_t)(addr & 0x7FFFF);
    dut->cpu_din  = (uint16_t)(data & 0xFFFF);
    dut->cpu_be   = (uint8_t)(be & 0x3);
    tick();
    dut->cpu_we = 0;
    dut->cpu_cs = 0;
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "Usage: %s <tier1_vectors.jsonl>\n", argv[0]); return 1; }
    init_gfx_rom();

    std::vector<Vec> vecs;
    FILE* fp = fopen(argv[1], "r"); if (!fp) { perror(argv[1]); return 1; }
    char line[4096];
    while (fgets(line, sizeof(line), fp)) {
        std::string s(line);
        if (s.empty() || s[0]=='#') continue;
        Vec v;
        std::string op = jstr(s, "op");
        v.is_write = (op == "write");
        v.addr     = jint(s, "addr");
        v.data     = jint(s, "data");
        v.be       = jint(s, "be", 3);
        v.exp_dout = jint(s, "exp_dout");
        v.note     = jstr(s, "note");
        vecs.push_back(v);
    }
    fclose(fp);
    printf("Loaded %zu vectors\n", vecs.size());

    Verilated::commandArgs(argc, argv);
    dut = new Vtc0180vcu;
    int pass=0, fail=0;

    reset();

    // ── Reset state check
    {
        bool ok = (dut->cpu_dout == 0) && (dut->pixel_out == 0)
               && (dut->int_h == 0) && (dut->int_l == 0);
        if (ok) ++pass;
        else { ++fail; printf("FAIL [reset] cpu_dout=%u pixel_out=%u int_h=%u int_l=%u\n",
                              dut->cpu_dout, dut->pixel_out, dut->int_h, dut->int_l); }
    }

    for (size_t vi=0; vi<vecs.size(); vi++) {
        const Vec& v = vecs[vi];

        if (v.is_write) {
            // Drive write
            dut->cpu_cs   = 1;
            dut->cpu_we   = 1;
            dut->cpu_addr = (uint32_t)(v.addr & 0x7FFFF);
            dut->cpu_din  = (uint16_t)(v.data & 0xFFFF);
            dut->cpu_be   = (uint8_t)(v.be & 0x3);
            tick();
            dut->cpu_we = 0;
            dut->cpu_cs = 0;
            ++pass;   // writes always pass (no observable output to check)
        } else {
            // Drive read: present address for one cycle, sample dout after
            dut->cpu_cs   = 1;
            dut->cpu_we   = 0;
            dut->cpu_addr = (uint32_t)(v.addr & 0x7FFFF);
            dut->cpu_be   = 0x3;
            tick();
            dut->cpu_cs = 0;

            int got = (int)dut->cpu_dout;
            if (got == v.exp_dout) {
                ++pass;
            } else {
                ++fail;
                printf("FAIL [%zu] %s\n  addr=0x%05X got=0x%04X exp=0x%04X\n",
                       vi, v.note.c_str(), v.addr, got, v.exp_dout);
            }
        }
    }

    // ── VBLANK interrupt test
    // Drive vblank pulse, check int_h fires
    {
        dut->cpu_cs = 0;
        dut->vblank_n = 0;  // assert vblank (active low → vblank_fall)
        tick();
        bool int_h_fired = (dut->int_h == 1);
        dut->vblank_n = 1;
        tick();
        if (int_h_fired) ++pass;
        else { ++fail; printf("FAIL [vblank] int_h did not fire on vblank assertion\n"); }

        // After ~8 more cycles, int_l should fire
        bool int_l_found = false;
        for (int i=0; i<12; i++) {
            tick();
            if (dut->int_l == 1) { int_l_found = true; break; }
        }
        if (int_l_found) ++pass;
        else { ++fail; printf("FAIL [intl] int_l did not fire within 12 cycles after vblank\n"); }
    }

    // ── TX Tilemap Render Test ──────────────────────────────────────────────
    // Program: tx_rampage=1 (tx_base=0x800), tx_bank0=2, tx_bank1=0
    // Test tile: VRAM[0x800 + row*64 + col] for various (row, col)
    // Drive vpos=N such that fetch_vpos=N+1, fetch_row=(N+1)>>3, fetch_py=(N+1)&7
    // Then assert HBLANK for 350 cycles, then check pixel_out at hpos = col*8+px
    {
        // Reset cleanly
        reset();

        // CPU address bases
        const int CTRL_BASE  = 0x0C000;
        const int VRAM_BASE  = 0x00000;
        // tx_rampage = 1  → ctrl[6][11:8] = 0x1 → write 0x0100 to high byte
        // ctrl[6] high byte = ctrl[6][15:8]; field tx_rampage = ctrl[6][11:8]
        // Write 0x0100 to ctrl[6]: addr = CTRL_BASE + 6 = 0xC006
        dut->cpu_cs   = 1;
        dut->cpu_we   = 1;
        dut->cpu_addr = (uint32_t)(CTRL_BASE + 6);
        dut->cpu_din  = 0x0100;   // tx_rampage=1
        dut->cpu_be   = 0x2;      // high byte only
        tick();
        dut->cpu_we = 0; dut->cpu_cs = 0;

        // tx_bank0 = 2 → ctrl[4][13:8] = 0x02 → write 0x0200 to high byte of ctrl[4]
        dut->cpu_cs   = 1;
        dut->cpu_we   = 1;
        dut->cpu_addr = (uint32_t)(CTRL_BASE + 4);
        dut->cpu_din  = 0x0200;   // tx_bank0=2
        dut->cpu_be   = 0x2;
        tick();
        dut->cpu_we = 0; dut->cpu_cs = 0;

        // tx_bank1 = 0 (already 0 from reset)

        // Write tile words to VRAM for test pattern
        // tx_rampage=1 → tx_base = 1<<11 = 0x800
        // Tile at (col=5, row=3): vram_addr = 0x800 + 3*64 + 5 = 0x800 + 0xC5 = 0x8C5
        // tile_word = color=0xB, bank_sel=0, tile_idx=0x12A → 0xB12A
        const int TX_RAMPAGE  = 1;
        const int TX_BANK0    = 2;
        const int TX_BANK1    = 0;
        const int TEST_COL    = 5;
        const int TEST_ROW    = 3;
        int vram_tile_addr = (TX_RAMPAGE << 11) + TEST_ROW * 64 + TEST_COL;
        const int TILE_WORD = 0xB12A;  // color=0xB, bank_sel=0, tile_idx=0x12A

        dut->cpu_cs   = 1;
        dut->cpu_we   = 1;
        dut->cpu_addr = (uint32_t)(VRAM_BASE + vram_tile_addr);
        dut->cpu_din  = (uint16_t)TILE_WORD;
        dut->cpu_be   = 0x3;
        tick();
        dut->cpu_we = 0; dut->cpu_cs = 0;
        tick(); tick();

        // Set vpos so that fetch_vpos = TEST_ROW*8 + fetch_py_test
        // We test fetch_py=5: fetch_vpos = 3*8+5 = 29 → vpos = 28
        const int FETCH_PY   = 5;
        const int FETCH_VPOS = TEST_ROW * 8 + FETCH_PY;  // = 29
        dut->vpos     = (uint8_t)(FETCH_VPOS - 1);        // = 28
        dut->hblank_n = 1;
        dut->vblank_n = 1;
        dut->cpu_cs   = 0;
        tick(); tick();  // settle vpos

        // Assert HBLANK (falling edge triggers TX fill)
        dut->hblank_n = 0;
        for (int i = 0; i < 350; i++) tick();  // 5 states × 64 tiles = 320 cycles
        dut->hblank_n = 1;
        tick(); tick();  // settle

        // Check pixel output for all 8 pixels of the test tile.
        // Compositor: transparent TX pixels (pix_idx=0) show as 0 when BG/FG are empty.
        int tx_errors = 0;
        for (int px = 0; px < 8; px++) {
            int hpos_val = TEST_COL * 8 + px;
            dut->hpos = (uint16_t)hpos_val;
            dut->clk = 0; dut->eval();   // combinational update
            uint8_t got = (uint8_t)(dut->pixel_out & 0xFF);
            uint8_t raw = tx_expected_pixel(TEST_COL, px, TILE_WORD,
                                            TX_BANK0, TX_BANK1, FETCH_PY);
            // With compositor: transparent pixel (pix_idx==0) → output 0 (all layers empty)
            uint8_t exp = ((raw & 0xF) == 0) ? 0 : raw;
            if (got == exp) {
                ++pass;
            } else {
                ++fail; ++tx_errors;
                printf("FAIL [tx col=%d px=%d hpos=%d] got=0x%02X exp=0x%02X (raw=0x%02X)\n",
                       TEST_COL, px, hpos_val, got, exp, raw);
            }
        }
        if (tx_errors == 0) printf("  TX render test: 8/8 pixels OK\n");

        // Also verify a tile that uses bank_sel=1 (tile_word bit[11]=1)
        // Tile at (col=10, row=3): bank_sel=1, tile_idx=0x055, color=0x3
        // tile_word = color[15:12]=0x3, bank_sel[11]=1, idx[10:0]=0x055 → 0x3855
        const int COL2       = 10;
        const int TILE_WORD2 = 0x3855;
        int vram_addr2 = (TX_RAMPAGE << 11) + TEST_ROW * 64 + COL2;

        // Write the second tile word
        reset();
        // Re-program ctrl (reset cleared it)
        dut->cpu_cs   = 1; dut->cpu_we = 1;
        dut->cpu_addr = (uint32_t)(CTRL_BASE + 6);
        dut->cpu_din  = 0x0100; dut->cpu_be = 0x2; tick();
        dut->cpu_we = 0; dut->cpu_cs = 0;
        dut->cpu_cs   = 1; dut->cpu_we = 1;
        dut->cpu_addr = (uint32_t)(CTRL_BASE + 4);
        dut->cpu_din  = 0x0200; dut->cpu_be = 0x2; tick();
        dut->cpu_we = 0; dut->cpu_cs = 0;
        dut->cpu_cs   = 1; dut->cpu_we = 1;
        dut->cpu_addr = (uint32_t)(VRAM_BASE + vram_addr2);
        dut->cpu_din  = (uint16_t)TILE_WORD2; dut->cpu_be = 0x3; tick();
        dut->cpu_we = 0; dut->cpu_cs = 0;
        tick(); tick();

        dut->vpos = (uint8_t)(FETCH_VPOS - 1);
        dut->hblank_n = 1; dut->vblank_n = 1; dut->cpu_cs = 0;
        tick(); tick();
        dut->hblank_n = 0;
        for (int i = 0; i < 350; i++) tick();
        dut->hblank_n = 1;
        tick(); tick();

        for (int px = 0; px < 8; px++) {
            int hpos_val = COL2 * 8 + px;
            dut->hpos = (uint16_t)hpos_val;
            dut->clk = 0; dut->eval();
            uint8_t got = (uint8_t)(dut->pixel_out & 0xFF);
            uint8_t raw = tx_expected_pixel(COL2, px, TILE_WORD2,
                                            TX_BANK0, TX_BANK1, FETCH_PY);
            // Compositor: transparent pixel (pix_idx==0) → output 0
            uint8_t exp = ((raw & 0xF) == 0) ? 0 : raw;
            if (got == exp) {
                ++pass;
            } else {
                ++fail;
                printf("FAIL [tx2 col=%d px=%d hpos=%d] got=0x%02X exp=0x%02X (raw=0x%02X)\n",
                       COL2, px, hpos_val, got, exp, raw);
            }
        }
    }

    // ── BG Tilemap Render Test ──────────────────────────────────────────────
    // Use BG bg_bank0=0, bg_bank1=1 (ctrl[1][11:8]=0, ctrl[1][15:12]=1).
    // Scroll: BG scrollX=0, scrollY=0 (scroll_ram[0x200]=0, scroll_ram[0x201]=0).
    // Test tile: BG at (tx=3, ty=2), tile_code=0x0050, color=0x0F, flipx=0, flipy=0.
    //   attr word = 0x000F (color=0x0F, no flip)
    // fetch: vpos=15 → fetch vpos+1=16 → canvas_y=16 → fetch_py=0, fetch_ty=1.
    //   Wait: ty=2 → need canvas_y[9:4]=2 → canvas_y=32 → fetch_vpos=32 → vpos=31.
    //   fetch_py = canvas_y[3:0] = 32&0xF = 0.  tile col: scrollX=0 → first_tile=0, tile_col=3 → tx=3.
    // BG linebuf position for screen_x in [tx*16..tx*16+15] = [48..63].
    // At hpos=48+px: layer_pixel = linebuf[48+px] → should match bg_expected_pixel(48+px, ...).
    //
    // The sequencer fires bg_start at hblank_cyc==321, fg_start at ==545.
    // Total HBLANK for all layers: need at least 545+223=768 cycles.
    // Drive HBLANK for 800 cycles to be safe.
    {
        const int BG_BANK0  = 0;
        const int BG_BANK1  = 1;
        const int BG_TX     = 3;    // tile column in map
        const int BG_TY     = 2;    // tile row in map
        // vpos such that canvas_y = BG_TY*16 = 32 → vpos = 31
        const int BG_VPOS   = 31;
        const int BG_FETCH_PY = 0;  // canvas_y[3:0] = 0
        const int BG_TILE_CODE = 0x0050;
        const int BG_COLOR  = 0x0F;
        const int BG_ATTR   = 0x000F;  // color=0x0F, no flip

        reset();

        // ctrl[0]: set FG bank0=7, bank1=7 → FG reads vram[0x7000+] which is all 0.
        // With tile_code=0 transparent (gfx_rom[0..127]=0), FG produces no pixels.
        cpu_write(0x0C000, (7 << 12) | (7 << 8), 0x3);

        // ctrl[1]: bg_bank0=BG_BANK0, bg_bank1=BG_BANK1
        // ctrl[1][11:8]=bank0, ctrl[1][15:12]=bank1 → value = (bank1<<12)|(bank0<<8)
        cpu_write(0x0C001, (BG_BANK1 << 12) | (BG_BANK0 << 8), 0x3);

        // Write tile code to VRAM: bank0_base=BG_BANK0<<12=0x0000, idx=BG_TY*64+BG_TX=131
        int bg_code_addr = (BG_BANK0 << 12) + BG_TY * 64 + BG_TX;   // = 0x083
        cpu_write(bg_code_addr, BG_TILE_CODE, 0x3);

        // Write attr to VRAM: bank1_base=BG_BANK1<<12=0x1000
        int bg_attr_addr = (BG_BANK1 << 12) + BG_TY * 64 + BG_TX;   // = 0x1083
        cpu_write(bg_attr_addr, BG_ATTR, 0x3);

        // Write BG scroll: scroll_ram[0x200]=scrollX=0, scroll_ram[0x201]=scrollY=0
        // Also zero FG scroll registers to prevent FG rendering from cross-test state.
        // scroll_ram CPU addr base = 0x09C00 (word offset 0x9C00 in 19-bit space)
        const int SCROLL_BASE_CPU = 0x09C00;
        cpu_write(SCROLL_BASE_CPU + 0x000, 0x0000, 0x3);  // FG scrollX (clear)
        cpu_write(SCROLL_BASE_CPU + 0x001, 0x0000, 0x3);  // FG scrollY (clear)
        cpu_write(SCROLL_BASE_CPU + 0x200, 0x0000, 0x3);  // BG scrollX
        cpu_write(SCROLL_BASE_CPU + 0x201, 0x0000, 0x3);  // BG scrollY

        tick(); tick();

        // Drive HBLANK: TX runs 0-320, BG starts at 321, runs to ~544.
        dut->vpos     = (uint8_t)BG_VPOS;
        dut->hblank_n = 1; dut->vblank_n = 1; dut->cpu_cs = 0;
        tick(); tick();

        dut->hblank_n = 0;
        for (int i = 0; i < 800; i++) tick();
        dut->hblank_n = 1;
        tick(); tick();

        int bg_errors = 0;
        for (int px = 0; px < 16; px++) {
            int hpos_val = BG_TX * 16 + px;
            dut->hpos = (uint16_t)hpos_val;
            dut->clk = 0; dut->eval();
            uint16_t got = dut->pixel_out & 0x3FF;
            uint16_t exp = bg_expected_pixel(hpos_val, BG_TILE_CODE, BG_COLOR,
                                             false, false, BG_FETCH_PY);
            if (got == exp) {
                ++pass;
            } else {
                ++fail; ++bg_errors;
                printf("FAIL [bg px=%d hpos=%d] got=0x%03X exp=0x%03X\n",
                       px, hpos_val, got, exp);
            }
        }
        if (bg_errors == 0) printf("  BG render test: 16/16 pixels OK\n");

        // Also test BG tile with flipX=1, flipY=1
        // tile at (tx=5, ty=2): tile_code=0x0080, color=0x12, flipx=1, flipy=1
        const int BG_TX2   = 5;
        const int BG_TILE2 = 0x0080;
        const int BG_COL2  = 0x12;
        const int BG_ATTR2 = 0xC012;  // flipY[15]=1, flipX[14]=1, color[5:0]=0x12

        int bg_code_addr2 = (BG_BANK0 << 12) + BG_TY * 64 + BG_TX2;
        int bg_attr_addr2 = (BG_BANK1 << 12) + BG_TY * 64 + BG_TX2;
        cpu_write(bg_code_addr2, BG_TILE2, 0x3);
        cpu_write(bg_attr_addr2, BG_ATTR2, 0x3);
        tick(); tick();

        dut->vpos     = (uint8_t)BG_VPOS;
        dut->hblank_n = 1; dut->vblank_n = 1;
        tick(); tick();
        dut->hblank_n = 0;
        for (int i = 0; i < 800; i++) tick();
        dut->hblank_n = 1;
        tick(); tick();

        int bg2_errors = 0;
        for (int px = 0; px < 16; px++) {
            int hpos_val = BG_TX2 * 16 + px;
            dut->hpos = (uint16_t)hpos_val;
            dut->clk = 0; dut->eval();
            uint16_t got = dut->pixel_out & 0x3FF;
            uint16_t exp = bg_expected_pixel(hpos_val, BG_TILE2, BG_COL2,
                                             true, true, BG_FETCH_PY);
            if (got == exp) {
                ++pass;
            } else {
                ++fail; ++bg2_errors;
                printf("FAIL [bg2 flipX/Y px=%d hpos=%d] got=0x%03X exp=0x%03X\n",
                       px, hpos_val, got, exp);
            }
        }
        if (bg2_errors == 0) printf("  BG flipX/Y test: 16/16 pixels OK\n");
    }

    // ── FG Tilemap Render Test ──────────────────────────────────────────────
    // Use FG fg_bank0=2, fg_bank1=3 (ctrl[0][11:8]=2, ctrl[0][15:12]=3).
    // Scroll: FG scrollX=0, scrollY=0 (scroll_ram[0x000]=0, scroll_ram[0x001]=0).
    // Test tile: FG at (tx=4, ty=1), tile_code=0x00A0, color=0x2A.
    // fetch: canvas_y = TY*16 = 16 → vpos = 15.
    // FG starts at hblank_cyc==545. BG must also run (its linebuf irrelevant here).
    {
        const int FG_BANK0  = 2;
        const int FG_BANK1  = 3;
        const int FG_TX     = 4;
        const int FG_TY     = 1;
        const int FG_VPOS   = 15;    // canvas_y=16 → fetch_py=0, fetch_ty=1
        const int FG_FETCH_PY = 0;
        const int FG_TILE_CODE = 0x00A0;
        const int FG_COLOR  = 0x2A;
        const int FG_ATTR   = 0x002A;  // color=0x2A, no flip

        reset();

        // ctrl[0]: fg_bank0=FG_BANK0=2, fg_bank1=FG_BANK1=3
        // ctrl[0][11:8]=bank0=2, ctrl[0][15:12]=bank1=3 → value = (3<<12)|(2<<8) = 0x3200
        cpu_write(0x0C000, (FG_BANK1 << 12) | (FG_BANK0 << 8), 0x3);

        // FG tile code at bank0_base=(FG_BANK0<<12)=0x2000, idx=FG_TY*64+FG_TX=68
        int fg_code_addr = (FG_BANK0 << 12) + FG_TY * 64 + FG_TX;
        cpu_write(fg_code_addr, FG_TILE_CODE, 0x3);

        // FG attr at bank1_base=FG_BANK1<<12=0x3000
        int fg_attr_addr = (FG_BANK1 << 12) + FG_TY * 64 + FG_TX;
        cpu_write(fg_attr_addr, FG_ATTR, 0x3);

        // FG scroll at scroll_ram[0x000..0x001] = 0.
        // Also zero BG scroll to prevent BG rendering from cross-test state.
        const int SCROLL_BASE_CPU = 0x09C00;
        cpu_write(SCROLL_BASE_CPU + 0x000, 0x0000, 0x3);
        cpu_write(SCROLL_BASE_CPU + 0x001, 0x0000, 0x3);
        cpu_write(SCROLL_BASE_CPU + 0x200, 0x0000, 0x3);
        cpu_write(SCROLL_BASE_CPU + 0x201, 0x0000, 0x3);

        tick(); tick();

        dut->vpos     = (uint8_t)FG_VPOS;
        dut->hblank_n = 1; dut->vblank_n = 1; dut->cpu_cs = 0;
        tick(); tick();

        // FG starts at cycle 545; drive for 800 total
        dut->hblank_n = 0;
        for (int i = 0; i < 800; i++) tick();
        dut->hblank_n = 1;
        tick(); tick();

        int fg_errors = 0;
        for (int px = 0; px < 16; px++) {
            int hpos_val = FG_TX * 16 + px;
            dut->hpos = (uint16_t)hpos_val;
            dut->clk = 0; dut->eval();
            uint16_t got = dut->pixel_out & 0x3FF;
            uint16_t exp = bg_expected_pixel(hpos_val, FG_TILE_CODE, FG_COLOR,
                                             false, false, FG_FETCH_PY);
            if (got == exp) {
                ++pass;
            } else {
                ++fail; ++fg_errors;
                printf("FAIL [fg px=%d hpos=%d] got=0x%03X exp=0x%03X\n",
                       px, hpos_val, got, exp);
            }
        }
        if (fg_errors == 0) printf("  FG render test: 16/16 pixels OK\n");
    }

    // ── BG Per-Block Scroll Test (lpb=8, lpb_ctrl=0xF8) ─────────────────
    // Set BG lpb_ctrl = 0xF8 → lpb = 256 - 0xF8 = 8.
    // Use BG bank0=4, bank1=5 (VRAM[0x4000+] / [0x5000+]).
    // Use scrollX=0 for all blocks → sx_frac=0, sx_tile=0.
    //   linebuf[0..15] = tile at map (col=0, ty=fetch_ty).
    // Distinguish blocks by scrollY per block:
    //   Block 0 (vpos=0):  fetch_vpos=1,  scrollY=0  → canvas_y=1,  ty=0, py=1
    //   Block 1 (vpos=8):  fetch_vpos=9,  scrollY=16 → canvas_y=25, ty=1, py=9
    //   Block 2 (vpos=16): fetch_vpos=17, scrollY=32 → canvas_y=49, ty=3, py=1
    // Place tile_code=0x0030+b with color=0x0E at (col=0, ty=exp_ty_b[b]).
    // scroll_off[b] = b*16 (block b * 2 * lpb = b*16 words from BG SCROLL_BASE 0x200).
    {
        const int BG_BANK0_B  = 4;
        const int BG_BANK1_B  = 5;
        const int LPB         = 8;
        const int LPB_CTRL    = 256 - LPB;   // = 0xF8 = 248
        const int COLOR       = 0x0E;

        // For each block b (vpos=b*8):
        //   fetch_vpos = b*8+1, canvas_y = fetch_vpos + scrollY_b[b]
        //   we want canvas_y[9:4] = exp_ty_b[b], so scrollY_b[b] = exp_ty_b[b]*16 - fetch_vpos
        // b=0: fetch_vpos=1,  want ty=0 → scrollY = 0*16-1 → wrap impossible, use ty=0: canvas_y=1, ty=0, py=1
        // b=1: fetch_vpos=9,  want ty=1 → canvas_y=16 → scrollY=16-9=7
        // b=2: fetch_vpos=17, want ty=2 → canvas_y=32 → scrollY=32-17=15
        const int scrollY_b[3]  = {  0,  7, 15 };
        const int exp_ty_b[3]   = {  0,  1,  2 };
        const int exp_py_b[3]   = {  1,  0,  0 };
        // canvas_y: b=0→1, b=1→16, b=2→32
        // py = canvas_y & 0xF: b=0→1, b=1→0, b=2→0
        const int tile_codes[3] = { 0x0030, 0x0031, 0x0032 };

        reset();

        // ctrl[6]: tx_rampage=7 → TX reads VRAM[0x3800+], far from BG banks 4/5
        cpu_write(0x0C006, 0x0700, 0x2);

        // ctrl[1]: bg_bank0=4, bg_bank1=5
        cpu_write(0x0C001, (BG_BANK1_B << 12) | (BG_BANK0_B << 8), 0x3);

        // ctrl[3]: bg_lpb_ctrl = 0xF8
        cpu_write(0x0C003, LPB_CTRL << 8, 0x3);

        // ctrl[0]: FG bank0=7, bank1=7 → all-zero VRAM → transparent
        cpu_write(0x0C000, (7 << 12) | (7 << 8), 0x3);

        const int SCROLL_CPU = 0x09C00;
        const int BG_SBASE   = SCROLL_CPU + 0x200;   // 0x09E00

        // Block 0: scroll_off=0,  scrollX=0, scrollY=scrollY_b[0]=0
        cpu_write(BG_SBASE +  0, 0,           0x3);  // scrollX
        cpu_write(BG_SBASE +  1, scrollY_b[0],0x3);  // scrollY
        // Block 1: scroll_off=16, scrollX=0, scrollY=scrollY_b[1]
        cpu_write(BG_SBASE + 16, 0,           0x3);
        cpu_write(BG_SBASE + 17, scrollY_b[1],0x3);
        // Block 2: scroll_off=32, scrollX=0, scrollY=scrollY_b[2]
        cpu_write(BG_SBASE + 32, 0,           0x3);
        cpu_write(BG_SBASE + 33, scrollY_b[2],0x3);

        // FG scroll=0
        cpu_write(SCROLL_CPU + 0, 0, 0x3);
        cpu_write(SCROLL_CPU + 1, 0, 0x3);

        // Tile data: tile at (col=0, ty=exp_ty_b[b]) in BG banks 4/5
        // VRAM code addr = (BG_BANK0_B<<12) + exp_ty_b[b]*64 + 0 = 0x4000 + b_ty*64
        // VRAM attr addr = (BG_BANK1_B<<12) + exp_ty_b[b]*64 + 0 = 0x5000 + b_ty*64
        for (int b = 0; b < 3; b++) {
            int ty   = exp_ty_b[b];
            int code = tile_codes[b];
            cpu_write((BG_BANK0_B << 12) + ty * 64, code,  0x3);
            cpu_write((BG_BANK1_B << 12) + ty * 64, COLOR, 0x3);
        }

        tick(); tick();

        int blk_errors = 0;
        // Test each block.
        // scrollX=0 → sx_frac=0, sx_tile=0 → linebuf[0..15] = tile at (col=0, ty=exp_ty_b[b]).
        // bg_expected_pixel(screen_x, tile_code, COLOR, false, false, fetch_py):
        //   screen_x=px (0..15) → px_in_tile=px, uses tile at map col 0.
        for (int b = 0; b < 3; b++) {
            int vpos_val = b * LPB;
            int fetch_py = exp_py_b[b];
            int tile_code= tile_codes[b];

            dut->vpos     = (uint8_t)vpos_val;
            dut->hblank_n = 1; dut->vblank_n = 1; dut->cpu_cs = 0;
            tick(); tick();
            dut->hblank_n = 0;
            for (int i = 0; i < 800; i++) tick();
            dut->hblank_n = 1;
            tick(); tick();

            for (int px = 0; px < 16; px++) {
                uint16_t exp = bg_expected_pixel(px, tile_code, COLOR,
                                                 false, false, fetch_py);
                dut->hpos = (uint16_t)px;
                dut->clk = 0; dut->eval();
                uint16_t got = dut->pixel_out & 0x3FF;
                if (got == exp) {
                    ++pass;
                } else {
                    ++fail; ++blk_errors;
                    printf("FAIL [bg_lpb8 blk=%d px=%d] got=0x%03X exp=0x%03X "
                           "(tile=%04X color=%02X fetch_py=%d)\n",
                           b, px, got, exp, tile_code, COLOR, fetch_py);
                }
            }
        }
        if (blk_errors == 0) printf("  BG per-block (lpb=8) test: 48/48 pixels OK\n");
    }

    // ── FG Per-Scanline Scroll Test (lpb=1, lpb_ctrl=0xFF) ────────────────
    // Set FG lpb_ctrl = 0xFF → lpb = 1 → per-scanline scroll.
    // scrollX for scanline 0: scroll_ram[0x000] = 8  (word offset 0*2*1 = 0)
    // scrollX for scanline 1: scroll_ram[0x002] = 16 (word offset 1*2*1 = 2)
    // scrollY = 0 for both.
    //
    // fetch_vpos for vpos=N is N+1.
    //   vpos=0 → fetch_vpos=1 → block=1 → scroll_off=2 → scrollX=scroll_ram[2]=16
    //   vpos=255 → fetch_vpos=256 → fetch_vpos & 0xFF = 0 → block=0 → scroll_off=0 → scrollX=8
    //
    // Wait — the RTL uses {1'b0, vpos} + 9'd1, and then divides by lpb.
    // For lpb=1: block = fetch_vpos = (vpos+1) & 0xFF (vpos is 8-bit, so adding 1 wraps at 256).
    // Actually fetch_vpos_c is 9-bit: {1'b0, vpos} + 9'd1 → for vpos=255, result=256 (9-bit).
    // block_c = fetch_vpos_c / lpb_c = 256 / 1 = 256. But block_c is 9-bit → 256 fits.
    // scroll_off_c = block_c * (lpb_c << 1) = 256 * 2 = 512 → 10 bits → truncates to 0!
    // So for vpos=255: scroll_off=0 → wraps to block 0. This is the correct wrapping behavior.
    //
    // Test plan (avoiding the vpos=255 wrap edge case):
    //   Scanline A = fetch_vpos=1 (vpos=0): block=1, scroll_off=2, scrollX=scroll_ram[0x002]
    //   Scanline B = fetch_vpos=2 (vpos=1): block=2, scroll_off=4, scrollX=scroll_ram[0x004]
    //
    // Write:
    //   scroll_ram[FG base 0x000] + 0 = ? (block 0, not tested)
    //   scroll_ram[0x002] = scrollX_A = 8  (block 1)
    //   scroll_ram[0x004] = scrollX_B = 16 (block 2)
    //   scrollY = 0 for all.
    //
    // Use FG fg_bank0=2, fg_bank1=3.
    // Tile for scanline A: scrollX=8, sx_tile=0, map col=0; canvas_y=1 → ty=0, py=1.
    // Tile for scanline B: scrollX=16, sx_tile=1, map col=1; canvas_y=2 → ty=0, py=2.
    //   tile_code_A=0x00C0, tile_code_B=0x00D0, color=0x1E, no flip.
    {
        const int FG_BANK0_P  = 2;
        const int FG_BANK1_P  = 3;

        reset();

        // ctrl[6]: tx_rampage=4 → TX reads from VRAM[0x2000+], away from FG bank0=2 area
        // (FG bank0=2 maps to VRAM[0x2000+]. Move TX to page 5 = VRAM[0x2800+] to avoid conflict)
        // Actually FG bank0=2 uses VRAM[0x2000+0] = VRAM[0x2000] for col=0, ty=0.
        // TX at rampage=5 uses VRAM[5<<11=0x2800+], so no overlap with FG at 0x2000.
        cpu_write(0x0C006, 0x0500, 0x2);  // high byte: tx_rampage = 5 (VRAM[0x2800+], untouched)

        // ctrl[0]: fg_bank0=2, fg_bank1=3
        cpu_write(0x0C000, (FG_BANK1_P << 12) | (FG_BANK0_P << 8), 0x3);

        // ctrl[2]: fg_lpb_ctrl = 0xFF → ctrl[2][15:8] = 0xFF
        cpu_write(0x0C002, 0xFF00, 0x3);

        // ctrl[1]: set BG bank0=7, bank1=7 → BG transparent
        cpu_write(0x0C001, (7 << 12) | (7 << 8), 0x3);

        // Zero all FG scroll entries we'll use, plus BG entries
        const int SCROLL_CPU = 0x09C00;
        // FG scroll: words 0x000..0x005 (blocks 0-2, 2 words each)
        for (int i = 0; i < 6; i++) cpu_write(SCROLL_CPU + i, 0, 0x3);
        // BG scroll: words 0x200..0x201
        cpu_write(SCROLL_CPU + 0x200, 0, 0x3);
        cpu_write(SCROLL_CPU + 0x201, 0, 0x3);

        // Scanline A: vpos=0, fetch_vpos=1, block=1, scroll_off=2
        //   scrollX=8 → scroll_ram[0x002]=8, scrollY=0 → scroll_ram[0x003]=0
        cpu_write(SCROLL_CPU + 2, 8, 0x3);   // scrollX for block 1
        cpu_write(SCROLL_CPU + 3, 0, 0x3);   // scrollY

        // Scanline B: vpos=1, fetch_vpos=2, block=2, scroll_off=4
        //   scrollX=16 → scroll_ram[0x004]=16, scrollY=0 → scroll_ram[0x005]=0
        cpu_write(SCROLL_CPU + 4, 16, 0x3);  // scrollX for block 2
        cpu_write(SCROLL_CPU + 5,  0, 0x3);  // scrollY

        // Tiles for scanline A (scrollX=8, sx_tile=0, map col=0, canvas_y=1, py=1, ty=0)
        const int TILE_A   = 0x00C0;
        const int TILE_B   = 0x00D0;
        const int FG_COLOR = 0x1E;
        const int FG_ATTR  = FG_COLOR;  // no flip

        // Scanline A tile at FG map (col=0, ty=0)
        cpu_write((FG_BANK0_P << 12) + 0, TILE_A, 0x3);
        cpu_write((FG_BANK1_P << 12) + 0, FG_ATTR, 0x3);

        // Scanline B tile at FG map (col=1, ty=0)
        cpu_write((FG_BANK0_P << 12) + 1, TILE_B, 0x3);
        cpu_write((FG_BANK1_P << 12) + 1, FG_ATTR, 0x3);

        tick(); tick();

        int psl_errors = 0;

        // Test scanline A: vpos=0, scrollX=8, sx_frac=8, sx_tile=0
        {
            int vpos_val  = 0;
            int scrollX   = 8;
            int sx_frac   = scrollX & 0xF;   // = 8
            int sx_tile   = scrollX >> 4;     // = 0
            int fetch_py  = 1;               // canvas_y = (0+1+0) & 0x3FF = 1, py=1&0xF=1
            int tile_code = TILE_A;
            int color     = FG_COLOR;

            dut->vpos     = (uint8_t)vpos_val;
            dut->hblank_n = 1; dut->vblank_n = 1; dut->cpu_cs = 0;
            tick(); tick();
            dut->hblank_n = 0;
            for (int i = 0; i < 800; i++) tick();
            dut->hblank_n = 1;
            tick(); tick();

            // Check 8 pixels starting at hpos=sx_frac
            // linebuf[(hpos + sx_frac) & 511]:
            //   hpos=sx_frac → idx=2*sx_frac & 511; for sx_frac=8: idx=16 = tile_col=1, px=0
            //   Actually we want to verify the pixels that correspond to the tile placed at sx_tile.
            //   The tile is at linebuf[tile_col=0..21, px=0..15]. For tile_col=0: linebuf[0..15].
            //   layer_pixel = linebuf[(hpos + sx_frac) & 511].
            //   To get linebuf[0..15] (tile_col=0), need hpos such that (hpos+sx_frac)&511 in [0..15].
            //   hpos = (0 - sx_frac + 512) & 511 = 512-8 = 504 .. 504+15
            //   Then screen_x_equiv = sx_tile*16 + px = 0*16 + px = px.
            for (int px = 0; px < 16; px++) {
                int hpos_val = (512 - sx_frac + px) & 511;
                int screen_x_equiv = sx_tile * 16 + px;
                uint16_t exp = bg_expected_pixel(screen_x_equiv, tile_code, color,
                                                 false, false, fetch_py);
                dut->hpos = (uint16_t)hpos_val;
                dut->clk = 0; dut->eval();
                uint16_t got = dut->pixel_out & 0x3FF;
                if (got == exp) {
                    ++pass;
                } else {
                    ++fail; ++psl_errors;
                    printf("FAIL [fg_lpb1 scanA px=%d hpos=%d] got=0x%03X exp=0x%03X "
                           "(tile=%04X color=%02X fetch_py=%d)\n",
                           px, hpos_val, got, exp, tile_code, color, fetch_py);
                }
            }
        }

        // Test scanline B: vpos=1, scrollX=16, sx_frac=0, sx_tile=1
        {
            int vpos_val  = 1;
            int scrollX   = 16;
            int sx_frac   = scrollX & 0xF;   // = 0
            int sx_tile   = scrollX >> 4;     // = 1
            int fetch_py  = 2;               // canvas_y = (1+1+0) & 0x3FF = 2, py=2&0xF=2
            int tile_code = TILE_B;
            int color     = FG_COLOR;

            dut->vpos     = (uint8_t)vpos_val;
            dut->hblank_n = 1; dut->vblank_n = 1; dut->cpu_cs = 0;
            tick(); tick();
            dut->hblank_n = 0;
            for (int i = 0; i < 800; i++) tick();
            dut->hblank_n = 1;
            tick(); tick();

            // sx_frac=0: linebuf[(hpos+0)&511] = linebuf[hpos].
            // tile_col=0 occupies linebuf[0..15]: tile at map col=sx_tile=1.
            // hpos = 0..15 gives linebuf[0..15] = pixels of tile at col=1.
            // bg_expected_pixel: screen_x_equiv = sx_tile*16 + px = 16 + px.
            for (int px = 0; px < 16; px++) {
                int hpos_val = px;   // sx_frac=0 → linebuf[hpos]
                int screen_x_equiv = sx_tile * 16 + px;
                uint16_t exp = bg_expected_pixel(screen_x_equiv, tile_code, color,
                                                 false, false, fetch_py);
                dut->hpos = (uint16_t)hpos_val;
                dut->clk = 0; dut->eval();
                uint16_t got = dut->pixel_out & 0x3FF;
                if (got == exp) {
                    ++pass;
                } else {
                    ++fail; ++psl_errors;
                    printf("FAIL [fg_lpb1 scanB px=%d hpos=%d] got=0x%03X exp=0x%03X "
                           "(tile=%04X color=%02X fetch_py=%d)\n",
                           px, hpos_val, got, exp, tile_code, color, fetch_py);
                }
            }
        }

        if (psl_errors == 0) printf("  FG per-scanline (lpb=1) test: 32/32 pixels OK\n");
    }

    // ── Sprite Render Test (step 5) ──────────────────────────────────────────
    // Tests unzoomed, non-big-sprite rendering into the framebuffer during VBLANK,
    // then compositing of the framebuffer into pixel_out during active display.
    //
    // Setup:
    //   - BG/FG banks point to VRAM[0x7000+] (all-zero → transparent)
    //   - TX rampage=7 → VRAM[0x3800+] (all-zero → transparent)
    //   - sprite_priority=1 (VIDEO_CTRL[3]=1): SP above FG, below TX
    //   - VIDEO_CTRL[0]=0: erase FB on VBLANK
    //   - One sprite at sprite RAM[0] (highest priority):
    //       tile_code=0x0042, color=0x07, x=64, y=48, zoom=0, big=0, flipX=0, flipY=0
    //   - Drive VBLANK low for 300,000 cycles (enough for sprite engine to complete)
    //   - Verify pixel_out at hpos=64+px, vpos=48+py matches expected sprite pixel
    //
    // Expected pixel: {0x07, gfx_expected_low2bits} or 0 (transparent)
    {
        reset();
        const int CTRL_BASE = 0x0C000;

        // ctrl[0]: FG bank0=7, bank1=7 → transparent
        cpu_write(CTRL_BASE + 0, (7 << 12) | (7 << 8), 0x3);
        // ctrl[1]: BG bank0=7, bank1=7 → transparent
        cpu_write(CTRL_BASE + 1, (7 << 12) | (7 << 8), 0x3);
        // ctrl[6]: TX rampage=7 → transparent
        cpu_write(CTRL_BASE + 6, 0x0700, 0x2);
        // ctrl[7]: sprite_priority=1 (bit3), no_erase=0 (bit0)
        // VIDEO_CTRL = 0x08 → ctrl[7][15:8] = 0x08
        cpu_write(CTRL_BASE + 7, 0x0800, 0x2);

        // Zero scroll RAM to avoid stale FG/BG scroll offsets
        const int SCROLL_CPU = 0x09C00;
        cpu_write(SCROLL_CPU + 0x000, 0, 0x3);
        cpu_write(SCROLL_CPU + 0x001, 0, 0x3);
        cpu_write(SCROLL_CPU + 0x200, 0, 0x3);
        cpu_write(SCROLL_CPU + 0x201, 0, 0x3);

        // Write sprite 0 (highest priority) to sprite RAM.
        // Sprite RAM chip address: 0x10000 → word address 0x8000.
        // Sprite 0 base word: 0x8000 + 0*8 = 0x8000.
        const int SPR_BASE_CPU = 0x8000;  // sprite 0, word 0 (19-bit word addr)
        const int SPR_TILE   = 0x0042;
        const int SPR_ATTR   = 0x001C;  // color=0x1C (0b011100), flipX=0, flipY=0
        //   color = attr[5:0] = 0x1C = 28 decimal
        const int SPR_COLOR  = 0x1C;
        const int SPR_X      = 64;
        const int SPR_Y      = 48;

        cpu_write(SPR_BASE_CPU + 0, SPR_TILE,  0x3);  // word+0: tile_code
        cpu_write(SPR_BASE_CPU + 1, SPR_ATTR,  0x3);  // word+1: attr (color, flip)
        cpu_write(SPR_BASE_CPU + 2, SPR_X,     0x3);  // word+2: x
        cpu_write(SPR_BASE_CPU + 3, SPR_Y,     0x3);  // word+3: y
        cpu_write(SPR_BASE_CPU + 4, 0x0000,    0x3);  // word+4: zoom=0 (unzoomed)
        cpu_write(SPR_BASE_CPU + 5, 0x0000,    0x3);  // word+5: big=0 (single tile)

        tick(); tick();

        // Drive TWO VBLANKs, each long enough for the sprite engine to complete.
        //
        // Page flip mechanics (auto-flip, no_erase=0):
        //   Before:      fb_page_reg=0, display_page=1
        //   VBLANK 1 ↓:  fb_page_reg→1, erase page1, render sprites to page1
        //   VBLANK 2 ↓:  fb_page_reg→0, erase page0, render sprites to page0
        //                display_page=1 → shows page1 (rendered in VBLANK 1) ✓
        //
        // Sprite engine: erase (131072 cycles) + 407 sprites × ~8 cycles (skip check)
        //   + 1 sprite × 16 rows × ~12 cycles (8 GFX + 2×8 write) ≈ ~135000 cycles.
        // Drive each VBLANK for 200,000 cycles to be safe.
        for (int vb = 0; vb < 2; vb++) {
            dut->vblank_n = 0;
            dut->hblank_n = 1;
            dut->vpos     = 0;
            dut->hpos     = 0;
            for (int i = 0; i < 200000; i++) tick();
            dut->vblank_n = 1;
            tick(); tick();
        }
        // After 2nd VBLANK: display_page=1, which shows sprites rendered in VBLANK 1.

        // Now check pixels at (vpos=48+py, hpos=64+px) for all 16 rows and 16 columns.
        // Expected: framebuffer pixel = {SPR_COLOR[5:0], pix_idx[1:0]} or 0 (transparent).
        int spr_errors = 0;
        int spr_total  = 0;
        for (int py = 0; py < 16; py++) {
            for (int px = 0; px < 16; px++) {
                int screen_x = SPR_X + px;
                int screen_y = SPR_Y + py;

                // Compute expected GFX pixel (same formula as bg_expected_pixel
                // but the FB only stores lower 2 bits of pixel index).
                int py_eff  = py;  // flipY=0
                int tile_row = (py_eff >> 3) & 1;
                int char_row = py_eff & 7;
                int half     = (px >> 3) & 1;
                int lx       = px & 7;

                // char block selection (no flip)
                int char_block = tile_row * 2 + half;

                int char_base = SPR_TILE * 128 + char_block * 32 + char_row * 2;
                uint8_t p0 = gfx_rom[char_base + 0];
                uint8_t p1 = gfx_rom[char_base + 1];
                uint8_t p2 = gfx_rom[char_base + 16];
                uint8_t p3 = gfx_rom[char_base + 17];
                int bit = 7 - lx;  // flipX=0
                int pix_idx = (((p3 >> bit) & 1) << 3) |
                              (((p2 >> bit) & 1) << 2) |
                              (((p1 >> bit) & 1) << 1) |
                              (((p0 >> bit) & 1));

                // FB encoding: {color[5:0], pix_idx[1:0]}, transparent if pix_idx==0
                uint8_t exp_fb = (pix_idx == 0) ? 0 :
                                 (uint8_t)((SPR_COLOR << 2) | (pix_idx & 3));

                // pixel_out from compositor:
                // sprite_priority=1, so if sp_pix!=0: pixel_out = {5'b0, sp_pix}
                uint16_t exp_out = (uint16_t)exp_fb;  // transparent → 0

                dut->vpos = (uint8_t)screen_y;
                dut->hpos = (uint16_t)screen_x;
                dut->clk = 0; dut->eval();
                uint16_t got = dut->pixel_out & 0xFF;

                ++spr_total;
                if (got == exp_out) {
                    ++pass;
                } else {
                    ++fail; ++spr_errors;
                    printf("FAIL [spr px=%d py=%d hpos=%d vpos=%d] got=0x%02X exp=0x%02X "
                           "(pix_idx=%d color=0x%02X)\n",
                           px, py, screen_x, screen_y, got, exp_out, pix_idx, SPR_COLOR);
                }
            }
        }
        if (spr_errors == 0)
            printf("  Sprite render test (no-flip): %d/%d pixels OK\n", spr_total, spr_total);
    }

    // ── Sprite flipX Test ────────────────────────────────────────────────────
    // Same setup but flipX=1: pixel order within each 8-px half is reversed.
    {
        reset();
        const int CTRL_BASE = 0x0C000;

        cpu_write(CTRL_BASE + 0, (7 << 12) | (7 << 8), 0x3);
        cpu_write(CTRL_BASE + 1, (7 << 12) | (7 << 8), 0x3);
        cpu_write(CTRL_BASE + 6, 0x0700, 0x2);
        cpu_write(CTRL_BASE + 7, 0x0800, 0x2);  // sprite_priority=1

        const int SCROLL_CPU = 0x09C00;
        cpu_write(SCROLL_CPU + 0x000, 0, 0x3);
        cpu_write(SCROLL_CPU + 0x001, 0, 0x3);
        cpu_write(SCROLL_CPU + 0x200, 0, 0x3);
        cpu_write(SCROLL_CPU + 0x201, 0, 0x3);

        // Sprite 0: tile=0x0055, color=0x0A, x=100, y=80, flipX=1, flipY=0
        const int SPR_BASE_CPU = 0x8000;
        const int SPR_TILE2  = 0x0055;
        const int SPR_COLOR2 = 0x0A;
        const int SPR_ATTR2  = (1 << 14) | SPR_COLOR2;  // flipX=bit14, color=bit[5:0]
        const int SPR_X2     = 100;
        const int SPR_Y2     = 80;

        cpu_write(SPR_BASE_CPU + 0, SPR_TILE2,  0x3);
        cpu_write(SPR_BASE_CPU + 1, SPR_ATTR2,  0x3);
        cpu_write(SPR_BASE_CPU + 2, SPR_X2,     0x3);
        cpu_write(SPR_BASE_CPU + 3, SPR_Y2,     0x3);
        cpu_write(SPR_BASE_CPU + 4, 0x0000,     0x3);
        cpu_write(SPR_BASE_CPU + 5, 0x0000,     0x3);

        tick(); tick();

        // Two VBLANKs so display_page ends up showing the rendered sprites.
        for (int vb = 0; vb < 2; vb++) {
            dut->vblank_n = 0;
            dut->hblank_n = 1;
            dut->vpos     = 0;
            dut->hpos     = 0;
            for (int i = 0; i < 200000; i++) tick();
            dut->vblank_n = 1;
            tick(); tick();
        }

        int spr2_errors = 0;
        int spr2_total  = 0;
        for (int py = 0; py < 16; py++) {
            for (int px = 0; px < 16; px++) {
                int screen_x = SPR_X2 + px;
                int screen_y = SPR_Y2 + py;

                // flipX=1: char-blocks L/R swapped; bit order reversed within half
                int py_eff   = py;  // flipY=0
                int tile_row = (py_eff >> 3) & 1;
                int char_row = py_eff & 7;
                int half     = (px >> 3) & 1;
                int lx       = px & 7;

                // flipX: swap L and R char-blocks
                int cb_left  = tile_row * 2 + 0;
                int cb_right = tile_row * 2 + 1;
                int char_block = (half == 0) ? cb_right : cb_left;  // swapped

                int char_base = SPR_TILE2 * 128 + char_block * 32 + char_row * 2;
                uint8_t p0 = gfx_rom[char_base + 0];
                uint8_t p1 = gfx_rom[char_base + 1];
                uint8_t p2 = gfx_rom[char_base + 16];
                uint8_t p3 = gfx_rom[char_base + 17];
                int bit = lx;  // flipX=1: reversed bit order
                int pix_idx = (((p3 >> bit) & 1) << 3) |
                              (((p2 >> bit) & 1) << 2) |
                              (((p1 >> bit) & 1) << 1) |
                              (((p0 >> bit) & 1));

                uint8_t exp_fb = (pix_idx == 0) ? 0 :
                                 (uint8_t)((SPR_COLOR2 << 2) | (pix_idx & 3));
                uint16_t exp_out = (uint16_t)exp_fb;

                dut->vpos = (uint8_t)screen_y;
                dut->hpos = (uint16_t)screen_x;
                dut->clk = 0; dut->eval();
                uint16_t got = dut->pixel_out & 0xFF;

                ++spr2_total;
                if (got == exp_out) {
                    ++pass;
                } else {
                    ++fail; ++spr2_errors;
                    printf("FAIL [spr_flipX px=%d py=%d hpos=%d vpos=%d] got=0x%02X exp=0x%02X "
                           "(pix_idx=%d color=0x%02X)\n",
                           px, py, screen_x, screen_y, got, exp_out, pix_idx, SPR_COLOR2);
                }
            }
        }
        if (spr2_errors == 0)
            printf("  Sprite render test (flipX=1): %d/%d pixels OK\n", spr2_total, spr2_total);
    }

    printf("\n%s: %d/%d tests passed\n", (fail==0)?"PASS":"FAIL", pass, pass+fail);
    delete dut;
    return (fail==0) ? 0 : 1;
}
