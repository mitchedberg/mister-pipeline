// =============================================================================
// GP9001 Gate 5 — Verilator testbench
//
// Reads gate5_vectors.jsonl and exercises the priority mixer (Gate 5).
//
// Gate 5 is purely combinational: it reads
//   spr_rd_valid / spr_rd_color / spr_rd_priority   (Gate 4 read-back)
//   bg_pix_valid / bg_pix_color / bg_pix_priority   (Gate 3 outputs, per layer)
//   layer_ctrl                                       (active register)
// and produces:
//   final_valid, final_color
//
// To inject a known sprite pixel at position x=0:
//   - Write sprite ROM with a solid-fill tile
//   - Write sprite RAM at slot 0 (position x=0, y=0)
//   - Run vblank_scan + scan_line(0)
//   - Set spr_rd_addr=0
// For a transparent sprite: use null sprite RAM entries.
//
// To inject a known BG pixel for layer L at position (0,0):
//   - Write VRAM cell 0 of layer L (code + attr words)
//   - Write tile ROM bytes for the BG tile
//   - Drive hpos=0, vpos=0, hblank=0, vblank_in=0
//   - Clock ≥8 cycles so Gate 3 pipeline settles
//
// Supported op codes:
//
//   reset                              — pulse rst_n low then high
//   vsync_pulse                        — pulse vsync for shadow→active staging
//   write_sram   addr, data            — write sprite RAM word
//   write_sprite_ctrl  data            — write SPRITE_CTRL + vsync_pulse
//   vblank_scan                        — assert vblank; wait for display_list_ready
//   write_spr_rom  addr, data          — write sprite ROM byte
//   scan_line   scanline               — pulse scan_trigger; wait for spr_render_done
//   set_spr_rd_addr  x                 — set spr_rd_addr (sprite buffer read port)
//   write_reg    addr, data            — write control register addr[3:0]
//   write_vram   layer, addr, data     — write VRAM (select layer via VRAM_SEL, then write)
//   write_rom_byte  addr, data         — write BG tile ROM byte in testbench memory
//   set_pixel    hpos, vpos            — drive hpos/vpos (hblank=0, vblank_in=0)
//   clock_n      n                     — advance n clock cycles
//   check_final  exp_valid, exp_color  — check final_valid and final_color outputs
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
static constexpr int VBLANK_CYCLES  = 512;
static constexpr int SCAN_TIMEOUT   = 4096;

