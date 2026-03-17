// =============================================================================
// X1-001A Phase 1 + Phase 2 — Verilator testbench
//
// Reads gate1_vectors.jsonl, gate4_vectors.jsonl, and gate5_vectors.jsonl.
//
// Supported op codes:
//
// Gate 1 (Y RAM):
//   zero_yram      — clear Y RAM in DUT via CPU writes
//   yram_write     — addr, data, be
//   yram_read      — addr, exp
//   yram_scan_rd   — addr, exp
//
// Gate 4 (All RAMs + control registers):
//   reset          — pulse rst_n low then high
//   yram_write     — addr, data, be
//   yram_read      — addr, exp
//   yram_scan_rd   — addr, exp
//   cram_write     — addr, data, be
//   cram_read      — addr, exp
//   cram_scan_rd   — addr, exp
//   ctrl_write     — addr, data, be
//   ctrl_read      — addr, exp
//   check_flip_screen    — exp (0 or 1)
//   check_bg_startcol    — exp (0..3)
//   check_bg_numcol      — exp (0..15)
//   check_frame_bank     — exp (0 or 1)
//   check_col_upper_mask — exp (16-bit)
//
// Gate 5 (Phase 2 sprite rendering):
//   load_gfx_word  — addr (18-bit word addr), data (16-bit)
//   run_frame      — runs one full VBlank period through the scanner FSM;
//                    drives timing signals for SCREEN_H scanlines
//   check_pixel    — x, y, exp_color (5-bit), exp_valid (0 or 1)
//                    checks pixel at (x,y) in the rendered frame
//
// GFX ROM model:
//   64K × 16-bit words (18-bit address, word 0..0x3FFFF).
//   Zero-latency: gfx_ack mirrors gfx_req before every eval().
//
// Timing model for run_frame:
//   - Pulse vblank high for VBLANK_LINES scanlines (scanner runs)
//   - Then drive SCREEN_H active scanlines with hblank/hpos/vpos
//   - check_pixel queries the internal linebuf state after run_frame completes
//
// Exit: 0 = all pass, 1 = any failure.
// =============================================================================

#include "Vx1_001a.h"
#include "Vx1_001a_x1_001a.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdint.h>
#include <string>
#include <fstream>
#include <vector>
#include <array>

// Screen geometry (must match RTL parameters)
static constexpr int SCREEN_H        = 240;
static constexpr int SCREEN_W        = 384;
static constexpr int SPRITE_LIMIT    = 511;
static constexpr int VBLANK_LINES    = 8;     // cycles to hold vblank high
static constexpr int HBLANK_CYCLES   = 128;   // cycles per hblank within each line
static constexpr int LINE_CYCLES     = SCREEN_W + HBLANK_CYCLES;

// GFX ROM size: 2^18 words of 16-bit
static constexpr int GFX_ROM_WORDS   = 1 << 18;

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

static int jint(const std::string& s, const std::string& key, int dflt = -999) {
    auto p = jfind(s, key);
    if (p == std::string::npos) return dflt;
    return (int)strtol(s.c_str() + p, nullptr, 0);
}

static std::string jstr(const std::string& s, const std::string& key) {
    auto p = jfind(s, key);
    if (p == std::string::npos || s[p] != '"') return "";
    p++;
    auto end = s.find('"', p);
    if (end == std::string::npos) return "";
    return s.substr(p, end - p);
}

// ---------------------------------------------------------------------------
// DUT wrapper
// ---------------------------------------------------------------------------
struct DUT {
    Vx1_001a* top;
    uint64_t  cycle;
    int       failures;
    int       checks;

    // GFX ROM (word-addressed, 16-bit words)
    std::vector<uint16_t> gfx_rom;

    // Rendered frame pixel buffer: [y][x] = {valid, color[4:0]}
    // Populated by run_frame()
    uint8_t framebuf[SCREEN_H][SCREEN_W];  // 6-bit entries: [5]=valid [4:0]=color

    DUT() : cycle(0), failures(0), checks(0) {
        top = new Vx1_001a();
        gfx_rom.assign(GFX_ROM_WORDS, 0);
        memset(framebuf, 0, sizeof(framebuf));
        reset();
    }

    ~DUT() { delete top; }

    // Drive gfx_ack = gfx_req before eval (zero-latency ROM model)
    // Also serve gfx_data from our ROM array.
    void update_gfx() {
        top->gfx_ack  = top->gfx_req;
        uint32_t addr = top->gfx_addr & 0x3FFFF;
        top->gfx_data = gfx_rom[addr];
    }

