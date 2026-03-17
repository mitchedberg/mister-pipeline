// =============================================================================
// TC0480SCP — Verilator testbench
//
// Reads one or more JSONL vector files.  Each line is a JSON object with "op":
//
// Step 1 ops:
//   op="reset"
//   op="write"        Fields: "addr" (word 0–23), "data" (16-bit), "be"
//   op="read"         Fields: "addr", "exp_dout"
//   op="check_bgscrollx"  Fields: "layer" (0–3), "exp"
//   op="check_bgscrolly"  Fields: "layer", "exp"
//   op="check_dblwidth"   Fields: "exp"
//   op="check_flipscreen" Fields: "exp"
//   op="check_bg_priority" Fields: "exp"
//   op="check_rowzoom_en" Fields: "layer" (2 or 3), "exp"
//   op="check_bg_dx"  Fields: "layer", "exp"
//   op="check_bg_dy"  Fields: "layer", "exp"
//   op="timing_frame" Fields: "exp_pv"
//   op="timing_check" Fields: "hpos","vpos","exp_hblank","exp_vblank","exp_pixel_active"
//
// Step 2 ops:
//   op="vram_write"
//       CPU write to VRAM.
//       Fields: "addr" (word address 0x0000–0x7FFF), "data" (16-bit), "be" (byte enables)
//
//   op="vram_read"
//       CPU read from VRAM; compare to "exp_data".
//       Fields: "addr" (word address), "exp_data" (16-bit)
//
//   op="vram_zero"
//       Zero a range of VRAM words. Fields: "base" (word addr), "count" (# words).
//       Used to ensure BRAM persistence doesn't affect tests.
//
// Step 3 ops:
//   op="gfx_write"
//       Write FG0 gfx tile data to VRAM (byte 0xE000–0xFFFF = word 0x7000–0x7FFF).
//       Fields: "word_addr" (offset within gfx region, 0..0xFFF), "data" (16-bit)
//
//   op="map_write_fg"
//       Write FG0 tile map entry.
//       Fields: "tile_x" (0..63), "tile_y" (0..63), "data" (16-bit tile word)
//
//   op="run_frame"
//       Simulate one full frame (H_TOTAL × V_TOTAL cycles).
//       Collects nothing — just advances simulation time.
//
//   op="check_pixel"
//       Sample pixel_out at the given screen position.
//       The testbench advances to that position and reads pixel_out.
//       Fields: "screen_x" (0..319), "screen_y" (0..239), "exp" (16-bit palette index)
//
// Step 4 ops:
//   op="gfx_rom_write"
//       Write to the simulated GFX ROM array (word-addressed 32-bit words).
//       Fields: "word_addr" (21-bit), "data" (32-bit as two 16-bit fields "data_hi","data_lo")
//
//   op="map_write_bg"
//       Write BG tile map entry (attr or code word) directly to VRAM.
//       Fields: "layer" (0..3), "tile_x", "tile_y", "attr" (16-bit), "code" (16-bit)
//       Writes both attr and code words for the tile.
//
// All passing tests: prints "PASS [note]"
// Any failure:       prints "FAIL [note]: got=X exp=Y"
// Final summary:     "TESTS: N passed, M failed"
// Exit code: 0=all pass, 1=any failure.
// =============================================================================

#include "Vtc0480scp.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdint.h>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// Timing constants — must match RTL localparam and Python model
// ---------------------------------------------------------------------------
static const int H_TOTAL  = 424;
static const int H_END    = 320;   // hblank starts here
static const int V_TOTAL  = 262;
static const int V_START  = 16;
static const int V_END    = 256;

// ---------------------------------------------------------------------------
// Minimal JSON field extractors
// ---------------------------------------------------------------------------
static size_t jfind(const std::string& s, const std::string& key) {
    std::string pat = "\"" + key + "\"";
    auto p = s.find(pat);
    if (p == std::string::npos) return std::string::npos;
    p += pat.size();
    while (p < s.size() && (s[p] == ' ' || s[p] == ':')) ++p;
    return p;
}

static int jint(const std::string& s, const std::string& key, int dflt = 0) {
    auto p = jfind(s, key);
    if (p == std::string::npos) return dflt;
    return (int)strtol(s.c_str() + p, nullptr, 0);
}

