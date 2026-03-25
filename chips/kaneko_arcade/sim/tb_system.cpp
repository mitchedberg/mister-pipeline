// =============================================================================
// tb_system.cpp — Kaneko16 Arcade full-system Verilator testbench
//
// Wraps tb_top.sv (which includes kaneko_arcade + fx68k CPU) and drives:
//   - Clock (32 MHz) and reset
//   - Five ROM/data channels (prog, gfx 32-bit, adpcm, z80)
//   - Player inputs (held at 0xFF = no input, active-low)
//
// The CPU (fx68k) is inside tb_top.sv and executes the real Berlin Wall ROM.
//
// Key differences from NMK testbench:
//   - 32 MHz system clock (not 40 MHz); pixel divider /5 = ~6.4 MHz
//   - kaneko_arcade generates internal video timing (320×240 from kaneko16.sv)
//     so NO video timing inputs are driven here; we capture using DUT hblank/vblank
//   - GFX ROM is 32-bit wide: C++ reads TWO consecutive 16-bit SDRAM words and
//     assembles them combinationally (zero-latency, like NMK sprite/BG channels)
//   - clk_sound_cen: 1-cycle pulse every 32 sys clocks (~1 MHz)
//   - SDRAM layout:
//       0x000000 — CPU program ROM (up to 1MB)
//       0x100000 — GFX ROM (up to 4MB; 2 × 16-bit words = 1 × 32-bit word)
//       0x500000 — ADPCM ROM (OKI M6295)
//       0x580000 — Z80 sound ROM (32KB)
//
// Environment variables:
//   N_FRAMES   — number of vertical frames to simulate (default 30)
//   ROM_PROG   — path to program ROM binary  (SDRAM 0x000000)
//   ROM_GFX    — path to GFX ROM binary      (SDRAM 0x100000, 32-bit assembled)
//   ROM_ADPCM  — path to ADPCM ROM binary    (SDRAM 0x500000)
//   ROM_Z80    — path to Z80 sound ROM binary(SDRAM 0x580000)
//   DUMP_VCD   — set to "1" to enable VCD trace (slow)
//
// Output:
//   frame_NNNN.ppm — one PPM file per vertical frame
//
// Video resolution: 320×240 (Kaneko16 standard — kaneko_arcade.sv generates this)
//   Horizontal: 320 active pixels  (H_TOTAL = 416)
//   Vertical:   240 active lines   (V_TOTAL = 264)
//   Pixel clock: ~6.4 MHz (32 MHz / 5)
//   Iters per frame: 416 × 264 × 5 × 2 = 1,098,240  (budget: 1,200,000)
// =============================================================================

#include "Vtb_top.h"
#include "Vtb_top_tb_top.h"    // access to sub-module internal arrays
#include "verilated.h"
#include "verilated_vcd_c.h"

#include "sdram_model.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>

// ── Video frame buffer ───────────────────────────────────────────────────────
// Kaneko16 native resolution: 320×240 (matches kaneko_arcade.sv H_ACTIVE/V_ACTIVE)
static constexpr int VID_H_ACTIVE = 320;
static constexpr int VID_V_ACTIVE = 240;

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
};

// =============================================================================
// WRAM dump helpers — for gate-5 comparison against MAME Lua dumps
// =============================================================================
//
// MAME Lua dump format (dump_berlwall.lua):
//   Per frame: 65536 bytes  = 32768 × 16-bit words, high byte first (big-endian)
//   Addresses: 0x200000–0x20FFFF (work RAM)
//
// Verilator struct path:
//   top->tb_top->__PVT__u_kaneko__DOT__work_ram   (VlUnpacked<SData,32768>)
//
// Environment variable:
//   RAM_DUMP — path for per-frame WRAM binary dump
//

static inline void write_byte(FILE* f, uint8_t b) {
    fwrite(&b, 1, 1, f);
}

// Write a 16-bit word as two bytes in 68000 big-endian order (MSB first).
static inline void write_word_be(FILE* f, uint16_t w) {
    uint8_t b[2] = { (uint8_t)(w >> 8), (uint8_t)(w & 0xFF) };
    fwrite(b, 1, 2, f);
}