// ROM sizes
static constexpr int SPR_ROM_SIZE  = 1 << 21;   // 2 MB
static constexpr int TILE_ROM_SIZE = 1 << 20;    // 1 MB

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
    Vgp9001*              top;
    uint64_t              cycle;
    int                   failures;
    int                   checks;

    // Sprite ROM
    std::vector<uint8_t>  spr_rom;
    // BG tile ROM
    std::vector<uint8_t>  tile_rom;

    DUT() : cycle(0), failures(0), checks(0) {
        top = new Vgp9001();
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

    // Tick one clock. Drive both ROMs combinationally.
    void clk_tick(int n = 1) {
        for (int i = 0; i < n; i++) {
            top->clk = 0;
            top->eval();
            // Drive sprite ROM combinationally
            uint32_t sa = top->spr_rom_addr & (SPR_ROM_SIZE - 1);
            top->spr_rom_data = spr_rom[sa];
            // Drive BG tile ROM combinationally
            uint32_t ba = top->bg_rom_addr & (TILE_ROM_SIZE - 1);
            top->bg_rom_data = tile_rom[ba];
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

    // ── Sprite RAM write ──────────────────────────────────────────────────
    void write_sram(int word_idx, int data) {
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

    // ── VRAM write (select layer via reg 0x0F, then write via addr[10]=1) ─
    void write_vram(int layer, int word_addr, int data) {
        // Select VRAM layer: write reg 0x0F with layer[1:0]
        top->addr = (uint32_t)(0x0F & 0xF);
        top->din  = (uint16_t)(layer & 0x3);
        top->cs_n = 0;
        top->wr_n = 0;
        top->rd_n = 1;
        clk_tick(1);
        top->cs_n = 1;
        top->wr_n = 1;
        clk_tick(1);

        // Write VRAM: addr[10]=1, addr[9:0] = word_addr
        top->addr = (uint32_t)(0x400 | (word_addr & 0x3FF));
        top->din  = (uint16_t)(data & 0xFFFF);
        top->cs_n = 0;
        top->wr_n = 0;
        top->rd_n = 1;
        clk_tick(1);
        top->cs_n = 1;
        top->wr_n = 1;
        clk_tick(1);
    }

    // ── vsync pulse ───────────────────────────────────────────────────────
    void vsync_pulse() {
        top->vsync = 1;
        clk_tick(2);
        top->vsync = 0;
        clk_tick(2);
    }

    // ── vblank scan ───────────────────────────────────────────────────────
    void vblank_scan() {
        top->vblank = 1;
        bool done = false;
        for (int i = 0; i < VBLANK_CYCLES && !done; i++) {
            clk_tick(1);
            if (top->display_list_ready) done = true;
        }
        top->vblank = 0;
        clk_tick(4);
        if (!done) {
            fprintf(stderr, "WARNING: vblank_scan: display_list_ready not seen "
                    "within %d cycles\n", VBLANK_CYCLES);
        }
    }

    // ── scan_line: trigger Gate 4 FSM ─────────────────────────────────────
    bool scan_line(int scanline) {
        top->current_scanline = (uint16_t)(scanline & 0x1FF);
        top->scan_trigger     = 1;
        clk_tick(1);
        top->scan_trigger     = 0;
        for (int i = 0; i < SCAN_TIMEOUT; i++) {
            clk_tick(1);
            if (top->spr_render_done) {
                clk_tick(1);
                return true;
            }
        }
        fprintf(stderr, "WARNING: scan_line(%d): spr_render_done not seen "
                "within %d cycles\n", scanline, SCAN_TIMEOUT);
        return false;
    }

    // ── Set spr_rd_addr and settle combinational paths ────────────────────
    void set_spr_rd_addr(int x) {
        top->spr_rd_addr = (uint16_t)(x & 0x1FF);
        top->clk = 0;
        top->eval();
        uint32_t sa = top->spr_rom_addr & (SPR_ROM_SIZE - 1);
        top->spr_rom_data = spr_rom[sa];
        uint32_t ba = top->bg_rom_addr & (TILE_ROM_SIZE - 1);
        top->bg_rom_data = tile_rom[ba];
        top->eval();  // settle combinational (Gate 5 is comb from spr_rd_* + bg_pix_*)
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

    int get_final_color() { return (int)(uint8_t)top->final_color; }
    int get_final_valid() { return (int)(top->final_valid & 1); }
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
    int scenario = 0;

    while (std::getline(f, line)) {
        ++line_num;
        if (line.empty() || line[0] == '#') continue;

        std::string op = jstr(line, "op");

        if (op == "reset") {
            dut.reset();
            ++scenario;
            fprintf(stderr, "-- scenario %d --\n", scenario);

        } else if (op == "vsync_pulse") {
            dut.vsync_pulse();

        } else if (op == "write_sram") {
            int addr = jint(line, "addr", 0);
            int data = jint(line, "data", 0);
            dut.write_sram(addr, data);

        } else if (op == "write_sprite_ctrl") {
            int data = jint(line, "data", 0);
            dut.write_reg(0x0A, data);
            dut.vsync_pulse();

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

        } else if (op == "set_spr_rd_addr") {
            int x = jint(line, "x", 0);
            dut.set_spr_rd_addr(x);

        } else if (op == "write_reg") {
            int addr = jint(line, "addr", 0);
            int data = jint(line, "data", 0);
            dut.write_reg(addr, data);

        } else if (op == "write_vram") {
            int layer = jint(line, "layer", 0);
            int addr  = jint(line, "addr",  0);
            int data  = jint(line, "data",  0);
            dut.write_vram(layer, addr, data);

        } else if (op == "write_rom_byte") {
            int addr = jint(line, "addr", 0);
            int data = jint(line, "data", 0);
            uint32_t a = (uint32_t)addr & (TILE_ROM_SIZE - 1);
            dut.tile_rom[a] = (uint8_t)(data & 0xFF);

        } else if (op == "set_pixel") {
            int hpos = jint(line, "hpos", 0);
            int vpos = jint(line, "vpos", 0);
            dut.top->hpos      = (uint16_t)(hpos & 0x1FF);
            dut.top->vpos      = (uint16_t)(vpos & 0x1FF);
            dut.top->hblank    = 0;
            dut.top->vblank_in = 0;

        } else if (op == "clock_n") {
            int n = jint(line, "n", 1);
            dut.clk_tick(n);

        } else if (op == "check_final") {
            int exp_valid = jint(line, "exp_valid", 0);
            int exp_color = jint(line, "exp_color", 0);

            // Settle combinational (final_color/final_valid are always_comb)
            dut.top->clk = 0;
            dut.top->eval();
            uint32_t sa = dut.top->spr_rom_addr & (SPR_ROM_SIZE - 1);
            dut.top->spr_rom_data = dut.spr_rom[sa];
            uint32_t ba = dut.top->bg_rom_addr & (TILE_ROM_SIZE - 1);
            dut.top->bg_rom_data = dut.tile_rom[ba];
            dut.top->eval();

            dut.check("final_valid", dut.get_final_valid(), exp_valid);
            if (exp_valid) {
                dut.check("final_color", dut.get_final_color(), exp_color);
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
        fprintf(stderr, "Usage: %s <gate5_vectors.jsonl> [...]\n", argv[0]);
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
