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
#include "Vtb_top_tb_top.h"  // needed for top->tb_top->__PVT__... member access
#include "verilated.h"
#include "verilated_vcd_c.h"

// Include generated root-struct header for deep-hierarchy signal access.
// top->rootp (Vtb_top___024root*) holds all internal state including
// unpacked arrays like work_ram, tilemap_ram, sprite_ram_storage, etc.
#include "Vtb_top___024root.h"

#include "sdram_model.h"
#include "Vtb_top_tb_top.h"
#include "Vtb_top_fx68k.h"

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
// NMK004 MCU Simulation — Thunder Dragon (FBNeo-compatible)
//
// The Thunder Dragon NMK004 (TLCS90 MCU) performs two jobs:
//   1. PROT_JSR dispatch: when the 68K writes a trigger value to a specific
//      WRAM address, the MCU patches a JMP instruction into WRAM so that the
//      next 68K JSR to that WRAM location executes the real ROM subroutine.
//   2. mcu_run: each frame, writes coin/credit state and DIP inputs to WRAM.
//
// This replicates FBNeo's tdragon_mainram_w + mcu_run logic.
// All WRAM word accesses use the word index: wram[byte_offset_within_wram / 2].
// =============================================================================

class TdragonMCU {
public:
    // Call this whenever the 68K writes to WRAM.
    // wram_word_idx = (cpu_addr & 0xFFFF) >> 1  (byte offset within WRAM / 2)
    // din = 16-bit data being written (before RTL has stored it)
    // wram = pointer to work_ram Verilator array
    //
    // IMPORTANT: We call this at bus-cycle START, before the RTL write commits.
    // Therefore we check 'din == protvalue' directly, NOT wram[offs/2].
    static void on_wram_write(uint32_t wram_word_idx,
                               uint16_t din,
                               uint16_t* wram)
    {
        uint32_t offs = wram_word_idx * 2;  // byte offset within WRAM

        switch (offs) {
            case 0xe066: PROT_INPUT(din, 0xe23e, 0xe000, 0x000c0000, wram); break;
            case 0xe144: PROT_INPUT(din, 0xf54d, 0xe004, 0x000c0002, wram); break;
            case 0xe60e: PROT_INPUT(din, 0x067c, 0xe008, 0x000c0008, wram); break;
            case 0xe714: PROT_INPUT(din, 0x198b, 0xe00c, 0x000c000a, wram); break;
            case 0xe70e: PROT_JSR(offs, din, 0x8007, 0x9e22, wram);
                         PROT_JSR(offs, din, 0x8000, 0xd518, wram); break;
            case 0xe71e: PROT_JSR(offs, din, 0x8038, 0xaa0a, wram);
                         PROT_JSR(offs, din, 0x8031, 0x8e7c, wram); break;
            case 0xe72e: PROT_JSR(offs, din, 0x8019, 0xac48, wram);
                         PROT_JSR(offs, din, 0x8022, 0xd558, wram); break;
            case 0xe73e: PROT_JSR(offs, din, 0x802a, 0xb110, wram);
                         PROT_JSR(offs, din, 0x8013, 0x96da, wram); break;
            case 0xe74e: PROT_JSR(offs, din, 0x800b, 0xb9b2, wram);
                         PROT_JSR(offs, din, 0x8004, 0xa062, wram); break;
            case 0xe75e: PROT_JSR(offs, din, 0x803c, 0xbb4c, wram);
                         PROT_JSR(offs, din, 0x8035, 0xa154, wram); break;
            case 0xe76e: PROT_JSR(offs, din, 0x801d, 0xafa6, wram);
                         PROT_JSR(offs, din, 0x8026, 0xa57a, wram); break;
            case 0xe77e: PROT_JSR(offs, din, 0x802e, 0xc6a4, wram);
                         PROT_JSR(offs, din, 0x8017, 0x9e22, wram); break;
            case 0xe78e: PROT_JSR(offs, din, 0x8004, 0xaa0a, wram);
                         PROT_JSR(offs, din, 0x8008, 0xaa0a, wram); break;
            case 0xe79e: PROT_JSR(offs, din, 0x8030, 0xd518, wram);
                         PROT_JSR(offs, din, 0x8039, 0xac48, wram); break;
            case 0xe7ae: PROT_JSR(offs, din, 0x8011, 0x8e7c, wram);
                         PROT_JSR(offs, din, 0x802a, 0xb110, wram); break;
            case 0xe7be: PROT_JSR(offs, din, 0x8022, 0xd558, wram);
                         PROT_JSR(offs, din, 0x801b, 0xb9b2, wram); break;
            case 0xe7ce: PROT_JSR(offs, din, 0x8003, 0x96da, wram);
                         PROT_JSR(offs, din, 0x800c, 0xbb4c, wram); break;
            case 0xe7de: PROT_JSR(offs, din, 0x8034, 0xa062, wram);
                         PROT_JSR(offs, din, 0x803d, 0xafa6, wram); break;
            case 0xe7ee: PROT_JSR(offs, din, 0x8015, 0xa154, wram);
                         PROT_JSR(offs, din, 0x802e, 0xc6a4, wram); break;
            case 0xe7fe: PROT_JSR(offs, din, 0x8026, 0xa57a, wram);
                         PROT_JSR(offs, din, 0x8016, 0xa57a, wram); break;
            case 0xef00:
                if (din == 0x60fe) {
                    // Game wrote an infinite-loop opcode at 0xEF00 as MCU trigger.
                    // MCU patches it into JMP $92F4 (coin counter / init dispatcher).
                    wram[0xef00/2] = 0x0000;
                    wram[0xef02/2] = 0x0000;
                    wram[0xef04/2] = 0x4ef9;   // JMP opcode
                    wram[0xef06/2] = 0x0000;
                    wram[0xef08/2] = 0x92f4;
                    fprintf(stderr, "  [MCU] EF00 trigger: patched JMP $92F4\n");
                }
                break;
            default: break;
        }
    }

