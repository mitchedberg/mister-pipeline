// =============================================================================
// tb_system.cpp — Raizing Arcade (Battle Garegga) Verilator testbench
//
// Wraps tb_top.sv (which includes raizing_arcade scaffold) and drives:
//   - Clock (96 MHz system — divided from 32 MHz XTAL × 3)
//   - Reset (active-low, released after RESET_CYCLES)
//   - SDRAM model (stub — scaffold never issues SDRAM commands)
//   - Player inputs (all held idle)
//
// NOTE: raizing_arcade.sv is currently a SCAFFOLD. The CPU, GP9001, and all
// memory subsystems are not implemented yet. This harness:
//   - Verifies gate-1 (Verilator build succeeds)
//   - Runs for N frames (time-based, not vblank-based, since vblank=0)
//   - Produces PPM frames (all black — expected for scaffold)
//   - Records build status for the pipeline
//
// Environment variables:
//   N_FRAMES   — number of frames to simulate (default 50)
//   DUMP_VCD   — set to "1" to enable VCD trace (slow)
//   RAM_DUMP   — path for per-frame RAM dump binary (e.g. raizing_sim_frames.bin)
//               Format for future implementation: [4B LE frame#][64KB work RAM]
//
// Output:
//   frame_NNNN.ppm — one PPM file per frame (320×240, all black)
//   raizing_sim_frames.bin — optional per-frame RAM dump (zeros while scaffold)
//   Build result printed to stderr
//
// Video timing (Battle Garegga / GP9001 standard):
//   320×240 active, same as Batsugun (both use GP9001)
//   Total: 416×264 (same as Toaplan V2)
//   At 96 MHz system clock, GP9001 pixel clock ≈ 96/12 = 8 MHz
//   → one pixel every 12 sys clocks, H_TOTAL=416, V_TOTAL=264
//   → frame duration = 416 × 264 × 12 = 1,318,272 system cycles
// =============================================================================

#include "Vtb_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <cinttypes>

// ── Video timing constants (GP9001 standard 320×240) ─────────────────────────
static constexpr int VID_H_ACTIVE  = 320;
static constexpr int VID_V_ACTIVE  = 240;
static constexpr int VID_H_TOTAL   = 416;
static constexpr int VID_V_TOTAL   = 264;

// Pixel clock divider: 96 MHz / 12 = 8 MHz pixel clock
// (96 / 8 = 12 sys clocks per pixel)
static constexpr int PIX_DIV = 12;

// Frame duration in system clock half-cycles (rising + falling edges)
// 416 pixels/line × 264 lines × 12 sys clocks × 2 half-cycles
static constexpr uint64_t FRAME_HALF_CYCLES =
    (uint64_t)VID_H_TOTAL * VID_V_TOTAL * PIX_DIV * 2;

// =============================================================================
// Frame buffer (320×240)
// =============================================================================
struct FrameBuffer {
    static constexpr int W = VID_H_ACTIVE;
    static constexpr int H = VID_V_ACTIVE;
    std::vector<uint32_t> pixels;

    FrameBuffer() : pixels(W * H, 0) {}

    void set(int x, int y, uint8_t r, uint8_t g, uint8_t b) {
        if (x >= 0 && x < W && y >= 0 && y < H)
            pixels[y * W + x] = ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
    }

    bool write_ppm(const char* path) const {
        FILE* f = fopen(path, "wb");
        if (!f) { fprintf(stderr, "Cannot write %s\n", path); return false; }
        fprintf(f, "P6\n%d %d\n255\n", W, H);
        for (int y = 0; y < H; y++) {
            for (int x = 0; x < W; x++) {
                uint32_t p = pixels[y * W + x];
                uint8_t rgb[3] = { (uint8_t)(p >> 16), (uint8_t)(p >> 8), (uint8_t)p };
                fwrite(rgb, 1, 3, f);
            }
        }
        fclose(f);
        return true;
    }

    int count_nonblack() const {
        int cnt = 0;
        for (auto p : pixels) if (p) ++cnt;
        return cnt;
    }

    void clear() { std::fill(pixels.begin(), pixels.end(), 0u); }
};

// =============================================================================
// RAM dump helpers
//
// Dumps internal RTL state for byte-by-byte comparison with MAME Lua dumps.
// For raizing_arcade (Battle Garegga-based):
//   Per frame: [4B LE frame#][64KB work RAM]
//   Total: 65540 bytes per frame
//
// 68000 word layout: high byte (addr+0) = word[15:8], low byte (addr+1) = word[7:0]
//
// When raizing_arcade.sv is implemented with CPU/memory, access via Verilator:
//   tb_top.u_raizing.work_ram → rootp->tb_top__DOT__u_raizing__DOT__work_ram
// =============================================================================