static uint32_t juint(const std::string& s, const std::string& key, uint32_t dflt = 0) {
    auto p = jfind(s, key);
    if (p == std::string::npos) return dflt;
    return (uint32_t)strtoul(s.c_str() + p, nullptr, 0);
}

static std::string jstr(const std::string& s, const std::string& key) {
    auto p = jfind(s, key);
    if (p == std::string::npos || s[p] != '"') return "";
    ++p;
    auto e = s.find('"', p);
    return (e == std::string::npos) ? "" : s.substr(p, e - p);
}

// ---------------------------------------------------------------------------
// DUT, clock, and pass/fail counters
// ---------------------------------------------------------------------------
static Vtc0480scp* dut = nullptr;
static int g_pass = 0;
static int g_fail = 0;

// GFX ROM simulation array (Step 4): 2^21 words × 32-bit
// Allocated on heap to avoid stack overflow.
static uint32_t* gfx_rom = nullptr;
static const int GFX_ROM_WORDS = (1 << 21);

static void tick() {
    // Drive GFX ROM outputs to DUT (Step 4: combinational async read).
    // Each BG engine (0–3) has an independent read port so simultaneous
    // fetches from different layers never collide.
    if (gfx_rom) {
        for (int n = 0; n < 4; n++) {
            uint32_t addr = dut->gfx_addr[n] & (GFX_ROM_WORDS - 1);
            dut->gfx_data[n] = gfx_rom[addr];
        }
    } else {
        for (int n = 0; n < 4; n++) dut->gfx_data[n] = 0;
    }
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
}

static void idle_bus() {
    dut->cpu_cs   = 0;
    dut->cpu_we   = 0;
    dut->cpu_addr = 0;
    dut->cpu_din  = 0;
    dut->cpu_be   = 0;
    dut->vram_cs  = 0;
    dut->vram_we  = 0;
    dut->vram_addr = 0;
    dut->vram_din  = 0;
    dut->vram_be   = 0;
}

static void do_reset() {
    dut->async_rst_n = 0;
    idle_bus();
    for (int i = 0; i < 4; i++) tick();
    dut->async_rst_n = 1;
    for (int i = 0; i < 2; i++) tick();
}

// ---------------------------------------------------------------------------
// Check helpers
// ---------------------------------------------------------------------------
static void check(bool ok, const std::string& note, int got, int exp) {
    if (ok) {
        printf("PASS %s\n", note.c_str());
        g_pass++;
    } else {
        printf("FAIL %s: got=0x%04X exp=0x%04X\n", note.c_str(), got, exp);
        g_fail++;
    }
}

static void check32(bool ok, const std::string& note, uint32_t got, uint32_t exp) {
    if (ok) {
        printf("PASS %s\n", note.c_str());
        g_pass++;
    } else {
        printf("FAIL %s: got=0x%08X exp=0x%08X\n", note.c_str(), got, exp);
        g_fail++;
    }
}

// ---------------------------------------------------------------------------
// CPU bus operations (control register window)
// ---------------------------------------------------------------------------
static void cpu_write(int word_addr, int data, int be) {
    dut->cpu_cs   = 1;
    dut->cpu_we   = 1;
    dut->cpu_addr = (uint32_t)(word_addr & 0x1F);
    dut->cpu_din  = (uint16_t)(data & 0xFFFF);
    dut->cpu_be   = (uint8_t)(be & 0x3);
    tick();
    idle_bus();
    tick();
}

static int cpu_read(int word_addr) {
    dut->cpu_cs   = 1;
    dut->cpu_we   = 0;
    dut->cpu_addr = (uint32_t)(word_addr & 0x1F);
    dut->cpu_be   = 0x3;
    tick();
    int result = (int)(dut->cpu_dout & 0xFFFF);
    idle_bus();
    tick();
    return result;
}

// ---------------------------------------------------------------------------
// VRAM bus operations (Step 2)
// vram_addr[14:0] = word address within 64KB VRAM (byte_addr >> 1)
// ---------------------------------------------------------------------------
static void vram_write(int word_addr, int data, int be) {
    dut->vram_cs   = 1;
    dut->vram_we   = 1;
    dut->vram_addr = (uint32_t)(word_addr & 0x7FFF);
    dut->vram_din  = (uint16_t)(data & 0xFFFF);
    dut->vram_be   = (uint8_t)(be & 0x3);
    tick();
    idle_bus();
    tick();
}

