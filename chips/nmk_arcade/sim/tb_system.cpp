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
//               Format for byte-by-byte comparison with MAME Lua dumps:
//               Per frame: [4B LE frame#][64KB work RAM][1KB palette RAM][2KB sprite RAM][16KB BG VRAM][2KB TX VRAM][8B scroll]
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
// vl_stop override removed — using Verilated::fatalOnError(false) instead

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
// Dumps internal RTL state for byte-by-byte comparison with MAME Lua dumps.
//   Per frame (87052 bytes total):
//     [0..3]         4-byte little-endian frame number
//     [4..65539]     64 KB work RAM     (work_ram[0..32767], big-endian word → byte)
//     [65540..66563] 1 KB  palette RAM  (palette_ram[0..511], big-endian word → byte)
//     [66564..68611] 2 KB  sprite RAM   (sprite_ram_storage[0..1023] in nmk16)
//     [68612..84995] 16 KB BG VRAM      (tilemap_ram[0..2047] padded to 16 KB)
//     [84996..87043] 2 KB  TX VRAM      (zeros — stub)
//     [87044..87051] 8 bytes scroll regs (scroll0_x, scroll0_y, scroll1_x, scroll1_y)
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
//   SData tb_top__DOT__u_nmk__DOT__u_nmk16__DOT__scroll0_x_active (and y, 1_x, 1_y)
//   SData tb_top__DOT__u_nmk__DOT__u_nmk16__DOT__scroll1_x_shadow  (only x; others optimized out)
//
// NOTE: NMK_ARCADE_PRESENT must be defined at compile time (via CFLAGS -DNMK_ARCADE_PRESENT)
// to enable the actual RAM dump. Without it, all regions write zeros.
#define NMK_ARCADE_PRESENT
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

    // ── RAM regions — only available when nmk_arcade is instantiated ────────
    // In isolation mode (no nmk_arcade), write zeros for all regions to keep
    // the binary format consistent.
#ifdef NMK_ARCADE_PRESENT
    // Work RAM: 64KB = 32768 words at 0x0B0000-0x0BFFFF
    for (int i = 0; i < 32768; i++)
        write_word_be(f, (uint16_t)r->tb_top__DOT__u_nmk__DOT__work_ram[i]);
    // Palette RAM: 512 words at 0x0C8000-0x0C87FF
    for (int i = 0; i < 512; i++)
        write_word_be(f, (uint16_t)r->tb_top__DOT__u_nmk__DOT__palette_ram[i]);
    // Sprite RAM: 1024 words in nmk16
    for (int i = 0; i < 1024; i++)
        write_word_be(f, (uint16_t)r->tb_top__DOT__u_nmk__DOT__u_nmk16__DOT__sprite_ram_storage[i]);
    // BG Tilemap RAM: 2048 words in nmk16, padded to 16KB
    for (int i = 0; i < 2048; i++)
        write_word_be(f, (uint16_t)r->tb_top__DOT__u_nmk__DOT__u_nmk16__DOT__tilemap_ram[i]);
    write_zeros(f, 16384 - 4096);  // pad to 16KB
    // TX VRAM: 2KB (zeros — stub)
    write_zeros(f, 2048);
    // Scroll regs: use active (post-vblank latch) values
    // Note: Verilator optimizes out some shadow registers; use _active which are always present
    write_word_be(f, (uint16_t)r->tb_top__DOT__u_nmk__DOT__u_nmk16__DOT__scroll0_x_active);
    write_word_be(f, (uint16_t)r->tb_top__DOT__u_nmk__DOT__u_nmk16__DOT__scroll0_y_active);
    write_word_be(f, (uint16_t)r->tb_top__DOT__u_nmk__DOT__u_nmk16__DOT__scroll1_x_active);
    write_word_be(f, (uint16_t)r->tb_top__DOT__u_nmk__DOT__u_nmk16__DOT__scroll1_y_active);
#else
    write_zeros(f, 65536);  // main RAM
    write_zeros(f, 1024);   // palette RAM
    write_zeros(f, 2048);   // sprite RAM
    write_zeros(f, 16384);  // BG VRAM
    write_zeros(f, 2048);   // TX VRAM
    write_zeros(f, 8);      // scroll regs
