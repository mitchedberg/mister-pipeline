// =============================================================================
// TC0480SCP — Verilator testbench (Step 1: skeleton + timing + control regs)
//
// Reads one or more JSONL vector files.  Each line is a JSON object with "op":
//
// Step 1 ops:
//   op="reset"
//       Assert async_rst_n=0 for 4 ticks, release, settle.
//
//   op="write"
//       CPU write to control register.
//       Fields: "addr" (word 0–23), "data" (16-bit), "be" (byte enables, default 3)
//
//   op="read"
//       CPU read from control register; compare to "exp_dout".
//       Fields: "addr", "exp_dout"
//
//   op="check_bgscrollx"
//       After a write cycle, sample bgscrollx[layer] output.
//       Fields: "layer" (0–3), "exp" (16-bit expected value, signed 2's-complement as uint16)
//
//   op="check_bgscrolly"
//       Fields: "layer" (0–3), "exp" (16-bit)
//
//   op="check_dblwidth"
//       Fields: "exp" (0 or 1)
//
//   op="check_flipscreen"
//       Fields: "exp" (0 or 1)
//
//   op="check_bg_priority"
//       Fields: "exp" (16-bit priority word)
//
//   op="check_rowzoom_en"
//       Fields: "layer" (2 or 3), "exp" (0 or 1)
//
//   op="check_bg_dx"
//       Fields: "layer" (0–3), "exp" (8-bit)
//
//   op="check_bg_dy"
//       Fields: "layer" (0–3), "exp" (8-bit)
//
//   op="timing_frame"
//       Run one full H_TOTAL×V_TOTAL frame (424×262 = 111,088 cycles).
//       Count cycles where pixel_active==1.
//       Fields: "exp_pv" (expected pixel_active count)
//
//   op="timing_check"
//       Advance to (hpos, vpos), then sample hblank/vblank/pixel_active.
//       Fields: "hpos", "vpos", "exp_hblank", "exp_vblank", "exp_pixel_active"
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
static const int H_TOTAL = 424;
static const int H_END   = 320;   // hblank starts here
static const int V_TOTAL = 262;
static const int V_START = 16;
static const int V_END   = 256;

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

static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
}

static void idle_bus() {
    dut->cpu_cs   = 0;
    dut->cpu_we   = 0;
    dut->cpu_addr = 0;
    dut->cpu_din  = 0;
    dut->cpu_be   = 0;
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

// ---------------------------------------------------------------------------
// CPU bus operations (control register window)
//
// cpu_addr[4:0] = word index 0–23 within the control register window.
// NOTE: TC0480SCP cpu_addr port is [4:0] (5 bits, word index).
// There is NO [18:1] offset here — this is the ctrl window only.
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
// Timing helpers
// ---------------------------------------------------------------------------

// Run one complete frame (H_TOTAL × V_TOTAL cycles), counting pixel_active.
static void run_timing_frame(int exp_pv, const std::string& note) {
    int pv_count = 0;
    int total    = H_TOTAL * V_TOTAL;
    for (int i = 0; i < total; i++) {
        tick();
        if (dut->pixel_active) pv_count++;
    }
    check(pv_count == exp_pv, note + " [pixel_active_count]", pv_count, exp_pv);
}

// Advance to (target_hpos, target_vpos), then sample timing signals.
//
// hblank, vblank, and pixel_active are registered outputs: they are updated
// on the posedge *after* hpos/vpos update.  Strategy:
//   1. Tick until hpos/vpos == target (they update on the posedge).
//   2. Then tick one more time so the registered timing outputs catch up.
//   3. Sample after that tick.
static void run_timing_check(int target_hpos, int target_vpos,
                              int exp_hblank, int exp_vblank, int exp_pv,
                              const std::string& note) {
    int limit = 2 * H_TOTAL * V_TOTAL;
    for (int i = 0; i < limit; i++) {
        if ((int)dut->hpos == target_hpos && (int)dut->vpos == target_vpos)
            break;
        tick();
    }
    // One additional tick: lets the registered hblank/vblank/pixel_active
    // reflect the combinational decode for the current (hpos, vpos).
    tick();
    bool got_hb = dut->hblank       != 0;
    bool got_vb = dut->vblank       != 0;
    bool got_pv = dut->pixel_active != 0;

    check(got_hb == (bool)exp_hblank,  note + " [hblank]",       (int)got_hb, exp_hblank);
    check(got_vb == (bool)exp_vblank,  note + " [vblank]",       (int)got_vb, exp_vblank);
    check(got_pv == (bool)exp_pv,      note + " [pixel_active]", (int)got_pv, exp_pv);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <vectors1.jsonl> [vectors2.jsonl ...]\n", argv[0]);
        return 1;
    }

    Verilated::commandArgs(argc, argv);
    dut = new Vtc0480scp;

    // Initial power-on state
    dut->async_rst_n = 0;
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

            } else {
                printf("WARN unknown op='%s'\n", op.c_str());
            }
        }
        fclose(fp);
    }

    printf("\nTESTS: %d passed, %d failed\n", g_pass, g_fail);
    delete dut;
    return (g_fail == 0) ? 0 : 1;
}
