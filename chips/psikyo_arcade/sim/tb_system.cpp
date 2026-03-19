// =============================================================================
// tb_system.cpp — Psikyo Arcade full-system Verilator testbench
//
// Architecture:
//   - psikyo_arcade.sv is the Verilator DUT (GPU, audio, I/O, ROM bridges)
//   - MC68EC020 CPU is emulated by Musashi (C software model)
//   - Musashi memory reads/writes are serviced by driving the DUT bus directly
//   - RTL clock runs at 32 MHz; pixel=32/5=6.4 MHz, sound=32/4=8 MHz
//
// CPU-to-RTL interface:
//   Each Musashi memory access drives:
//     cpu_addr, cpu_dout, cpu_rw, cpu_as_n, cpu_uds_n, cpu_lds_n
//   Then clocks the RTL until cpu_dtack_n=0, reads cpu_din.
//
// Timing model:
//   - 32 MHz system clock; 2 RTL clocks per CPU cycle → 16 MHz CPU
//   - One CPU instruction = variable cycles (3-10+), each with 0 or 1 memory access
//   - Program ROM reads: 1 SDRAM cycle (toggle-handshake, 1 latency)
//   - All other accesses: combinational DTACK from psikyo_arcade logic
//   - We run RTL cycles independently to drive video timing regardless of CPU
//
// Video:
//   psikyo_arcade generates its own video timing (320×240 @ ~58 Hz)
//   We capture pixel data from rgb_r/g/b + hblank/vblank outputs
//
// SDRAM layout (byte addresses, per Gunbird.mra):
//   0x000000  CPU program ROM (2 MB)
//   0x200000  Sprite ROM      (4 MB, PS2001B)
//   0x600000  BG tile ROM     (4 MB, PS3103)
//   0xA00000  ADPCM ROM       (YM2610B)
//   0xA80000  Z80 sound ROM   (32 KB, per emu.sv)
//
// Environment variables:
//   N_FRAMES   — number of vertical frames to simulate (default 30)
//   ROM_PROG   — path to CPU program ROM binary  (SDRAM 0x000000, 2 MB)
//   ROM_SPR    — path to sprite ROM binary       (SDRAM 0x200000, 4 MB)
//   ROM_BG     — path to BG tile ROM binary      (SDRAM 0x600000, 4 MB)
//   ROM_ADPCM  — path to ADPCM ROM binary        (SDRAM 0xA00000)
//   ROM_Z80    — path to Z80 sound ROM binary    (SDRAM 0xA80000, 32 KB byte-wide)
//   DUMP_VCD   — set to "1" to enable VCD trace (slow)
//
// Output:
//   frame_NNNN.ppm — one PPM file per vertical frame
// =============================================================================

// Musashi 68EC020 CPU emulator (C headers, standalone)
// Include BEFORE Verilator to allow #undef of conflicting macro
extern "C" {
#include "musashi/m68k.h"
#include "musashi/m68kcpu.h"
}

// m68kcpu.h defines 'uint' as a macro which conflicts with macOS sys/types.h typedef.
// Undefine it before pulling in system/Verilator headers.
#ifdef uint
#undef uint
#endif

#include "Vtb_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include "sdram_model.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cinttypes>
#include <string>
#include <vector>

// =============================================================================
// Global simulation state (accessed by Musashi callbacks)
// =============================================================================

static Vtb_top*   g_top    = nullptr;
static SdramModel* g_sdram = nullptr;
static uint64_t   g_iter   = 0;        // half-cycle counter
static uint64_t   g_vcd_ts = 0;
static VerilatedVcdC* g_vcd = nullptr;

// Clock dividers
static int g_pix_div  = 0;
static int g_snd_div  = 0;

// Video capture state
static int g_pix_x      = 0;
static int g_pix_y      = 0;
static int g_frame_num  = 0;
static bool g_done      = false;
static uint8_t g_vsync_prev = 1;
static uint8_t g_hsync_prev = 1;

// SDRAM channels
static ToggleSdramChannel* g_prog_ch  = nullptr;
static ToggleSdramChannel* g_adpcm_ch = nullptr;
static ToggleSdramChannelByte* g_z80_ch = nullptr;

