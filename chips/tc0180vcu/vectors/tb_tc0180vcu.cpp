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

        // Check pixel output for all 8 pixels of the test tile
        int tx_errors = 0;
        for (int px = 0; px < 8; px++) {
            int hpos_val = TEST_COL * 8 + px;
            dut->hpos = (uint16_t)hpos_val;
            dut->clk = 0; dut->eval();   // combinational update
            uint8_t got = (uint8_t)(dut->pixel_out & 0xFF);
            uint8_t exp = tx_expected_pixel(TEST_COL, px, TILE_WORD,
                                            TX_BANK0, TX_BANK1, FETCH_PY);
            if (got == exp) {
                ++pass;
            } else {
                ++fail; ++tx_errors;
                printf("FAIL [tx col=%d px=%d hpos=%d] got=0x%02X exp=0x%02X\n",
                       TEST_COL, px, hpos_val, got, exp);
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
            uint8_t exp = tx_expected_pixel(COL2, px, TILE_WORD2,
                                            TX_BANK0, TX_BANK1, FETCH_PY);
            if (got == exp) {
                ++pass;
            } else {
                ++fail;
                printf("FAIL [tx2 col=%d px=%d hpos=%d] got=0x%02X exp=0x%02X\n",
                       COL2, px, hpos_val, got, exp);
            }
        }
    }

    printf("\n%s: %d/%d tests passed\n", (fail==0)?"PASS":"FAIL", pass, pass+fail);
    delete dut;
    return (fail==0) ? 0 : 1;
}
