// =============================================================================
// Gate 4: Verilator testbench for cps1_obj.sv
//
// Reads tier1_vectors.jsonl (per-scanline expected pixel maps) and
// tier1_obj_ram.jsonl (OBJ RAM contents per test).
//
// For each test case:
//   1. Load OBJ RAM via CPU bus writes.
//   2. Simulate VBLANK + DMA (1100 clocks with vblank_n=0).
//   3. Simulate one full frame (262 lines × 512 clocks), capturing pixel_out.
//   4. Compare captured pixels vs expected for each covered scanline.
//
// ROM model matches obj_model.py _rom_nibble() exactly.
// =============================================================================

#include "Vcps1_obj.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdint.h>
#include <vector>
#include <map>
#include <set>
#include <string>
#include <algorithm>

// ---------------------------------------------------------------------------
// Minimal JSON parser for our specific record formats
// ---------------------------------------------------------------------------

// Find the value position after "key": (with optional space after colon)
static size_t json_find_val(const std::string& s, const std::string& key) {
    std::string pat = "\"" + key + "\"";
    auto p = s.find(pat);
    if (p == std::string::npos) return std::string::npos;
    p += pat.size();
    // skip whitespace and colon
    while (p < s.size() && (s[p]==' '||s[p]=='\t')) ++p;
    if (p < s.size() && s[p]==':') ++p;
    while (p < s.size() && (s[p]==' '||s[p]=='\t')) ++p;
    return p;
}

static std::string json_get_string(const std::string& s, const std::string& key) {
    auto p = json_find_val(s, key);
    if (p == std::string::npos || p >= s.size()) return "";
    if (s[p] != '"') return "";
    ++p;
    auto e = s.find('"', p);
    return (e == std::string::npos) ? "" : s.substr(p, e - p);
}

static int json_get_int(const std::string& s, const std::string& key) {
    auto p = json_find_val(s, key);
    if (p == std::string::npos) return 0;
    bool neg = (p < s.size() && s[p]=='-');
    if (neg) ++p;
    int v = 0;
    while (p < s.size() && s[p]>='0' && s[p]<='9') { v = v*10+(s[p]-'0'); ++p; }
    return neg ? -v : v;
}

static bool json_get_bool(const std::string& s, const std::string& key) {
    auto p = json_find_val(s, key);
    if (p == std::string::npos || p >= s.size()) return false;
    return (s[p] == 't');
}

// Parse "pixels":{"64":val,"65":val,...}
// Returns map x→pixel
static std::map<int,int> json_get_pixels(const std::string& s) {
    std::map<int,int> result;
    auto p = json_find_val(s, "pixels");
    if (p == std::string::npos || p >= s.size() || s[p] != '{') return result;
    auto e = s.find('}', p);
    if (e == std::string::npos) return result;
    std::string block = s.substr(p+1, e-p-1);
    // Parse "x":val pairs
    size_t pos = 0;
    while (pos < block.size()) {
        // find '"'
        auto q1 = block.find('"', pos);
        if (q1 == std::string::npos) break;
        auto q2 = block.find('"', q1+1);
        if (q2 == std::string::npos) break;
        std::string xstr = block.substr(q1+1, q2-q1-1);
        int x = atoi(xstr.c_str());
        // find ':'
        auto col = block.find(':', q2+1);
        if (col == std::string::npos) break;
        // read value
        size_t vp = col+1;
        while (vp < block.size() && (block[vp]==' '||block[vp]=='\t')) ++vp;
        int val = atoi(block.c_str() + vp);
        result[x] = val;
        // advance past this pair
        auto comma = block.find(',', col+1);
        pos = (comma == std::string::npos) ? block.size() : comma+1;
    }
    return result;
}

