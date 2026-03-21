// =============================================================================
// tb_system.cpp — Toaplan V2 (Batsugun) Verilator testbench
//
// Wraps tb_top.sv (which includes toaplan_v2 + fx68k CPU) and drives:
//   - Clock (32 MHz system) and reset
//   - Video timing (generated internally by toaplan_v2; 320×240 @ ~60 Hz)
//   - SDRAM channels:
//       prog_rom:  toggle-handshake 16-bit (CPU program ROM)
//       gfx_rom:   toggle-handshake 32-bit (GP9001 tile + sprite data)
//       adpcm_rom: toggle-handshake 16-bit (OKI M6295 ADPCM)
//       z80_rom:   toggle-handshake 8-bit  (Z80 sound CPU ROM)
//   - Player inputs (all held at 0xFF = no input, active-low)
//
// The CPU (fx68k) is inside tb_top.sv and executes the real Batsugun ROM.
//
// Environment variables:
//   N_FRAMES   — number of vertical frames to simulate (default 30)
//   ROM_PROG   — path to CPU program ROM binary  (SDRAM 0x000000)
//   ROM_GFX    — path to GFX ROM binary (32-bit wide, SDRAM 0x100000)
//   ROM_ADPCM  — path to ADPCM ROM binary        (SDRAM 0x500000)
//   ROM_Z80    — path to Z80 sound ROM binary     (SDRAM 0x600000)
//   DUMP_VCD   — set to "1" to enable VCD trace (slow)
//
// Output:
//   frame_NNNN.ppm — one PPM file per vertical frame (320×240)
//
// Video timing: 320×240 (internal to toaplan_v2)
//   Horizontal: 320 active + 96 blanking = 416 total pixels/line
//   Vertical:   240 active + 24 blanking = 264 total lines/frame
//   At 32 MHz system clock, pixel clock divider = 4 → 8 MHz pixel clock
//   Htotal = 416, Vtotal = 264 → ~73 Hz (pixel) / 60 Hz (frame)
//   Actually: 32 MHz / (416 × 264) ≈ 291 Hz? No — at 8 MHz pixel clock:
//   8 MHz / (416 × 264) ≈ 72.8 Hz...
//   For Toaplan V2: sys_clk = 32 MHz, pix_clk = 8 MHz (CE every 4 sys clks)
// =============================================================================

#include "Vtb_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include "Vtb_top___024root.h"
#include "sdram_model.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <cinttypes>

// ── Video timing constants (Toaplan V2 / GP9001 standard 320×240) ───────────
// Internal to toaplan_v2.sv — testbench only needs to count pixels for capture
static constexpr int VID_H_ACTIVE  = 320;
static constexpr int VID_V_ACTIVE  = 240;
static constexpr int VID_H_TOTAL   = 416;
static constexpr int VID_V_TOTAL   = 264;

// Pixel clock: one pixel every 4 system clocks (8 MHz from 32 MHz)
static constexpr int PIX_DIV = 4;

// Sound clock: Z80/YM2151 CE @ ~3.5 MHz from 32 MHz → every ~9 sys clocks
// 32 MHz / 3.5 MHz ≈ 9.14 → use 9
static constexpr int SND_DIV = 9;

// =============================================================================
// Frame buffer
// =============================================================================
struct FrameBuffer {
    static constexpr int W = VID_H_ACTIVE;
    static constexpr int H = VID_V_ACTIVE;
    std::vector<uint32_t> pixels;  // RGB packed: (r<<16)|(g<<8)|b

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
};

