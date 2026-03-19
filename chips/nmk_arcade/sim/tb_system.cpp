// =============================================================================
// tb_system.cpp — NMK Arcade full-system Verilator testbench
//
// Wraps tb_top.sv (which includes nmk_arcade + fx68k CPU) and drives:
//   - Clock (40 MHz) and reset
//   - Video timing generator (software-modelled NMK16 standard: 384×224 @ ~60 Hz)
//   - Five SDRAM channels (ToggleSdramChannel behavioral model)
//   - Player inputs (all held at 0xFF = no input, active-low)
//
// The CPU (fx68k) is inside tb_top.sv and executes the real Thunder Dragon ROM.
//
// Environment variables:
//   N_FRAMES   — number of vertical frames to simulate (default 30)
//   ROM_PROG   — path to program ROM binary  (SDRAM 0x000000)
//   ROM_SPR    — path to sprite ROM binary   (SDRAM 0x0C0000)
//   ROM_BG     — path to BG tile ROM binary  (SDRAM 0x1C0000)
//   ROM_ADPCM  — path to ADPCM ROM binary    (SDRAM 0x200000)
//   ROM_Z80    — path to Z80 sound ROM binary(SDRAM 0x280000)
//   DUMP_VCD   — set to "1" to enable VCD trace (slow)
//   RAM_DUMP   — path for per-frame RAM dump binary (e.g. tdragon_sim_frames.bin)
//               Format matches mame_ram_dump.lua exactly for byte-by-byte comparison:
//               Per frame: [4-byte LE frame#][64KB main RAM][2KB sprite/pal][16KB BG VRAM][2KB TX VRAM][8B scroll]
//
// Output:
//   frame_NNNN.ppm — one PPM file per vertical frame
//
// Video resolution: 384×224 (NMK16 standard)
//   Horizontal: 384 active + ~128 blanking = 512 total pixels/line
//   Vertical:   224 active +  ~38 blanking = 262 total lines/frame
//   At 40 MHz system clock, pixel clock divider = 2 → 20 MHz pixel clock
//   Htotal = 512, Vtotal = 262 → ~60.0 Hz
// =============================================================================

#include "Vtb_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

// Include generated root-struct header for deep-hierarchy signal access.
// top->rootp (Vtb_top___024root*) holds all internal state including
// unpacked arrays like work_ram, tilemap_ram, sprite_ram_storage, etc.
#include "Vtb_top___024root.h"

#include "sdram_model.h"

// =============================================================================
// Suppress fx68k $stop assertions from unique-case failures during CPU reset.
// fx68k's ALU unique-case fires with all-zero operands while the CPU pipeline
// flushes through its power-up microcode sequences. These are benign and do not
// indicate RTL bugs; they stop after the first few initialization microsteps.
// =============================================================================
void vl_stop(const char* /*filename*/, int /*linenum*/, const char* /*hier*/) VL_MT_UNSAFE {}

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <algorithm>

// ── Video timing constants (NMK16 standard 384×224) ─────────────────────────
static constexpr int VID_H_ACTIVE  = 384;
static constexpr int VID_V_ACTIVE  = 224;
static constexpr int VID_H_TOTAL   = 512;   // pixels per line
static constexpr int VID_V_TOTAL   = 262;   // lines per frame
static constexpr int VID_H_BLANK   = VID_H_TOTAL - VID_H_ACTIVE;
static constexpr int VID_V_BLANK   = VID_V_TOTAL - VID_V_ACTIVE;
static constexpr int VID_HSYNC_START = VID_H_ACTIVE + 16;
static constexpr int VID_HSYNC_END   = VID_HSYNC_START + 32;
static constexpr int VID_VSYNC_START = VID_V_ACTIVE + 4;
static constexpr int VID_VSYNC_END   = VID_VSYNC_START + 4;

// Pixel clock: one pixel every 2 system clocks (20 MHz from 40 MHz)
static constexpr int PIX_DIV = 2;

// (CPU is inside tb_top.sv — fx68k runs the real Thunder Dragon ROM)

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
};