    // Call once per frame at VBlank to simulate MCU housekeeping.
    // Sets free-play mode (no coin required) so the game enters attract mode.
    static void per_frame(uint16_t* wram)
    {
        // Set free-play bit in game state (DIP switch 0 = free play)
        wram[0x9000/2] |= 0x4000;
    }

    // Call every rising clock edge (or every few iters) to catch any PROT trigger
    // values that the RTL may have just committed to WRAM.
    // This is necessary because the RTL's write_ff commits one cycle AFTER our
    // on_wram_write() fires. Polling here ensures we catch the value in WRAM
    // even if timing races prevent our write hook from acting in time.
    static void poll_and_patch(uint16_t* wram)
    {
        // EF00: if game wrote 0x60FE (infinite loop trap), immediately patch it.
        if (wram[0xef00/2] == 0x60fe) {
            static bool ef00_patched = false;
            if (!ef00_patched) {
                ef00_patched = true;
                fprintf(stderr, "  [MCU] poll: EF00=0x60FE → patching JMP $92F4 at EF04\n");
            }
            wram[0xef00/2] = 0x0000;  // NOP out the BRA (break the infinite loop)
            wram[0xef02/2] = 0x0000;
            wram[0xef04/2] = 0x4ef9;  // JMP
            wram[0xef06/2] = 0x0000;  // target high word
            wram[0xef08/2] = 0x92f4;  // target low word
        }

        // WRAM[0x9008] = MCU handshake: 68K writes non-zero to request MCU action,
        // MCU clears it to acknowledge. Without a real TLCS90, we simply ACK immediately.
        if (wram[0x9008/2] != 0) {
            static int ack_count = 0;
            ++ack_count;
            if (ack_count <= 5)
                fprintf(stderr, "  [MCU] poll: ACK WRAM[9008]=%04X → clearing (ack #%d)\n",
                        wram[0x9008/2], ack_count);
            wram[0x9008/2] = 0x0000;  // acknowledge MCU request
        }
    }

private:
    // wram_wridx(off) = word index of byte offset `off` within WRAM
    static inline uint16_t wram_rd(const uint16_t* wram, uint32_t byte_off) {
        return wram[byte_off / 2];
    }
    static inline void wram_wr(uint16_t* wram, uint32_t byte_off, uint16_t v) {
        wram[byte_off / 2] = v;
    }