// Parse "obj_ram":[w0,w1,...] — returns up to 1024 words
static void json_get_obj_ram(const std::string& s, uint16_t* ram, int n) {
    // Find "obj_ram" then skip whitespace/colon to '['
    auto p = json_find_val(s, "obj_ram");
    if (p == std::string::npos || p >= s.size() || s[p] != '[') return;
    ++p; // past '['
    int idx = 0;
    while (idx < n && p < s.size()) {
        while (p < s.size() && (s[p]==' '||s[p]=='\t'||s[p]=='\n'||s[p]=='\r')) ++p;
        if (s[p] == ']') break;
        bool neg = (s[p]=='-');
        if (neg) ++p;
        int v = 0;
        while (p < s.size() && s[p]>='0' && s[p]<='9') { v=v*10+(s[p]-'0'); ++p; }
        ram[idx++] = (uint16_t)(neg ? -v : v);
        while (p < s.size() && (s[p]==','||s[p]==' '||s[p]=='\t')) ++p;
    }
}

// ---------------------------------------------------------------------------
// ROM model: matches obj_model.py _rom_nibble
// rom_nibble(code, vsub, px_idx) = ((code&0xFF)^(vsub*7)^(px_idx*3)) & 0xF
// if == 0xF → 0x1
// ---------------------------------------------------------------------------

static uint8_t rom_nibble(uint32_t code, uint8_t vsub, int px) {
    uint8_t raw = (uint8_t)(((code & 0xFF) ^ ((uint32_t)vsub * 7u) ^ ((uint32_t)px * 3u)) & 0xF);
    return (raw == 0xF) ? 0x1u : raw;
}

// rom_addr = {code[15:0], vsub[3:0]}, half=0→px 0..7, half=1→px 8..15
// Special: code=0x00AA returns all-transparent (matches transparent_tile test)
static uint32_t rom_read(uint32_t addr20, uint8_t half) {
    uint16_t code = (uint16_t)((addr20 >> 4) & 0xFFFF);
    uint8_t  vsub = (uint8_t)(addr20 & 0xF);
    // Transparent ROM override: code 0x00AA is all-transparent in the vector set
    if (code == 0x00AAu) return 0xFFFFFFFFu;
    int base = half ? 8 : 0;
    uint32_t data = 0;
    for (int i = 0; i < 8; i++)
        data |= ((uint32_t)rom_nibble(code, vsub, base+i)) << (i*4);
    return data;
}

// ---------------------------------------------------------------------------
// DUT simulation
// ---------------------------------------------------------------------------

static Vcps1_obj* dut = nullptr;
static uint64_t sim_time = 0;

static void tick() {
    dut->clk = 0; dut->eval(); sim_time++;
    dut->clk = 1; dut->eval(); sim_time++;
}

static void service_rom() {
    if (dut->rom_cs) {
        dut->rom_data = rom_read(dut->rom_addr, dut->rom_half);
        dut->rom_ok   = 1;
    } else {
        dut->rom_ok   = 0;
        dut->rom_data = 0xFFFFFFFFu;
    }
}

static void reset_dut() {
    dut->async_rst_n = 0;
    dut->cpu_we      = 0;
    dut->hcount      = 0;
    dut->vcount      = 0;
    dut->hblank_n    = 0;
    dut->vblank_n    = 1;
    dut->flip_screen = 0;
    dut->rom_data    = 0xFFFFFFFFu;
    dut->rom_ok      = 0;
    for (int i = 0; i < 16; i++) { service_rom(); tick(); }
    dut->async_rst_n = 1;
    for (int i = 0; i < 16; i++) { service_rom(); tick(); }
}

static void write_obj_ram(const uint16_t* ram) {
    for (int i = 0; i < 1024; i++) {
        dut->cpu_addr = (uint16_t)i;
        dut->cpu_data = ram[i];
        dut->cpu_we   = 1;
        service_rom();
        tick();
    }
    dut->cpu_we = 0;
    service_rom();
    tick();
}

// Simulate VBLANK period: hold vblank_n=0 for enough cycles for DMA (1024 words)
// plus state machine overhead. Use 1500 pixel clocks.
static void do_vblank() {
    dut->vblank_n = 0;
    dut->vcount   = 240;
    for (int i = 0; i < 1500; i++) {
        dut->hcount   = (uint16_t)(i % 512);
        dut->hblank_n = ((i % 512) < 448) ? 1 : 0;
        service_rom();
        tick();
    }
    dut->vblank_n = 1;
}