// Video timing constants
static constexpr int VID_H_ACTIVE = 320;
static constexpr int VID_V_ACTIVE = 240;
static constexpr int VID_H_TOTAL  = 416;
static constexpr int VID_V_TOTAL  = 264;
static constexpr int PIX_DIV      = 5;
static constexpr int SND_DIV      = 4;

// Frame buffer
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
};

static FrameBuffer* g_fb     = nullptr;
static int          g_nframes = 30;  // set in main() from N_FRAMES env var

// =============================================================================
// RTL clock tick — advance the DUT by one full system clock cycle (rising edge)
// =============================================================================
// This function:
//  1. Sets rising-edge clock enables (pix, snd)
//  2. Rising edge eval
//  3. VCD dump (if enabled)
//  4. Updates SDRAM models
//  5. Captures pixels (if any)
//  6. Handles vsync → frame save
// =============================================================================

static void rtl_tick_rising()
{
    // ── Pixel clock enable ─────────────────────────────────────────────────
    if (++g_pix_div >= PIX_DIV) {
        g_pix_div = 0;
        g_top->clk_pix = 1;
    } else {
        g_top->clk_pix = 0;
    }

    // ── Sound clock enable ─────────────────────────────────────────────────
    if (++g_snd_div >= SND_DIV) {
        g_snd_div = 0;
        g_top->clk_sound = 1;
    } else {
        g_top->clk_sound = 0;
    }

    // ── Clock rising edge ──────────────────────────────────────────────────
    g_top->clk_sys = 1;
    g_top->eval();
    if (g_vcd) g_vcd->dump((vluint64_t)g_vcd_ts++);
    ++g_iter;

    // ── SDRAM channels ──────────────────────────────────────────────────────
    {
        auto r = g_prog_ch->tick(g_top->prog_rom_req, (uint32_t)g_top->prog_rom_addr);
        g_top->prog_rom_data = r.data;
        g_top->prog_rom_ack  = r.ack;
    }
    {
        uint32_t spr_addr = (uint32_t)g_top->spr_rom_addr;
        g_top->spr_rom_data = g_sdram->read_word(spr_addr & ~1u);
        g_top->spr_rom_ack  = g_top->spr_rom_req;
    }
    {
        uint32_t bg_addr = (uint32_t)g_top->bg_rom_addr;
        g_top->bg_rom_data = g_sdram->read_word(bg_addr & ~1u);
        g_top->bg_rom_ack  = g_top->bg_rom_req;
    }
    {
        auto r = g_adpcm_ch->tick(g_top->adpcm_rom_req, (uint32_t)g_top->adpcm_rom_addr);
        g_top->adpcm_rom_data = r.data;
        g_top->adpcm_rom_ack  = r.ack;
    }
    {
        uint32_t z80_byte_addr = 0xA80000u + (uint32_t)g_top->z80_rom_addr;
        auto r = g_z80_ch->tick(g_top->z80_rom_req, z80_byte_addr);
        g_top->z80_rom_data = r.data;
        g_top->z80_rom_ack  = r.ack;
    }

    // ── Eval again after SDRAM updates ────────────────────────────────────────
    g_top->eval();

    // ── Pixel capture ──────────────────────────────────────────────────────────
    if (g_top->clk_pix) {
        bool active = (!g_top->vblank) && (!g_top->hblank);
        if (active && g_pix_x < VID_H_ACTIVE && g_pix_y < VID_V_ACTIVE) {
            if (g_fb) g_fb->set(g_pix_x, g_pix_y, g_top->rgb_r, g_top->rgb_g, g_top->rgb_b);
        }

        uint8_t hsync_now = g_top->hsync_n;
        if (g_hsync_prev == 0 && hsync_now == 1) {
            g_pix_x = 0;
            g_pix_y++;
        } else if (active) {
            g_pix_x++;
        }
        g_hsync_prev = hsync_now;
    }

    // ── Vsync → frame save ─────────────────────────────────────────────────────
    uint8_t vsync_now = g_top->vsync_n;
    if (g_vsync_prev == 1 && vsync_now == 0) {
        char fname[80];
        snprintf(fname, sizeof(fname), "frame_%04d.ppm", g_frame_num);
        int bus_cyc = (int)(g_iter / 2);  // approximate bus cycle count
        if (g_fb && g_fb->write_ppm(fname))
            fprintf(stderr, "Frame %4d written: %s  (iter=%" PRIu64 ")\n",
                    g_frame_num, fname, g_iter);

        ++g_frame_num;
        if (g_frame_num >= g_nframes) g_done = true;
        if (g_fb) *g_fb = FrameBuffer();
        g_pix_x = 0;
        g_pix_y = 0;
    }
    g_vsync_prev = vsync_now;

    // ── Falling edge ────────────────────────────────────────────────────────────
    g_top->clk_sys   = 0;
    g_top->clk_pix   = 0;
    g_top->clk_sound = 0;
    g_top->eval();
    if (g_vcd) g_vcd->dump((vluint64_t)g_vcd_ts++);
    ++g_iter;
}