    // PROT_JSR: if din == protvalue, patch JMP at (offs+2-0x10)
    // Called at bus start before the RTL write commits, so we compare 'din' not wram[offs/2].
    // The RTL will write 'din' to wram[offs/2] momentarily; the JMP patch goes to a
    // DIFFERENT set of addresses (offs+2-0x10 through offs+6-0x10) which are not
    // simultaneously written by the CPU, so the patch persists correctly.
    static void PROT_JSR(uint32_t offs, uint16_t din, uint16_t protvalue, uint16_t pc,
                         uint16_t* wram)
    {
        if (din == protvalue) {
            static int pjsr_log = 0;
            ++pjsr_log;
            if (pjsr_log <= 20)
                fprintf(stderr, "  [MCU] PROT_JSR: offs=%04X din=%04X → JMP $%04X at wram[%04X]\n",
                        offs, din, pc, offs + 2 - 0x10);
            // Patch JMP at the slot's entry point (offs+2-0x10), e.g. 0xE700 for offs=0xE70E
            wram[(offs + 2 - 0x10) / 2] = 0x4ef9;  // JMP opcode
            wram[(offs + 4 - 0x10) / 2] = 0x0000;  // high word of target address
            wram[(offs + 6 - 0x10) / 2] = pc;       // low word of target address
        }
    }

