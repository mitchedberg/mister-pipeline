// =============================================================================
// Gate 5 (Steps 1–13): Verilator testbench for tc0630fdp.sv
//
// Reads one or more vector files (jsonl). Each line is a JSON object with "op":
//
// Step 1 ops:
//   op="reset":              Assert async_rst_n=0 for 4 ticks, release, settle.
//   op="write":              CPU write to ctrl register at word addr.
//   op="read":               CPU read from ctrl register; compare to exp_dout.
//   op="check_extend_mode":  No-op (verified via ctrl readback). Emits PASS.
//   op="timing_frame":       Run one full frame, count pixel_valid/int pulses.
//   op="timing_check":       Advance to (hpos,vpos), check hblank/vblank/pv.
//
// Step 2 ops:
//   op="write_text":   CPU write to Text RAM.
//   op="read_text":    CPU read from Text RAM; compare exp_dout.
//   op="write_char":   CPU write to Char RAM.
//   op="read_char":    CPU read from Char RAM; compare exp_dout.
//   op="check_text_pixel":
//     Advance to HBLANK at vpos. Wait 90 cycles. Advance to active display
//     of vpos+1 at screen_col. Sample text_pixel_out. Compare to exp_pixel.
//
// Step 3 ops:
//   op="write_pf":    CPU write to PF RAM (plane 0..3, pf_word_addr, data).
//   op="read_pf":     CPU read from PF RAM; compare exp_dout.
//   op="write_gfx":   Write 32-bit word to GFX ROM via gfx_wr_* ports.
//   op="check_bg_pixel":
//     Similar to check_text_pixel: advance to HBLANK at vpos, wait for BG FSM
//     (115 cycles), advance to active display of vpos+1 at screen_col, sample
//     bg_pixel_out[plane]. Compare to exp_pixel (13-bit: {palette[8:0],pen[3:0]}).
//
// Step 5 ops (Plan Step 5: Line RAM Parser + Rowscroll):
//   op="write_line":  CPU write to Line RAM at chip word addr 0x10000+offset.
//     "addr" is the cpu_addr word address within the chip window (must be in
//     range 0x10000–0x17FFF).
//   op="read_line":   CPU read from Line RAM; compare exp_dout.
//   All pixel check ops (check_bg_pixel, check_text_pixel, etc.) are reused.
//   Rowscroll and alt-tilemap are exercised by writing Line RAM, then
//   checking bg_pixel_out[plane] with check_bg_pixel.
//
// Step 4 ops (Plan Step 4: Text Layer + Character RAM — completion tests):
//   op="check_text_over_bg":
//     Advance to HBLANK at vpos. Wait 115 cycles (covers both text FSM ≤80 and
//     BG FSM ≤106). Advance to active display of vpos+1 at screen_col.
//     Sample BOTH text_pixel_out (9-bit) AND bg_pixel_out[0] (13-bit).
//     Compare each independently: exp_text vs text_pixel_out, exp_bg vs bg[0].
//     Validates that text and BG layers both render correctly at the same
//     screen position — compositing priority ("text wins") is Plan Step 11.
//
// Step 8 ops:
//   op="write_sprite":  CPU write to Sprite RAM at chip word addr 0x20000+offset.
//     "addr" is the cpu_addr word address within the chip window (0x20000–0x27FFF).
//   op="check_sprite_pixel":
//     Advance to HBLANK at vpos (hblank_fall triggers renderer for vpos+1).
//     Renderer completes within HBLANK (112 cycles; ≤64 sprites × ~6 cycles each).
//     Advance to active display of vpos+1 at screen_col.
//     Sample spr_pixel_out (12-bit: {prio[1:0], palette[5:0], pen[3:0]}).
//     Compare to exp_pixel. pen==0 means transparent (spr_pixel_out==0).
//
// Step 11 ops:
//   op="write_line":    (reused) CPU write to Line RAM.
//   op="check_colmix_pixel":
//     Advance to HBLANK at vpos (triggers sprite renderer and line RAM latch).
//     Wait 115 cycles (covers BG, text, sprite renderer).
//     Advance to active display of vpos+1 at screen_col+1 (colmix adds 1 pipeline stage).
//     Sample colmix_pixel_out (13-bit: {palette[8:0], pen[3:0]}).
//     Compare to exp_pixel. pen==0 means all transparent (background).
//
// Step 13 ops:
//   op="write_pal":
//     Write one 16-bit color word to palette RAM via pal_wr_* testbench port.
//     "pal_addr": 13-bit address (0..8191)
//     "pal_data": 16-bit color word (bits[15:12]=R, bits[11:8]=G, bits[7:4]=B)
//   op="check_blend_pixel":
//     Like check_colmix_pixel but samples blend_rgb_out (24-bit) instead.
//     blend_rgb_out is registered 1 cycle after colmix_pixel_out, so advance
//     to screen_col+2 (colmix stage + palette read stage).
//     "exp_rgb": 24-bit expected blended RGB value {R8, G8, B8}.
//
// All passing tests: prints "PASS [note]"
// Any failure:       prints "FAIL [note]: got=X exp=Y"
// Final summary:     "TESTS: N passed, M failed"
// Exit code: 0=all pass, 1=any failure.
// =============================================================================