    void clk(int n = 1) {
        for (int i = 0; i < n; i++) {
            top->clk = 0;
            update_gfx();
            top->eval();
            top->clk = 1;
            update_gfx();
            top->eval();
            cycle++;
        }
    }

    void reset() {
        top->rst_n       = 0;
        top->yram_cs     = 0;
        top->yram_we     = 0;
        top->yram_addr   = 0;
        top->yram_din    = 0;
        top->yram_be     = 3;
        top->cram_cs     = 0;
        top->cram_we     = 0;
        top->cram_addr   = 0;
        top->cram_din    = 0;
        top->cram_be     = 3;
        top->ctrl_cs     = 0;
        top->ctrl_we     = 0;
        top->ctrl_addr   = 0;
        top->ctrl_din    = 0;
        top->ctrl_be     = 3;
        top->scan_yram_addr = 0;
        top->scan_cram_addr = 0;
        top->vblank      = 0;
        top->hblank      = 0;
        top->hpos        = 0;
        top->vpos        = 0;
        top->gfx_ack     = 0;
        top->gfx_data    = 0;
        clk(4);
        top->rst_n = 1;
        clk(4);
    }

    // ── Y RAM access ──────────────────────────────────────────────────────────
    void yram_write(int addr, int data, int be = 3) {
        top->yram_cs   = 1;
        top->yram_we   = 1;
        top->yram_addr = addr & 0x3FF;
        top->yram_din  = data & 0xFFFF;
        top->yram_be   = be & 3;
        clk(2);
        top->yram_cs = 0;
        top->yram_we = 0;
    }

    uint16_t yram_read(int addr) {
        top->yram_cs   = 1;
        top->yram_we   = 0;
        top->yram_addr = addr & 0x3FF;
        top->yram_be   = 3;
        clk(2);
        uint16_t d = top->yram_dout;
        top->yram_cs = 0;
        return d;
    }

    uint16_t yram_scan_read(int addr) {
        top->scan_yram_addr = addr & 0x3FF;
        clk(2);
        return top->scan_yram_data;
    }

    void zero_yram() {
        for (int a = 0; a < 0x180; a++) {
            top->yram_cs   = 1;
            top->yram_we   = 1;
            top->yram_addr = a;
            top->yram_din  = 0;
            top->yram_be   = 3;
            clk(1);
        }
        top->yram_cs = 0;
        top->yram_we = 0;
        clk(1);
    }

    // ── Code RAM access ───────────────────────────────────────────────────────
    void cram_write(int addr, int data, int be = 3) {
        top->cram_cs   = 1;
        top->cram_we   = 1;
        top->cram_addr = addr & 0x1FFF;
        top->cram_din  = data & 0xFFFF;
        top->cram_be   = be & 3;
        clk(2);
        top->cram_cs = 0;
        top->cram_we = 0;
    }

    uint16_t cram_read(int addr) {
        top->cram_cs   = 1;
        top->cram_we   = 0;
        top->cram_addr = addr & 0x1FFF;
        top->cram_be   = 3;
        clk(2);
        uint16_t d = top->cram_dout;
        top->cram_cs = 0;
        return d;
    }

    uint16_t cram_scan_read(int addr) {
        top->scan_cram_addr = addr & 0x1FFF;
        clk(2);
        return top->scan_cram_data;
    }

    // ── Control register access ───────────────────────────────────────────────
    void ctrl_write(int addr, int data, int be = 3) {
        top->ctrl_cs   = 1;
        top->ctrl_we   = 1;
        top->ctrl_addr = addr & 3;
        top->ctrl_din  = data & 0xFFFF;
        top->ctrl_be   = be & 3;
        clk(2);
        top->ctrl_cs = 0;
        top->ctrl_we = 0;
    }

    uint16_t ctrl_read(int addr) {
        top->ctrl_cs   = 1;
        top->ctrl_we   = 0;
        top->ctrl_addr = addr & 3;
        top->ctrl_be   = 3;
        clk(2);
        uint16_t d = top->ctrl_dout;
        top->ctrl_cs = 0;
        return d;
    }

    // ── GFX ROM load ──────────────────────────────────────────────────────────
    void load_gfx_word(int addr, int data) {
        if (addr >= 0 && addr < GFX_ROM_WORDS)
            gfx_rom[addr] = (uint16_t)(data & 0xFFFF);
    }