// Write a 16-bit word as two bytes in 68000 big-endian order (MSB first).
static inline void write_word_be(FILE* f, uint16_t w) {
    uint8_t b[2] = { (uint8_t)(w >> 8), (uint8_t)(w & 0xFF) };
    fwrite(b, 1, 2, f);
}

// Write N zero bytes.
static inline void write_zeros(FILE* f, size_t n) {
    static const uint8_t zero_buf[4096] = {};
    while (n >= sizeof(zero_buf)) {
        fwrite(zero_buf, 1, sizeof(zero_buf), f);
        n -= sizeof(zero_buf);
    }
    if (n > 0) fwrite(zero_buf, 1, n, f);
}

// Dump one frame of RAM state to the binary dump file.
//
// NOTE: RAIZING_ARCADE_PRESENT must be defined at compile time (via CFLAGS -DRAIZING_ARCADE_PRESENT)
// to enable the actual RAM dump. Without it, all regions write zeros (scaffold placeholder).
#define RAIZING_ARCADE_PRESENT
static void dump_frame_ram(FILE* f, uint32_t frame_num, Vtb_top* top) {
    // ── 4-byte LE frame number ───────────────────────────────────────────────
    uint8_t hdr[4] = {
        (uint8_t)(frame_num & 0xFF),
        (uint8_t)((frame_num >> 8) & 0xFF),
        (uint8_t)((frame_num >> 16) & 0xFF),
        (uint8_t)((frame_num >> 24) & 0xFF)
    };
    fwrite(hdr, 1, 4, f);

    // ── RAM regions — only available when raizing_arcade is instantiated ─────
    // raizing_arcade is currently a SCAFFOLD — RTL not yet implemented.
    // When RTL is complete, uncomment the ifdef block below and update the
    // hierarchy to match the actual Verilator-generated naming.
#ifdef RAIZING_ARCADE_PRESENT
    // Work RAM: 64KB = 32768 words (0x0B0000-0x0BFFFF, similar to GP9001 systems)
    // TODO: Implement work_ram dump when raizing_arcade RTL is ready.
    // Access pattern (Verilator 5.x): auto* r = top->tb_top;
    // Then: write_word_be(f, (uint16_t)r->__PVT__u_raizing__DOT__work_ram[i]);
#else
    // Scaffold: no RAM to dump, write zeros
#endif
    write_zeros(f, 65536);  // work RAM stub (32768 words × 2 bytes)
}