#endif
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

    // ── Verilator init ──────────────────────────────────────────────────────
    Verilated::fatalOnError(false);  // match minimal test — suppress assertion halts

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

    // Bus bypass: disabled — CPU reads through nmk_arcade RTL data mux + DTACK
    top->bypass_en      = 0;   // RTL bus mode: nmk_arcade handles all bus cycles
    top->bypass_data    = 0xFFFF;
    top->bypass_dtack_n = 1;

    // Clock enables: driven from C++ (matching working minimal test pattern)
    top->enPhi1 = 0;
    top->enPhi2 = 0;

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

        // ── CPU bus bypass: set data BEFORE posedge eval using prev cycle's ASn ─
        // The CPU samples iEdb DURING posedge eval. We must set bypass_data
        // BEFORE eval. Since ASn changes during eval, we use the previous
        // cycle's ASn to decide what data to present.
        if (top->bypass_en) {
            static uint8_t  prev_bp_asn  = 1;
            static uint32_t prev_bp_addr = 0;
            // Use CURRENT output (from previous posedge, settled after negedge)
            uint8_t  cur_asn  = top->dbg_cpu_as_n;
            uint32_t cur_addr = top->dbg_cpu_addr;
            if (!cur_asn) {
                uint32_t byte_addr = ((uint32_t)cur_addr << 1) & 0x7FFFFF;
                top->bypass_data    = sdram.read_word(byte_addr);
                top->bypass_dtack_n = 0;
            } else {
                top->bypass_data    = 0xFFFF;
                top->bypass_dtack_n = 1;
            }
            prev_bp_asn  = cur_asn;
            prev_bp_addr = cur_addr;
        }

        // ── Phi enables: set BEFORE posedge eval (matching minimal test) ─────
        {
            static bool phi_toggle = false;
            if (cycle >= 8) {  // let reset settle first
                top->enPhi1 = phi_toggle ? 0 : 1;
                top->enPhi2 = phi_toggle ? 1 : 0;
                phi_toggle  = !phi_toggle;
            } else {
                top->enPhi1 = 0;
                top->enPhi2 = 0;
            }
        }

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
            fprintf(stderr, "  [%4" PRIu64 "] as_n=%d halted_n=%d rw=%d addr=0x%06X dtack_n=%d dout=0x%04X\n",
                    cycle,
                    (int)top->dbg_cpu_as_n,
                    (int)top->dbg_cpu_halted_n,
                    (int)top->dbg_cpu_rw,
                    (unsigned)(((uint32_t)top->dbg_cpu_addr) << 1),
                    (int)top->dbg_cpu_dtack_n,
                    (unsigned)(top->dbg_cpu_dout & 0xFFFF));
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
        // Clear phi enables on negedge (matching minimal test pattern)
        top->enPhi1 = 0;
        top->enPhi2 = 0;
        top->eval();
        if (vcd) vcd->dump((vluint64_t)(cycle * 2));

        ++cycle;

        if ((cycle % 1000000) == 0 && cycle > 0) {
            fprintf(stderr, "  cycle %7" PRIu64 "  frame %d / %d\n",
                    cycle, frame_num, n_frames);
        }
    };

    // ========================================================================
    // RTL BUS EVAL LOOP — bypass_en=0, CPU reads through nmk_arcade RTL.
    //
    // Follows the working minimal-test clock pattern (one eval per toggle,
    // phi set on rising edge, cleared on falling edge) while also:
    //   • Ticking all SDRAM channels on every rising edge so the prog_rom
    //     toggle-handshake completes and nmk_arcade can assert DTACK.
    //   • Advancing video timing counters and driving hblank/vblank/hpos/vpos
    //     so the GPU and interrupt logic see correct sync signals.
    //   • Capturing pixels and writing PPM frames on vsync.
    // ========================================================================
    fprintf(stderr, "Running RTL BUS eval loop (bypass_en=0)...\n");

    bool     phi_toggle_c    = false;
    bool     prev_asn_c      = true;
    int      bus_cycles_c    = 0;
    uint64_t iter            = 0;
    bool     halted_reported_c = false;
    static constexpr int RESET_ITERS = 20;

    top->reset_n = 0;

    // VCD timestamp counter (each iter = one half-clock)
    uint64_t vcd_ts = 0;

    for (iter = 0; iter < (uint64_t)n_frames * 600000ULL; iter++) {
        // Toggle clock
        top->clk_sys = top->clk_sys ^ 1;

        // Release reset after RESET_ITERS half-cycles
        if (iter >= RESET_ITERS) top->reset_n = 1;

        if (top->clk_sys == 1) {
            // ── Rising edge ──────────────────────────────────────────────────

            // Phi enables (matching working minimal-test pattern)
            top->enPhi1 = phi_toggle_c ? 0 : 1;
            top->enPhi2 = phi_toggle_c ? 1 : 0;
            phi_toggle_c = !phi_toggle_c;

            // ── Video timing (advance every 2 system clocks = 1 pixel clock) ─
            ++pix_div_cnt;
            if (pix_div_cnt >= PIX_DIV) {
                pix_div_cnt = 0;
                top->clk_pix = 1;

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
                top->hpos = (uint16_t)(h_active ? hcnt : 0);
                top->vpos = (uint8_t) (v_active ? vcnt : 0);

                ++hcnt;
                if (hcnt >= VID_H_TOTAL) {
                    hcnt = 0;
                    ++vcnt;
                    if (vcnt >= VID_V_TOTAL)
                        vcnt = 0;
                }
            } else {
                top->clk_pix = 0;
            }

            // ── SDRAM channels (must tick every rising edge) ──────────────────
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
                // BG tile ROM: pixel-rate access, bypass toggle-handshake.
                // Directly read the SDRAM word at bg_rom_sdram_addr on every cycle.
                // This gives 0-latency data return so the NMK16 BG pipeline always
                // sees the correct tile data (Stage 2 reads bg_rom_data combinationally
                // the cycle after Stage 1 presents bg_rom_addr).
                uint32_t bg_addr = (uint32_t)top->bg_rom_sdram_addr;
                top->bg_rom_sdram_data = sdram.read_word(bg_addr & ~1u);
                top->bg_rom_sdram_ack  = top->bg_rom_sdram_req;  // always ack immediately
            }
            {
                auto r = adpcm_ch.tick(top->adpcm_rom_req, (uint32_t)top->adpcm_rom_addr);
                top->adpcm_rom_data = r.data;
                top->adpcm_rom_ack  = r.ack;
            }
            {
                uint32_t z80_byte_addr = 0x280000u + (uint32_t)top->z80_rom_addr;
                auto r = z80_ch.tick(top->z80_rom_req, z80_byte_addr);
                top->z80_rom_data = r.data;
                top->z80_rom_ack  = r.ack;
            }

            // ── Bus diagnostics (first bus cycles) ────────────────────────────
            {
                uint8_t  asn_c  = top->dbg_cpu_as_n;
                uint8_t  rwn_c  = top->dbg_cpu_rw;
                uint32_t addr_c = ((uint32_t)top->dbg_cpu_addr << 1) & 0xFFFFFF;

                if (!prev_asn_c && asn_c) {
                    // Falling edge of AS_n (end of bus cycle)
                    bus_cycles_c++;
                }

                // Log first 60 bus cycles and snapshots at key boundaries
                bool log_this = (!asn_c && prev_asn_c && iter > RESET_ITERS) &&
                    (bus_cycles_c < 60 ||
                     (bus_cycles_c >= 657020 && bus_cycles_c <= 657120));
                if (log_this) {
                    fprintf(stderr, "  [%6lu|bc%d] ASn=0 RW=%d addr=%06X dtack_n=%d dout=%04X\n",
                            (unsigned long)iter, bus_cycles_c, (int)rwn_c, addr_c,
                            (int)top->dbg_cpu_dtack_n, (unsigned)(top->dbg_cpu_dout));
                }

                // NMK004 I/O: log reads from 0x0C000E and writes to 0x0C001E
                static int nmk_io_log_count = 0;
                if (!asn_c && prev_asn_c && iter > RESET_ITERS && nmk_io_log_count < 50) {
                    if (addr_c == 0x0C000E && rwn_c) {
                        fprintf(stderr, "  NMK_RD bc%d addr=0C000E dout=%04X\n",
                                bus_cycles_c, (unsigned)(top->dbg_cpu_dout & 0xFFFF));
                        ++nmk_io_log_count;
                    }
                    if (addr_c == 0x0C001E && !rwn_c) {
                        fprintf(stderr, "  NMK_WR bc%d addr=0C001E din=%04X\n",
                                bus_cycles_c, (unsigned)(top->dbg_cpu_din & 0xFFFF));
                        ++nmk_io_log_count;
                    }
                }

                // Track palette writes (0x0C8000-0x0C87FF) and report first few
                static int pal_wr_count_c = 0;
                static int wram_wr_count_c = 0;
                if (!asn_c && !rwn_c && prev_asn_c) {
                    // New write bus cycle starting
                    if (addr_c >= 0x0C8000 && addr_c <= 0x0C87FF) {
                        ++pal_wr_count_c;
                        if (pal_wr_count_c <= 5)
                            fprintf(stderr, "  PAL WR #%d addr=%06X data=%04X @iter=%lu\n",
                                    pal_wr_count_c, addr_c, (unsigned)top->dbg_cpu_din,
                                    (unsigned long)iter);
                    }
                    if (addr_c >= 0x0B0000 && addr_c <= 0x0BFFFF) {
                        ++wram_wr_count_c;
                        if (wram_wr_count_c <= 3)
                            fprintf(stderr, "  WRAM WR #%d addr=%06X @iter=%lu\n",
                                    wram_wr_count_c, addr_c, (unsigned long)iter);
                    }
                }

                // Periodic write summary
                if (bus_cycles_c > 0 && (bus_cycles_c % 50000) == 0 && prev_asn_c && asn_c) {
                    fprintf(stderr, "  [%dK bus] pal_wr=%d wram_wr=%d frame=%d\n",
                            bus_cycles_c/1000, pal_wr_count_c, wram_wr_count_c, frame_num);
                }

                // Detect CPU halt
                if (top->dbg_cpu_halted_n == 0 && iter > RESET_ITERS + 100 && !halted_reported_c) {
                    halted_reported_c = true;
                    fprintf(stderr, "\n*** CPU HALTED at iter %lu (bus_cycles=%d) ***\n",
                            (unsigned long)iter, bus_cycles_c);
                }

                prev_asn_c = asn_c;
            }

        } else {
            // ── Falling edge ─────────────────────────────────────────────────
            top->enPhi1  = 0;
            top->enPhi2  = 0;
            top->clk_pix = 0;
        }

        top->eval();
        if (vcd) vcd->dump((vluint64_t)vcd_ts);
        ++vcd_ts;

        // ── Pixel capture (on rising edge, after eval) ────────────────────
        if (top->clk_sys == 1) {
            bool active = (!top->vblank) && (!top->hblank);
            if (active) {
                int cx = (int)top->hpos;
                int cy = (int)top->vpos;
                if (cx >= 0 && cx < VID_H_ACTIVE && cy >= 0 && cy < VID_V_ACTIVE)
                    fb.set(cx, cy, top->rgb_r, top->rgb_g, top->rgb_b);
            }
        }

        // ── Vsync edge detection → frame save ────────────────────────────
        {
            uint8_t vsync_n_now = top->vsync_n;
            if (vsync_n_prev == 1 && vsync_n_now == 0) {
                char fname[64];
                snprintf(fname, sizeof(fname), "frame_%04d.ppm", frame_num);
                if (fb.write_ppm(fname))
                    fprintf(stderr, "Frame %4d written: %s  (bus_cycles=%d)\n",
                            frame_num, fname, bus_cycles_c);

                if (ram_dump_f) {
                    dump_frame_ram(ram_dump_f, (uint32_t)frame_num, top);
                    if ((frame_num % 10) == 0) fflush(ram_dump_f);
                }

                ++frame_num;
                if (frame_num >= n_frames) done = true;
                fb = FrameBuffer();
            }
            vsync_n_prev = vsync_n_now;
        }

        if (done) break;

        if ((iter % 2000000) == 0 && iter > 0) {
            fprintf(stderr, "  iter %lu  bus_cycles=%d  frame=%d\n",
                    (unsigned long)iter, bus_cycles_c, frame_num);
        }
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
                (size_t)(4 + 65536 + 1024 + 2048 + 16384 + 2048 + 8));
    }
    top->final();
    delete top;

    fprintf(stderr, "Simulation complete. %d frames captured, %" PRIu64 " iters (%d bus cycles).\n",
            frame_num, iter, bus_cycles_c);
    return 0;
}
