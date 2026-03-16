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

    printf("\n%s: %d/%d tests passed\n", (fail==0)?"PASS":"FAIL", pass, pass+fail);
    delete dut;
    return (fail==0) ? 0 : 1;
}