// =============================================================================
// main
// =============================================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::fatalOnError(false);

    // ── Configuration from environment ──────────────────────────────────────
    const char* env_frames   = getenv("N_FRAMES");
    const char* env_vcd      = getenv("DUMP_VCD");
    const char* env_ram_dump = getenv("RAM_DUMP");

    int n_frames = env_frames ? atoi(env_frames) : 50;
    if (n_frames < 1) n_frames = 1;

    fprintf(stderr, "=================================================\n");
    fprintf(stderr, "Raizing Arcade (Battle Garegga) simulation\n");
    fprintf(stderr, "NOTE: RTL is a SCAFFOLD — gate-1 build check only\n");
    fprintf(stderr, "Frames requested: %d\n", n_frames);
    fprintf(stderr, "System clock: 96 MHz (simulated)\n");
    fprintf(stderr, "=================================================\n");

    // ── Instantiate DUT ──────────────────────────────────────────────────────
    Vtb_top* top = new Vtb_top();

    // ── Optional VCD trace ───────────────────────────────────────────────────
    VerilatedVcdC* vcd = nullptr;
    if (env_vcd && env_vcd[0] == '1') {
        Verilated::traceEverOn(true);
        vcd = new VerilatedVcdC();
        top->trace(vcd, 99);
        vcd->open("sim_raizing.vcd");
        fprintf(stderr, "VCD trace enabled: sim_raizing.vcd\n");
    }

    // ── Optional RAM dump file (gate-5 WRAM comparison) ─────────────────────────
    FILE* ram_dump_f = nullptr;
    if (env_ram_dump) {
        ram_dump_f = fopen(env_ram_dump, "wb");
        if (!ram_dump_f) {
            fprintf(stderr, "ERROR: cannot open RAM_DUMP file: %s\n", env_ram_dump);
        } else {
            fprintf(stderr, "RAM dump enabled: %s\n", env_ram_dump);
            fprintf(stderr, "  Format: 4B frame# + per-frame RAM contents\n");
        }
    }

    // ── Initial port state ───────────────────────────────────────────────────
    top->clk   = 0;
    top->rst_n = 0;

    // ROM loading — disabled (scaffold doesn't use it)
    top->ioctl_wr    = 0;
    top->ioctl_addr  = 0;
    top->ioctl_dout  = 0;
    top->ioctl_index = 0;

    // SDRAM model — scaffold never issues commands (cs_n=1 always)
    top->sdram_dq_in = 0xFFFF;  // SDRAM returns 0xFFFF when idle

    // Player inputs — all released (active-low, held high = no input)
    top->joystick_0 = 0x3FF;  // all bits high = no input
    top->joystick_1 = 0x3FF;
    top->dipsw_a    = 0xFF;
    top->dipsw_b    = 0xFF;

    // ── Simulation state ─────────────────────────────────────────────────────
    uint64_t iter       = 0;
    int      frame_num  = 0;
    bool     done       = false;

    // Pixel position tracking (time-based, since vblank=0 in scaffold)
    int      hcnt       = 0;
    int      vcnt       = 0;
    int      pix_cnt    = 0;  // counts sys clocks since last pixel step

    // Reset duration: hold reset for 40 half-cycles (20 full clocks)
    static constexpr int RESET_HALF_CYCLES = 40;

    // Frame tracking: use fixed cycle count since scaffold has no vblank
    uint64_t frame_start_iter = RESET_HALF_CYCLES;
    uint64_t vcd_ts = 0;

    // Frame buffer
    FrameBuffer fb;

    fprintf(stderr, "Starting eval loop...\n");

    // Maximum iterations: n_frames × frame duration + reset time
    uint64_t max_iter = (uint64_t)n_frames * FRAME_HALF_CYCLES + RESET_HALF_CYCLES + 100;

    for (iter = 0; !done && iter < max_iter; iter++) {
        // Toggle clock
        top->clk = top->clk ^ 1;

        // Release reset after RESET_HALF_CYCLES
        if (iter >= RESET_HALF_CYCLES) top->rst_n = 1;

        if (top->clk == 1) {
            // ── Rising edge ──────────────────────────────────────────────────

            // Advance pixel counter (time-based)
            ++pix_cnt;
            if (pix_cnt >= PIX_DIV) {
                pix_cnt = 0;
                ++hcnt;
                if (hcnt >= VID_H_TOTAL) {
                    hcnt = 0;
                    ++vcnt;
                    if (vcnt >= VID_V_TOTAL) vcnt = 0;
                }
            }

            // Capture pixel (scaffold outputs are 0 = all black, as expected)
            if (top->rst_n && hcnt < VID_H_ACTIVE && vcnt < VID_V_ACTIVE) {
                fb.set(hcnt, vcnt, top->rgb_r, top->rgb_g, top->rgb_b);
            }
        }

        // Evaluate the DUT
        top->eval();

        if (vcd) {
            vcd->dump(vcd_ts++);
        }

        // ── Frame boundary: fixed cycle count ────────────────────────────────
        if (iter >= frame_start_iter && top->clk == 1) {
            uint64_t elapsed = iter - frame_start_iter;
            if (elapsed > 0 && (elapsed % (FRAME_HALF_CYCLES / 2)) == 0) {
                // Write PPM
                char fname[64];
                snprintf(fname, sizeof(fname), "frame_%04d.ppm", frame_num);
                fb.write_ppm(fname);

                int nb = fb.count_nonblack();
                fprintf(stderr, "  Frame %4d: %d non-black pixels (expected 0 — scaffold)\n",
                        frame_num, nb);

                // ── Per-frame RAM dump (gate-5 WRAM validation) ─────────────────
                if (ram_dump_f) {
                    dump_frame_ram(ram_dump_f, (uint32_t)frame_num, top);
                    if ((frame_num % 10) == 0)
                        fflush(ram_dump_f);
                }

                fb.clear();
                ++frame_num;

                if (frame_num >= n_frames) {
                    done = true;
                }
            }
        }
    }

    // ── Finalize ─────────────────────────────────────────────────────────────
    top->eval();

    if (vcd) {
        vcd->close();
        delete vcd;
    }

    if (ram_dump_f) {
        fclose(ram_dump_f);
        fprintf(stderr, "RAM dump closed: %s\n", env_ram_dump);
    }

    fprintf(stderr, "\n=================================================\n");
    fprintf(stderr, "Raizing sim COMPLETE\n");
    fprintf(stderr, "  Frames completed: %d / %d\n", frame_num, n_frames);
    fprintf(stderr, "  Total half-cycles: %" PRIu64 "\n", iter);
    fprintf(stderr, "  RTL status: SCAFFOLD (gate-1 build check)\n");
    fprintf(stderr, "  All frames are all-black (expected — no CPU/GP9001)\n");
    fprintf(stderr, "  Next step: implement raizing_arcade CPU + bus logic\n");
    fprintf(stderr, "=================================================\n");

    delete top;
    return 0;
}