// Returns the registered read result (one-cycle latency).
static int vram_read(int word_addr) {
    dut->vram_cs   = 1;
    dut->vram_we   = 0;
    dut->vram_addr = (uint32_t)(word_addr & 0x7FFF);
    dut->vram_be   = 0x3;
    tick();                          // posedge: VRAM latches address
    idle_bus();
    tick();                          // posedge: cpu_dout updated with VRAM[addr]
    return (int)(dut->vram_dout & 0xFFFF);
}

// Zero a range of VRAM words [base .. base+count-1]
static void vram_zero_range(int base, int count) {
    for (int i = 0; i < count; i++)
        vram_write(base + i, 0, 3);
}

// ---------------------------------------------------------------------------
// Timing helpers
// ---------------------------------------------------------------------------
static void run_timing_frame(int exp_pv, const std::string& note) {
    int pv_count = 0;
    int total    = H_TOTAL * V_TOTAL;
    for (int i = 0; i < total; i++) {
        tick();
        if (dut->pixel_active) pv_count++;
    }
    check(pv_count == exp_pv, note + " [pixel_active_count]", pv_count, exp_pv);
}

static void run_timing_check(int target_hpos, int target_vpos,
                              int exp_hblank, int exp_vblank, int exp_pv,
                              const std::string& note) {
    int limit = 2 * H_TOTAL * V_TOTAL;
    for (int i = 0; i < limit; i++) {
        if ((int)dut->hpos == target_hpos && (int)dut->vpos == target_vpos)
            break;
        tick();
    }
    tick();
    bool got_hb = dut->hblank       != 0;
    bool got_vb = dut->vblank       != 0;
    bool got_pv = dut->pixel_active != 0;

    check(got_hb == (bool)exp_hblank,  note + " [hblank]",       (int)got_hb, exp_hblank);
    check(got_vb == (bool)exp_vblank,  note + " [vblank]",       (int)got_vb, exp_vblank);
    check(got_pv == (bool)exp_pv,      note + " [pixel_active]", (int)got_pv, exp_pv);
}

// ---------------------------------------------------------------------------
// Pixel-capture helper (Step 3+)
// Advance to the given screen position and sample pixel_out.
// screen_y is 0-based (first visible line = V_START = 16, so vpos = V_START + screen_y).
// screen_x is 0-based hpos (active display starts at hpos=0).
// ---------------------------------------------------------------------------
static int capture_pixel(int screen_x, int screen_y) {
    // Target vpos and hpos
    int target_vpos = V_START + screen_y;
    int target_hpos = screen_x;

    // Advance until we reach the target position
    int limit = 2 * H_TOTAL * V_TOTAL;
    for (int i = 0; i < limit; i++) {
        if ((int)dut->hpos == target_hpos && (int)dut->vpos == target_vpos)
            break;
        tick();
    }
    // Tick once more so registered pixel_out is valid for this position
    tick();
    return (int)(dut->pixel_out & 0xFFFF);
}

// Run one full frame then check a pixel on the NEXT frame.
// This gives the fill FSM a full frame to populate the line buffer before reading.
static int capture_pixel_next_frame(int screen_x, int screen_y) {
    // Run to VBLANK first to let the engines fill buffers cleanly
    int limit = H_TOTAL * V_TOTAL;
    for (int i = 0; i < limit; i++) tick();
    return capture_pixel(screen_x, screen_y);
}