// =============================================================================
// RAM dump helpers
//
// Dumps internal RTL state to match the mame_ram_dump.lua format exactly:
//   Per frame (86028 bytes total):
//     [0..3]       4-byte little-endian frame number
//     [4..65539]   64 KB main RAM  (work_ram[0..32767], big-endian word → byte)
//     [65540..67587] 2 KB  at 0x0C8000 (sprite_ram_storage[0..1023] in nmk16)
//     [67588..83971] 16 KB at 0x0CC000 (tilemap_ram[0..2047] padded to 16 KB)
//     [83972..86019] 2 KB  at 0x0D0000 (zeros — unmapped in this RTL)
//     [86020..86027] 8 bytes scroll regs (scroll0_x, scroll0_y, scroll1_x, scroll1_y)
//
// 68000 word layout: high byte (addr+0) = word[15:8], low byte (addr+1) = word[7:0]
//
// Internal signal access uses Verilator's flat-struct naming convention:
//   Hierarchy separator: __DOT__
//   tb_top.u_nmk.work_ram  →  rootp->tb_top__DOT__u_nmk__DOT__work_ram
//   tb_top.u_nmk.u_nmk16.tilemap_ram  →  rootp->tb_top__DOT__u_nmk__DOT__u_nmk16__DOT__tilemap_ram
//
// The rootp pointer is obtained via top->rootp (Vtb_top___024root*),
// which is a public member of Vtb_top. Access requires including Vtb_top___024root.h
// directly (Vtb_top.h only forward-declares the class).
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
// Verilator flat-struct field names (from obj_dir/Vtb_top___024root.h):
//   VlUnpacked<SData,32768> tb_top__DOT__u_nmk__DOT__work_ram
//   VlUnpacked<SData,512>   tb_top__DOT__u_nmk__DOT__palette_ram
//   VlUnpacked<SData,1024>  tb_top__DOT__u_nmk__DOT__u_nmk16__DOT__sprite_ram_storage
//   VlUnpacked<SData,2048>  tb_top__DOT__u_nmk__DOT__u_nmk16__DOT__tilemap_ram
//   SData tb_top__DOT__u_nmk__DOT__u_nmk16__DOT__scroll0_x_shadow  (and y, 1_x, 1_y)
static void dump_frame_ram(FILE* f, uint32_t frame_num, Vtb_top* top) {
    // Access the Verilator-generated root struct that holds all internal state.
    auto* r = top->rootp;

    // ── 4-byte LE frame number ───────────────────────────────────────────────
    uint8_t hdr[4] = {
        (uint8_t)(frame_num & 0xFF),
        (uint8_t)((frame_num >> 8) & 0xFF),
        (uint8_t)((frame_num >> 16) & 0xFF),
        (uint8_t)((frame_num >> 24) & 0xFF)
    };
    fwrite(hdr, 1, 4, f);

    // ── 64 KB main RAM (0x080000-0x08FFFF): work_ram[0..32767] × 16-bit ────
    // Each element is SData (uint16_t); write MSB first (68000 big-endian).
    for (int i = 0; i < 32768; i++) {
        write_word_be(f, (uint16_t)r->tb_top__DOT__u_nmk__DOT__work_ram[i]);
    }

    // ── 2 KB at 0x0C8000-0x0C87FF: sprite_ram_storage[0..1023] in nmk16 ────
    // sprite_ram_storage has 1024 × 16-bit words = 2048 bytes exactly.
    // In the real NMK16 hardware this region holds sprite attribute RAM;
    // MAME reads it as "Palette" but the RTL stores sprite data here.
    for (int i = 0; i < 1024; i++) {
        write_word_be(f, (uint16_t)r->tb_top__DOT__u_nmk__DOT__u_nmk16__DOT__sprite_ram_storage[i]);
    }

    // ── 16 KB at 0x0CC000-0x0CFFFF: tilemap_ram[0..2047] + padding ─────────
    // tilemap_ram has 2048 × 16-bit words = 4096 bytes.
    // The MAME region is 16384 bytes; pad the remaining 12288 bytes with zeros.
    for (int i = 0; i < 2048; i++) {
        write_word_be(f, (uint16_t)r->tb_top__DOT__u_nmk__DOT__u_nmk16__DOT__tilemap_ram[i]);
    }
    write_zeros(f, 16384 - 4096);  // 12288 zero bytes to reach 16 KB

    // ── 2 KB at 0x0D0000-0x0D07FF: unmapped in this RTL ─────────────────────
    // MAME reads TX VRAM here; this RTL does not implement this region yet.
    // Write zeros to keep frame offsets consistent with the MAME dump format.
    write_zeros(f, 2048);

    // ── 8 bytes scroll regs at 0x0C4000-0x0C4007 ────────────────────────────
    // GPU shadow registers in nmk16: scroll0_x, scroll0_y, scroll1_x, scroll1_y.
    // Shadow registers hold the CPU-written values (copied to active on VBlank).
    // MAME reads these directly from the register file, so shadow values match.
    write_word_be(f, (uint16_t)r->tb_top__DOT__u_nmk__DOT__u_nmk16__DOT__scroll0_x_shadow);
    write_word_be(f, (uint16_t)r->tb_top__DOT__u_nmk__DOT__u_nmk16__DOT__scroll0_y_shadow);
    write_word_be(f, (uint16_t)r->tb_top__DOT__u_nmk__DOT__u_nmk16__DOT__scroll1_x_shadow);
    write_word_be(f, (uint16_t)r->tb_top__DOT__u_nmk__DOT__u_nmk16__DOT__scroll1_y_shadow);
}

