// Psikyo Gate 3 Verilator Testbench — Per-scanline Sprite Rasterizer
//
// Reads gate3_vectors.jsonl and drives the psikyo_gate3 DUT.
//
// Supported ops:
//   reset             — pulse rst_n low then high
//   write_spr_rom     — addr, data: write one byte into testbench sprite ROM
//   load_display_list — count, entries[]: inject display_list into DUT arrays
//   scan_line         — scanline: pulse scan_trigger=1 for 1 cycle, then clock
//                       until spr_render_done or SCAN_TIMEOUT cycles
//   check_spr         — x, exp_valid, exp_color, exp_priority: verify pixel
//   comment           — ignored (used for section markers in vector file)
//
// Sprite ROM model:
//   16 MB byte array.  spr_rom_data driven combinationally (zero latency).
//
// Exit: 0 = all pass, 1 = any failure.

#include "Vpsikyo_gate3.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdint.h>
#include <string>
#include <fstream>
#include <vector>

// ─── Timing constants ────────────────────────────────────────────────────────

static constexpr int SCAN_TIMEOUT  = 8192;   // max cycles for one scanline render
static constexpr int SPR_ROM_SIZE  = 1 << 24; // 16 MB

// ─── Minimal JSON field extractors ───────────────────────────────────────────

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
    ++p;
    auto end = s.find('"', p);
    if (end == std::string::npos) return "";
    return s.substr(p, end - p);
}

// Parse array of JSON objects: "entries": [{...},{...}, ...]
// Returns vector of {x, y, tile_num, palette, flip_x, flip_y, prio, size, valid}
struct SprEntry {
    int x, y, tile_num, palette, flip_x, flip_y, prio, size, valid;
};

static std::vector<SprEntry> jentries(const std::string& line) {
    std::vector<SprEntry> out;

    // Find "entries": [
    auto key_pos = line.find("\"entries\"");
    if (key_pos == std::string::npos) return out;

    auto bracket = line.find('[', key_pos);
    if (bracket == std::string::npos) return out;

    size_t pos = bracket + 1;
    while (pos < line.size()) {
        // Skip whitespace
        while (pos < line.size() && (line[pos] == ' ' || line[pos] == '\t' ||
               line[pos] == '\n' || line[pos] == '\r' || line[pos] == ',')) ++pos;
        if (pos >= line.size() || line[pos] == ']') break;
        if (line[pos] != '{') { ++pos; continue; }

        // Find matching }
        int depth = 1;
        size_t obj_start = pos;
        ++pos;
        while (pos < line.size() && depth > 0) {
            if (line[pos] == '{') ++depth;
            else if (line[pos] == '}') --depth;
            ++pos;
        }
        std::string obj = line.substr(obj_start, pos - obj_start);

        SprEntry e;
        e.x        = jint(obj, "x",        0);
        e.y        = jint(obj, "y",        0);
        e.tile_num = jint(obj, "tile_num", 0);
        e.palette  = jint(obj, "palette",  0);
        e.flip_x   = jint(obj, "flip_x",  0);
        e.flip_y   = jint(obj, "flip_y",  0);
        e.prio     = jint(obj, "prio",     0);
        e.size     = jint(obj, "size",     0);
        e.valid    = jint(obj, "valid",    0);
        out.push_back(e);
    }
    return out;
}

// ─── DUT wrapper ─────────────────────────────────────────────────────────────

struct DUT {
    Vpsikyo_gate3* top;
    uint64_t       cycle;
    int            failures;
    int            checks;

    std::vector<uint8_t> spr_rom;

    DUT() : cycle(0), failures(0), checks(0) {
        top = new Vpsikyo_gate3();
        spr_rom.assign(SPR_ROM_SIZE, 0);
        reset_inputs();
        do_reset();
    }

    ~DUT() {
        top->final();
        delete top;
    }

    void reset_inputs() {
        top->rst_n           = 0;
        top->clk             = 0;
        top->scan_trigger    = 0;
        top->current_scanline = 0;
        top->spr_rom_data    = 0;
        top->spr_rd_addr     = 0;

        // Zero display_list arrays
        for (int i = 0; i < 256; i++) {
            top->display_list_x[i]        = 0;
            top->display_list_y[i]        = 0;
            top->display_list_tile[i]     = 0;
            top->display_list_palette[i]  = 0;
            top->display_list_flip_x[i]   = 0;
            top->display_list_flip_y[i]   = 0;
            top->display_list_priority[i] = 0;
            top->display_list_size[i]     = 0;
            top->display_list_valid[i]    = 0;
        }
        top->display_list_count = 0;
    }

    // Tick one clock, driving sprite ROM combinationally
    void clk_tick(int n = 1) {
        for (int i = 0; i < n; i++) {
            top->clk = 0;
            top->eval();
            uint32_t a = top->spr_rom_addr & (SPR_ROM_SIZE - 1);
            top->spr_rom_data = spr_rom[a];
            top->clk = 1;
            top->eval();
            ++cycle;
        }
    }

    void do_reset() {
        reset_inputs();
        clk_tick(4);
        top->rst_n = 1;
        clk_tick(4);
    }