// ---------------------------------------------------------------------------
// BG tile map write helper (Step 4)
// Writes attr + code word pair for tile (tile_x, tile_y) on layer L.
// Standard mode assumed (dblwidth=0).
// ---------------------------------------------------------------------------
static void bg_map_write(int layer, int tile_x, int tile_y, int attr, int code) {
    // Word address = layer * 0x0400 + (tile_y * 32 + tile_x) * 2
    int tile_idx = tile_y * 32 + tile_x;
    int word_base = layer * 0x0400 + tile_idx * 2;
    vram_write(word_base,     attr & 0xFFFF, 3);
    vram_write(word_base + 1, code & 0x7FFF, 3);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <vectors1.jsonl> [vectors2.jsonl ...]\n", argv[0]);
        return 1;
    }

    // Allocate GFX ROM
    gfx_rom = new uint32_t[GFX_ROM_WORDS]();  // zero-initialized

    Verilated::commandArgs(argc, argv);
    dut = new Vtc0480scp;

    // Initial power-on state
    dut->async_rst_n = 0;
    for (int n = 0; n < 4; n++) dut->gfx_data[n] = 0;
    idle_bus();
    for (int i = 0; i < 4; i++) tick();
    dut->async_rst_n = 1;
    for (int i = 0; i < 4; i++) tick();

    // Process each vector file in sequence
    for (int fnum = 1; fnum < argc; fnum++) {
        FILE* fp = fopen(argv[fnum], "r");
        if (!fp) {
            fprintf(stderr, "Cannot open %s\n", argv[fnum]);
            return 1;
        }

        char lbuf[4096];
        while (fgets(lbuf, sizeof(lbuf), fp)) {
            std::string line(lbuf);
            while (!line.empty() &&
                   (line.back() == '\n' || line.back() == '\r'))
                line.pop_back();
            if (line.empty() || line[0] == '#') continue;

            std::string op   = jstr(line, "op");
            std::string note = jstr(line, "note");

            // ── Step 1 ops ──────────────────────────────────────────────────

            if (op == "reset") {
                do_reset();
                printf("PASS %s\n", note.c_str());
                g_pass++;

            } else if (op == "write") {
                cpu_write(jint(line, "addr"),
                          jint(line, "data"),
                          jint(line, "be", 3));

            } else if (op == "read") {
                int got = cpu_read(jint(line, "addr"));
                check(got == jint(line, "exp_dout"), note, got,
                      jint(line, "exp_dout"));

            } else if (op == "check_bgscrollx") {
                int layer = jint(line, "layer");
                int exp   = jint(line, "exp") & 0xFFFF;
                int got   = 0;
                dut->eval();
                switch (layer) {
                    case 0: got = (int)(dut->bgscrollx[0] & 0xFFFF); break;
                    case 1: got = (int)(dut->bgscrollx[1] & 0xFFFF); break;
                    case 2: got = (int)(dut->bgscrollx[2] & 0xFFFF); break;
                    case 3: got = (int)(dut->bgscrollx[3] & 0xFFFF); break;
                    default: got = 0; break;
                }
                check(got == exp, note, got, exp);

            } else if (op == "check_bgscrolly") {
                int layer = jint(line, "layer");
                int exp   = jint(line, "exp") & 0xFFFF;
                int got   = 0;
                dut->eval();
                switch (layer) {
                    case 0: got = (int)(dut->bgscrolly[0] & 0xFFFF); break;
                    case 1: got = (int)(dut->bgscrolly[1] & 0xFFFF); break;
                    case 2: got = (int)(dut->bgscrolly[2] & 0xFFFF); break;
                    case 3: got = (int)(dut->bgscrolly[3] & 0xFFFF); break;
                    default: got = 0; break;
                }
                check(got == exp, note, got, exp);

            } else if (op == "check_dblwidth") {
                int exp = jint(line, "exp");
                dut->eval();
                int got = (int)(dut->dblwidth & 1);
                check(got == exp, note, got, exp);

            } else if (op == "check_flipscreen") {
                int exp = jint(line, "exp");
                dut->eval();
                int got = (int)(dut->flipscreen & 1);
                check(got == exp, note, got, exp);

            } else if (op == "check_bg_priority") {
                int exp = jint(line, "exp") & 0xFFFF;
                dut->eval();
                int got = (int)(dut->bg_priority & 0xFFFF);
                check(got == exp, note, got, exp);

            } else if (op == "check_rowzoom_en") {
                int layer = jint(line, "layer");
                int exp   = jint(line, "exp");
                dut->eval();
                int got = 0;
                if (layer == 2)      got = (int)(dut->rowzoom_en[0] & 1);
                else if (layer == 3) got = (int)(dut->rowzoom_en[1] & 1);
                check(got == exp, note, got, exp);

            } else if (op == "check_bg_dx") {
                int layer = jint(line, "layer");
                int exp   = jint(line, "exp") & 0xFF;
                int got   = 0;
                dut->eval();
                switch (layer) {
                    case 0: got = (int)(dut->bg_dx[0] & 0xFF); break;
                    case 1: got = (int)(dut->bg_dx[1] & 0xFF); break;
                    case 2: got = (int)(dut->bg_dx[2] & 0xFF); break;
                    case 3: got = (int)(dut->bg_dx[3] & 0xFF); break;
                    default: got = 0; break;
                }
                check(got == exp, note, got, exp);

            } else if (op == "check_bg_dy") {
                int layer = jint(line, "layer");
                int exp   = jint(line, "exp") & 0xFF;
                int got   = 0;
                dut->eval();
                switch (layer) {
                    case 0: got = (int)(dut->bg_dy[0] & 0xFF); break;
                    case 1: got = (int)(dut->bg_dy[1] & 0xFF); break;
                    case 2: got = (int)(dut->bg_dy[2] & 0xFF); break;
                    case 3: got = (int)(dut->bg_dy[3] & 0xFF); break;
                    default: got = 0; break;
                }
                check(got == exp, note, got, exp);

            } else if (op == "timing_frame") {
                run_timing_frame(jint(line, "exp_pv"), note);

            } else if (op == "timing_check") {
                run_timing_check(jint(line, "hpos"), jint(line, "vpos"),
                                 jint(line, "exp_hblank"),
                                 jint(line, "exp_vblank"),
                                 jint(line, "exp_pixel_active"),
                                 note);

            // ── Step 2 ops ──────────────────────────────────────────────────

            } else if (op == "vram_write") {
                vram_write(jint(line, "addr"), jint(line, "data"), jint(line, "be", 3));
                // No PASS output for writes — they are setup ops

            } else if (op == "vram_read") {
                int exp = jint(line, "exp_data") & 0xFFFF;
                int got = vram_read(jint(line, "addr"));
                check(got == exp, note, got, exp);

            } else if (op == "vram_zero") {
                int base  = jint(line, "base");
                int count = jint(line, "count");
                vram_zero_range(base, count);
                // No PASS output — setup op

            // ── Step 3 ops ──────────────────────────────────────────────────

            } else if (op == "gfx_write") {
                // Write FG0 gfx data to VRAM (word 0x7000 + word_addr)
                int waddr = 0x7000 + jint(line, "word_addr");
                vram_write(waddr, jint(line, "data"), 3);

            } else if (op == "map_write_fg") {
                // Write FG0 tile map entry at (tile_x, tile_y)
                // Map word addr = 0x6000 + tile_y * 64 + tile_x
                int tile_x = jint(line, "tile_x");
                int tile_y = jint(line, "tile_y");
                int waddr  = 0x6000 + tile_y * 64 + tile_x;
                vram_write(waddr, jint(line, "data"), 3);

            } else if (op == "run_frame") {
                // Run one full frame
                for (int i = 0; i < H_TOTAL * V_TOTAL; i++) tick();

            } else if (op == "check_pixel") {
                // Sample pixel_out at screen position (screen_x, screen_y).
                // Run 2 full frames first to ensure line buffers are filled.
                int screen_x = jint(line, "screen_x");
                int screen_y = jint(line, "screen_y");
                int exp      = jint(line, "exp") & 0xFFFF;
                // Run 2 frames to warm up the fill FSMs
                for (int i = 0; i < 2 * H_TOTAL * V_TOTAL; i++) tick();
                int got = capture_pixel(screen_x, screen_y);
                check(got == exp, note, got, exp);

            // ── Step 4 ops ──────────────────────────────────────────────────

            } else if (op == "gfx_rom_write") {
                // Write a 32-bit word to the GFX ROM simulation array
                uint32_t waddr = juint(line, "word_addr");
                uint32_t hi    = juint(line, "data_hi");
                uint32_t lo    = juint(line, "data_lo");
                uint32_t data  = (hi << 16) | (lo & 0xFFFF);
                if (waddr < (uint32_t)GFX_ROM_WORDS)
                    gfx_rom[waddr] = data;

            } else if (op == "map_write_bg") {
                // Write BG tile map entry (both attr and code words) for layer L
                int layer  = jint(line, "layer");
                int tile_x = jint(line, "tile_x");
                int tile_y = jint(line, "tile_y");
                int attr   = jint(line, "attr") & 0xFFFF;
                int code   = jint(line, "code") & 0x7FFF;
                bg_map_write(layer, tile_x, tile_y, attr, code);

            } else {
                printf("WARN unknown op='%s'\n", op.c_str());
            }
        }
        fclose(fp);
    }

    printf("\nTESTS: %d passed, %d failed\n", g_pass, g_fail);
    delete dut;
    delete[] gfx_rom;
    return (g_fail == 0) ? 0 : 1;
}