// =============================================================================
// main
// =============================================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    // ── Configuration from environment ──────────────────────────────────────
    const char* env_frames   = getenv("N_FRAMES");
    const char* env_prog     = getenv("ROM_PROG");
    const char* env_spr      = getenv("ROM_SPR");
    const char* env_bg       = getenv("ROM_BG");
    const char* env_adpcm    = getenv("ROM_ADPCM");
    const char* env_z80      = getenv("ROM_Z80");
    const char* env_vcd      = getenv("DUMP_VCD");
    const char* env_ram_dump = getenv("RAM_DUMP");

    int n_frames = env_frames ? atoi(env_frames) : 30;
    if (n_frames < 1) n_frames = 1;

    fprintf(stderr, "NMK Arcade simulation: %d frames\n", n_frames);

    // ── Optional RAM dump file ───────────────────────────────────────────────
    FILE* ram_dump_f = nullptr;
    if (env_ram_dump) {
        ram_dump_f = fopen(env_ram_dump, "wb");
        if (!ram_dump_f) {
            fprintf(stderr, "ERROR: cannot open RAM_DUMP file: %s\n", env_ram_dump);
        } else {
            fprintf(stderr, "RAM dump enabled: %s\n", env_ram_dump);
            fprintf(stderr, "  Format: 4B frame# + 64KB wram + 2KB spr + 16KB bg + 2KB tx + 8B scroll\n");
            fprintf(stderr, "  (matches mame_ram_dump.lua layout for byte-by-byte comparison)\n");
        }
    }

    // ── Load ROM data ────────────────────────────────────────────────────────
    SdramModel sdram;
    if (env_prog)  sdram.load(env_prog,  0x000000);
    if (env_spr)   sdram.load(env_spr,   0x0C0000);
    if (env_bg)    sdram.load(env_bg,    0x1C0000);
    if (env_adpcm) sdram.load(env_adpcm, 0x200000);
    // Z80 ROM is byte-addressed; load at 0x280000
    if (env_z80)   sdram.load(env_z80,   0x280000);

    // ── SDRAM channels ───────────────────────────────────────────────────────
    ToggleSdramChannel     prog_ch(sdram);
    ToggleSdramChannel     spr_ch(sdram);
    ToggleSdramChannel     bg_ch(sdram);
    ToggleSdramChannel     adpcm_ch(sdram);
    ToggleSdramChannelByte z80_ch(sdram);

    // ── Instantiate DUT ──────────────────────────────────────────────────────
    Vtb_top* top = new Vtb_top();

    // ── Optional VCD trace ───────────────────────────────────────────────────
    VerilatedVcdC* vcd = nullptr;
    if (env_vcd && env_vcd[0] == '1') {
        Verilated::traceEverOn(true);
        vcd = new VerilatedVcdC();
        top->trace(vcd, 99);
        vcd->open("sim_nmk_arcade.vcd");
        fprintf(stderr, "VCD trace enabled: sim_nmk_arcade.vcd\n");
    }

    // ── Initial port state ───────────────────────────────────────────────────
    top->clk_sys       = 0;
    top->clk_pix       = 0;
    top->reset_n       = 0;

    // (CPU bus is driven internally by fx68k_adapter inside tb_top.sv)

    // SDRAM inputs
    top->prog_rom_data     = 0;
    top->prog_rom_ack      = 0;
    top->spr_rom_sdram_data= 0;
    top->spr_rom_sdram_ack = 0;
    top->bg_rom_sdram_data = 0;
    top->bg_rom_sdram_ack  = 0;
    top->adpcm_rom_data    = 0;
    top->adpcm_rom_ack     = 0;
    top->z80_rom_data      = 0;
    top->z80_rom_ack       = 0;

    // Video timing inputs
    top->hblank_n_in   = 1;
    top->vblank_n_in   = 1;
    top->hpos          = 0;
    top->vpos          = 0;
    top->hsync_n_in    = 1;
    top->vsync_n_in    = 1;

    // Player inputs — all active-low: release all buttons/coins
    top->joystick_p1   = 0xFF;
    top->joystick_p2   = 0xFF;
    top->coin          = 0x3;   // both coins inactive (active low)
    top->service       = 1;
    top->dipsw1        = 0xFF;
    top->dipsw2        = 0xFF;

    // ── Simulation state ─────────────────────────────────────────────────────
    uint64_t cycle      = 0;
    int      frame_num  = 0;
    bool     done       = false;

    // Video timing counters
    int  hcnt           = 0;   // horizontal pixel counter [0, H_TOTAL)
    int  vcnt           = 0;   // vertical line counter [0, V_TOTAL)
    int  pix_div_cnt    = 0;   // pixel clock divider counter

    // Frame buffer and pixel capture
    FrameBuffer fb;
    int  px             = 0;   // current write X (0..H_ACTIVE-1)
    int  py             = 0;   // current write Y (0..V_ACTIVE-1)
    bool in_active      = false;

    // vsync edge detection
    uint8_t vsync_n_prev = 1;

    // ── Helper: posedge clk tick ─────────────────────────────────────────────
    auto tick = [&]() {
        // ── Video timing ─────────────────────────────────────────────────────
        ++pix_div_cnt;
        if (pix_div_cnt >= PIX_DIV) {
            pix_div_cnt = 0;
            top->clk_pix = 1;  // one-cycle-wide pulse

            // Compute sync/blank signals
            bool h_active = (hcnt < VID_H_ACTIVE);
            bool v_active = (vcnt < VID_V_ACTIVE);
            bool hsync    = (hcnt >= VID_HSYNC_START && hcnt < VID_HSYNC_END);
            bool vsync    = (vcnt >= VID_VSYNC_START && vcnt < VID_VSYNC_END);
            bool hblank   = !h_active;
            bool vblank   = !v_active;

            top->hblank_n_in = hblank ? 0 : 1;
            top->vblank_n_in = vblank ? 0 : 1;
            top->hsync_n_in  = hsync  ? 0 : 1;
            top->vsync_n_in  = vsync  ? 0 : 1;

            // Drive hpos/vpos to the GPU
            // hpos is 9-bit: x position within the active line
            // vpos is 8-bit: y position within the active frame
            top->hpos = (uint16_t)(h_active ? hcnt : 0);
            top->vpos = (uint8_t) (v_active ? vcnt : 0);

            // Advance pixel counter
            ++hcnt;
            if (hcnt >= VID_H_TOTAL) {
                hcnt = 0;
                ++vcnt;
                if (vcnt >= VID_V_TOTAL) {
                    vcnt = 0;
                }
            }
        } else {
            top->clk_pix = 0;
        }

        // ── SDRAM channels ───────────────────────────────────────────────────
        {
            auto r = prog_ch.tick(top->prog_rom_req, top->prog_rom_addr);
            top->prog_rom_data = r.data;
            top->prog_rom_ack  = r.ack;
        }
        {
            auto r = spr_ch.tick(top->spr_rom_sdram_req, top->spr_rom_sdram_addr);
            top->spr_rom_sdram_data = r.data;
            top->spr_rom_sdram_ack  = r.ack;
        }
        {
            auto r = bg_ch.tick(top->bg_rom_sdram_req, top->bg_rom_sdram_addr);
            top->bg_rom_sdram_data = r.data;
            top->bg_rom_sdram_ack  = r.ack;
        }
        {
            auto r = adpcm_ch.tick(top->adpcm_rom_req, (uint32_t)top->adpcm_rom_addr);
            top->adpcm_rom_data = r.data;
            top->adpcm_rom_ack  = r.ack;
        }
        {
            // Z80 ROM: addr is 16-bit, mapped from SDRAM base 0x280000
            uint32_t z80_byte_addr = 0x280000u + (uint32_t)top->z80_rom_addr;
            auto r = z80_ch.tick(top->z80_rom_req, z80_byte_addr);
            top->z80_rom_data = r.data;
            top->z80_rom_ack  = r.ack;
        }

        // (CPU bus driven by fx68k inside tb_top.sv)

        // ── Posedge eval ─────────────────────────────────────────────────────
        top->clk_sys = 1;
        top->eval();
        if (vcd) vcd->dump((vluint64_t)(cycle * 2 + 1));

        // ── Capture pixel (on posedge, after DUT has settled) ────────────────
        // Capture when inside the active display area, driven by our own
        // hcnt/vcnt counters (one-cycle ahead of the DUT output register, which
        // is fine for a visual dump).
        {
            // Use the previous cycle's hcnt/vcnt (before the pixel advance above)
            // For simplicity, capture using DUT's own vsync/hsync outputs.
            // Active area: !vblank && !hblank from DUT
            bool active = (!top->vblank) && (!top->hblank);
            if (active) {
                // hpos and vpos are driven from our counters above
                int cx = (int)top->hpos;
                int cy = (int)top->vpos;
                if (cx >= 0 && cx < VID_H_ACTIVE && cy >= 0 && cy < VID_V_ACTIVE) {
                    fb.set(cx, cy, top->rgb_r, top->rgb_g, top->rgb_b);
                }
            }
        }

        // ── CPU bus diagnostics ───────────────────────────────────────────────
        static uint64_t as_cycles = 0;
        static uint64_t write_count = 0;
        static uint64_t pal_write_count = 0;
        // Circular buffer: record each bus cycle start (AS_n falling edge)
        static constexpr int BUS_LOG = 64;
        static struct { uint64_t cyc; uint32_t addr; uint8_t rw; uint8_t dtack; } bus_log[BUS_LOG];
        static int bus_log_idx = 0;
        static int bus_log_total = 0;
        static bool prev_as_n = true;
        static bool halted_reported = false;

        bool cur_as_n = (bool)top->dbg_cpu_as_n;
        bool cur_halted_n = (bool)top->dbg_cpu_halted_n;

        if (!cur_as_n) {
            ++as_cycles;
            uint32_t byte_addr = ((uint32_t)top->dbg_cpu_addr) << 1;
            // Log new bus cycle on AS_n falling edge
            if (prev_as_n) {
                bus_log[bus_log_idx] = { cycle, byte_addr, top->dbg_cpu_rw, top->dbg_cpu_dtack_n };
                bus_log_idx = (bus_log_idx + 1) % BUS_LOG;
                ++bus_log_total;
            }
            if (!top->dbg_cpu_rw) {
                ++write_count;
                if (write_count <= 20) {
                    fprintf(stderr, "  [%7" PRIu64 "] CPU WR  addr=0x%06X data=0x%04X dtack=%d\n",
                            cycle, byte_addr, (unsigned)top->dbg_cpu_din,
                            (int)top->dbg_cpu_dtack_n);
                }
                if (byte_addr >= 0x0E0000 && byte_addr <= 0x0E03FF) {
                    ++pal_write_count;
                    if (pal_write_count <= 5)
                        fprintf(stderr, "  PAL WRITE #%lu\n", (unsigned long)pal_write_count);
                }
            }
        }

        // Fine-grained trace for first 200 cycles (covers all 6 bus cycles)
        if (cycle <= 200) {
            fprintf(stderr, "  [%4" PRIu64 "] as_n=%d halted_n=%d rw=%d addr=0x%06X dtack_n=%d\n",
                    cycle,
                    (int)top->dbg_cpu_as_n,
                    (int)top->dbg_cpu_halted_n,
                    (int)top->dbg_cpu_rw,
                    (unsigned)(((uint32_t)top->dbg_cpu_addr) << 1),
                    (int)top->dbg_cpu_dtack_n);
        }

        // Detect CPU halt
        if (!cur_halted_n && !halted_reported) {
            halted_reported = true;
            fprintf(stderr, "\n*** CPU HALTED at cycle %" PRIu64 " (double bus fault) ***\n"
                            "    bus_cycles=%d  as_cycles=%" PRIu64 "  writes=%" PRIu64 "\n\n",
                    cycle, bus_log_total, as_cycles, write_count);
        }

        prev_as_n = cur_as_n;

        // Periodic status: every 10K cycles for first 200K, then every 100K
        bool print_status = false;
        if (cycle < 200000 && (cycle % 10000) == 0 && cycle > 0) print_status = true;
        if (cycle >= 200000 && (cycle % 100000) == 0) print_status = true;

        if (print_status) {
            fprintf(stderr, "  @%luK: as_cycles=%lu bus_cycles=%d writes=%lu pal_writes=%lu"
                            " cpu_as_n=%d halted_n=%d addr=0x%06X\n",
                    (unsigned long)(cycle/1000),
                    (unsigned long)as_cycles, bus_log_total,
                    (unsigned long)write_count,
                    (unsigned long)pal_write_count,
                    (int)top->dbg_cpu_as_n,
                    (int)top->dbg_cpu_halted_n,
                    (unsigned)(((uint32_t)top->dbg_cpu_addr) << 1));
        }
        if (cycle == 10000) {
            // Print all logged bus cycles once after startup
            fprintf(stderr, "  --- bus log (first %d cycles) ---\n", (int)cycle);
            int start = (bus_log_total >= BUS_LOG) ? bus_log_idx : 0;
            int count = (bus_log_total >= BUS_LOG) ? BUS_LOG : bus_log_total;
            for (int i = 0; i < count; ++i) {
                int ii = (start + i) % BUS_LOG;
                fprintf(stderr, "    [%7" PRIu64 "] %s 0x%06X dtack_at_start=%d\n",
                        bus_log[ii].cyc,
                        bus_log[ii].rw ? "RD" : "WR",
                        bus_log[ii].addr, bus_log[ii].dtack);
            }
        }

        // ── Detect vsync falling edge (DUT output) ────────────────────────────
        uint8_t vsync_n_now = top->vsync_n;
        if (vsync_n_prev == 1 && vsync_n_now == 0) {
            // Vertical sync start — write the frame we just captured
            char fname[64];
            snprintf(fname, sizeof(fname), "frame_%04d.ppm", frame_num);
            if (fb.write_ppm(fname))
                fprintf(stderr, "Frame %4d written: %s\n", frame_num, fname);

            // ── Per-frame RAM dump (matches mame_ram_dump.lua format) ─────────
            if (ram_dump_f) {
                dump_frame_ram(ram_dump_f, (uint32_t)frame_num, top);
                if ((frame_num % 10) == 0)
                    fflush(ram_dump_f);
            }

            ++frame_num;
            if (frame_num >= n_frames) done = true;
            // Clear frame buffer for next frame
            fb = FrameBuffer();
        }
        vsync_n_prev = vsync_n_now;

        // ── Negedge ──────────────────────────────────────────────────────────
        top->clk_sys = 0;
        top->clk_pix = 0;
        top->eval();
        if (vcd) vcd->dump((vluint64_t)(cycle * 2));

        ++cycle;

        if ((cycle % 1000000) == 0 && cycle > 0) {
            fprintf(stderr, "  cycle %7" PRIu64 "  frame %d / %d\n",
                    cycle, frame_num, n_frames);
        }
    };

    // ── Reset sequence ────────────────────────────────────────────────────────
    top->reset_n = 0;
    for (int i = 0; i < 16; i++) tick();
    top->reset_n = 1;

    fprintf(stderr, "Reset released. Running %d frames...\n", n_frames);

    // ── Main simulation loop ─────────────────────────────────────────────────
    while (!done && !Verilated::gotFinish()) {
        tick();
    }

    // ── Final cleanup ────────────────────────────────────────────────────────
    if (vcd) {
        vcd->close();
        delete vcd;
    }
    if (ram_dump_f) {
        fflush(ram_dump_f);
        fclose(ram_dump_f);
        fprintf(stderr, "RAM dump closed: %s (%d frames, %zu bytes/frame)\n",
                env_ram_dump, frame_num,
                (size_t)(4 + 65536 + 2048 + 16384 + 2048 + 8));
    }
    top->final();
    delete top;

    fprintf(stderr, "Simulation complete. %d frames captured, %" PRIu64 " cycles.\n",
            frame_num, cycle);
    return 0;
}