// Dump one frame of RAM to the binary file.
// Format: 4B LE frame# + 64KB work_ram + 4KB palette_ram
// Total: 4 + 65536 + 4096 = 69636 bytes per frame
static void dump_frame_ram(FILE* f, uint32_t frame_num, Vtb_top* top) {
    auto* r = top->tb_top;

    // ── 4-byte LE frame number ───────────────────────────────────────────────
    uint8_t hdr[4] = {
        (uint8_t)(frame_num & 0xFF),
        (uint8_t)((frame_num >> 8) & 0xFF),
        (uint8_t)((frame_num >> 16) & 0xFF),
        (uint8_t)((frame_num >> 24) & 0xFF)
    };
    fwrite(hdr, 1, 4, f);

    // ── Work RAM: 64KB = 32768 words at byte 0x200000–0x20FFFF ──────────────
    for (int i = 0; i < 32768; i++)
        write_word_be(f, (uint16_t)r->__PVT__u_kaneko__DOT__work_ram[i]);

    // ── Palette RAM: 4KB = 2048 words at byte 0x400000–0x400FFF ──────────────
    for (int i = 0; i < 2048; i++)
        write_word_be(f, (uint16_t)r->__PVT__u_kaneko__DOT__palette_ram[i]);
}

// =============================================================================
// main
// =============================================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    // ── Configuration from environment ──────────────────────────────────────
    const char* env_frames   = getenv("N_FRAMES");
    const char* env_prog     = getenv("ROM_PROG");
    const char* env_gfx      = getenv("ROM_GFX");
    const char* env_adpcm    = getenv("ROM_ADPCM");
    const char* env_z80      = getenv("ROM_Z80");
    const char* env_vcd      = getenv("DUMP_VCD");
    const char* env_ram_dump = getenv("RAM_DUMP");

    int n_frames = env_frames ? atoi(env_frames) : 30;
    if (n_frames < 1) n_frames = 1;

    fprintf(stderr, "Kaneko16 Arcade simulation: %d frames\n", n_frames);

    // ── Open RAM dump file if requested ──────────────────────────────────────
    FILE* ram_dump_f = nullptr;
    if (env_ram_dump && env_ram_dump[0]) {
        ram_dump_f = fopen(env_ram_dump, "wb");
        if (!ram_dump_f) {
            fprintf(stderr, "WARNING: Cannot open RAM_DUMP file: %s\n", env_ram_dump);
        } else {
            fprintf(stderr, "RAM dump enabled: %s (69636 bytes/frame = 4B frame# + 64KB wram + 4KB palette)\n", env_ram_dump);
        }
    }

    // ── Load ROM data ────────────────────────────────────────────────────────
    // SDRAM layout (byte addresses):
    //   0x000000 — CPU program ROM (1MB max)
    //   0x100000 — GFX ROM (sprites + BG tiles; 32-bit = two consecutive 16-bit words)
    //   0x500000 — ADPCM ROM (OKI M6295)
    //   0x580000 — Z80 ROM (32KB)
    SdramModel sdram;
    if (env_prog)  sdram.load(env_prog,  0x000000);
    if (env_gfx)   sdram.load(env_gfx,   0x100000);
    if (env_adpcm) sdram.load(env_adpcm, 0x500000);
    if (env_z80)   sdram.load(env_z80,   0x580000);

    // ── SDRAM channels ───────────────────────────────────────────────────────
    // prog_ch: toggle-handshake for CPU program ROM (16-bit words)
    ToggleSdramChannel     prog_ch(sdram);
    // gfx: combinational 32-bit read (zero-latency, assembled from two 16-bit reads)
    // adpcm_ch: toggle-handshake byte channel for OKI M6295
    ToggleSdramChannelByte adpcm_ch(sdram);
    // z80_ch: toggle-handshake byte channel for Z80 ROM
    ToggleSdramChannelByte z80_ch(sdram);

    // ── Verilator init ──────────────────────────────────────────────────────
    Verilated::fatalOnError(false);  // suppress assertion halts during CPU reset

    // ── Instantiate DUT ──────────────────────────────────────────────────────
    Vtb_top* top = new Vtb_top();

    // ── Optional VCD trace ───────────────────────────────────────────────────
    VerilatedVcdC* vcd = nullptr;
    if (env_vcd && env_vcd[0] == '1') {
        Verilated::traceEverOn(true);
        vcd = new VerilatedVcdC();
        top->trace(vcd, 99);
        vcd->open("sim_kaneko_arcade.vcd");
        fprintf(stderr, "VCD trace enabled: sim_kaneko_arcade.vcd\n");
    }

    // ── Initial port state ───────────────────────────────────────────────────
    top->clk_sys       = 0;
    top->clk_pix       = 0;
    top->reset_n       = 0;

    // Bus bypass: disabled — CPU reads through kaneko_arcade RTL data mux
    top->bypass_en      = 0;
    top->bypass_data    = 0xFFFF;
    top->bypass_dtack_n = 1;

    // Clock enables: driven from C++
    top->enPhi1 = 0;
    top->enPhi2 = 0;

    // Sound clock enable: driven from C++
    top->clk_sound_cen = 0;

    // SDRAM inputs
    top->prog_rom_data  = 0;
    top->prog_rom_ack   = 0;
    top->gfx_rom_data   = 0;
    top->gfx_rom_ack    = 0;
    top->adpcm_rom_data = 0;
    top->adpcm_rom_ack  = 0;
    top->z80_rom_data   = 0;
    top->z80_rom_ack    = 0;

    // Player inputs — all active-low: release all buttons/coins
    top->joystick_p1   = 0xFF;
    top->joystick_p2   = 0xFF;
    top->coin          = 0x3;   // both coins inactive (active low)
    top->service       = 1;
    top->dipsw1        = 0xFF;
    top->dipsw2        = 0xFF;

    // ── Simulation state ─────────────────────────────────────────────────────
    int      frame_num  = 0;
    bool     done       = false;

    // Pixel clock divider: /5 from 32 MHz = ~6.4 MHz
    static constexpr int PIX_DIV = 5;
    int      pix_div_cnt = 0;

    // Sound clock enable divider: /32 from 32 MHz = ~1 MHz
    static constexpr int SND_DIV = 32;
    int      snd_div_cnt = 0;

    // Frame buffer and pixel capture
    FrameBuffer fb;

    // vsync edge detection (DUT output)
    uint8_t vsync_n_prev = 1;

    // Horizontal/vertical counters for pixel position tracking
    // kaneko_arcade generates its own timing internally; we track externally
    // for frame buffer filling using the DUT's hblank/vblank outputs.
    // We use a simple x/y counter reset on hblank/vblank edges.
    int px = 0;   // current pixel x within active area
    int py = 0;   // current pixel y within active area
    bool prev_hblank = false;
    bool prev_vblank = false;

    bool     phi_toggle      = false;
    bool     prev_asn        = true;
    int      bus_cycles      = 0;
    uint64_t iter            = 0;
    bool     halted_reported = false;

    static constexpr int RESET_ITERS = 20;

    top->reset_n = 0;

    // VCD timestamp counter
    uint64_t vcd_ts = 0;

    // Budget: 1,200,000 iters/frame = 416×264×5×2 (320×240 @ 32MHz/5 pixel div, +~10% margin)
    for (iter = 0; iter < (uint64_t)n_frames * 1200000ULL; iter++) {
        // Toggle clock
        top->clk_sys = top->clk_sys ^ 1;

        // Release reset after RESET_ITERS half-cycles
        if (iter >= RESET_ITERS) top->reset_n = 1;

        if (top->clk_sys == 1) {
            // ── Rising edge ──────────────────────────────────────────────────

            // Phi enables: alternate every rising edge (CPU runs at sys/2 = 16 MHz)
            top->enPhi1 = phi_toggle ? 0 : 1;
            top->enPhi2 = phi_toggle ? 1 : 0;
            phi_toggle  = !phi_toggle;

            // Pixel clock enable: 1-cycle pulse every PIX_DIV rising edges
            ++pix_div_cnt;
            if (pix_div_cnt >= PIX_DIV) {
                pix_div_cnt    = 0;
                top->clk_pix   = 1;
            } else {
                top->clk_pix   = 0;
            }

            // Sound clock enable: 1-cycle pulse every SND_DIV rising edges
            ++snd_div_cnt;
            if (snd_div_cnt >= SND_DIV) {
                snd_div_cnt        = 0;
                top->clk_sound_cen = 1;
            } else {
                top->clk_sound_cen = 0;
            }

            // ── Program ROM channel (toggle-handshake, 16-bit) ────────────────
            {
                auto r = prog_ch.tick(top->prog_rom_req,
                                      (uint32_t)top->prog_rom_addr << 1);
                top->prog_rom_data = r.data;
                top->prog_rom_ack  = r.ack;
            }

            // ── GFX ROM channel (32-bit combinational, zero-latency) ──────────
            // kaneko16 fetches 32-bit GFX ROM words via toggle-handshake.
            // For simulation we provide zero-latency combinational reads:
            // assemble 32 bits from two consecutive 16-bit SDRAM words at
            //   SDRAM_base + gfx_rom_addr*2     → bits [15:0]  (lower word)
            //   SDRAM_base + gfx_rom_addr*2 + 2 → bits [31:16] (upper word)
            // SDRAM layout: GFX ROM at byte offset 0x100000.
            {
                uint32_t gfx_byte_base = 0x100000u + ((uint32_t)top->gfx_rom_addr << 1);
                uint16_t lo = sdram.read_word(gfx_byte_base);
                uint16_t hi = sdram.read_word(gfx_byte_base + 2);
                top->gfx_rom_data = ((uint32_t)hi << 16) | lo;
                top->gfx_rom_ack  = top->gfx_rom_req;  // immediate ack
            }

            // ── ADPCM ROM channel (toggle-handshake, byte) ────────────────────
            // adpcm_rom_addr is a byte address; SDRAM offset 0x500000.
            {
                uint32_t adpcm_byte_addr = 0x500000u + (uint32_t)top->adpcm_rom_addr;
                auto r = adpcm_ch.tick(top->adpcm_rom_req, adpcm_byte_addr);
                top->adpcm_rom_data = r.data;
                top->adpcm_rom_ack  = r.ack;
            }

            // ── Z80 ROM channel (toggle-handshake, byte) ──────────────────────
            // z80_rom_addr is a 16-bit Z80 address; SDRAM offset 0x580000.
            {
                uint32_t z80_byte_addr = 0x580000u + (uint32_t)top->z80_rom_addr;
                auto r = z80_ch.tick(top->z80_rom_req, z80_byte_addr);
                top->z80_rom_data = r.data;
                top->z80_rom_ack  = r.ack;
            }

            // ── Bus diagnostics ────────────────────────────────────────────────
            {
                uint8_t  asn_c  = top->dbg_cpu_as_n;
                uint8_t  rwn_c  = top->dbg_cpu_rw;
                uint32_t addr_c = ((uint32_t)top->dbg_cpu_addr << 1) & 0xFFFFFF;
                uint16_t dout_c = (uint16_t)top->dbg_cpu_dout;
                uint16_t din_c  = (uint16_t)top->dbg_cpu_din;

                if (!prev_asn && asn_c) {
                    bus_cycles++;
                }

                // Log first 200 bus cycles for boot diagnostics
                bool log_this = (!asn_c && prev_asn && iter > RESET_ITERS) &&
                                (bus_cycles < 200);

                // Also log ALL bus cycles when CPU address is in key milestone regions:
                //   0x0000B4E-0x0000B7E: WRAM march test
                //   0x00089A:            JSR $28014 (MCU protection call)
                //   0x000880-0x00089E:   sprite data copy + JSR
                //   0x000490-0x0004C0:   TRAP #3 handler
                //   0x028014-0x028020:   MCU protection stub
                //   0x000ADE-0x000AF0:   state counter increment path
                // Track BC at 100000 boundaries to find where CPU is executing
                static uint32_t next_bc_check = 100000;
                if (bus_cycles >= (int)next_bc_check && !prev_asn && asn_c) {
                    fprintf(stderr, "  [bc_check %7d] current_addr=%06X\n", bus_cycles, addr_c);
                    next_bc_check += 100000;
                }
                bool in_milestone = (!asn_c && iter > RESET_ITERS) &&
                    ((addr_c >= 0x000B4E && addr_c <= 0x000B82) ||
                     (addr_c >= 0x000880 && addr_c <= 0x0008A0) ||
                     (addr_c >= 0x000490 && addr_c <= 0x0004C0) ||
                     (addr_c >= 0x028010 && addr_c <= 0x028020) ||
                     (addr_c >= 0x000ADE && addr_c <= 0x000AF0));

                if (log_this || in_milestone) {
                    fprintf(stderr, "  [bc%6d] RW=%d addr=%06X dtack=%d dout=%04X din=%04X iack=%d\n",
                            bus_cycles, (int)rwn_c, addr_c,
                            (int)top->dbg_cpu_dtack_n, dout_c, din_c,
                            (int)top->tb_top->dbg_iack);
                }

                // Detect CPU halt
                if (top->dbg_cpu_halted_n == 0 && iter > RESET_ITERS + 100 && !halted_reported) {
                    halted_reported = true;
                    fprintf(stderr, "\n*** CPU HALTED at iter %lu (bus_cycles=%d) ***\n",
                            (unsigned long)iter, bus_cycles);
                }

                prev_asn = asn_c;
            }

        } else {
            // ── Falling edge ─────────────────────────────────────────────────
            top->enPhi1        = 0;
            top->enPhi2        = 0;
            top->clk_pix       = 0;
            top->clk_sound_cen = 0;
        }

        top->eval();
        if (vcd) vcd->dump((uint64_t)vcd_ts);
        ++vcd_ts;

        // ── Pixel capture (on rising edge, after eval) ────────────────────────
        // kaneko_arcade generates its own hblank/vblank signals.
        // Track pixel position using transitions of these signals.
        if (top->clk_sys == 1) {
            bool cur_hblank = (bool)top->hblank;
            bool cur_vblank = (bool)top->vblank;

            // On hblank falling edge (entering active region): reset x
            if (prev_hblank && !cur_hblank) {
                px = 0;
            }
            // On vblank falling edge (entering active frame): reset y
            if (prev_vblank && !cur_vblank) {
                py = 0;
            }

            // Capture pixel when in active area and pixel clock is enabled
            if (!cur_hblank && !cur_vblank && top->clk_pix) {
                fb.set(px, py, top->rgb_r, top->rgb_g, top->rgb_b);
                ++px;
                if (px >= VID_H_ACTIVE) px = 0;
            }

            // Increment y on hblank rising edge (end of active line) within active frame
            if (!prev_hblank && cur_hblank && !cur_vblank) {
                ++py;
                if (py >= VID_V_ACTIVE) py = VID_V_ACTIVE - 1;
            }

            prev_hblank = cur_hblank;
            prev_vblank = cur_vblank;
        }

        // ── Vsync edge detection → frame save ─────────────────────────────────
        {
            uint8_t vsync_n_now = top->vsync_n;
            if (vsync_n_prev == 1 && vsync_n_now == 0) {
                // vsync falling edge = start of vertical sync = end of active frame
                char fname[64];
                snprintf(fname, sizeof(fname), "frame_%04d.ppm", frame_num);
                if (fb.write_ppm(fname))
                    fprintf(stderr, "Frame %4d written: %s  (bus_cycles=%d)\n",
                            frame_num, fname, bus_cycles);

                // Dump RAM regions for gate-5 comparison against MAME golden
                if (ram_dump_f) dump_frame_ram(ram_dump_f, (uint32_t)frame_num, top);

                ++frame_num;
                if (frame_num >= n_frames) done = true;
                fb = FrameBuffer();
                px = 0;
                py = 0;
            }
            vsync_n_prev = vsync_n_now;
        }

        if (done) break;

        if ((iter % 2000000) == 0 && iter > 0) {
            fprintf(stderr, "  iter %lu  bus_cycles=%d  frame=%d\n",
                    (unsigned long)iter, bus_cycles, frame_num);
        }
    }

    // ── Final cleanup ─────────────────────────────────────────────────────────
    if (ram_dump_f) {
        fclose(ram_dump_f);
        fprintf(stderr, "RAM dump closed: %d frames × 65536 bytes = %d bytes total\n",
                frame_num, frame_num * 65536);
    }
    if (vcd) {
        vcd->close();
        delete vcd;
    }
    top->final();
    delete top;

    fprintf(stderr, "Simulation complete. %d frames captured, %lu iters (%d bus cycles).\n",
            frame_num, (unsigned long)iter, bus_cycles);
    return 0;
}