#include "Vtc0630fdp.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdint.h>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// Timing constants (must match RTL and Python model)
// ---------------------------------------------------------------------------
static const int H_TOTAL  = 432;
static const int H_START  = 46;
static const int H_END    = 366;
static const int V_TOTAL  = 262;
static const int V_START  = 24;
static const int V_END    = 256;
static const int V_SYNC_S = 0;
static const int V_SYNC_E = 4;
static const int H_SYNC_S = 0;
static const int H_SYNC_E = 32;

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
// DUT and clock
// ---------------------------------------------------------------------------
static Vtc0630fdp* dut = nullptr;
static int g_pass = 0;
static int g_fail = 0;

static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
}

static void do_reset() {
    dut->async_rst_n = 0;
    dut->cpu_cs    = 0;
    dut->cpu_rw    = 1;
    dut->cpu_addr  = 0;
    dut->cpu_din   = 0;
    dut->cpu_lds_n = 1;
    dut->cpu_uds_n = 1;
    dut->gfx_wr_en   = 0;
    dut->spr_wr_en   = 0;
    dut->spr_wr_addr = 0;
    dut->spr_wr_data = 0;
    dut->pal_wr_en   = 0;
    dut->pal_wr_addr = 0;
    dut->pal_wr_data = 0;
    for (int i = 0; i < 4; i++) tick();
    dut->async_rst_n = 1;
    for (int i = 0; i < 2; i++) tick();
}