// =============================================================================
// Advance RTL by N system clock cycles (each cycle = 1 rising + 1 falling)
// =============================================================================
static void rtl_ticks(int n)
{
    for (int i = 0; i < n; i++) rtl_tick_rising();
}

// =============================================================================
// Perform a 16-bit bus read through the RTL DUT
//
// This drives the psikyo_arcade bus (cpu_addr/cpu_as_n/cpu_rw/cpu_uds_n/cpu_lds_n)
// and clocks the RTL until cpu_dtack_n=0.
//
// addr: byte address (bits [23:1] extracted for 16-bit word address)
// uds_n, lds_n: byte enable strobes
// Returns 16-bit word read from DUT
// =============================================================================
static constexpr int MAX_DTACK_CYCLES = 64;  // safety limit

static uint16_t bus_read16(uint32_t addr, uint8_t uds_n, uint8_t lds_n)
{
    // Drive bus signals
    g_top->cpu_addr  = (addr >> 1) & 0x7FFFFF;  // word address [23:1]
    g_top->cpu_rw    = 1;                         // read
    g_top->cpu_uds_n = uds_n;
    g_top->cpu_lds_n = lds_n;
    g_top->cpu_as_n  = 0;                         // assert AS
    g_top->cpu_dout  = 0xFFFF;

    // Clock until DTACK
    int wait = 0;
    do {
        rtl_tick_rising();
        ++wait;
        if (wait > MAX_DTACK_CYCLES) {
            fprintf(stderr, "WARNING: bus_read16 DTACK timeout @ addr=%06X\n", addr);
            break;
        }
    } while (g_top->cpu_dtack_n);

    uint16_t data = (uint16_t)g_top->cpu_din;

    // Deassert bus
    g_top->cpu_as_n  = 1;
    g_top->cpu_uds_n = 1;
    g_top->cpu_lds_n = 1;
    g_top->eval();

    return data;
}

// =============================================================================
// Perform a 16-bit bus write through the RTL DUT
// =============================================================================
static void bus_write16(uint32_t addr, uint16_t data, uint8_t uds_n, uint8_t lds_n)
{
    g_top->cpu_addr  = (addr >> 1) & 0x7FFFFF;
    g_top->cpu_rw    = 0;                         // write
    g_top->cpu_uds_n = uds_n;
    g_top->cpu_lds_n = lds_n;
    g_top->cpu_as_n  = 0;
    g_top->cpu_dout  = data;

    int wait = 0;
    do {
        rtl_tick_rising();
        ++wait;
        if (wait > MAX_DTACK_CYCLES) {
            fprintf(stderr, "WARNING: bus_write16 DTACK timeout @ addr=%06X\n", addr);
            break;
        }
    } while (g_top->cpu_dtack_n);

    g_top->cpu_as_n  = 1;
    g_top->cpu_uds_n = 1;
    g_top->cpu_lds_n = 1;
    g_top->cpu_rw    = 1;
    g_top->eval();
}