    // Load a full 16×16 tile (128 bytes = 64 words) into the GFX ROM.
    // tile_pixels[row][col] = 4-bit color index (0=transparent)
    void load_tile(int tile_code, uint8_t pixels[16][16]) {
        int base = tile_code * 64;
        for (int row = 0; row < 16; row++) {
            for (int w = 0; w < 4; w++) {
                uint16_t word = 0;
                for (int n = 0; n < 4; n++) {
                    int px = w * 4 + n;
                    word = (word << 4) | (pixels[row][px] & 0xF);
                }
                gfx_rom[base + row * 4 + w] = word;
            }
        }
    }

    // ── Run one VBlank frame ──────────────────────────────────────────────────
    // Drives the timing signals through one complete frame:
    //   1. Assert vblank for VBLANK_LINES * LINE_CYCLES cycles
    //      (scanner FSM runs; GFX ROM responses are zero-latency)
    //   2. Deassert vblank; drive SCREEN_H scanlines of active video
    //      (each line: SCREEN_W active cycles + HBLANK_CYCLES hblank)
    //   3. Capture pixel outputs into framebuf[][]
    //
    // The scanner runs until scan_active deasserts.  We give it at most
    // SPRITE_LIMIT * (2 + 16*7) cycles to complete.
    //
    // Double-buffer pipeline delay:
    //   On vblank_rise the RTL swaps linebuf_bank.  The scanner writes to
    //   ~linebuf_bank (the write bank).  The display reads from linebuf_bank
    //   (the bank rendered during the PREVIOUS vblank).  Therefore we must
    //   run TWO vblank/scan cycles so that the freshly rendered pixels end
    //   up in the display bank during the second active-video phase.
    //   Pass 0 (warm-up): scanner fills write bank; no pixel capture.
    //   Pass 1 (capture): bank swaps again, write bank becomes display bank;
    //                     scanner fills the new write bank; active video reads
    //                     the pixels written during pass 0.

    // Run one vblank + scan cycle (no pixel capture).
    void run_vblank_scan() {
        auto* pvt = top->__PVT__x1_001a;
        // Debug: show CRAM[0x200] (x_ptr for sprite 0) before scan
        uint16_t cram200 = ((uint16_t)pvt->__PVT__cram_hi[0x200] << 8) | pvt->__PVT__cram_lo[0x200];
        uint16_t cram0   = ((uint16_t)pvt->__PVT__cram_hi[0] << 8) | pvt->__PVT__cram_lo[0];
        fprintf(stderr, "  DEBUG pre-scan: cram[0]=0x%04X cram[0x200]=0x%04X yram_lo[0]=0x%02X frame_bank=%d\n",
                cram0, cram200, (int)pvt->__PVT__yram_lo[0], (int)top->frame_bank);
        top->vblank = 1;
        top->hblank = 0;
        top->hpos   = 0;
        top->vpos   = 0;
        clk(2);  // let vblank_rise propagate

        int timeout = (SPRITE_LIMIT + 1) * 200;
        int i = 0;
        for (; i < timeout; i++) {
            clk(1);
            // Debug: monitor linebuf every cycle in last 200
            if (i > 50480) {
                fprintf(stderr, "    cycle %d: linebuf[0][100][50]=%02X do_write=%d pix_en[0]=%d fsm=%d spr_color=%d scan_idx=%d wr_y=%d wr_sx=%d\n",
                    i, (int)pvt->__PVT__linebuf[0][100][50],
                    (int)pvt->__PVT__do_write, (int)pvt->__PVT__pix_en[0],
                    (int)pvt->__PVT__fsm_state, (int)pvt->__PVT__spr_color,
                    (int)pvt->__PVT__scan_idx, (int)pvt->__PVT__wr_y, (int)pvt->__PVT__wr_sx);
            }
            if (!top->scan_active)
                break;
        }
        fprintf(stderr, "DEBUG run_vblank_scan: completed in %d cycles, scan_active=%d, linebuf_bank=%d\n",
                i, (int)top->scan_active, (int)pvt->__PVT__linebuf_bank);
        // Sample linebuf at expected sprite location (50,100) in both banks
        fprintf(stderr, "  linebuf[0][100][50]=0x%02X  linebuf[1][100][50]=0x%02X\n",
                (int)pvt->__PVT__linebuf[0][100][50],
                (int)pvt->__PVT__linebuf[1][100][50]);
        fprintf(stderr, "  pix_en[0]=%d do_write=%d wr_y=%d spr_color=%d\n",
                (int)pvt->__PVT__pix_en[0], (int)pvt->__PVT__do_write,
                (int)pvt->__PVT__wr_y, (int)pvt->__PVT__spr_color);

        top->vblank = 0;
        clk(2);
    }