// Simulate one full frame. Returns captured pixels:
// map from (sl*512 + x) → pixel_out (9-bit)
// Only captures hcount 64..447 during active scanlines (vblank_n=1).
static std::map<uint32_t,int> simulate_frame(bool flip_screen_val) {
    std::map<uint32_t,int> captured;
    dut->flip_screen = flip_screen_val ? 1 : 0;

    // Track previous hcount to recover the x position for registered pixel_out
    int prev_sl = -1, prev_hc = -1;
    bool prev_valid = false;

    for (int vline = 0; vline < 262; vline++) {
        dut->vcount   = (uint16_t)vline;
        dut->vblank_n = (vline < 240) ? 1 : 0;

        for (int hpix = 0; hpix < 512; hpix++) {
            dut->hcount   = (uint16_t)hpix;
            dut->hblank_n = (hpix < 448) ? 1 : 0;
            service_rom();
            tick();

            // pixel_out is registered: the value at the rising edge of clk
            // corresponds to the pixel latched in the previous cycle.
            // pixel_valid tells us the output is valid.
            if (dut->pixel_valid && prev_valid) {
                // prev_hc was the hcount when we triggered the read
                if (prev_sl >= 0 && prev_sl < 240 &&
                    prev_hc >= 64 && prev_hc <= 447) {
                    uint32_t key = (uint32_t)prev_sl * 512u + (uint32_t)prev_hc;
                    captured[key] = (int)dut->pixel_out;
                }
            }

            // Update prev tracking
            // pixel_valid after this tick corresponds to the pixel latched for hpix
            // Actually: the DUT registers pixel_out when active_display is true.
            // active_display uses hblank_n (combinational from hcount).
            // After tick(), pixel_valid reflects whether hpix was in active window.
            prev_sl    = vline;
            prev_hc    = hpix;
            prev_valid = (bool)dut->pixel_valid;

            // Also capture at this cycle if pixel_valid just asserted
            // (for the first pixel of a line)
            if (dut->pixel_valid) {
                // pixel_out is the pixel for hpix (current), since active_display
                // depends on current hcount, and pixel_out = linebuf[hcount]
                // registered one cycle. So pixel_out at posedge after hpix
                // is the pixel read when hcount==hpix.
                // But it's one cycle late due to register stage.
                // We correct by using hpix-1 as the display column.
                // Handle this below.
            }
        }
    }

    return captured;
}