// =============================================================================
// main
// =============================================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    // ── Configuration from environment ──────────────────────────────────────
    const char* env_frames  = getenv("N_FRAMES");
    const char* env_prog    = getenv("ROM_PROG");
    const char* env_gfx     = getenv("ROM_GFX");
    const char* env_adpcm   = getenv("ROM_ADPCM");
    const char* env_z80     = getenv("ROM_Z80");
    const char* env_vcd     = getenv("DUMP_VCD");

    int n_frames = env_frames ? atoi(env_frames) : 30;
    if (n_frames < 1) n_frames = 1;

    fprintf(stderr, "Toaplan V2 (Batsugun) simulation: %d frames\n", n_frames);

    // ── Load ROM data ────────────────────────────────────────────────────────
    SdramModel sdram;

    // CPU program ROM: SDRAM byte 0x000000
    if (env_prog)  sdram.load(env_prog,  0x000000);

    // GFX ROM: SDRAM byte 0x100000 (4 MB, 32-bit wide tiles/sprites)
    if (env_gfx)   sdram.load(env_gfx,   0x100000);

    // ADPCM ROM: SDRAM byte 0x500000
    if (env_adpcm) sdram.load(env_adpcm, 0x500000);

    // Z80 ROM: SDRAM byte 0x600000 (byte-wide)
    if (env_z80)   sdram.load(env_z80,   0x600000);

    // ── SDRAM channels ───────────────────────────────────────────────────────
    ToggleSdramChannel     prog_ch(sdram);
    ToggleSdramChannel32   gfx_ch(sdram);
    ToggleSdramChannel     adpcm_ch(sdram);
    ToggleSdramChannelByte z80_ch(sdram);

    // ── Verilator init ───────────────────────────────────────────────────────
    Verilated::fatalOnError(false);  // suppress fx68k unique-case $stop during reset

    // ── Instantiate DUT ──────────────────────────────────────────────────────
    Vtb_top* top = new Vtb_top();

    // ── Optional VCD trace ───────────────────────────────────────────────────
    VerilatedVcdC* vcd = nullptr;
    if (env_vcd && env_vcd[0] == '1') {
        Verilated::traceEverOn(true);
        vcd = new VerilatedVcdC();
        top->trace(vcd, 99);
        vcd->open("sim_toaplan_v2.vcd");
        fprintf(stderr, "VCD trace enabled: sim_toaplan_v2.vcd\n");
    }

    // ── Initial port state ───────────────────────────────────────────────────
    top->clk_sys    = 0;
    top->clk_pix    = 0;
    top->clk_sound  = 0;
    top->reset_n    = 0;

    // Bus bypass: disabled — CPU reads through toaplan_v2 RTL data mux + DTACK
    top->bypass_en      = 0;
    top->bypass_data    = 0xFFFF;
    top->bypass_dtack_n = 1;

    // Clock enables: driven from C++
    top->enPhi1 = 0;
    top->enPhi2 = 0;

    // SDRAM inputs
    top->prog_rom_data   = 0;
    top->prog_rom_ack    = 0;
    top->gfx_rom_data    = 0;
    top->gfx_rom_ack     = 0;
    top->adpcm_rom_data  = 0;
    top->adpcm_rom_ack   = 0;
    top->z80_rom_data    = 0;
    top->z80_rom_ack     = 0;

    // Player inputs — all active-low: release all buttons/coins
    top->joystick_p1 = 0xFF;
    top->joystick_p2 = 0xFF;
    top->coin        = 0x3;   // both coins inactive (active low)
    top->service     = 1;
    top->dipsw1      = 0xFF;
    top->dipsw2      = 0xFF;

    // ── Simulation state ─────────────────────────────────────────────────────
    uint64_t iter         = 0;
    int      frame_num    = 0;
    bool     done         = false;

    // Video pixel counters (mirror toaplan_v2's internal timing)
    int      hcnt         = 0;   // [0, H_TOTAL)
    int      vcnt         = 0;   // [0, V_TOTAL)
    int      pix_div_cnt  = 0;   // pixel clock divider
    int      snd_div_cnt  = 0;   // sound clock divider

    // Frame buffer and pixel capture
    FrameBuffer fb;

    // vsync edge detection
    uint8_t vsync_n_prev = 1;

    // Phi toggle
    bool phi_toggle = false;

    // Bus diagnostics
    int      bus_cycles_c      = 0;
    bool     prev_asn_c        = true;
    bool     halted_reported   = false;
    int      pal_wr_count      = 0;
    int      wram_wr_count     = 0;

    // Stall detection: track repeated reads to the same address
    uint32_t last_read_addr    = 0xFFFFFFFF;
    int      last_read_repeat  = 0;
    int      stall_reported    = 0;

    // Reset duration
    static constexpr int RESET_ITERS = 20;

    top->reset_n = 0;

    // VCD timestamp
    uint64_t vcd_ts = 0;

    // ========================================================================
    // MAIN EVAL LOOP
    //
    // One eval per clock toggle (posedge / negedge).
    // Phi enabled on rising edge, cleared on falling edge (matching NMK pattern).
    // SDRAM channels ticked on every rising edge.
    // Pixel clock: 1-cycle pulse every PIX_DIV rising edges.
    // Sound clock: 1-cycle pulse every SND_DIV rising edges.
    // ========================================================================
    fprintf(stderr, "Running RTL BUS eval loop (bypass_en=0)...\n");

    for (iter = 0; !done && iter < (uint64_t)n_frames * 800000ULL; iter++) {
        // Toggle clock
        top->clk_sys = top->clk_sys ^ 1;

        // Release reset after RESET_ITERS half-cycles
        if (iter >= RESET_ITERS) top->reset_n = 1;

        if (top->clk_sys == 1) {
            // ── Rising edge ──────────────────────────────────────────────────

            // Phi enables (C++-driven, matching minimal-test pattern)
            top->enPhi1 = phi_toggle ? 0 : 1;
            top->enPhi2 = phi_toggle ? 1 : 0;
            phi_toggle  = !phi_toggle;

            // Pixel clock: 1-cycle pulse every PIX_DIV sys clocks
            ++pix_div_cnt;
            if (pix_div_cnt >= PIX_DIV) {
                pix_div_cnt = 0;
                top->clk_pix = 1;

                // Advance our pixel counters (mirrors toaplan_v2 internal)
                ++hcnt;
                if (hcnt >= VID_H_TOTAL) {
                    hcnt = 0;
                    ++vcnt;
                    if (vcnt >= VID_V_TOTAL) vcnt = 0;
                }
            } else {
                top->clk_pix = 0;
            }

            // Sound clock: ~3.5 MHz CE
            ++snd_div_cnt;
            if (snd_div_cnt >= SND_DIV) {
                snd_div_cnt  = 0;
                top->clk_sound = 1;
            } else {
                top->clk_sound = 0;
            }

            // ── SDRAM channels ───────────────────────────────────────────────

            // Program ROM: combinational zero-latency (bypass toggle-handshake).
            // toaplan_v2's prog_rom_addr is a REGISTERED word address (lags CPU
            // addr by 1 cycle). Since dtack asserts the same cycle as AS_n, we
            // must use the LIVE CPU byte address (dbg_cpu_addr << 1) to get
            // the correct data for the current bus cycle.
            {
                uint32_t prog_byte_addr = ((uint32_t)top->dbg_cpu_addr << 1) & 0x0FFFFFu;
                top->prog_rom_data = sdram.read_word(prog_byte_addr);
                top->prog_rom_ack  = top->prog_rom_req;  // always ack immediately
            }

            // GFX ROM: combinational zero-latency (bypass toggle-handshake).
            // gfx_rom_addr is a WORD address; *2 for byte addr.
            // SDRAM GFX base is 0x100000 (added when sdram.load() was called).
            {
                uint32_t gfx_byte_addr = (uint32_t)top->gfx_rom_addr * 2u + 0x100000u;
                top->gfx_rom_data = sdram.read_dword(gfx_byte_addr);
                top->gfx_rom_ack  = top->gfx_rom_req;  // always ack immediately
            }

            // ADPCM ROM: toggle-handshake 16-bit
            {
                auto r = adpcm_ch.tick(top->adpcm_rom_req,
                                       (uint32_t)top->adpcm_rom_addr);
                top->adpcm_rom_data = r.data;
                top->adpcm_rom_ack  = r.ack;
            }

            // Z80 ROM: byte-wide, at SDRAM 0x600000
            {
                uint32_t z80_byte_addr = 0x600000u + (uint32_t)top->z80_rom_addr;
                auto r = z80_ch.tick(top->z80_rom_req, z80_byte_addr);
                top->z80_rom_data = r.data;
                top->z80_rom_ack  = r.ack;
            }

            // ── Bus diagnostics ──────────────────────────────────────────────
            {
                uint8_t  asn_c  = top->dbg_cpu_as_n;
                uint8_t  rwn_c  = top->dbg_cpu_rw;
                uint32_t addr_c = ((uint32_t)top->dbg_cpu_addr << 1) & 0xFFFFFF;

                // Cycle-level trace: log EVERY clock when AS_n=0 near the stall
                // to see what happens to din/dout/dtack cycle by cycle
                if (!asn_c && iter > RESET_ITERS && bus_cycles_c >= 114760 && bus_cycles_c <= 114875) {
                    fprintf(stderr, "  [iter%7" PRIu64 "|bc%d] ASn=%d RW=%d addr=%06X dtack_n=%d din=%04X dout=%04X uds=%d lds=%d\n",
                            iter, bus_cycles_c, (int)asn_c, (int)rwn_c, addr_c,
                            (int)top->dbg_cpu_dtack_n,
                            (unsigned)(top->dbg_cpu_din & 0xFFFF),
                            (unsigned)(top->dbg_cpu_dout & 0xFFFF),
                            (int)top->dbg_cpu_uds_n,
                            (int)top->dbg_cpu_lds_n);
                }

                // Count bus cycles on AS_n falling edge (new cycle start)
                if (!asn_c && prev_asn_c && iter > RESET_ITERS) {
                    bus_cycles_c++;

                    // Log first 60 bus cycles in detail
                    if (bus_cycles_c <= 60) {
                        fprintf(stderr, "  [%6" PRIu64 "|bc%d] ASn=0 RW=%d addr=%06X dtack_n=%d dout=%04X\n",
                                iter, bus_cycles_c, (int)rwn_c, addr_c,
                                (int)top->dbg_cpu_dtack_n,
                                (unsigned)(top->dbg_cpu_dout & 0xFFFF));
                    }

                    // Log bus cycles near the 114K stall point
                    if (bus_cycles_c >= 114700) {
                        fprintf(stderr, "  [bc%d] RW=%d addr=%06X dtack_n=%d din=%04X dout=%04X\n",
                                bus_cycles_c, (int)rwn_c, addr_c,
                                (int)top->dbg_cpu_dtack_n,
                                (unsigned)(top->dbg_cpu_din & 0xFFFF),
                                (unsigned)(top->dbg_cpu_dout & 0xFFFF));
                    }

                    // Track repeated reads to same address (polling loop detection)
                    if (rwn_c && addr_c == last_read_addr) {
                        last_read_repeat++;
                        if (last_read_repeat == 100 && stall_reported < 5) {
                            stall_reported++;
                            fprintf(stderr, "\n*** STALL DETECTED at bc=%d: addr=%06X read 100+ times, dout=%04X ***\n",
                                    bus_cycles_c, addr_c,
                                    (unsigned)(top->dbg_cpu_dout & 0xFFFF));
                        }
                    } else {
                        last_read_addr   = addr_c;
                        last_read_repeat = rwn_c ? 1 : 0;
                    }

                    // Track palette and work RAM writes
                    if (!rwn_c) {
                        // Truxton II palette at 0x300000; Batsugun at 0x500000
                        if ((addr_c >= 0x300000 && addr_c <= 0x300FFF) ||
                            (addr_c >= 0x500000 && addr_c <= 0x5003FF)) {
                            ++pal_wr_count;
                            if (pal_wr_count <= 5)
                                fprintf(stderr, "  PAL WR #%d addr=%06X data=%04X\n",
                                        pal_wr_count, addr_c,
                                        (unsigned)(top->dbg_cpu_din & 0xFFFF));
                        }
                        if (addr_c >= 0x100000 && addr_c <= 0x10FFFF) {
                            ++wram_wr_count;
                            if (wram_wr_count <= 3)
                                fprintf(stderr, "  WRAM WR #%d addr=%06X\n",
                                        wram_wr_count, addr_c);
                        }
                    }
                }

                // Periodic status summary
                if (bus_cycles_c > 0 && (bus_cycles_c % 10000) == 0 &&
                    !prev_asn_c && asn_c) {
                    fprintf(stderr, "  [%dK bus] pal_wr=%d wram_wr=%d frame=%d\n",
                            bus_cycles_c / 1000, pal_wr_count, wram_wr_count,
                            frame_num);
                }

                // Detect CPU halt
                if (top->dbg_cpu_halted_n == 0 && iter > RESET_ITERS + 100 &&
                    !halted_reported) {
                    halted_reported = true;
                    fprintf(stderr,
                            "\n*** CPU HALTED at iter %" PRIu64
                            " (bus_cycles=%d) ***\n",
                            iter, bus_cycles_c);
                }

                prev_asn_c = asn_c;
            }

        } else {
            // ── Falling edge ─────────────────────────────────────────────────
            top->enPhi1    = 0;
            top->enPhi2    = 0;
            top->clk_pix   = 0;
            top->clk_sound = 0;
        }

        top->eval();
        if (vcd) vcd->dump((vluint64_t)vcd_ts);
        ++vcd_ts;

        // ── Pixel capture (on rising edge, after eval) ───────────────────────
        if (top->clk_sys == 1) {
            bool active = (!top->vblank) && (!top->hblank);
            if (active) {
                // Use internal hcnt/vcnt which track toaplan_v2 timing
                int cx = hcnt - 1;  // hcnt incremented above before eval
                int cy = vcnt;
                if (cx < 0) cx = 0;
                if (cx >= 0 && cx < VID_H_ACTIVE && cy >= 0 && cy < VID_V_ACTIVE)
                    fb.set(cx, cy, top->rgb_r, top->rgb_g, top->rgb_b);
            }
        }

        // ── Vsync edge detection → frame save ────────────────────────────────
        {
            uint8_t vsync_n_now = top->vsync_n;
            if (vsync_n_prev == 1 && vsync_n_now == 0) {
                char fname[64];
                snprintf(fname, sizeof(fname), "frame_%04d.ppm", frame_num);
                if (fb.write_ppm(fname)) {
                    int nonblack = fb.count_nonblack();
                    fprintf(stderr, "Frame %4d written: %s  (bus_cycles=%d, nonblack=%d)\n",
                            frame_num, fname, bus_cycles_c, nonblack);
                }

                ++frame_num;
                if (frame_num >= n_frames) done = true;
                fb = FrameBuffer();
            }
            vsync_n_prev = vsync_n_now;
        }

        if ((iter % 2000000) == 0 && iter > 0) {
            fprintf(stderr, "  iter %" PRIu64 "  bus_cycles=%d  frame=%d\n",
                    iter, bus_cycles_c, frame_num);
        }
    }

    // ── Final summary ────────────────────────────────────────────────────────
    if (vcd) { vcd->close(); delete vcd; }
    top->final();
    delete top;

    fprintf(stderr,
            "\nSimulation complete. %d frames captured, %" PRIu64
            " iters (%d bus cycles).\n",
            frame_num, iter, bus_cycles_c);

    // Report CPU boot status
    if (bus_cycles_c >= 6)
        fprintf(stderr, "CPU BOOT: SUCCESS (>= 6 bus cycles)\n");
    else
        fprintf(stderr, "CPU BOOT: FAIL (only %d bus cycles)\n", bus_cycles_c);

    return 0;
}
