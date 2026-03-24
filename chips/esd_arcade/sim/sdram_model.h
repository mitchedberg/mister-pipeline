// =============================================================================
// sdram_model.h — Behavioral SDRAM model for ESD 16-bit Arcade simulation
//
// Serves ROM data loaded from binary files.
// Toggle-handshake protocol: req toggles to initiate, ack mirrors req when data
// is ready (matches the esd_arcade.sv bridge logic).
// 1-cycle latency per request for CPU bring-up.
//
// SDRAM layout (byte addresses, per Multi_Champ.mra):
//   0x000000 — CPU program ROM  (512KB, word-wide)
//   0x080000 — Sprite ROM       (up to 1.25MB for hedpanic_sprite_16x16x5)
//   0x280000 — BG Tile ROM      (up to 512KB, 8bpp tiles)
// =============================================================================
#pragma once
#include <vector>
#include <cstdint>
#include <cstdio>
#include <cstring>

class SdramModel {
public:
    static constexpr size_t BYTE_SIZE = 1 << 23;   // 8 MB
    static constexpr size_t WORD_SIZE = BYTE_SIZE / 2;

    std::vector<uint16_t> mem;

    SdramModel() : mem(WORD_SIZE, 0xFFFF) {}

    // Load a raw binary file (big-endian 16-bit words) at a byte offset.
    bool load(const char* path, uint32_t byte_offset) {
        if (!path || !*path) return false;
        FILE* f = fopen(path, "rb");
        if (!f) {
            fprintf(stderr, "SDRAM: cannot open '%s'\n", path);
            return false;
        }
        size_t word_idx = byte_offset / 2;
        uint8_t buf[2];
        size_t count = 0;
        while (fread(buf, 1, 2, f) == 2) {
            if (word_idx >= mem.size()) break;
            mem[word_idx++] = ((uint16_t)buf[0] << 8) | buf[1];
            ++count;
        }
        fclose(f);
        fprintf(stderr, "SDRAM: loaded '%s' at byte 0x%06X (%zu words)\n",
                path, byte_offset, count);
        return true;
    }

    // Read a 16-bit word by byte address (word-aligned).
    uint16_t read_word(uint32_t byte_addr) const {
        size_t idx = (byte_addr & (BYTE_SIZE - 1)) / 2;
        return (idx < mem.size()) ? mem[idx] : 0xFFFF;
    }

    // Read a byte by byte address.
    uint8_t read_byte(uint32_t byte_addr) const {
        uint16_t w = read_word(byte_addr & ~1u);
        return (byte_addr & 1) ? (uint8_t)(w & 0xFF) : (uint8_t)(w >> 8);
    }
};

// =============================================================================
// ToggleSdramChannel — models a single SDRAM channel using toggle handshake.
//
// Protocol (matches esd_arcade.sv bridges):
//   - Requestor raises req to initiate a transfer (level-based, not toggle).
//   - ack is returned as 1 when data is ready.
//   - On each posedge clk the testbench calls tick():
//       if req && !ack_prev: new request, start countdown
//       countdown → 0: present data, set ack=1
//       if !req: ack=0
// =============================================================================
class ToggleSdramChannel {
public:
    static constexpr int LATENCY = 1;

    const SdramModel& sdram;
    int               countdown  = 0;
    bool              pending    = false;
    uint16_t          data_out   = 0xFFFF;
    uint8_t           ack_out    = 0;

    explicit ToggleSdramChannel(const SdramModel& s) : sdram(s) {}

    struct Result { uint16_t data; uint8_t ack; };

    // Call on every posedge clk_sys.
    // req  — current req port value from DUT
    // addr — current addr port value from DUT (byte address)
    Result tick(uint8_t req, uint32_t addr) {
        if (req && !pending) {
            // New request
            pending   = true;
            countdown = LATENCY;
        }
        if (pending) {
            if (countdown > 0) {
                --countdown;
                ack_out = 0;
            } else {
                // Latch data and acknowledge
                data_out = sdram.read_word(addr & ~1u);
                ack_out  = 1;
                pending  = false;
            }
        }
        if (!req) {
            ack_out = 0;
            pending = false;
        }
        return { data_out, ack_out };
    }
};
