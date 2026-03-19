// =============================================================================
// sdram_model.h — Behavioral SDRAM model for Toaplan V2 simulation
//
// Serves ROM data loaded from binary files.
// Toggle-handshake protocol: req toggles to initiate, ack mirrors req when
// data is ready (matches the toaplan_v2.sv bridge logic).
//
// SDRAM layout (byte addresses, per emu.sv / Batsugun MRA):
//   0x000000 — CPU program ROM (512 KB; WORD-SWAPPED per ROM_LOAD16_WORD_SWAP)
//   0x100000 — GFX ROM (6 MB; sprites + BG tiles from two GP9001 VDPs)
//   0x500000 — ADPCM ROM (OKI M6295 sample data, 256 KB)
//   (no Z80 ROM — Batsugun uses NEC V25 which uploads its code from main ROM)
//
// The GFX channel is 32-bit wide (gfx_rom_data[31:0]).
// All other channels are 16-bit (prog, adpcm) or 8-bit (z80).
// =============================================================================
#pragma once
#include <vector>
#include <cstdint>
#include <cstdio>
#include <cstring>

class SdramModel {
public:
    static constexpr size_t BYTE_SIZE = 1 << 24;   // 16 MB (covers 0x600000+)
    static constexpr size_t WORD_SIZE = BYTE_SIZE / 2;

    std::vector<uint16_t> mem;

    SdramModel() : mem(WORD_SIZE, 0) {}

    // Load a raw binary file (big-endian 16-bit words) at a byte offset.
    // The byte_offset must be even.
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
            mem[word_idx++] = ((uint16_t)buf[0] << 8) | buf[1];  // big-endian
            ++count;
        }
        fclose(f);
        fprintf(stderr, "SDRAM: loaded '%s' at byte 0x%06X (%zu words)\n",
                path, byte_offset, count);
        return true;
    }

    // Load a raw binary file applying MAME ROM_LOAD16_WORD_SWAP byte order.
    // The ROM file has each 16-bit word stored with bytes swapped (lo byte first,
    // hi byte second).  Swap them back to produce correct big-endian 68000 words.
    // This matches MAME's ROM_LOAD16_WORD_SWAP / ROM_GROUPWORD | ROM_REVERSE.
    bool load_word_swap(const char* path, uint32_t byte_offset) {
        if (!path || !*path) return false;
        FILE* f = fopen(path, "rb");
        if (!f) {
            fprintf(stderr, "SDRAM: cannot open (word-swap) '%s'\n", path);
            return false;
        }
        size_t word_idx = byte_offset / 2;
        uint8_t buf[2];
        size_t count = 0;
        while (fread(buf, 1, 2, f) == 2) {
            if (word_idx >= mem.size()) break;
            // ROM file stores [lo][hi]; swap to produce big-endian word (hi<<8)|lo
            mem[word_idx++] = ((uint16_t)buf[1] << 8) | buf[0];
            ++count;
        }
        fclose(f);
        fprintf(stderr, "SDRAM: loaded (word-swap) '%s' at byte 0x%06X (%zu words)\n",
                path, byte_offset, count);
        return true;
    }

    // Load a raw binary file as interleaved byte pairs (for 68000 ROM halves).
    // hi=true: load into even bytes (upper byte of each word)
    // hi=false: load into odd bytes (lower byte of each word)
    bool load_interleaved(const char* path, uint32_t byte_offset, bool hi) {
        if (!path || !*path) return false;
        FILE* f = fopen(path, "rb");
        if (!f) {
            fprintf(stderr, "SDRAM: cannot open (interleaved) '%s'\n", path);
            return false;
        }
        size_t word_idx = byte_offset / 2;
        int c;
        size_t count = 0;
        while ((c = fgetc(f)) != EOF) {
            if (word_idx >= mem.size()) break;
            if (hi) {
                mem[word_idx] = (mem[word_idx] & 0x00FF) | ((uint16_t)(c & 0xFF) << 8);
            } else {
                mem[word_idx] = (mem[word_idx] & 0xFF00) | (uint16_t)(c & 0xFF);
            }
            ++word_idx;
            ++count;
        }
        fclose(f);
        fprintf(stderr, "SDRAM: loaded interleaved '%s' at byte 0x%06X hi=%d (%zu bytes)\n",
                path, byte_offset, (int)hi, count);
        return true;
    }

    // Read a 16-bit word by byte address (word-aligned).
    uint16_t read_word(uint32_t byte_addr) const {
        size_t idx = (byte_addr & (BYTE_SIZE - 1)) / 2;
        return (idx < mem.size()) ? mem[idx] : 0xFFFF;
    }

    // Read a 32-bit word by byte address (4-byte aligned).
    // GFX channel returns 4 bytes packed as [31:24]=byte0, [23:16]=byte1, ...
    uint32_t read_dword(uint32_t byte_addr) const {
        byte_addr &= ~3u;
        uint16_t hi = read_word(byte_addr);
        uint16_t lo = read_word(byte_addr + 2);
        return ((uint32_t)hi << 16) | (uint32_t)lo;
    }

    // Read a byte by byte address.
    uint8_t read_byte(uint32_t byte_addr) const {
        uint16_t w = read_word(byte_addr & ~1u);
        return (byte_addr & 1) ? (uint8_t)(w & 0xFF) : (uint8_t)(w >> 8);
    }
};

// =============================================================================
// ToggleSdramChannel — models a single 16-bit SDRAM channel.
//
// Protocol (matches toaplan_v2.sv prog ROM bridge):
//   - Requestor toggles req to initiate a transfer.
//   - Controller returns ack == req when data is ready.
//   - 1-cycle latency (suitable for sim; real hardware is ~143 MHz SDRAM).
// =============================================================================
class ToggleSdramChannel {
public:
    static constexpr int LATENCY = 1;

    explicit ToggleSdramChannel(const SdramModel& sdram)
        : sdram_(sdram), ack_(0), last_req_(0), countdown_(0),
          pending_addr_(0), data_(0) {}

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
// ToggleSdramChannel32 — 32-bit GFX ROM channel.
//
// toaplan_v2 uses a 32-bit GFX channel for GP9001 tile/sprite fetches.
// In sim we use direct combinational read (zero latency) on every tick.
// =============================================================================
class ToggleSdramChannel32 {
public:
    static constexpr int LATENCY = 1;

    explicit ToggleSdramChannel32(const SdramModel& sdram)
        : sdram_(sdram), ack_(0), last_req_(0), countdown_(0),
          pending_addr_(0), data_(0) {}

    struct Result { uint32_t data; uint8_t ack; };

    Result tick(uint8_t req, uint32_t addr) {
        if (req != last_req_) {
            last_req_     = req;
            pending_addr_ = addr;
            countdown_    = LATENCY;
        }
        if (countdown_ > 0) {
            --countdown_;
            if (countdown_ == 0) {
                data_ = sdram_.read_dword(pending_addr_ & ~3u);
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
    uint32_t data_;
};

// =============================================================================
// ToggleSdramChannelByte — byte-wide channel (Z80 ROM).
// =============================================================================
class ToggleSdramChannelByte {
public:
    static constexpr int LATENCY = 3;

    explicit ToggleSdramChannelByte(const SdramModel& sdram)
        : sdram_(sdram), ack_(0), last_req_(0), countdown_(0),
          pending_addr_(0), data_(0) {}

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