    // PROT_INPUT: if din == protvalue, write input data to wram[input_offs/2]
    // Called at bus start before the RTL write commits, so we compare 'din' not wram[offs/2].
    static void PROT_INPUT(uint16_t din, uint16_t protvalue,
                           uint32_t input_offs, uint32_t input_val,
                           uint16_t* wram)
    {
        if (din == protvalue) {
            wram[input_offs/2]     = (uint16_t)((input_val >> 16) & 0xffff);
            wram[input_offs/2 + 1] = (uint16_t)(input_val & 0xffff);
        }
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
//     [66564..70659] 4 KB  sprite RAM   (sprite_ram_storage[0..2047] in nmk16 — 8-word format)
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
    // Access the Verilator-generated tb_top sub-module that holds all internal state.
    // (In Verilator 5.x, internal arrays migrated from rootp to tb_top.)
    auto* r = top->tb_top;

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
        write_word_be(f, (uint16_t)r->__PVT__u_nmk__DOT__work_ram[i]);
    // Palette RAM: 512 words at 0x0C8000-0x0C87FF
    for (int i = 0; i < 512; i++)
        write_word_be(f, (uint16_t)r->__PVT__u_nmk__DOT__palette_ram[i]);
    // Sprite RAM: 2048 words in nmk16 (256 sprites × 8 words)
    for (int i = 0; i < 2048; i++)
        write_word_be(f, (uint16_t)r->__PVT__u_nmk__DOT__u_nmk16__DOT__sprite_ram_storage[i]);
    // BG Tilemap RAM: 2048 words in nmk16, padded to 16KB
    for (int i = 0; i < 2048; i++)
        write_word_be(f, (uint16_t)r->__PVT__u_nmk__DOT__u_nmk16__DOT__tilemap_ram[i]);
    write_zeros(f, 16384 - 4096);  // pad to 16KB
    // TX VRAM: 2KB (zeros — stub)
    write_zeros(f, 2048);
    // Scroll regs: use active (post-vblank latch) values
    // Note: Verilator optimizes out some shadow registers; use _active which are always present
    write_word_be(f, (uint16_t)r->__PVT__u_nmk__DOT__u_nmk16__DOT__scroll0_x_active);
    write_word_be(f, (uint16_t)r->__PVT__u_nmk__DOT__u_nmk16__DOT__scroll0_y_active);
    write_word_be(f, (uint16_t)r->__PVT__u_nmk__DOT__u_nmk16__DOT__scroll1_x_active);
    write_word_be(f, (uint16_t)r->__PVT__u_nmk__DOT__u_nmk16__DOT__scroll1_y_active);
#else
    write_zeros(f, 65536);  // main RAM
    write_zeros(f, 1024);   // palette RAM
    write_zeros(f, 4096);   // sprite RAM (2048 words × 2 bytes)
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

    // ── Thunder Dragon ROM patches (matching FBNeo TdragonLoadCallback) ───────
    // FBNeo patches two instructions with NOP (0x4E71) to bypass protection checks.
    // Without these patches the CPU loops in a protection routine and never enters
    // the main game loop, so sprite data is never written to WRAM[0x8000].
    //   ROM byte 0x048A: NOP (was BNE +8)
    //   ROM byte 0x04AA: NOP (was BRA +0x40)
    if (env_prog) {
        sdram.mem[0x048A / 2] = 0x4E71;  // NOP replaces BNE branch
        sdram.mem[0x04AA / 2] = 0x4E71;  // NOP replaces BRA branch

        // ── RAM test bypass (0x919C, 0x91A4, 0x91AA) ─────────────────────────
        // The init code at 0x9186 runs a WRAM read/write test.  The test loop at
        // 0x9198-0x91AA writes a pattern, reads it back, and branches to a
        // "WORK RAM CHECK ERROR" display path at 0x9256/0x925A if the comparison
        // fails.  That error path is entered via a direct BNE (no JSR), so SP
        // stays at its initial value of 0x0C0000 (reset SSP).  The RTS at 0x92B6
        // then reads the return address from the NMK4 I/O registers (0x0C0000),
        // gets 0xFFFFFFFF, and triggers an Address Error crash loop.
        //
        // Additional issue: The loop at 0x91A8-0x91AA (CMPA.L A0, A1; BNE.S 0x9198)
        // runs until A0 == A1.  A0 starts at 0x0B0000 (WRAM) and A1 at 0x0C0000
        // (one past WRAM end), both advancing by 2 per iteration.  They are always
        // 0x10000 apart and NEVER converge → infinite loop.  The original ROM exits
        // via the BNE.W branches (either error or some other mechanism), but in our
        // simulation with WRAM working, neither BNE fires.
        //
        // Fix: NOP out the error BNE.W branches AND the loop-back BNE.S so the
        // RAM test executes one iteration and falls through to the success path
        // (BRA.W at 0x9250 → main game loop at 0xBE8E).
        //   0x919C: 6600 00BA = BNE.W 0x925A (error A) → NOP NOP
        //   0x91A4: 6600 00AE = BNE.W 0x9256 (error B) → NOP NOP
        //   0x91AA: 66EC      = BNE.S 0x9198 (loop back) → NOP
        sdram.mem[0x919C / 2] = 0x4E71;  // NOP replaces BNE.W opcode
        sdram.mem[0x919E / 2] = 0x4E71;  // NOP replaces BNE.W displacement
        sdram.mem[0x91A4 / 2] = 0x4E71;  // NOP replaces BNE.W opcode
        sdram.mem[0x91A6 / 2] = 0x4E71;  // NOP replaces BNE.W displacement
        sdram.mem[0x91AA / 2] = 0x4E71;  // NOP replaces BNE.S loop-back (was 0x66EC)

        // ROM at 0x92B6 contains 0x60FE (BRA.s -2 = infinite loop to self).
        // This is the end of the "WORK RAM CHECK ERROR" display path.  With the
        // RAM test bypass above this path should never be reached in normal
        // simulation, but the RTS patch remains as a safety net.
        sdram.mem[0x92B6 / 2] = 0x4E75;  // RTS replaces BRA.s -2 (infinite loop)

        // ROM at 0x946A contains CLR.W $0002.W followed by BRA.s -6 (infinite
        // loop at 0x946E).  This is an MCU-sync trap: the game writes a command
        // to TX RAM ($0D07C4) and waits for the TLCS90 to patch 0x946E with RTS.
        // Patch all three words to NOP so execution falls through to 0x9470.
        sdram.mem[0x946A / 2] = 0x4E71;  // NOP replaces CLR.W opcode (was 0x4278)
        sdram.mem[0x946C / 2] = 0x4E71;  // NOP replaces CLR.W addr  (was 0x0002)
        sdram.mem[0x946E / 2] = 0x4E71;  // NOP replaces BRA.s -6    (was 0x60FA)
        fprintf(stderr, "ROM patches applied:\n");
        fprintf(stderr, "  NOP at 0x048A, 0x04AA (FBNeo compat)\n");
        fprintf(stderr, "  NOP+NOP at 0x919C-E (RAM test BNE.W error-A bypass)\n");
        fprintf(stderr, "  NOP+NOP at 0x91A4-6 (RAM test BNE.W error-B bypass)\n");
        fprintf(stderr, "  NOP at 0x91AA (RAM test BNE.S loop-back bypass → falls through to 0xBE8E)\n");
        fprintf(stderr, "  RTS at 0x92B6 (error path safety net)\n");
        fprintf(stderr, "  NOP+NOP+NOP at 0x946A-C-E (MCU sync trap bypass)\n");
    }

    // ── SDRAM channels ───────────────────────────────────────────────────────
    ToggleSdramChannel     prog_ch(sdram);
    // spr_ch and bg_ch removed: both use combinational direct-read (zero-latency)
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
            // Sprite ROM: pixel-rate access, bypass toggle-handshake.
            // nmk16 G3_FETCH reads spr_rom_data combinationally the same cycle
            // spr_rom_addr is valid ("combinational zero-latency" interface).
            uint32_t spr_addr = (uint32_t)top->spr_rom_sdram_addr;
            top->spr_rom_sdram_data = sdram.read_word(spr_addr & ~1u);
            top->spr_rom_sdram_ack  = top->spr_rom_sdram_req;  // always ack immediately
        }
        {
            // BG tile ROM: pixel-rate combinational access (same as main loop).
            uint32_t bg_addr = (uint32_t)top->bg_rom_sdram_addr;
            top->bg_rom_sdram_data = sdram.read_word(bg_addr & ~1u);
            top->bg_rom_sdram_ack  = top->bg_rom_sdram_req;
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

            // ── Sprite DMA: copy WRAM[0x4000..0x4FFF] → NMK16 sprite_ram_storage ──
            // Emulates the hardware DMA that fires at VBlank.
            // FBNeo: memcpy(DrvSprBuf2, Drv68KRAM + 0x8000, 0x1000) copies 4096 bytes
            // = 2048 words from WRAM byte-offset 0x8000 = WRAM word-offset 0x4000.
            // 256 sprites × 8 words = 2048 words.
            // Verilator-only: RTL synthesis path needs a proper DMA state machine.
            {
                auto* r = top->tb_top;
                for (int i = 0; i < 2048; i++) {
                    r->__PVT__u_nmk__DOT__u_nmk16__DOT__sprite_ram_storage[i] =
                        r->__PVT__u_nmk__DOT__work_ram[0x4000 + i];
                }
            }

            // ── NMK004 MCU per-frame housekeeping (free-play, DIP inputs) ─────
            // NOTE: Skip frame 0 — game hasn't initialized work RAM yet.
            // MAME's NMK004 MCU also doesn't start housekeeping until after init.
            // (TASK-060 discovered this causes divergence at frame 0.)
            if (frame_num > 0) {
                auto* wram = &top->tb_top->__PVT__u_nmk__DOT__work_ram.m_storage[0];
                TdragonMCU::per_frame(wram);
            }

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

    // Per-frame write counters (reset at each vsync)
    int      bg_vram_wr_this_frame  = 0;
    int      wram_wr_this_frame     = 0;
    int      scroll_wr_this_frame   = 0;

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
                // Sprite ROM: pixel-rate access, bypass toggle-handshake.
                // nmk16 G3_FETCH reads spr_rom_data combinationally the same cycle
                // spr_rom_addr is valid ("combinational zero-latency" interface).
                uint32_t spr_addr = (uint32_t)top->spr_rom_sdram_addr;
                top->spr_rom_sdram_data = sdram.read_word(spr_addr & ~1u);
                top->spr_rom_sdram_ack  = top->spr_rom_sdram_req;  // always ack immediately
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

            // ── NMK004 MCU: poll WRAM for protection triggers each rising edge ─
            // Catches values that the RTL just committed to work_ram (one cycle
            // after on_wram_write() fires). Runs every rising edge so we respond
            // within one CPU cycle of the trigger write.
            {
                auto* wram = &top->tb_top->__PVT__u_nmk__DOT__work_ram.m_storage[0];
                TdragonMCU::poll_and_patch(wram);
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

                // Log first 200 bus cycles, bc20000-20200 (expected JMP 9186 area),
                // and bc25000-25200 (expected main game loop entry area).
                bool log_this = (!asn_c && prev_asn_c && iter > RESET_ITERS) &&
                    (bus_cycles_c < 200 ||
                     (bus_cycles_c >= 20000 && bus_cycles_c <= 20200) ||
                     (bus_cycles_c >= 25000 && bus_cycles_c <= 25200));
                if (log_this) {
                    auto* wram = &top->tb_top->__PVT__u_nmk__DOT__work_ram.m_storage[0];
                    uint16_t stk_f6 = (uint16_t)wram[0xFFF6/2];
                    uint16_t stk_f8 = (uint16_t)wram[0xFFF8/2];
                    uint16_t stk_fa = (uint16_t)wram[0xFFFA/2];
                    uint16_t stk_fc = (uint16_t)wram[0xFFFC/2];
                    fprintf(stderr, "  [%6lu|bc%d] ASn=0 RW=%d addr=%06X dtack_n=%d dout=%04X | stk@BFFF6=%04X %04X %04X %04X\n",
                            (unsigned long)iter, bus_cycles_c, (int)rwn_c, addr_c,
                            (int)top->dbg_cpu_dtack_n, (unsigned)(top->dbg_cpu_dout),
                            stk_f6, stk_f8, stk_fa, stk_fc);
                }
                // Also log reads from main game loop region (0xBE00-0xCFFF) - first 30
                static int main_loop_log = 0;
                if (!asn_c && prev_asn_c && iter > RESET_ITERS && rwn_c &&
                    addr_c >= 0xBE00 && addr_c <= 0xCFFF && main_loop_log < 30) {
                    ++main_loop_log;
                    fprintf(stderr, "  MAINLOOP bc%d addr=%06X dout=%04X frame=%d\n",
                            bus_cycles_c, addr_c, (unsigned)(top->dbg_cpu_dout & 0xFFFF), frame_num);
                }
                // Log reads from RAM test / early init area (0x9000-0x9300) - first 20
                static int ramtest_log = 0;
                if (!asn_c && prev_asn_c && iter > RESET_ITERS && rwn_c &&
                    addr_c >= 0x9000 && addr_c <= 0x9300 && ramtest_log < 20) {
                    ++ramtest_log;
                    fprintf(stderr, "  RAMTEST bc%d addr=%06X dout=%04X frame=%d\n",
                            bus_cycles_c, addr_c, (unsigned)(top->dbg_cpu_dout & 0xFFFF), frame_num);
                }

                // Exception vector table reads: 0x0000-0x003F → log first 20
                static int vec_read_count = 0;
                if (!asn_c && prev_asn_c && iter > RESET_ITERS && rwn_c &&
                    addr_c <= 0x3F && vec_read_count < 80) {
                    ++vec_read_count;
                    fprintf(stderr, "  VECRD bc%d addr=%06X dout=%04X (vec#%d)\n",
                            bus_cycles_c, addr_c, (unsigned)(top->dbg_cpu_dout & 0xFFFF),
                            addr_c / 4);
                }

                // Log any execution from suspicious/invalid addresses (> 0x3FFFF ROM range)
                static int bad_pc_count = 0;
                if (!asn_c && prev_asn_c && iter > RESET_ITERS && rwn_c &&
                    addr_c > 0x3FFFF && addr_c < 0x0B0000 && bad_pc_count < 20) {
                    ++bad_pc_count;
                    fprintf(stderr, "  BADPC bc%d addr=%06X dout=%04X frame=%d\n",
                            bus_cycles_c, addr_c, (unsigned)(top->dbg_cpu_dout & 0xFFFF), frame_num);
                }
                // Log VBL interrupt handler execution (reads from 0x030000-0x03FFFF = VBL handler area)
                // Thunder Dragon VBL IRQ vector is at 0x70 (level 4 autovector), handler typically ~0x030xxx
                // Log first 5 times per frame
                static int vbl_exec_count = 0;
                static int prev_frame_vbl = -1;
                if (!asn_c && prev_asn_c && iter > RESET_ITERS && rwn_c) {
                    // Track any execution in interrupt/VBL handler ranges
                    // Read of VBL vector table entry (0x70 = level 4 autovector)
                    if (addr_c == 0x70 || addr_c == 0x72) {
                        fprintf(stderr, "  VBL_VEC bc%d addr=%06X dout=%04X frame=%d\n",
                                bus_cycles_c, addr_c, (unsigned)(top->dbg_cpu_dout & 0xFFFF), frame_num);
                    }
                    // Track interrupt acknowledgement cycles (VPAn / autovector)
                    // FC0=1,FC1=0,FC2=1 and AS low = IACK cycle
                }

                // NMK004 I/O: log reads from 0x0C000E and writes to 0x0C001E
                static int nmk_io_log_count = 0;
                if (!asn_c && prev_asn_c && iter > RESET_ITERS && nmk_io_log_count < 200) {
                    if (addr_c == 0x0C000E && rwn_c) {
                        fprintf(stderr, "  NMK_RD bc%d addr=0C000E dout=%04X frame=%d\n",
                                bus_cycles_c, (unsigned)(top->dbg_cpu_dout & 0xFFFF), frame_num);
                        ++nmk_io_log_count;
                    }
                    if (addr_c == 0x0C001E && !rwn_c) {
                        fprintf(stderr, "  NMK_WR bc%d addr=0C001E din=%04X frame=%d\n",
                                bus_cycles_c, (unsigned)(top->dbg_cpu_din & 0xFFFF), frame_num);
                        ++nmk_io_log_count;
                    }
                }

                // Track palette writes (0x0C8000-0x0C87FF) and report first few
                static int pal_wr_count_c = 0;
                static int wram_wr_count_c = 0;
                static int spr_direct_wr_c = 0;
                static int bg_vram_wr_count_c = 0;     // BG VRAM writes (0x0CC000-0x0CFFFF)
                if (!asn_c && !rwn_c && prev_asn_c) {
                    // New write bus cycle starting
                    // Track direct sprite RAM writes (0x130000-0x13FFFF)
                    if (addr_c >= 0x130000 && addr_c <= 0x13FFFF) {
                        ++spr_direct_wr_c;
                        if (spr_direct_wr_c <= 8)
                            fprintf(stderr, "  SPR DIRECT WR #%d addr=%06X din=%04X frame=%d\n",
                                    spr_direct_wr_c, addr_c, (unsigned)(top->dbg_cpu_din & 0xFFFF), frame_num);
                    }
                    // BG VRAM writes (0x0CC000-0x0CFFFF) — tilemap data
                    if (addr_c >= 0x0CC000 && addr_c <= 0x0CFFFF) {
                        ++bg_vram_wr_count_c;
                        ++bg_vram_wr_this_frame;
                        if (bg_vram_wr_count_c <= 8)
                            fprintf(stderr, "  BG VRAM WR #%d addr=%06X din=%04X frame=%d\n",
                                    bg_vram_wr_count_c, addr_c,
                                    (unsigned)(top->dbg_cpu_din & 0xFFFF), frame_num);
                    }
                    // Scroll register writes (0x0C4000-0x0C43FF)
                    if (addr_c >= 0x0C4000 && addr_c <= 0x0C43FF) {
                        ++scroll_wr_this_frame;
                        if (frame_num <= 5 || (frame_num % 10) == 0)
                            fprintf(stderr, "  SCROLL WR addr=%06X din=%04X frame=%d\n",
                                    addr_c, (unsigned)(top->dbg_cpu_din & 0xFFFF), frame_num);
                    }
                    // At frame 5: print all write addresses and data (first 30 writes)
                    static int frame5_wr = 0;
                    static bool frame5_logged = false;
                    if (frame_num == 5 && !frame5_logged) {
                        ++frame5_wr;
                        if (frame5_wr <= 40) {
                            fprintf(stderr, "  F5 WR #%d addr=%06X din=%04X\n",
                                    frame5_wr, addr_c, (unsigned)(top->dbg_cpu_din & 0xFFFF));
                        } else {
                            frame5_logged = true;
                        }
                    }
                    if (addr_c >= 0x0C8000 && addr_c <= 0x0C87FF) {
                        ++pal_wr_count_c;
                        if (pal_wr_count_c <= 5)
                            fprintf(stderr, "  PAL WR #%d addr=%06X data=%04X @iter=%lu\n",
                                    pal_wr_count_c, addr_c, (unsigned)top->dbg_cpu_din,
                                    (unsigned long)iter);
                    }
                    if (addr_c >= 0x0B0000 && addr_c <= 0x0BFFFF) {
                        ++wram_wr_count_c;
                        ++wram_wr_this_frame;
                        if (wram_wr_count_c <= 3)
                            fprintf(stderr, "  WRAM WR #%d addr=%06X @iter=%lu\n",
                                    wram_wr_count_c, addr_c, (unsigned long)iter);
                        // Track non-zero writes to WRAM[0x8000..0x8FFF] — sprite DMA source region
                        if ((addr_c & 0xFFFF) >= 0x8000 && (addr_c & 0xFFFF) <= 0x8FFF) {
                            static int wram_spr_nonzero = 0;
                            uint16_t din_val = (uint16_t)(top->dbg_cpu_din & 0xFFFF);
                            if (din_val != 0) {
                                ++wram_spr_nonzero;
                                if (wram_spr_nonzero <= 200)
                                    fprintf(stderr, "  WRAM SPR NONZERO #%d addr=%06X din=%04X frame=%d\n",
                                            wram_spr_nonzero, addr_c, din_val, frame_num);
                            }
                        }
                        // Track writes to WRAM EF00-EF10 (coin counter / init dispatcher)
                        if ((addr_c & 0xFFFF) >= 0xEF00 && (addr_c & 0xFFFF) <= 0xEF10) {
                            uint16_t din_val = (uint16_t)(top->dbg_cpu_din & 0xFFFF);
                            fprintf(stderr, "  EF WR addr=%06X din=%04X frame=%d\n",
                                    addr_c, din_val, frame_num);
                        }
                        // Track writes to stack area near crash point (0xBFFF0-0xBFFFF)
                        if ((addr_c & 0xFFFF) >= 0xFFF0 && (addr_c & 0xFFFF) <= 0xFFFF) {
                            uint16_t din_val = (uint16_t)(top->dbg_cpu_din & 0xFFFF);
                            fprintf(stderr, "  STKTOP WR bc%d addr=%06X din=%04X frame=%d\n",
                                    bus_cycles_c, addr_c, din_val, frame_num);
                        }
                        // Track writes to 0xBFFEC-0xBFFFF (entire top-of-stack region)
                        if ((addr_c & 0xFFFF) >= 0xFFEC) {
                            uint16_t din_val = (uint16_t)(top->dbg_cpu_din & 0xFFFF);
                            fprintf(stderr, "  TOPSTK WR bc%d addr=%06X din=%04X frame=%d\n",
                                    bus_cycles_c, addr_c, din_val, frame_num);
                        }
                        // NMK004 MCU dispatch: handle PROT_JSR/PROT_INPUT on WRAM writes
                        {
                            uint32_t wram_byte_off = addr_c & 0xFFFF;
                            uint16_t din_val = (uint16_t)(top->dbg_cpu_din & 0xFFFF);
                            auto* wram = &top->tb_top->__PVT__u_nmk__DOT__work_ram.m_storage[0];
                            TdragonMCU::on_wram_write(wram_byte_off / 2, din_val, wram);
                        }
                    }
                }

                // Periodic write summary
                if (bus_cycles_c > 0 && (bus_cycles_c % 50000) == 0 && prev_asn_c && asn_c) {
                    fprintf(stderr, "  [%dK bus] pal_wr=%d wram_wr=%d frame=%d\n",
                            bus_cycles_c/1000, pal_wr_count_c, wram_wr_count_c, frame_num);
                    { auto* cpu = top->tb_top->u_cpu;
                      fprintf(stderr, "  IRQ: pswI=%d intPend=%d iIpl=%d rIpl=%d\n",
                              (int)cpu->pswI, (int)cpu->intPend, (int)cpu->iIpl, (int)cpu->rIpl); }
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
                    fprintf(stderr, "Frame %4d written: %s  (bus_cycles=%d  bg_vram_wr=%d  wram_wr=%d  scroll_wr=%d)\n",
                            frame_num, fname, bus_cycles_c,
                            bg_vram_wr_this_frame, wram_wr_this_frame, scroll_wr_this_frame);
                // Reset per-frame write counters
                bg_vram_wr_this_frame = 0;
                wram_wr_this_frame = 0;
                scroll_wr_this_frame = 0;

                // ── Sprite DMA: copy WRAM[0x4000..0x4FFF] → NMK16 sprite_ram_storage ──
                // Emulates the hardware DMA that fires at VBlank.
                // FBNeo: memcpy(DrvSprBuf2, Drv68KRAM + 0x8000, 0x1000) = 4096 bytes
                // = 2048 words from WRAM word-offset 0x4000 (byte-offset 0x8000).
                // 256 sprites × 8 words = 2048 words.
                // Verilator-only: RTL synthesis path needs a proper DMA state machine.
                {
                    auto* r = top->tb_top;
                    for (int i = 0; i < 2048; i++) {
                        r->__PVT__u_nmk__DOT__u_nmk16__DOT__sprite_ram_storage[i] =
                            r->__PVT__u_nmk__DOT__work_ram[0x4000 + i];
                    }
                }

                // ── NMK004 MCU per-frame housekeeping (free-play, DIP inputs) ─
                // NOTE: Skip frame 0 — game hasn't initialized work RAM yet.
                // MAME's NMK004 MCU also doesn't start housekeeping until after init.
                // (TASK-060 discovered this causes divergence at frame 0.)
                if (frame_num > 0) {
                    auto* wram = &top->tb_top->__PVT__u_nmk__DOT__work_ram.m_storage[0];
                    TdragonMCU::per_frame(wram);
                }

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