    // Inject display_list into DUT input ports
    void load_display_list(const std::vector<SprEntry>& entries, int count) {
        // First, zero everything
        for (int i = 0; i < 256; i++) {
            top->display_list_x[i]        = 0;
            top->display_list_y[i]        = 0;
            top->display_list_tile[i]     = 0;
            top->display_list_palette[i]  = 0;
            top->display_list_flip_x[i]   = 0;
            top->display_list_flip_y[i]   = 0;
            top->display_list_priority[i] = 0;
            top->display_list_size[i]     = 0;
            top->display_list_valid[i]    = 0;
        }

        int n = (int)entries.size();
        if (n > 256) n = 256;
        for (int i = 0; i < n; i++) {
            const auto& e = entries[i];
            top->display_list_x[i]        = (uint16_t)(e.x  & 0x3FF);
            top->display_list_y[i]        = (uint16_t)(e.y  & 0x3FF);
            top->display_list_tile[i]     = (uint16_t)(e.tile_num & 0xFFFF);
            top->display_list_palette[i]  = (uint8_t)(e.palette & 0xF);
            top->display_list_flip_x[i]   = (uint8_t)(e.flip_x & 1);
            top->display_list_flip_y[i]   = (uint8_t)(e.flip_y & 1);
            top->display_list_priority[i] = (uint8_t)(e.prio & 3);
            top->display_list_size[i]     = (uint8_t)(e.size & 7);
            top->display_list_valid[i]    = (uint8_t)(e.valid & 1);
        }
        top->display_list_count = (uint8_t)(count & 0xFF);
        top->eval();
    }

    // Pulse scan_trigger=1 for 1 cycle, then clock until spr_render_done
    bool scan_line(int scanline) {
        top->current_scanline = (uint16_t)(scanline & 0x1FF);
        top->scan_trigger     = 1;
        clk_tick(1);
        top->scan_trigger = 0;

        for (int i = 0; i < SCAN_TIMEOUT; i++) {
            clk_tick(1);
            if (top->spr_render_done) {
                clk_tick(1);  // let outputs settle
                return true;
            }
        }
        fprintf(stderr, "WARNING: scan_line(%d): spr_render_done not seen within %d cycles\n",
                scanline, SCAN_TIMEOUT);
        return false;
    }

    // Set spr_rd_addr and eval combinationally
    void set_rd_addr(int x) {
        top->spr_rd_addr = (uint16_t)(x & 0x3FF);
        top->clk = 0;
        top->eval();
        uint32_t a = top->spr_rom_addr & (SPR_ROM_SIZE - 1);
        top->spr_rom_data = spr_rom[a];
        top->eval();
    }

    int get_spr_valid()    { return (int)(top->spr_rd_valid & 1); }
    int get_spr_color()    { return (int)(uint8_t)top->spr_rd_color; }
    int get_spr_priority() { return (int)(top->spr_rd_priority & 3); }

    void check(const char* label, int got, int exp) {
        ++checks;
        if (got != exp) {
            fprintf(stderr, "FAIL  %s: got 0x%04X exp 0x%04X\n", label, got, exp);
            ++failures;
        } else {
            fprintf(stderr, "pass  %s: 0x%04X\n", label, got);
        }
    }
};

// ─── Process one vector file ──────────────────────────────────────────────────

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
            dut.do_reset();

        } else if (op == "write_spr_rom") {
            int addr = jint(line, "addr", 0);
            int data = jint(line, "data", 0);
            uint32_t a = (uint32_t)addr & (SPR_ROM_SIZE - 1);
            dut.spr_rom[a] = (uint8_t)(data & 0xFF);

        } else if (op == "load_display_list") {
            int count = jint(line, "count", 0);
            auto entries = jentries(line);
            dut.load_display_list(entries, count);

        } else if (op == "scan_line") {
            int scanline = jint(line, "scanline", 0);
            dut.scan_line(scanline);

        } else if (op == "check_spr") {
            int x            = jint(line, "x",            0);
            int exp_valid    = jint(line, "exp_valid",     0);
            int exp_color    = jint(line, "exp_color",     0);
            int exp_priority = jint(line, "exp_priority",  0);

            dut.set_rd_addr(x);

            char lbl_v[64], lbl_c[64], lbl_p[64];
            snprintf(lbl_v, sizeof(lbl_v), "spr_valid[%d]",    x);
            snprintf(lbl_c, sizeof(lbl_c), "spr_color[%d]",    x);
            snprintf(lbl_p, sizeof(lbl_p), "spr_priority[%d]", x);

            dut.check(lbl_v, dut.get_spr_valid(), exp_valid);
            if (exp_valid) {
                dut.check(lbl_c, dut.get_spr_color(), exp_color);
                dut.check(lbl_p, dut.get_spr_priority(), exp_priority);
            }

        } else if (op == "comment") {
            std::string text = jstr(line, "text");
            fprintf(stderr, "\n--- %s ---\n", text.c_str());

        } else {
            fprintf(stderr, "WARNING: unknown op '%s' at line %d\n",
                    op.c_str(), line_num);
        }
    }

    return 0;
}

// ─── main ─────────────────────────────────────────────────────────────────────

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    if (argc < 2) {
        fprintf(stderr, "Usage: %s <gate3_vectors.jsonl> [...]\n", argv[0]);
        return 1;
    }

    DUT dut;
    int err = 0;

    for (int i = 1; i < argc; i++) {
        err |= run_vectors(dut, argv[i]);
    }

    fprintf(stderr, "\n=== Results: %d checks, %d failures ===\n",
            dut.checks, dut.failures);

    printf("Passed: %d\n", dut.checks - dut.failures);
    printf("Failed: %d\n", dut.failures);
    printf("Total: %d/%d\n", dut.checks - dut.failures, dut.checks);

    if (dut.failures > 0 || err) {
        fprintf(stderr, "FAIL\n");
        return 1;
    }
    fprintf(stderr, "PASS\n");
    return 0;
}
