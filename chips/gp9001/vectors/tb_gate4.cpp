// =============================================================================
// GP9001 Gate 4 — Verilator testbench
//
// Reads gate4_vectors.jsonl and drives the gp9001 DUT through the sprite
// rasterizer (Gate 4) path.
//
// Supported op codes:
//
//   reset             — pulse rst_n low then high
//   vsync_pulse       — pulse vsync for shadow→active register staging
//   write_sram        — addr, data: write sprite RAM word at addr[9:0]
//   write_sprite_ctrl — data: write SPRITE_CTRL register (addr=0x0A) + vsync_pulse
//   vblank_scan       — assert vblank for ~32 cycles to let Gate 2 FSM scan
//                        all sprites and set display_list_ready
//   write_spr_rom     — addr, data: write sprite ROM byte in testbench memory
//   scan_line         — scanline: pulse scan_trigger, drive current_scanline,
//                        then clock until spr_render_done or timeout
//   check_spr         — x, exp_valid, exp_color, exp_prio:
//                        set spr_rd_addr=x, check spr_rd_valid/color/priority
//
// Sprite ROM model:
//   2MB byte array in testbench.  spr_rom_data is driven combinationally
//   (zero latency): after each negedge, look up spr_rom[spr_rom_addr].
//   bg_rom_data is also driven (unused by Gate 4 but needed to avoid X propagation).
//
// Timing for vblank_scan:
//   Assert vblank=1 for VBLANK_CYCLES clocks.  The Gate 2 FSM transitions on
//   vblank rising edge and processes all sprites, then asserts display_list_ready.
//   We clock until display_list_ready or VBLANK_CYCLES max.
//
// Timing for scan_line:
//   Pulse scan_trigger=1 for 1 cycle with current_scanline set.
//   Then clock until spr_render_done goes high (or SCAN_TIMEOUT).
//
// Exit: 0 = all pass, 1 = any failure.
// =============================================================================

#include "Vgp9001.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdint.h>
#include <string>
#include <fstream>
#include <vector>

// Timing constants
static constexpr int VBLANK_CYCLES  = 512;    // enough for Gate 2 to scan 32 sprites
static constexpr int SCAN_TIMEOUT   = 4096;   // max cycles for Gate 4 to finish one scanline

// Sprite ROM: 2MB
static constexpr int SPR_ROM_SIZE   = 1 << 21;

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

