// =============================================================================
// sdram_model.h — Behavioral SDRAM model for Psikyo Arcade simulation
//
// Serves ROM data loaded from binary files.
// Toggle-handshake protocol: req toggles to initiate, ack mirrors req when
// data is ready (matches psikyo_arcade.sv bridge logic).
// 1-cycle latency per request (sufficient for simulation correctness).
//
// SDRAM layout (byte addresses, per Gunbird.mra / psikyo_arcade.sv):
//   0x000000 – 0x1FFFFF   2 MB    CPU program ROM
//   0x200000 – 0x5FFFFF   4 MB    Sprite ROM (PS2001B / Gate 3)
//   0x600000 – 0x9FFFFF   4 MB    BG tile ROM (PS3103 / Gate 4)
//   0xA00000 – 0xAFFFFF   1 MB    ADPCM ROM (YM2610B)
//   0xA80000 – 0xA87FFF   32 KB   Z80 sound ROM (per emu.sv; within ADPCM region)
// =============================================================================
#pragma once
#include <vector>
#include <cstdint>
#include <cstdio>
#include <cstring>

class SdramModel {
public:
    // 32 MB covers all Psikyo SDRAM regions
    static constexpr size_t BYTE_SIZE = 1u << 25;   // 32 MB
    static constexpr size_t WORD_SIZE = BYTE_SIZE / 2;

    std::vector<uint16_t> mem;

    SdramModel() : mem(WORD_SIZE, 0) {}

    // Load a raw binary file at a byte offset.
    // interleave_stride: if > 0, load even bytes of pairs at byte_offset
    //   and odd bytes at byte_offset+1 (for interleaved 68000 ROM images).
    bool load(const char* path, uint32_t byte_offset, bool swap_words = false) {
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
            // big-endian byte order: buf[0] is MSB (D15:D8), buf[1] is LSB (D7:D0)
            uint16_t w = ((uint16_t)buf[0] << 8) | buf[1];
            if (swap_words) w = (w >> 8) | (w << 8);
            mem[word_idx++] = w;
            ++count;
        }
        fclose(f);
        fprintf(stderr, "SDRAM: loaded '%s' at byte 0x%07X (%zu words)\n",
                path, byte_offset, count);
        return true;
    }

    // Load a byte-wide file (e.g. Z80 ROM) at a byte offset.
    // Byte files are packed two-per-word with the first byte at bits[15:8].
    bool load_bytes(const char* path, uint32_t byte_offset) {
        if (!path || !*path) return false;
        FILE* f = fopen(path, "rb");
        if (!f) {
            fprintf(stderr, "SDRAM: cannot open '%s'\n", path);
            return false;
        }
        uint8_t buf[1];
        uint32_t byte_addr = byte_offset;
        size_t count = 0;
        while (fread(buf, 1, 1, f) == 1) {
            uint32_t word_idx = (byte_addr & (BYTE_SIZE - 1)) / 2;
            if (word_idx >= mem.size()) break;
            // High byte if even address, low byte if odd
            if ((byte_addr & 1) == 0)
                mem[word_idx] = (mem[word_idx] & 0x00FF) | ((uint16_t)buf[0] << 8);
            else
                mem[word_idx] = (mem[word_idx] & 0xFF00) | buf[0];
            ++byte_addr;
            ++count;
        }
        fclose(f);
        fprintf(stderr, "SDRAM: loaded_bytes '%s' at byte 0x%07X (%zu bytes)\n",
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
// ToggleSdramChannel — single SDRAM channel with toggle handshake.
//
// Protocol (matches psikyo_arcade.sv bridges):
//   req toggles → new request; ack mirrors req when data is ready.
// 1-cycle latency for simulation (no real SDRAM timing needed).
// =============================================================================
class ToggleSdramChannel {
public:
    static constexpr int LATENCY = 1;

    explicit ToggleSdramChannel(const SdramModel& sdram)
        : sdram_(sdram), ack_(0), last_req_(0), countdown_(0),
          pending_addr_(0), data_(0xFFFF) {}

    struct Result { uint16_t data; uint8_t ack; };

    Result tick(uint8_t req, uint32_t addr) {
        if (req != last_req_) {
            last_req_     = req;
            pending_addr_ = addr;
            countdown_    = LATENCY;
        }
        if (countdown_ > 0) {
            --countdown_;
            if (countdown_ == 0) {
                data_ = sdram_.read_word(pending_addr_ & ~1u);
                ack_  = last_req_;
            }
        }
        return {data_, ack_};
    }

    uint8_t ack() const { return ack_; }

private:
    const SdramModel& sdram_;
    uint8_t  ack_;
    uint8_t  last_req_;
    int      countdown_;
    uint32_t pending_addr_;
    uint16_t data_;
};

// =============================================================================
// ToggleSdramChannelByte — same but returns 8-bit data.
// Used for Z80 ROM channel (z80_rom_data is 8 bits).
// Latency = 3 to match what psikyo_arcade.sv Z80 bridge expects.
// =============================================================================
class ToggleSdramChannelByte {
public:
    static constexpr int LATENCY = 3;

    explicit ToggleSdramChannelByte(const SdramModel& sdram)
        : sdram_(sdram), ack_(0), last_req_(0), countdown_(0),
          pending_addr_(0), data_(0xFF) {}

    struct Result { uint8_t data; uint8_t ack; };

    Result tick(uint8_t req, uint32_t addr) {
        if (req != last_req_) {
            last_req_     = req;
            pending_addr_ = addr;
            countdown_    = LATENCY;
        }
        if (countdown_ > 0) {
            --countdown_;
            if (countdown_ == 0) {
                data_ = sdram_.read_byte(pending_addr_);
                ack_  = last_req_;
            }
        }
        return {data_, ack_};
    }

private:
    const SdramModel& sdram_;
    uint8_t  ack_;
    uint8_t  last_req_;
    int      countdown_;
    uint32_t pending_addr_;
    uint8_t  data_;
};
