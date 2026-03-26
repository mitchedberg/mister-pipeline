// =============================================================================
// sdram_model.h — Behavioral SDRAM model for NMK Arcade simulation
//
// Serves ROM data loaded from binary files.
// Toggle-handshake protocol: req toggles to initiate, ack mirrors req when data
// is ready (matches the nmk_arcade.sv bridge logic).
// 3-cycle latency per request.
//
// SDRAM layout (byte addresses, per Thunder_Dragon.mra):
//   0x000000 — CPU program ROM (up to 512KB; 256KB for Thunder Dragon)
//   0x0C0000 — Sprite ROM      (up to 1MB;  1MB  for Thunder Dragon)
//   0x1C0000 — BG tile ROM     (128KB, fgtile only — tile_idx is 10-bit)
//   0x200000 — ADPCM ROM       (up to 512KB OKI M6295 bank 0)
//   0x280000 — Z80 ROM         (64KB NMK004 MCU / Z80 sound, byte-wide)
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

    // Read a 16-bit word by byte address (must be word-aligned).
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
// Protocol (matches nmk_arcade.sv bridges):
//   - Requestor toggles req to initiate a transfer.
//   - Controller returns ack == req when data is ready.
//   - On each posedge clk the testbench calls tick():
//       if req != ack_prev: new request, start 3-cycle countdown
//       countdown → 0: present data and match ack to req
// =============================================================================
class ToggleSdramChannel {
public:
    static constexpr int LATENCY = 1;  // default fixed latency

    explicit ToggleSdramChannel(const SdramModel& sdram, int latency_min = LATENCY, int latency_max = LATENCY)
        : sdram_(sdram), ack_(0), last_req_(0), countdown_(0),
          pending_addr_(0), data_(0),
          latency_min_(latency_min), latency_max_(latency_max), prng_(0x12345678u) {
        if (latency_min_ < 1) latency_min_ = 1;
        if (latency_max_ < latency_min_) latency_max_ = latency_min_;
    }

    // Call every posedge clk.
    // req:  current req toggle value from DUT
    // addr: current address output from DUT (27-bit byte address)
    // Returns: {data, ack} to drive into DUT
    struct Result { uint16_t data; uint8_t ack; };

    Result tick(uint8_t req, uint32_t addr) {
        if (req != last_req_) {
            // Rising or falling edge on req → new request
            last_req_    = req;
            pending_addr_ = addr;
            countdown_   = pick_latency();
        }

        if (countdown_ > 0) {
            --countdown_;
            if (countdown_ == 0) {
                data_ = sdram_.read_word(pending_addr_ & ~1u);
                ack_  = last_req_;  // match req to signal completion
            }
        }

        return {data_, ack_};
    }

    uint8_t ack() const { return ack_; }

private:
    int pick_latency() {
        if (latency_min_ == latency_max_) return latency_min_;
        prng_ ^= prng_ << 13;
        prng_ ^= prng_ >> 17;
        prng_ ^= prng_ << 5;
        uint32_t span = (uint32_t)(latency_max_ - latency_min_ + 1);
        return latency_min_ + (int)(prng_ % span);
    }

    const SdramModel& sdram_;
    uint8_t  ack_;
    uint8_t  last_req_;
    int      countdown_;
    uint32_t pending_addr_;
    uint16_t data_;
    int      latency_min_;
    int      latency_max_;
    uint32_t prng_;
};

// =============================================================================
// ToggleSdramChannelByte — same as above but returns byte-wide data.
// Used for the Z80 ROM channel (z80_rom_data is 8 bits).
// =============================================================================
class ToggleSdramChannelByte {
public:
    static constexpr int LATENCY = 1;

    explicit ToggleSdramChannelByte(const SdramModel& sdram, int latency_min = LATENCY, int latency_max = LATENCY)
        : sdram_(sdram), ack_(0), last_req_(0), countdown_(0),
          pending_addr_(0), data_(0),
          latency_min_(latency_min), latency_max_(latency_max), prng_(0x9E3779B9u) {
        if (latency_min_ < 1) latency_min_ = 1;
        if (latency_max_ < latency_min_) latency_max_ = latency_min_;
    }

    struct Result { uint8_t data; uint8_t ack; };

    Result tick(uint8_t req, uint32_t addr) {
        if (req != last_req_) {
            last_req_     = req;
            pending_addr_ = addr;
            countdown_    = pick_latency();
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
    int pick_latency() {
        if (latency_min_ == latency_max_) return latency_min_;
        prng_ ^= prng_ << 13;
        prng_ ^= prng_ >> 17;
        prng_ ^= prng_ << 5;
        uint32_t span = (uint32_t)(latency_max_ - latency_min_ + 1);
        return latency_min_ + (int)(prng_ % span);
    }

    const SdramModel& sdram_;
    uint8_t  ack_;
    uint8_t  last_req_;
    int      countdown_;
    uint32_t pending_addr_;
    uint8_t  data_;
    int      latency_min_;
    int      latency_max_;
    uint32_t prng_;
};
