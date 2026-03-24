// =============================================================================
// tb_system.cpp — DECO 16-bit Arcade Verilator testbench
//
// Wraps tb_top.sv (deco16_arcade + fx68k CPU) and drives:
//   - Clock (40 MHz sys) and reset
//   - Video timing (software-modelled, 256×240 @ ~57 Hz)
//   - Program ROM SDRAM channel (toggle req/ack protocol)
//   - Video timing inputs (hpos/vpos/hblank/vblank) to deco16_arcade
//   - Player inputs (all held inactive)
//
// Environment variables:
//   N_FRAMES   — number of vertical frames to simulate (default 30)
//   ROM_PROG   — path to program ROM binary (384 KB)
//   DUMP_VCD   — set to "1" to enable VCD trace (slow)
//
// Output:
//   frame_NNNN.ppm — one PPM file per vertical frame
//
// Video resolution: DECO dec0 hardware
//   256×240 visible, standard DECO/Technos arcade timing
//   H_TOTAL = 384, V_TOTAL = 263 (approximately)
//   At 40 MHz sys clock, pixel clock divider = 2 → 20 MHz pixel clock
// =============================================================================

#include "Vtb_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include "sdram_model.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <inttypes.h>

// ── Video timing constants (DECO dec0 hardware) ───────────────────────────────
// 256×240 visible content, but we use 320 for safe capture
static constexpr int VID_H_ACTIVE  = 256;
static constexpr int VID_V_ACTIVE  = 240;
static constexpr int VID_H_TOTAL   = 384;
static constexpr int VID_V_TOTAL   = 263;
static constexpr int VID_H_BLANK   = VID_H_TOTAL - VID_H_ACTIVE;
static constexpr int VID_V_BLANK   = VID_V_TOTAL - VID_V_ACTIVE;
static constexpr int VID_HSYNC_START = VID_H_ACTIVE + 8;
static constexpr int VID_HSYNC_END   = VID_HSYNC_START + 32;
static constexpr int VID_VSYNC_START = VID_V_ACTIVE + 4;
static constexpr int VID_VSYNC_END   = VID_VSYNC_START + 4;

// Pixel clock: one pixel every 2 system clocks (20 MHz from 40 MHz)
static constexpr int PIX_DIV = 2;

// =============================================================================
// Frame buffer
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

    bool is_blank() const {
        for (auto p : pixels) if (p) return false;
        return true;
    }
};