    // Run active-video phase and capture pixels into framebuf[][].
    void run_active_video() {
        for (int y = 0; y < SCREEN_H; y++) {
            top->vpos = (uint8_t)y;

            // Active pixels
            top->hblank = 0;
            for (int x = 0; x < SCREEN_W; x++) {
                top->hpos = (uint16_t)x;
                // Sample pixel output (combinational)
                top->clk = 0;
                update_gfx();
                top->eval();
                // Capture before posedge
                if (top->pix_valid)
                    framebuf[y][x] = (uint8_t)(0x20 | (top->pix_color & 0x1F));
                else
                    framebuf[y][x] = 0;
                top->clk = 1;
                update_gfx();
                top->eval();
                cycle++;
            }

            // HBlank — triggers clear sweep in DUT
            top->hblank = 1;
            for (int hb = 0; hb < HBLANK_CYCLES; hb++) {
                top->hpos = (uint16_t)(SCREEN_W + hb);
                clk(1);
            }
            top->hblank = 0;
        }
    }

    void dump_framebuf_region(int x0, int y0, int x1, int y1) {
        for (int y = y0; y <= y1 && y < SCREEN_H; y++) {
            fprintf(stderr, "  row %3d:", y);
            for (int x = x0; x <= x1 && x < SCREEN_W; x++) {
                uint8_t e = framebuf[y][x];
                if (e & 0x20) fprintf(stderr, " %02X", e & 0x1F);
                else          fprintf(stderr, " --");
            }
            fprintf(stderr, "\n");
        }
    }

    void run_frame() {
        // Double-buffer pipeline delay:
        //   vblank_rise swaps linebuf_bank; scanner writes to ~linebuf_bank (write bank);
        //   display reads from linebuf_bank (the bank rendered the previous vblank).
        //
        //   We need the freshly-rendered pixels in the DISPLAY bank at capture time.
        //   Running active-video between the two scans would trigger HBlank clear sweeps
        //   that wipe the write bank (our freshly rendered pixels) before the bank swap
        //   makes them visible.  So we run two back-to-back vblank scans with NO active
        //   video in between:
        //
        //   Scan 0: linebuf_bank flips; scanner writes render-0 to write bank.
        //           vblank goes low.  No active video → no HBlank → write bank intact.
        //   Scan 1: linebuf_bank flips again; render-0 becomes the display bank;
        //           scanner writes render-1 to new write bank.  vblank goes low.
        //   Capture: active-video reads display bank (= render-0).  HBlank clears the
        //            new write bank (render-1); that's fine — we already captured render-0.

        run_vblank_scan();   // scan 0: render-0 → write bank
        run_vblank_scan();   // scan 1: bank swap → render-0 is now display bank

        // Active-video capture: reads display bank (= render-0 pixels).
        run_active_video();

        // Debug: dump framebuf around expected sprite location (first test: 50,100)
        fprintf(stderr, "DEBUG framebuf[98..102][48..68]:\n");
        dump_framebuf_region(48, 98, 68, 102);
    }

    // ── Check helper ──────────────────────────────────────────────────────────
    void check(const char* label, int got, int exp) {
        checks++;
        if (got != exp) {
            fprintf(stderr, "FAIL  %s: got 0x%04X exp 0x%04X\n", label, got, exp);
            failures++;
        } else {
            fprintf(stderr, "pass  %s: 0x%04X\n", label, got);
        }
    }

    void check_pixel(int x, int y, int exp_color, int exp_valid) {
        checks++;
        char lbl[64];
        snprintf(lbl, sizeof(lbl), "pixel(%d,%d)", x, y);

        if (x < 0 || x >= SCREEN_W || y < 0 || y >= SCREEN_H) {
            fprintf(stderr, "FAIL  %s: out of bounds\n", lbl);
            failures++;
            return;
        }

        uint8_t entry    = framebuf[y][x];
        int got_valid    = (entry >> 5) & 1;
        int got_color    = entry & 0x1F;

        bool ok = (got_valid == exp_valid) && (!exp_valid || (got_color == exp_color));
        if (!ok) {
            fprintf(stderr,
                "FAIL  %s: got valid=%d color=0x%02X  exp valid=%d color=0x%02X\n",
                lbl, got_valid, got_color, exp_valid, exp_color);
            failures++;
        } else {
            if (exp_valid)
                fprintf(stderr, "pass  %s: valid=1 color=0x%02X\n", lbl, got_color);
            else
                fprintf(stderr, "pass  %s: transparent\n", lbl);
        }
    }
};