// =============================================================================
// Musashi memory callbacks
//
// Psikyo address map (byte addresses):
//   0x000000–0x0FFFFF  Program ROM (read-only, direct from SDRAM model)
//   0xFE0000–0xFFFFFF  Work RAM (32-bit 68EC020 address: pass through DUT)
//   0x400000–0x401FFF  Sprite RAM   \
//   0x600000–0x601FFF  Palette RAM  |  All go through DUT bus
//   0x800000–0x807FFF  VRAM          |
//   0xC00000–0xC0001F  I/O           /
//   All others: open bus → return 0xFFFF
// =============================================================================

static unsigned int prog_rom_read8(unsigned int addr)
{
    uint32_t ba = addr & ~1u;
    uint16_t w  = g_sdram->read_word(ba);
    return (addr & 1) ? (w & 0xFF) : ((w >> 8) & 0xFF);
}

static unsigned int prog_rom_read16(unsigned int addr)
{
    return g_sdram->read_word(addr & ~1u);
}

static unsigned int prog_rom_read32(unsigned int addr)
{
    uint32_t hi = g_sdram->read_word(addr & ~1u);
    uint32_t lo = g_sdram->read_word((addr + 2) & ~1u);
    return (hi << 16) | lo;
}

// Check if address is in Program ROM (0x000000–0x0FFFFF)
static inline bool is_prog_rom(unsigned int addr) { return addr < 0x100000u; }

extern "C" {

unsigned int psikyo_read8(unsigned int addr)
{
    addr &= 0xFFFFFF;  // 24-bit bus
    if (is_prog_rom(addr)) return prog_rom_read8(addr);

    // Byte read through RTL: read 16-bit word, extract byte
    uint8_t uds_n = (addr & 1) ? 1 : 0;  // UDS for even addr (bits 15:8)
    uint8_t lds_n = (addr & 1) ? 0 : 1;  // LDS for odd  addr (bits  7:0)
    uint16_t w = bus_read16(addr & ~1u, uds_n, lds_n);
    return (addr & 1) ? (w & 0xFF) : ((w >> 8) & 0xFF);
}

unsigned int psikyo_read16(unsigned int addr)
{
    addr &= 0xFFFFFF;
    if (is_prog_rom(addr)) return prog_rom_read16(addr);
    return bus_read16(addr, 0, 0);  // both strobes active
}

unsigned int psikyo_read32(unsigned int addr)
{
    addr &= 0xFFFFFF;
    if (is_prog_rom(addr)) return prog_rom_read32(addr);
    // Two 16-bit accesses
    uint32_t hi = bus_read16(addr,     0, 0);
    uint32_t lo = bus_read16(addr + 2, 0, 0);
    return (hi << 16) | lo;
}

void psikyo_write8(unsigned int addr, unsigned int data)
{
    addr &= 0xFFFFFF;
    if (is_prog_rom(addr)) return;  // ROM: ignore writes
    uint8_t uds_n = (addr & 1) ? 1 : 0;
    uint8_t lds_n = (addr & 1) ? 0 : 1;
    // Place byte in correct lane
    uint16_t d16 = (addr & 1) ? (data & 0xFF) : ((data & 0xFF) << 8);
    bus_write16(addr & ~1u, d16, uds_n, lds_n);
}

void psikyo_write16(unsigned int addr, unsigned int data)
{
    addr &= 0xFFFFFF;
    if (is_prog_rom(addr)) return;
    bus_write16(addr, (uint16_t)data, 0, 0);
}

void psikyo_write32(unsigned int addr, unsigned int data)
{
    addr &= 0xFFFFFF;
    if (is_prog_rom(addr)) return;
    bus_write16(addr,     (uint16_t)(data >> 16), 0, 0);
    bus_write16(addr + 2, (uint16_t)(data),       0, 0);
}

int psikyo_int_ack(int level)
{
    // Psikyo uses autovectored interrupts
    (void)level;
    return M68K_INT_ACK_AUTOVECTOR;
}

} // extern "C"