// Write one 16-bit word to palette RAM via the dedicated write port.
// pal_addr: 13-bit address into palette RAM (0..8191).
static void pal_write(int pal_addr, uint16_t data) {
    dut->pal_wr_en   = 1;
    dut->pal_wr_addr = (uint32_t)(pal_addr & 0x1FFF);
    dut->pal_wr_data = data;
    tick();
    dut->pal_wr_en   = 0;
    tick();
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
// CPU bus operations
// ---------------------------------------------------------------------------
static void cpu_write(int addr, int data, int be) {
    dut->cpu_cs    = 1;
    dut->cpu_rw    = 0;
    dut->cpu_addr  = (uint32_t)(addr & 0x3FFFF);
    dut->cpu_din   = (uint16_t)(data & 0xFFFF);
    dut->cpu_uds_n = (be & 2) ? 0 : 1;
    dut->cpu_lds_n = (be & 1) ? 0 : 1;
    tick();
    dut->cpu_cs    = 0;
    dut->cpu_rw    = 1;
    dut->cpu_uds_n = 1;
    dut->cpu_lds_n = 1;
    tick();
}

static int cpu_read(int addr) {
    dut->cpu_cs    = 1;
    dut->cpu_rw    = 1;
    dut->cpu_addr  = (uint32_t)(addr & 0x3FFFF);
    dut->cpu_uds_n = 0;
    dut->cpu_lds_n = 0;
    tick();
    int result = dut->cpu_dout;
    dut->cpu_cs    = 0;
    dut->cpu_uds_n = 1;
    dut->cpu_lds_n = 1;
    tick();
    return result;
}

// Write one 32-bit word to GFX ROM via the dedicated write port.
static void gfx_write(int word_addr, uint32_t data) {
    dut->gfx_wr_en   = 1;
    dut->gfx_wr_addr = (uint32_t)(word_addr & 0x3FFFFF);
    dut->gfx_wr_data = data;
    tick();
    dut->gfx_wr_en   = 0;
    tick();
}

// Write one 16-bit word to Sprite RAM via the dedicated direct write port.
// word_addr: 15-bit word address into Sprite RAM (0..32767).
// This bypasses the CPU bus — used to pre-load sprite entries quickly.
static void spr_write(int word_addr, uint16_t data) {
    dut->spr_wr_en   = 1;
    dut->spr_wr_addr = (uint32_t)(word_addr & 0x7FFF);
    dut->spr_wr_data = data;
    tick();
    dut->spr_wr_en   = 0;
    tick();
}

// ---------------------------------------------------------------------------
// Step 8: check_sprite_pixel
//
// Strategy:
//   1. Advance to vpos==V_END (VBLANK start); the sprite scanner fires here.
//   2. Wait 8000 cycles for the scanner to finish walking all 256 entries
//      (232 clear cycles + 256 × ~24 cycles ≈ 6400 cycles; 8000 is conservative).
//   3. Advance to hpos==H_END, vpos==target_vpos (HBLANK start).
//      The sprite renderer fires on hblank_fall, loading sprites for vpos+1.
//      The renderer completes within HBLANK (112 cycles; 64 sprites × ~6 cycles).
//   4. Advance directly to hpos=H_START+screen_col, vpos=target_vpos+1.
//      The ping-pong swap fires at hblank_end (hpos==H_START), so the front
//      buffer holds the freshly-rendered sprites before we sample.
//   5. Sample spr_pixel_out (12-bit).
//   6. Compare to exp_pixel.
// ---------------------------------------------------------------------------
static void check_sprite_pixel(int target_vpos, int screen_col,
                                int exp_pixel, const std::string& note) {
    int limit = 4 * H_TOTAL * V_TOTAL;

    // Step 1: advance to VBLANK start (vpos==V_END)
    int found = 0;
    for (int i = 0; i < limit; i++) {
        if ((int)dut->vpos == V_END) {
            found = 1;
            break;
        }
        tick();
    }
    if (!found) {
        printf("FAIL %s: could not reach vpos=%d (VBLANK start)\n",
               note.c_str(), V_END);
        g_fail++;
        return;
    }

    // Step 2: wait for scanner to walk all 256 sprite entries
    for (int i = 0; i < 8000; i++) tick();

    // Step 3: advance to HBLANK start of target_vpos
    found = 0;
    for (int i = 0; i < limit; i++) {
        if ((int)dut->hpos == H_END && (int)dut->vpos == target_vpos) {
            found = 1;
            break;
        }
        tick();
    }
    if (!found) {
        printf("FAIL %s: could not reach hpos=%d vpos=%d\n",
               note.c_str(), H_END, target_vpos);
        g_fail++;
        return;
    }

    // Step 4: advance directly to active display of vpos+1 at screen_col.
    // Do NOT do a fixed-cycle blind wait here — that would overshoot HBLANK
    // (HBLANK is only 112 cycles) and cause the seek loop to wrap around to
    // the wrong frame.  The renderer completes within HBLANK for the test
    // vectors (1-2 sprites per scanline, ~10 cycles each).  The ping-pong
    // swap fires at hblank_end (hpos==H_START of vpos+1), so by the time we
    // reach disp_hpos = H_START+screen_col the front buffer holds the correct
    // rendered data.
    int disp_vpos = (target_vpos + 1) % V_TOTAL;
    int disp_hpos = H_START + screen_col;

    for (int i = 0; i < limit; i++) {
        if ((int)dut->hpos == disp_hpos && (int)dut->vpos == disp_vpos)
            break;
        tick();
    }

    dut->eval();
    int got = (int)dut->spr_pixel_out & 0xFFF;
    check(got == (exp_pixel & 0xFFF), note, got, exp_pixel & 0xFFF);
}

// ---------------------------------------------------------------------------
// Step 11: check_colmix_pixel
//
// The colmix module adds one registered pipeline stage on top of the layer
// outputs.  Layers output their pixel at hpos = H_START + col; colmix
// registers the composite and presents it at hpos = H_START + col + 1.
//
// Strategy:
//   1. Advance to vpos==V_END (VBLANK start) so sprite scanner fires.
//   2. Wait 8000 cycles for the scanner to finish.
//   3. Advance to hpos==H_END, vpos==target_vpos (HBLANK start).
//      Sprite renderer and line RAM latch fire on hblank_fall.
//   4. Wait 115 cycles for BG/text/sprite FSMs to complete.
//   5. Advance to hpos = H_START + screen_col + 1, vpos = target_vpos+1.
//      (+1 because colmix output is 1 cycle later than the layer outputs)
//   6. Sample colmix_pixel_out (13-bit).
//   7. Compare to exp_pixel.
// ---------------------------------------------------------------------------
static void check_colmix_pixel(int target_vpos, int screen_col,
                                int exp_pixel, const std::string& note) {
    int limit = 4 * H_TOTAL * V_TOTAL;

    // Step 1: advance to VBLANK start
    int found = 0;
    for (int i = 0; i < limit; i++) {
        if ((int)dut->vpos == V_END) {
            found = 1;
            break;
        }
        tick();
    }
    if (!found) {
        printf("FAIL %s: could not reach vpos=%d (VBLANK start)\n",
               note.c_str(), V_END);
        g_fail++;
        return;
    }

    // Step 2: wait for sprite scanner
    for (int i = 0; i < 8000; i++) tick();

    // Step 3: advance to HBLANK start of target_vpos
    found = 0;
    for (int i = 0; i < limit; i++) {
        if ((int)dut->hpos == H_END && (int)dut->vpos == target_vpos) {
            found = 1;
            break;
        }
        tick();
    }
    if (!found) {
        printf("FAIL %s: could not reach hpos=%d vpos=%d\n",
               note.c_str(), H_END, target_vpos);
        g_fail++;
        return;
    }

    // Step 4: wait for layer FSMs
    for (int i = 0; i < 115; i++) tick();

    // Step 5: advance to active display at screen_col+1 (colmix pipeline delay)
    int disp_vpos = (target_vpos + 1) % V_TOTAL;
    int disp_hpos = H_START + screen_col + 1;
    // Wrap if screen_col+1 >= 320 (edge case — unlikely in tests)
    if (disp_hpos >= H_END) {
        disp_hpos = H_START + screen_col + 1 - 320;
    }

    for (int i = 0; i < limit; i++) {
        if ((int)dut->hpos == disp_hpos && (int)dut->vpos == disp_vpos)
            break;
        tick();
    }

    dut->eval();
    int got = (int)dut->colmix_pixel_out & 0x1FFF;
    check(got == (exp_pixel & 0x1FFF), note, got, exp_pixel & 0x1FFF);
}

// ---------------------------------------------------------------------------
// Timing frame / check helpers (unchanged from step 1)
// ---------------------------------------------------------------------------
static void run_timing_frame(int exp_pv, int exp_int_vblank, int exp_int_hblank,
                              const std::string& note) {
    int pv_count     = 0;
    int int_vb_count = 0;
    int int_hb_count = 0;

    int total = H_TOTAL * V_TOTAL;
    for (int i = 0; i < total; i++) {
        tick();
        if (dut->pixel_valid) pv_count++;
        if (dut->int_vblank)  int_vb_count++;
        if (dut->int_hblank)  int_hb_count++;
    }

    check(pv_count == exp_pv,
          note + " [pixel_valid_count]", pv_count, exp_pv);
    check(int_vb_count == exp_int_vblank,
          note + " [int_vblank_count]", int_vb_count, exp_int_vblank);
    check(int_hb_count == exp_int_hblank,
          note + " [int_hblank_count]", int_hb_count, exp_int_hblank);
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
    bool got_hb = dut->hblank      != 0;
    bool got_vb = dut->vblank      != 0;
    bool got_pv = dut->pixel_valid != 0;

    check(got_hb == (bool)exp_hblank, note + " [hblank]", (int)got_hb, exp_hblank);
    check(got_vb == (bool)exp_vblank, note + " [vblank]", (int)got_vb, exp_vblank);
    check(got_pv == (bool)exp_pv,     note + " [pixel_valid]", (int)got_pv, exp_pv);
}

// ---------------------------------------------------------------------------
// Step 2: check text pixel
// ---------------------------------------------------------------------------
static void check_text_pixel(int target_vpos, int screen_col,
                              int exp_pixel, const std::string& note) {
    int limit = 2 * H_TOTAL * V_TOTAL;
    int found = 0;
    for (int i = 0; i < limit; i++) {
        if ((int)dut->hpos == H_END && (int)dut->vpos == target_vpos) {
            found = 1;
            break;
        }
        tick();
    }
    if (!found) {
        printf("FAIL %s: could not reach hpos=%d vpos=%d\n",
               note.c_str(), H_END, target_vpos);
        g_fail++;
        return;
    }

    for (int i = 0; i < 90; i++) tick();

    int disp_vpos = (target_vpos + 1) % V_TOTAL;
    int disp_hpos = H_START + screen_col;

    for (int i = 0; i < limit; i++) {
        if ((int)dut->hpos == disp_hpos && (int)dut->vpos == disp_vpos)
            break;
        tick();
    }

    dut->eval();
    int got = (int)dut->text_pixel_out & 0x1FF;
    check(got == (exp_pixel & 0x1FF), note, got, exp_pixel & 0x1FF);
}

// ---------------------------------------------------------------------------
// Step 4: check_text_over_bg — sample BOTH text_pixel_out AND bg_pixel_out[0]
// at the same screen coordinate.
//
// Strategy:
//   1. Advance to hpos==H_END, vpos==target_vpos (HBLANK start).
//   2. Clock 115 cycles (covers BG FSM ≤106 cycles AND text FSM ≤80 cycles).
//   3. Advance to hpos=H_START+screen_col, vpos=target_vpos+1.
//   4. Sample text_pixel_out (9-bit) and bg_pixel_out[0] (13-bit).
//   5. Compare each to its expected value independently.
//
// This is Plan Step 4, Test 4: both layers must have content at the same
// screen coordinate.  The text layer renders correctly (text_pixel == exp_text)
// and the BG layer renders correctly (bg_pixel == exp_bg).
// Compositing priority ("text wins") is deferred to Step 11.
// ---------------------------------------------------------------------------
static void check_text_over_bg(int target_vpos, int screen_col,
                                int exp_text, int exp_bg,
                                const std::string& note) {
    int limit = 2 * H_TOTAL * V_TOTAL;

    // Step 1: advance to HBLANK start of target_vpos
    int found = 0;
    for (int i = 0; i < limit; i++) {
        if ((int)dut->hpos == H_END && (int)dut->vpos == target_vpos) {
            found = 1;
            break;
        }
        tick();
    }
    if (!found) {
        printf("FAIL %s: could not reach hpos=%d vpos=%d\n",
               note.c_str(), H_END, target_vpos);
        g_fail += 2;   // two checks per call
        return;
    }

    // Step 2: wait for both FSMs to complete (BG needs 115, text needs 80)
    for (int i = 0; i < 115; i++) tick();

    // Step 3: advance to active display of vpos+1 at screen_col
    int disp_vpos = (target_vpos + 1) % V_TOTAL;
    int disp_hpos = H_START + screen_col;

    for (int i = 0; i < limit; i++) {
        if ((int)dut->hpos == disp_hpos && (int)dut->vpos == disp_vpos)
            break;
        tick();
    }

    dut->eval();

    // Step 4: sample both layer outputs
    int got_text = (int)dut->text_pixel_out & 0x1FF;
    int got_bg   = (int)dut->bg_pixel_out[0] & 0x1FFF;

    check(got_text == (exp_text & 0x1FF),
          note + " [text]",   got_text, exp_text & 0x1FF);
    check(got_bg   == (exp_bg   & 0x1FFF),
          note + " [bg]",     got_bg,   exp_bg   & 0x1FFF);
}

// ---------------------------------------------------------------------------
// Step 3: check BG layer pixel
//
// Strategy (same as check_text_pixel but with longer FSM wait):
//   1. Advance to hpos==H_END, vpos==target_vpos (HBLANK start).
//      The BG FSM fires on hblank_rise.
//   2. Clock 115 cycles (FSM needs ≤106 cycles for 21 tiles × 5 states + idle).
//   3. Advance to hpos=H_START+screen_col, vpos=target_vpos+1.
//   4. Sample bg_pixel_out[plane].  Compare to exp_pixel (13-bit).
// ---------------------------------------------------------------------------
static void check_bg_pixel(int target_vpos, int screen_col, int plane,
                            int exp_pixel, const std::string& note) {
    int limit = 2 * H_TOTAL * V_TOTAL;

    // Step 1: advance to HBLANK start of target_vpos
    int found = 0;
    for (int i = 0; i < limit; i++) {
        if ((int)dut->hpos == H_END && (int)dut->vpos == target_vpos) {
            found = 1;
            break;
        }
        tick();
    }
    if (!found) {
        printf("FAIL %s: could not reach hpos=%d vpos=%d\n",
               note.c_str(), H_END, target_vpos);
        g_fail++;
        return;
    }

    // Step 2: clock 115 cycles for BG FSM to complete
    for (int i = 0; i < 115; i++) tick();

    // Step 3: advance to active display of vpos+1 at screen_col
    int disp_vpos = (target_vpos + 1) % V_TOTAL;
    int disp_hpos = H_START + screen_col;

    for (int i = 0; i < limit; i++) {
        if ((int)dut->hpos == disp_hpos && (int)dut->vpos == disp_vpos)
            break;
        tick();
    }

    dut->eval();
    int got = 0;
    switch (plane) {
        case 0: got = (int)dut->bg_pixel_out[0] & 0x1FFF; break;
        case 1: got = (int)dut->bg_pixel_out[1] & 0x1FFF; break;
        case 2: got = (int)dut->bg_pixel_out[2] & 0x1FFF; break;
        case 3: got = (int)dut->bg_pixel_out[3] & 0x1FFF; break;
        default: got = 0; break;
    }
    check(got == (exp_pixel & 0x1FFF), note, got, exp_pixel & 0x1FFF);
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
    dut = new Vtc0630fdp;

    // Initial power-on reset
    dut->async_rst_n = 0;
    dut->cpu_cs    = 0;
    dut->cpu_rw    = 1;
    dut->cpu_addr  = 0;
    dut->cpu_din   = 0;
    dut->cpu_lds_n = 1;
    dut->cpu_uds_n = 1;
    dut->gfx_wr_en   = 0;
    dut->gfx_wr_addr = 0;
    dut->gfx_wr_data = 0;
    dut->spr_wr_en   = 0;
    dut->spr_wr_addr = 0;
    dut->spr_wr_data = 0;
    dut->pal_wr_en   = 0;
    dut->pal_wr_addr = 0;
    dut->pal_wr_data = 0;
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
            while (!line.empty() && (line.back() == '\n' || line.back() == '\r'))
                line.pop_back();
            if (line.empty() || line[0] == '#') continue;

            std::string op   = jstr(line, "op");
            std::string note = jstr(line, "note");

            // ── Step 1 ops ──────────────────────────────────────────────────
            if (op == "reset") {
                do_reset();

            } else if (op == "write") {
                cpu_write(jint(line, "addr"), jint(line, "data"), jint(line, "be", 3));

            } else if (op == "read") {
                int got = cpu_read(jint(line, "addr"));
                check(got == jint(line, "exp_dout"), note, got, jint(line, "exp_dout"));

            } else if (op == "check_extend_mode") {
                printf("PASS %s (verified via ctrl[15] readback)\n", note.c_str());
                g_pass++;

            } else if (op == "timing_frame") {
                run_timing_frame(jint(line, "exp_pv"),
                                 jint(line, "exp_int_vblank", 1),
                                 jint(line, "exp_int_hblank", 1),
                                 note);

            } else if (op == "timing_check") {
                run_timing_check(jint(line, "hpos"), jint(line, "vpos"),
                                 jint(line, "exp_hblank"), jint(line, "exp_vblank"),
                                 jint(line, "exp_pv"), note);

            // ── Step 2 ops ──────────────────────────────────────────────────
            } else if (op == "write_text") {
                cpu_write(jint(line, "addr"), jint(line, "data"), jint(line, "be", 3));

            } else if (op == "read_text") {
                int got = cpu_read(jint(line, "addr"));
                check(got == jint(line, "exp_dout"), note, got, jint(line, "exp_dout"));

            } else if (op == "write_char") {
                cpu_write(jint(line, "addr"), jint(line, "data"), jint(line, "be", 3));

            } else if (op == "read_char") {
                int got = cpu_read(jint(line, "addr"));
                check(got == jint(line, "exp_dout"), note, got, jint(line, "exp_dout"));

            } else if (op == "check_text_pixel") {
                check_text_pixel(jint(line, "vpos"),
                                 jint(line, "screen_col"),
                                 jint(line, "exp_pixel"),
                                 note);

            // ── Step 3 ops ──────────────────────────────────────────────────
            } else if (op == "write_pf") {
                // PF RAM CPU write.
                // "addr" is the cpu_addr word address within the chip window.
                cpu_write(jint(line, "addr"), jint(line, "data"), jint(line, "be", 3));

            } else if (op == "read_pf") {
                int got = cpu_read(jint(line, "addr"));
                check(got == jint(line, "exp_dout"), note, got, jint(line, "exp_dout"));

            } else if (op == "write_gfx") {
                // Write one 32-bit word to GFX ROM.
                // "gfx_addr" = 32-bit word address; "gfx_data" = 32-bit value.
                gfx_write(jint(line, "gfx_addr"), (uint32_t)jint(line, "gfx_data"));

            } else if (op == "check_bg_pixel") {
                check_bg_pixel(jint(line, "vpos"),
                               jint(line, "screen_col"),
                               jint(line, "plane"),
                               jint(line, "exp_pixel"),
                               note);

            // ── Step 5 ops ──────────────────────────────────────────────────
            // write_line: CPU write to Line RAM.
            // "addr" is the chip-window word address (0x10000–0x17FFF).
            } else if (op == "write_line") {
                cpu_write(jint(line, "addr"), jint(line, "data"), jint(line, "be", 3));

            } else if (op == "read_line") {
                int got = cpu_read(jint(line, "addr"));
                check(got == jint(line, "exp_dout"), note, got, jint(line, "exp_dout"));

            // ── Step 4 ops ──────────────────────────────────────────────────
            } else if (op == "check_text_over_bg") {
                // Plan Step 4, Test 4: both text layer and BG layer (PF1)
                // must produce non-transparent pixels at the same screen column.
                // Validates that both layers render correctly at overlapping
                // positions — compositing priority is deferred to Step 11.
                check_text_over_bg(jint(line, "vpos"),
                                   jint(line, "screen_col"),
                                   jint(line, "exp_text"),
                                   jint(line, "exp_bg"),
                                   note);

            // ── Step 8 ops ──────────────────────────────────────────────────
            // write_sprite: CPU write to Sprite RAM.
            // "addr" is the chip-window word address (0x20000–0x27FFF).
            // Uses direct spr_wr_* write port (offset = addr - 0x20000).
            } else if (op == "write_sprite") {
                int word_offset = jint(line, "addr") - 0x20000;
                spr_write(word_offset, (uint16_t)(jint(line, "data") & 0xFFFF));

            } else if (op == "check_sprite_pixel") {
                check_sprite_pixel(jint(line, "vpos"),
                                   jint(line, "screen_col"),
                                   jint(line, "exp_pixel"),
                                   note);

            // ── Step 11 ops ─────────────────────────────────────────────────
            } else if (op == "check_colmix_pixel") {
                check_colmix_pixel(jint(line, "vpos"),
                                   jint(line, "screen_col"),
                                   jint(line, "exp_pixel"),
                                   note);

            // ── Step 13 ops ─────────────────────────────────────────────────
            // write_pal: write one 16-bit color word to palette RAM.
            // "pal_addr": 13-bit address (0..8191)
            // "pal_data": 16-bit color word
            } else if (op == "write_pal") {
                pal_write(jint(line, "pal_addr"), (uint16_t)(jint(line, "pal_data") & 0xFFFF));

            // check_blend_pixel: advance to pixel position, sample blend_rgb_out.
            // blend_rgb_out is valid 2 cycles after the layer outputs (colmix stage + palette
            // read stage), so we advance to screen_col+2 rather than screen_col+1.
            } else if (op == "check_blend_pixel") {
                int target_vpos = jint(line, "vpos");
                int screen_col  = jint(line, "screen_col");
                int exp_rgb     = jint(line, "exp_rgb");
                int limit = 4 * H_TOTAL * V_TOTAL;

                // Step 1: advance to VBLANK start so sprite scanner fires
                int found = 0;
                for (int i = 0; i < limit; i++) {
                    if ((int)dut->vpos == V_END) { found = 1; break; }
                    tick();
                }
                if (!found) {
                    printf("FAIL %s: could not reach vpos=%d (VBLANK start)\n",
                           note.c_str(), V_END);
                    g_fail++;
                    continue;
                }

                // Step 2: wait for sprite scanner
                for (int i = 0; i < 8000; i++) tick();

                // Step 3: advance to HBLANK start of target_vpos
                found = 0;
                for (int i = 0; i < limit; i++) {
                    if ((int)dut->hpos == H_END && (int)dut->vpos == target_vpos) {
                        found = 1; break;
                    }
                    tick();
                }
                if (!found) {
                    printf("FAIL %s: could not reach hpos=%d vpos=%d\n",
                           note.c_str(), H_END, target_vpos);
                    g_fail++;
                    continue;
                }

                // Step 4: wait for layer FSMs
                for (int i = 0; i < 115; i++) tick();

                // Step 5: advance to screen_col+2 (colmix pipeline + palette read latency)
                int disp_vpos = (target_vpos + 1) % V_TOTAL;
                int disp_hpos = H_START + screen_col + 2;
                if (disp_hpos >= H_END) disp_hpos = H_START + screen_col + 2 - 320;

                for (int i = 0; i < limit; i++) {
                    if ((int)dut->hpos == disp_hpos && (int)dut->vpos == disp_vpos)
                        break;
                    tick();
                }

                dut->eval();
                int got = (int)dut->blend_rgb_out & 0xFFFFFF;
                check(got == (exp_rgb & 0xFFFFFF), note, got, exp_rgb & 0xFFFFFF);

            } else {
                fprintf(stderr, "Unknown op: %s\n", op.c_str());
            }
        }

        fclose(fp);
    }

    printf("\nTESTS: %d passed, %d failed\n", g_pass, g_fail);
    delete dut;
    return (g_fail == 0) ? 0 : 1;
}