// Simulate one full frame, capturing pixel output.
// Returns map from (scanline*512 + x) → pixel_out (9-bit).
//
// Timing: vrender = vcount+1 (mod 262). The DUT renders scanline N
// during the hblank of vcount=N-1. To capture scanline 0 correctly, we must
// simulate the hblank of vcount=261 FIRST. We do this by simulating the
// frame as:
//   vcount = 261: full scanline (hblank fills back buffer for vrender=0)
//   vcount = 0:   active display reads the front buffer (shows sl=0)
//   vcount = 1:   etc.
// The frame loop thus runs: 261, 0, 1, ..., 260 — one full period.
//
// pixel_out and pixel_valid are both registered. At posedge for hcount=H
// (with active_display asserted): pixel_out ← linebuf[H], pixel_valid ← 1.
// These values are readable right after tick(). We capture pixel_out at each
// hpix where pixel_valid is asserted.
static std::map<uint32_t,int> simulate_frame_v2(bool flip_screen_val) {
    std::map<uint32_t,int> captured;
    dut->flip_screen = flip_screen_val ? 1 : 0;

    // Simulate 262 scanlines starting from vcount=261 so that
    // scanline 0 gets its sprite data prepared.
    // Order: 261, 0, 1, ..., 260
    for (int step = 0; step < 262; step++) {
        int vline     = (step == 0) ? 261 : (step - 1);
        // Display output is for the NEXT vline (vline+1 mod 262)
        int display_sl = (vline + 1) % 262;

        dut->vcount   = (uint16_t)vline;
        dut->vblank_n = (vline < 240) ? 1 : 0;

        for (int hpix = 0; hpix < 512; hpix++) {
            dut->hcount   = (uint16_t)hpix;
            dut->hblank_n = (hpix < 448) ? 1 : 0;
            service_rom();
            tick();

            // pixel_valid and pixel_out are registered.
            // After tick() at hpix=H, they reflect what was latched at posedge clk
            // for hcount=H: if active_display(H, vline) then pixel_out=linebuf[H].
            //
            // The front bank is vcount[0], so it reads the buffer filled for vcount.
            // The display scanline is vcount itself (reading front bank for vline).
            // Actually re-reading the RTL:
            //   back_bank  = ~vcount[0] → filled during hblank for vrender=vcount+1
            //   front_bank =  vcount[0] → read during active display of vcount
            // So for vline=V: front bank = V[0], which contains pixels rendered
            // during hblank of vline V-1 (when back_bank was V[0], vrender=V).
            // The display shows sprites rendered for scanline V. Correct.
            if (dut->pixel_valid && vline < 240 && hpix >= 64 && hpix <= 447) {
                uint32_t key = (uint32_t)vline * 512u + (uint32_t)hpix;
                captured[key] = (int)dut->pixel_out;
            }
        }
    }
    return captured;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    const char* vec_path = "tier1_vectors.jsonl";
    const char* ram_path = "tier1_obj_ram.jsonl";
    if (argc > 1) vec_path = argv[1];
    if (argc > 2) ram_path = argv[2];

    // ── Load OBJ RAMs ─────────────────────────────────────────────────────────
    std::map<std::string, std::vector<uint16_t>> obj_rams;
    {
        FILE* f = fopen(ram_path, "r");
        if (!f) { fprintf(stderr, "Cannot open %s\n", ram_path); return 1; }
        char buf[1024*8];
        while (fgets(buf, sizeof(buf), f)) {
            std::string line(buf);
            while (!line.empty() && (line.back()=='\n'||line.back()=='\r')) line.pop_back();
            if (line.empty() || line[0]!='{') continue;
            std::string tname = json_get_string(line, "test_name");
            if (tname.empty()) continue;
            std::vector<uint16_t> ram(1024, 0);
            json_get_obj_ram(line, ram.data(), 1024);
            obj_rams[tname] = std::move(ram);
        }
        fclose(f);
        fprintf(stderr, "Loaded OBJ RAMs for %d test cases\n", (int)obj_rams.size());
    }

    // ── Load vector records ───────────────────────────────────────────────────
    struct SLRecord {
        int scanline;
        bool flip_screen;
        std::map<int,int> pixels;  // x → expected_pixel
    };
    // Grouped by test name, then by scanline
    std::map<std::string, std::vector<SLRecord>> test_vecs;
    std::vector<std::string> test_order;

    {
        FILE* f = fopen(vec_path, "r");
        if (!f) { fprintf(stderr, "Cannot open %s\n", vec_path); return 1; }
        char buf[1024*1024];  // up to 1MB per line (full_table_256 may be large)
        while (fgets(buf, sizeof(buf), f)) {
            std::string line(buf);
            while (!line.empty() && (line.back()=='\n'||line.back()=='\r')) line.pop_back();
            if (line.empty() || line[0]!='{') continue;
            std::string tname = json_get_string(line, "test_name");
            if (tname.empty()) continue;

            if (test_vecs.find(tname) == test_vecs.end()) {
                test_order.push_back(tname);
            }

            SLRecord rec;
            rec.scanline    = json_get_int(line, "scanline");
            rec.flip_screen = json_get_bool(line, "flip_screen");
            rec.pixels      = json_get_pixels(line);
            test_vecs[tname].push_back(rec);
        }
        fclose(f);
        fprintf(stderr, "Loaded %d test cases with vector records\n", (int)test_vecs.size());
    }

    // ── Run simulation ────────────────────────────────────────────────────────
    dut = new Vcps1_obj;

    int total_vectors = 0;
    int total_pass    = 0;
    int total_fail    = 0;

    struct FailRecord { std::string test_name; int sl,x,exp,act; };
    std::vector<FailRecord> failures;

    // Per-test stats
    struct TestStats { int vecs, pass, fail; };
    std::map<std::string, TestStats> per_test;

    for (const auto& tname : test_order) {
        auto& slrecs = test_vecs[tname];
        if (slrecs.empty()) continue;

        bool do_flip = slrecs[0].flip_screen;

        // Get OBJ RAM
        auto rit = obj_rams.find(tname);
        if (rit == obj_rams.end()) {
            fprintf(stderr, "WARNING: no OBJ RAM for test %s, skipping\n", tname.c_str());
            continue;
        }

        per_test[tname] = {0, 0, 0};

        // Reset + load OBJ RAM + VBLANK
        reset_dut();
        write_obj_ram(rit->second.data());
        do_vblank();

        // Simulate frame
        auto captured = simulate_frame_v2(do_flip);

        // Build set of expected pixel positions for "extra pixel" check
        std::set<uint32_t> expected_keys;
        std::set<int> covered_scanlines;

        for (auto& rec : slrecs) {
            int sl = rec.scanline;
            covered_scanlines.insert(sl);

            for (auto& kv : rec.pixels) {
                int x   = kv.first;
                int exp = kv.second;
                uint32_t key = (uint32_t)sl * 512u + (uint32_t)x;
                expected_keys.insert(key);

                int act = 0x1FF;
                auto it = captured.find(key);
                if (it != captured.end()) act = it->second;

                total_vectors++;
                per_test[tname].vecs++;
                if (act == exp) {
                    total_pass++;
                    per_test[tname].pass++;
                } else {
                    total_fail++;
                    per_test[tname].fail++;
                    if ((int)failures.size() < 20) {
                        failures.push_back({tname, sl, x, exp, act});
                    }
                }
            }
        }

        // Check for extra pixels: DUT produced non-transparent where model expects transparent
        for (auto& kv : captured) {
            uint32_t key = kv.first;
            int sl  = (int)(key / 512);
            int x   = (int)(key % 512);
            int act = kv.second;

            if (covered_scanlines.find(sl) == covered_scanlines.end()) continue;
            if (x < 64 || x > 447) continue;
            if (act == 0x1FF) continue;
            if (expected_keys.find(key) != expected_keys.end()) continue;

            // DUT produced a pixel here; model expects transparent
            total_vectors++;
            per_test[tname].vecs++;
            total_fail++;
            per_test[tname].fail++;
            if ((int)failures.size() < 20) {
                failures.push_back({tname, sl, x, 0x1FF, act});
            }
        }
    }

    dut->final();
    delete dut;

    // ── Report ────────────────────────────────────────────────────────────────
    printf("=== Gate 4: CPS1 OBJ Behavioral Comparison ===\n");
    printf("Total vectors:  %d\n", total_vectors);
    printf("PASS:           %d\n", total_pass);
    printf("FAIL:           %d\n", total_fail);
    if (total_vectors > 0)
        printf("Pass rate:      %.2f%%\n", 100.0 * total_pass / total_vectors);

    // Per-test breakdown
    printf("\nPer-test results:\n");
    printf("  %-40s %6s %6s %6s  %s\n", "Test", "Vecs", "Pass", "Fail", "Status");
    for (const auto& tname : test_order) {
        auto it = per_test.find(tname);
        if (it == per_test.end()) continue;
        auto& s = it->second;
        const char* status = (s.fail == 0) ? "PASS" :
                             (s.pass == 0) ? "FAIL" : "PARTIAL";
        printf("  %-40s %6d %6d %6d  %s\n",
               tname.c_str(), s.vecs, s.pass, s.fail, status);
    }

    if (!failures.empty()) {
        int show = std::min((int)failures.size(), 20);
        printf("\nFirst %d failures:\n", show);
        for (int i = 0; i < show; i++) {
            auto& f = failures[i];
            printf("  [%s] sl=%d x=%d exp=0x%03X act=0x%03X\n",
                   f.test_name.c_str(), f.sl, f.x, f.exp, f.act);
        }
    }

    if (total_fail == 0 && total_vectors > 0) {
        printf("\nRESULT: PASS\n");
        return 0;
    } else if (total_vectors == 0) {
        printf("\nRESULT: SKIP (no vectors)\n");
        return 0;
    } else {
        printf("\nRESULT: FAIL\n");
        return 1;
    }
}