static int jint(const std::string& s, const std::string& key, int dflt = -1) {
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
    Vgp9001*             top;
    uint64_t             cycle;
    int                  failures;
    int                  checks;

    // Sprite ROM: 2MB, combinationally read
    std::vector<uint8_t> spr_rom;

    // BG tile ROM (not used in gate4 tests but must not produce X)
    static const int TILE_ROM_SIZE = 1 << 20;
    std::vector<uint8_t> tile_rom;

    DUT() : cycle(0), failures(0), checks(0) {
        top     = new Vgp9001();
        spr_rom.assign(SPR_ROM_SIZE, 0);
        tile_rom.assign(TILE_ROM_SIZE, 0);
        reset_inputs();
        reset();
    }

    ~DUT() {
        top->final();
        delete top;
    }

    void reset_inputs() {
        top->rst_n            = 0;
        top->cs_n             = 1;
        top->rd_n             = 1;
        top->wr_n             = 1;
        top->addr             = 0;
        top->din              = 0;
        top->vsync            = 0;
        top->vblank           = 0;
        top->scan_addr        = 0;
        top->hpos             = 0;
        top->vpos             = 0;
        top->hblank           = 0;
        top->vblank_in        = 0;
        top->bg_rom_data      = 0;
        top->scan_trigger     = 0;
        top->current_scanline = 0;
        top->spr_rom_data     = 0;
        top->spr_rd_addr      = 0;
    }

    // Tick one clock.  Drive both ROMs combinationally.
    void clk_tick(int n = 1) {
        for (int i = 0; i < n; i++) {
            top->clk = 0;
            top->eval();
            // Drive sprite ROM combinationally
            uint32_t spr_addr = top->spr_rom_addr & (SPR_ROM_SIZE - 1);
            top->spr_rom_data = spr_rom[spr_addr];
            // Drive BG tile ROM combinationally
            uint32_t bg_addr  = top->bg_rom_addr & 0xFFFFF;
            top->bg_rom_data  = tile_rom[bg_addr];
            top->clk = 1;
            top->eval();
            ++cycle;
        }
    }

    void reset() {
        reset_inputs();
        clk_tick(4);
        top->rst_n = 1;
        clk_tick(4);
    }

    // ── Control register write ────────────────────────────────────────────
    void write_reg(int addr_offset, int data) {
        top->addr = (uint32_t)(addr_offset & 0xF);
        top->din  = (uint16_t)(data & 0xFFFF);
        top->cs_n = 0;
        top->wr_n = 0;
        top->rd_n = 1;
        clk_tick(1);
        top->cs_n = 1;
        top->wr_n = 1;
        clk_tick(1);
    }

    // ── Sprite RAM write (addr[9:8] = 01, addr[9:0] = word index) ─────────
    void write_sram(int word_idx, int data) {
        // addr[9:8] = 2'b01 to select sprite RAM
        top->addr = (uint32_t)(0x100 | (word_idx & 0xFF));
        top->din  = (uint16_t)(data & 0xFFFF);
        top->cs_n = 0;
        top->wr_n = 0;
        top->rd_n = 1;
        clk_tick(1);
        top->cs_n = 1;
        top->wr_n = 1;
        clk_tick(1);
    }

    // ── vsync pulse (shadow→active staging) ──────────────────────────────
    void vsync_pulse() {
        top->vsync = 1;
        clk_tick(2);
        top->vsync = 0;
        clk_tick(2);
    }

    // ── vblank scan: assert vblank, clock until display_list_ready ────────
    // If display_list_ready pulses within VBLANK_CYCLES, deassert vblank.
    void vblank_scan() {
        top->vblank = 1;
        bool done = false;
        for (int i = 0; i < VBLANK_CYCLES && !done; i++) {
            clk_tick(1);
            if (top->display_list_ready) {
                done = true;
            }
        }
        top->vblank = 0;
        clk_tick(4);   // settle

        if (!done) {
            fprintf(stderr, "WARNING: vblank_scan: display_list_ready not seen "
                    "within %d cycles\n", VBLANK_CYCLES);
        }
    }

    // ── scan_line: pulse scan_trigger, wait for spr_render_done ──────────
    // Returns true if spr_render_done seen within SCAN_TIMEOUT cycles.
    bool scan_line(int scanline) {
        top->current_scanline = (uint16_t)(scanline & 0x1FF);
        top->scan_trigger     = 1;
        clk_tick(1);
        top->scan_trigger     = 0;

        for (int i = 0; i < SCAN_TIMEOUT; i++) {
            clk_tick(1);
            if (top->spr_render_done) {
                clk_tick(1);  // let outputs settle after done pulse
                return true;
            }
        }
        fprintf(stderr, "WARNING: scan_line(%d): spr_render_done not seen "
                "within %d cycles\n", scanline, SCAN_TIMEOUT);
        return false;
    }

    // ── Check helper ──────────────────────────────────────────────────────
    void check(const char* label, int got, int exp) {
        ++checks;
        if (got != exp) {
            fprintf(stderr, "FAIL  %s: got 0x%04X exp 0x%04X\n", label, got, exp);
            ++failures;
        } else {
            fprintf(stderr, "pass  %s: 0x%04X\n", label, got);
        }
    }

    // ── Read one pixel from the sprite scanline buffer ────────────────────
    // Set spr_rd_addr, eval (combinational), read back.
    void set_rd_addr(int x) {
        top->spr_rd_addr = (uint16_t)(x & 0x1FF);
        top->clk = 0;
        top->eval();
        // Also update ROM data while we're here
        uint32_t spr_addr = top->spr_rom_addr & (SPR_ROM_SIZE - 1);
        top->spr_rom_data = spr_rom[spr_addr];
        uint32_t bg_addr  = top->bg_rom_addr & 0xFFFFF;
        top->bg_rom_data  = tile_rom[bg_addr];
        top->clk = 0;
        top->eval();  // settle combinational
    }

    int get_spr_color()    { return (int)(uint8_t)top->spr_rd_color; }
    int get_spr_valid()    { return (int)(top->spr_rd_valid & 1); }
    int get_spr_priority() { return (int)(top->spr_rd_priority & 1); }
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
        ++line_num;
        if (line.empty() || line[0] == '#') continue;

        std::string op = jstr(line, "op");

        if (op == "reset") {
            dut.reset();

        } else if (op == "vsync_pulse") {
            dut.vsync_pulse();

        } else if (op == "write_sram") {
            int addr = jint(line, "addr", 0);
            int data = jint(line, "data", 0);
            dut.write_sram(addr, data);

        } else if (op == "write_sprite_ctrl") {
            int data = jint(line, "data", 0);
            dut.write_reg(0x0A, data);   // SPRITE_CTRL register
            dut.vsync_pulse();           // stage shadow → active

        } else if (op == "vblank_scan") {
            dut.vblank_scan();

        } else if (op == "write_spr_rom") {
            int addr = jint(line, "addr", 0);
            int data = jint(line, "data", 0);
            uint32_t a = (uint32_t)addr & (SPR_ROM_SIZE - 1);
            dut.spr_rom[a] = (uint8_t)(data & 0xFF);

        } else if (op == "scan_line") {
            int scanline = jint(line, "scanline", 0);
            dut.scan_line(scanline);

        } else if (op == "check_spr") {
            int x          = jint(line, "x",          0);
            int exp_valid  = jint(line, "exp_valid",   0);
            int exp_color  = jint(line, "exp_color",   0);
            int exp_prio   = jint(line, "exp_prio",    0);

            dut.set_rd_addr(x);

            char lbl_v[64], lbl_c[64], lbl_p[64];
            snprintf(lbl_v, sizeof(lbl_v), "spr_valid[%d]",   x);
            snprintf(lbl_c, sizeof(lbl_c), "spr_color[%d]",   x);
            snprintf(lbl_p, sizeof(lbl_p), "spr_prio[%d]",    x);

            dut.check(lbl_v, dut.get_spr_valid(), exp_valid);
            if (exp_valid) {
                dut.check(lbl_c, dut.get_spr_color(),    exp_color);
                dut.check(lbl_p, dut.get_spr_priority(), exp_prio);
            }

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
        fprintf(stderr, "Usage: %s <gate4_vectors.jsonl> [...]\n", argv[0]);
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