// =============================================================================
// main
// =============================================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::fatalOnError(false);

    const char* env_frames = getenv("N_FRAMES");
    const char* env_prog   = getenv("ROM_PROG");
    const char* env_vcd    = getenv("DUMP_VCD");

    int n_frames = env_frames ? atoi(env_frames) : 30;
    if (n_frames < 1) n_frames = 1;

    fprintf(stderr, "DECO 16-bit Arcade simulation: %d frames\n", n_frames);

    // ── Load ROM data into SDRAM model ───────────────────────────────────────
    SdramModel sdram;
    if (env_prog) sdram.load(env_prog, 0x000000);  // CPU program ROM

    // ── SDRAM channels (toggle req/ack) ──────────────────────────────────────
    ToggleSdramChannel prog_ch(sdram);

    // ── Verilator instantiate DUT ─────────────────────────────────────────────
    Vtb_top* top = new Vtb_top();

    // ── Optional VCD trace ───────────────────────────────────────────────────
    VerilatedVcdC* vcd = nullptr;
    if (env_vcd && env_vcd[0] == '1') {
        Verilated::traceEverOn(true);
        vcd = new VerilatedVcdC();
        top->trace(vcd, 99);
        vcd->open("sim_deco16_arcade.vcd");
        fprintf(stderr, "VCD trace enabled: sim_deco16_arcade.vcd\n");
    }

    // ── Initial port state ───────────────────────────────────────────────────
    top->clk_sys   = 0;
    top->clk_pix   = 0;
    top->reset_n   = 0;
    top->enPhi1    = 0;
    top->enPhi2    = 0;

    top->prog_rom_data = 0xFFFF;
    top->prog_rom_ack  = 0;

    // All inputs inactive
    top->joystick_p1 = 0xFF;
    top->joystick_p2 = 0xFF;
    top->coin        = 0x3;  // active-low, 0x3 = no coin
    top->service     = 1;
    top->dipsw1      = 0xFF;
    top->dipsw2      = 0xFF;

    // Video timing inputs — start all inactive
    top->hblank_n_in = 0;   // in blanking
    top->vblank_n_in = 0;   // in blanking
    top->hpos        = 0;
    top->vpos        = 0;
    top->hsync_n_in  = 1;   // active-low, deasserted
    top->vsync_n_in  = 1;   // active-low, deasserted

    // ── Simulation state ─────────────────────────────────────────────────────
    int  frame_num  = 0;
    bool done       = false;
    int  hcnt       = 0;
    int  vcnt       = 0;
    int  pix_cnt    = 0;

    FrameBuffer fb;
    uint8_t vsync_n_prev = 1;

    static constexpr int RESET_ITERS = 20;
    bool phi_toggle = false;

    uint64_t iter    = 0;
    uint64_t vcd_ts  = 0;

    uint64_t as_cycles   = 0;
    uint64_t write_count = 0;
    bool prev_asn = true;
    bool halted   = false;

    fprintf(stderr, "Running eval loop...\n");
    top->reset_n = 0;

    for (iter = 0; !done && iter < (uint64_t)n_frames * 700000ULL; iter++) {
        top->clk_sys ^= 1;

        if (iter >= RESET_ITERS) top->reset_n = 1;

        if (top->clk_sys == 1) {
            // ── Rising edge ──────────────────────────────────────────────────

            // CPU phi enables (COMMUNITY_PATTERNS.md 2.1 Verilator pattern)
            top->enPhi1 = phi_toggle ? 0 : 1;
            top->enPhi2 = phi_toggle ? 1 : 0;
            phi_toggle  = !phi_toggle;

            // ── Pixel clock and video timing counters ─────────────────────────
            if (++pix_cnt >= PIX_DIV) {
                pix_cnt = 0;
                top->clk_pix = 1;

                if (++hcnt >= VID_H_TOTAL) {
                    hcnt = 0;
                    if (++vcnt >= VID_V_TOTAL) vcnt = 0;
                }

                // Drive video timing inputs to deco16_arcade
                bool h_active = (hcnt < VID_H_ACTIVE);
                bool v_active = (vcnt < VID_V_ACTIVE);
                bool h_sync   = (hcnt >= VID_HSYNC_START && hcnt < VID_HSYNC_END);
                bool v_sync   = (vcnt >= VID_VSYNC_START && vcnt < VID_VSYNC_END);

                top->hpos       = (uint16_t)hcnt;
                top->vpos       = (uint16_t)vcnt;
                top->hblank_n_in = h_active ? 1 : 0;
                top->vblank_n_in = v_active ? 1 : 0;
                top->hsync_n_in  = h_sync   ? 0 : 1;  // active-low
                top->vsync_n_in  = v_sync   ? 0 : 1;  // active-low
            } else {
                top->clk_pix = 0;
            }

            // ── SDRAM channel (toggle req/ack) ────────────────────────────────
            {
                auto r = prog_ch.tick(top->prog_rom_req, (uint32_t)top->prog_rom_addr);
                top->prog_rom_data = r.data;
                top->prog_rom_ack  = r.ack;
            }

            // ── Posedge eval ──────────────────────────────────────────────────
            top->eval();
            if (vcd) vcd->dump((vluint64_t)(vcd_ts++));

            // ── Pixel capture ─────────────────────────────────────────────────
            if (top->hblank_n_in && top->vblank_n_in && top->clk_pix) {
                int cx = hcnt - 1;
                int cy = vcnt;
                if (cx < 0) cx = VID_H_ACTIVE - 1;
                fb.set(cx, cy, top->rgb_r, top->rgb_g, top->rgb_b);
            }

            // ── CPU bus diagnostics ───────────────────────────────────────────
            {
                bool cur_asn    = (bool)top->dbg_cpu_as_n;
                bool cur_halted = !(bool)top->dbg_cpu_halted_n;
                if (!cur_asn) {
                    ++as_cycles;
                    if (prev_asn && !top->dbg_cpu_rw) {
                        ++write_count;
                        if (write_count <= 10) {
                            uint32_t ba = ((uint32_t)top->dbg_cpu_addr) << 1;
                            fprintf(stderr, "  [%7" PRIu64 "] WR addr=0x%06X data=0x%04X\n",
                                    iter, ba, (unsigned)top->dbg_cpu_dout);
                        }
                    }
                }
                if (cur_halted && !halted) {
                    halted = true;
                    fprintf(stderr, "\n*** CPU HALTED at iter=%" PRIu64 " as=%lu writes=%lu ***\n\n",
                            iter, (unsigned long)as_cycles, (unsigned long)write_count);
                }
                prev_asn = cur_asn;
            }

            // ── Periodic status ───────────────────────────────────────────────
            if ((iter % 100000) == 0 && iter > 0) {
                uint32_t ba = ((uint32_t)top->dbg_cpu_addr) << 1;
                fprintf(stderr, "  @%luK: as=%lu writes=%lu frame=%d/%d addr=0x%06X\n",
                        (unsigned long)(iter/1000),
                        (unsigned long)as_cycles, (unsigned long)write_count,
                        frame_num, n_frames, ba);
            }

            // ── Frame detection on vsync_n falling edge ────────────────────────
            uint8_t vsync_n_now = top->vsync_n;
            if (vsync_n_prev == 1 && vsync_n_now == 0) {
                char fname[64];
                snprintf(fname, sizeof(fname), "frame_%04d.ppm", frame_num);
                bool blank = fb.is_blank();
                fb.write_ppm(fname);
                fprintf(stderr, "Frame %4d: %s\n", frame_num,
                        blank ? "BLACK" : "has pixels");
                fb = FrameBuffer();
                frame_num++;
                if (frame_num >= n_frames) done = true;
            }
            vsync_n_prev = vsync_n_now;

        } else {
            // ── Falling edge eval ─────────────────────────────────────────────
            top->clk_pix = 0;
            top->enPhi1  = 0;
            top->enPhi2  = 0;
            top->eval();
            if (vcd) vcd->dump((vluint64_t)(vcd_ts++));
        }
    }

    fprintf(stderr, "\nSimulation complete: %d frames, %" PRIu64 " iters\n",
            frame_num, iter);
    fprintf(stderr, "CPU: %lu AS cycles, %lu writes, halted=%s\n",
            (unsigned long)as_cycles, (unsigned long)write_count,
            halted ? "YES" : "NO");

    if (vcd) { vcd->close(); delete vcd; }
    top->final();
    delete top;
    return 0;
}