// =============================================================================
// main
// =============================================================================
int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);

    // ── Configuration from environment ──────────────────────────────────────
    const char* env_frames = getenv("N_FRAMES");
    const char* env_prog   = getenv("ROM_PROG");
    const char* env_spr    = getenv("ROM_SPR");
    const char* env_bg     = getenv("ROM_BG");
    const char* env_adpcm  = getenv("ROM_ADPCM");
    const char* env_z80    = getenv("ROM_Z80");
    const char* env_vcd    = getenv("DUMP_VCD");

    int n_frames = env_frames ? atoi(env_frames) : 30;
    if (n_frames < 1) n_frames = 1;
    g_nframes = n_frames;

    fprintf(stderr, "Psikyo Arcade simulation (Musashi 68EC020): %d frames\n", n_frames);

    // ── Load ROM data ────────────────────────────────────────────────────────
    SdramModel sdram;
    if (env_prog)  sdram.load(env_prog,  0x000000);
    if (env_spr)   sdram.load(env_spr,   0x200000);
    if (env_bg)    sdram.load(env_bg,    0x600000);
    if (env_adpcm) sdram.load(env_adpcm, 0xA00000);
    if (env_z80)   sdram.load_bytes(env_z80, 0xA80000);
    g_sdram = &sdram;

    // ── SDRAM channels ───────────────────────────────────────────────────────
    ToggleSdramChannel prog_ch(sdram);
    ToggleSdramChannel adpcm_ch(sdram);
    ToggleSdramChannelByte z80_ch(sdram);
    g_prog_ch  = &prog_ch;
    g_adpcm_ch = &adpcm_ch;
    g_z80_ch   = &z80_ch;

    // ── Verilator init ──────────────────────────────────────────────────────
    Verilated::fatalOnError(false);
    g_top = new Vtb_top();

    // ── Optional VCD trace ───────────────────────────────────────────────────
    if (env_vcd && env_vcd[0] == '1') {
        Verilated::traceEverOn(true);
        g_vcd = new VerilatedVcdC();
        g_top->trace(g_vcd, 99);
        g_vcd->open("sim_psikyo_arcade.vcd");
        fprintf(stderr, "VCD trace enabled: sim_psikyo_arcade.vcd\n");
    }

    // ── Frame buffer ─────────────────────────────────────────────────────────
    FrameBuffer fb;
    g_fb = &fb;

    // ── Initial port state ───────────────────────────────────────────────────
    g_top->clk_sys   = 0;
    g_top->reset_n   = 0;
    g_top->clk_pix   = 0;
    g_top->clk_sound = 0;

    // CPU bus: idle state
    g_top->cpu_addr  = 0;
    g_top->cpu_dout  = 0xFFFF;
    g_top->cpu_rw    = 1;
    g_top->cpu_as_n  = 1;
    g_top->cpu_uds_n = 1;
    g_top->cpu_lds_n = 1;

    // SDRAM defaults
    g_top->prog_rom_data  = 0;
    g_top->prog_rom_ack   = 0;
    g_top->spr_rom_data   = 0;
    g_top->spr_rom_ack    = 0;
    g_top->bg_rom_data    = 0;
    g_top->bg_rom_ack     = 0;
    g_top->adpcm_rom_data = 0;
    g_top->adpcm_rom_ack  = 0;
    g_top->z80_rom_data   = 0;
    g_top->z80_rom_ack    = 0;

    // Player inputs: all active-low, released (no buttons pressed)
    g_top->joystick_p1 = 0xFF;
    g_top->joystick_p2 = 0xFF;
    g_top->coin        = 0x3;
    g_top->service     = 1;
    g_top->dipsw1      = 0xFF;
    g_top->dipsw2      = 0xFF;

    g_top->eval();

    // ── Reset sequence: hold reset for 20 RTL cycles ──────────────────────────
    static constexpr int RESET_CYCLES = 20;
    for (int i = 0; i < RESET_CYCLES; i++) rtl_tick_rising();
    g_top->reset_n = 1;
    g_top->eval();

    // ── Musashi 68EC020 initialization ────────────────────────────────────────
    m68k_init();
    m68k_set_cpu_type(M68K_CPU_TYPE_68EC020);
    m68k_pulse_reset();

    fprintf(stderr, "CPU reset. SSP=0x%08X  PC=0x%08X\n",
            m68k_get_reg(nullptr, M68K_REG_SP),
            m68k_get_reg(nullptr, M68K_REG_PC));
    fprintf(stderr, "Running simulation (%d frames)...\n", n_frames);

    // ── Main simulation loop ──────────────────────────────────────────────────
    //
    // Strategy:
    //   - Execute CPU instructions in bursts of ~16 RTL cycles (= 1 CPU cycle
    //     at 16 MHz from 32 MHz sys clock)
    //   - Between instruction bursts, run a few RTL cycles to advance video timing
    //   - The Musashi callbacks (psikyo_read16 etc.) will run RTL ticks as needed
    //     during memory accesses via bus_read16 / bus_write16
    //   - We stop when n_frames have been captured
    //
    // The rtl_tick_rising() function handles all video timing / frame capture.
    // We need to run RTL even when the CPU isn't doing a bus cycle, to clock
    // the sprite scanner, BG renderer, etc.
    //
    // CPU frequency: 16 MHz → 1 instruction per ~32 ns → at 32 MHz sys clock
    // = 2 RTL clocks per CPU state clock.
    // Typical 68020 instruction: 2-10 cycles at 16 MHz = 4-20 RTL clocks.
    // We execute 1 CPU instruction per loop iteration, then run 2 "idle" RTL
    // ticks to advance video timing between instructions.
    //
    // When Musashi makes memory bus accesses (bus_read16/bus_write16), those
    // consume RTL ticks internally via rtl_tick_rising(). The bus cycle adds
    // ~2-8 RTL ticks per access (for DTACK).
    // =============================================================================

    // Max iterations safety limit (well above what n_frames needs)
    // Each frame = 416 * 264 * 5 sys clocks = 549,120 rising edges
    // With CPU overhead, budget 3x that per frame.
    const uint64_t max_iters = (uint64_t)n_frames * 549120ULL * 3ULL;

    // IRQ tracking: sample cpu_ipl_n from DUT to drive Musashi interrupts
    int cpu_irq_level = 0;

    // Instruction counter for progress reporting
    uint64_t cpu_insns = 0;

    while (!g_done && g_iter < max_iters * 2)
    {
        if (g_frame_num >= n_frames) { g_done = true; break; }

        // ── Check for pending interrupt from DUT ────────────────────────────
        {
            // cpu_ipl_n is active-low encoded: 3'b111=no IRQ, 3'b011=level4, etc.
            uint8_t ipl = (uint8_t)g_top->cpu_ipl_n;
            int level = (~ipl) & 0x7;  // invert to get active-high level
            if (level != cpu_irq_level) {
                m68k_set_irq(level);
                cpu_irq_level = level;
            }
        }

        // ── Execute one CPU instruction ─────────────────────────────────────
        // m68k_execute(1) runs exactly 1 instruction and returns cycles used
        int cpu_cycles = m68k_execute(1);
        ++cpu_insns;

        // ── Run idle RTL ticks to advance video/audio timing ─────────────────
        // Each CPU cycle = 2 RTL clocks at 32 MHz (CPU runs at 16 MHz)
        // cpu_cycles from Musashi is in 16 MHz cycles.
        // bus_read16/bus_write16 already ran RTL ticks for memory accesses.
        // Here we run any remaining ticks for the non-memory part of the cycle.
        // We run at least 1 RTL tick per instruction to ensure video advances.
        int idle_ticks = (cpu_cycles * 2) / 4;  // scaled down to avoid over-running
        if (idle_ticks < 1) idle_ticks = 1;
        rtl_ticks(idle_ticks);

        // ── Progress report ──────────────────────────────────────────────────
        if ((cpu_insns % 1000000) == 0) {
            fprintf(stderr, "  insn=%" PRIu64 " iter=%" PRIu64 " frame=%d  PC=%06X\n",
                    cpu_insns, g_iter, g_frame_num,
                    m68k_get_reg(nullptr, M68K_REG_PC));
        }
    }

    // ── Cleanup ───────────────────────────────────────────────────────────────
    if (g_vcd) {
        g_vcd->close();
        delete g_vcd;
    }
    g_top->final();
    delete g_top;

    fprintf(stderr, "Simulation complete. %d frames, %" PRIu64 " instructions, %" PRIu64 " RTL half-cycles.\n",
            g_frame_num, cpu_insns, g_iter);
    return 0;
}