// ---------------------------------------------------------------------------
// Process one vector file
// ---------------------------------------------------------------------------
static int run_vectors(DUT& dut, const char* path) {
    std::ifstream f(path);
    if (!f.is_open()) {
        fprintf(stderr, "ERROR: cannot open %s\n", path);
        return 1;
    }

    fprintf(stderr, "\n=== %s ===\n", path);
    std::string line;
    int line_num = 0;

    while (std::getline(f, line)) {
        line_num++;
        if (line.empty() || line[0] == '#') continue;

        std::string op = jstr(line, "op");
        int addr = jint(line, "addr", 0);
        int data = jint(line, "data", 0);
        int be   = jint(line, "be",   3);
        int exp  = jint(line, "exp",  0);

        if (op == "zero_yram") {
            dut.zero_yram();

        } else if (op == "reset") {
            dut.reset();

        } else if (op == "yram_write") {
            dut.yram_write(addr, data, be);

        } else if (op == "yram_read") {
            uint16_t got = dut.yram_read(addr);
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "yram_rd[0x%03X]", addr);
            dut.check(lbl, got, exp);

        } else if (op == "yram_scan_rd") {
            uint16_t got = dut.yram_scan_read(addr);
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "yram_scan[0x%03X]", addr);
            dut.check(lbl, got, exp);

        } else if (op == "cram_write") {
            dut.cram_write(addr, data, be);

        } else if (op == "cram_read") {
            uint16_t got = dut.cram_read(addr);
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "cram_rd[0x%04X]", addr);
            dut.check(lbl, got, exp);

        } else if (op == "cram_scan_rd") {
            uint16_t got = dut.cram_scan_read(addr);
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "cram_scan[0x%04X]", addr);
            dut.check(lbl, got, exp);

        } else if (op == "ctrl_write") {
            dut.ctrl_write(addr, data, be);

        } else if (op == "ctrl_read") {
            uint16_t got = dut.ctrl_read(addr);
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "ctrl_rd[%d]", addr);
            dut.check(lbl, got, exp);

        } else if (op == "check_flip_screen") {
            int got = (int)dut.top->flip_screen;
            dut.check("flip_screen", got, exp);

        } else if (op == "check_bg_startcol") {
            int got = (int)dut.top->bg_startcol;
            dut.check("bg_startcol", got, exp);

        } else if (op == "check_bg_numcol") {
            int got = (int)dut.top->bg_numcol;
            dut.check("bg_numcol", got, exp);

        } else if (op == "check_frame_bank") {
            int got = (int)dut.top->frame_bank;
            dut.check("frame_bank", got, exp);

        } else if (op == "check_col_upper_mask") {
            int got = (int)dut.top->col_upper_mask;
            dut.check("col_upper_mask", got, exp);

        // ── Phase 2 ops ─────────────────────────────────────────────────────
        } else if (op == "load_gfx_word") {
            dut.load_gfx_word(addr, data);

        } else if (op == "run_frame") {
            dut.run_frame();

        } else if (op == "check_pixel") {
            int x         = jint(line, "x", 0);
            int y         = jint(line, "y", 0);
            int exp_color = jint(line, "exp_color", 0);
            int exp_valid = jint(line, "exp_valid", 0);
            dut.check_pixel(x, y, exp_color, exp_valid);

        } else {
            fprintf(stderr, "WARNING: unknown op '%s' at line %d\n",
                    op.c_str(), line_num);
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    if (argc < 2) {
        fprintf(stderr, "Usage: %s <vec1.jsonl> [vec2.jsonl ...]\n", argv[0]);
        return 1;
    }

    DUT dut;
    int err = 0;

    for (int i = 1; i < argc; i++) {
        err |= run_vectors(dut, argv[i]);
    }

    fprintf(stderr, "\n=== Results: %d checks, %d failures ===\n",
            dut.checks, dut.failures);

    if (dut.failures > 0 || err) {
        fprintf(stderr, "FAIL\n");
        return 1;
    }
    fprintf(stderr, "PASS\n");
    return 0;
}
