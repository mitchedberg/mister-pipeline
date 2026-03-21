// =============================================================================
// m68kconf.h — Musashi 3.32 configuration for Psikyo Arcade simulation
//
// Standalone configuration (not MAME, not FBNeo).
// We implement the read/write callbacks in tb_system.cpp.
// =============================================================================
#pragma once

#ifndef M68KCONF__HEADER
#define M68KCONF__HEADER

// ── Not MAME ─────────────────────────────────────────────────────────────────
#define M68K_COMPILE_FOR_MAME OPT_OFF

// ── Standalone type definitions (normally from driver.h / MAME) ───────────────
#include <stdint.h>
#include <string.h>
#include <math.h>
#ifndef FALSE
#define FALSE 0
#endif
#ifndef TRUE
#define TRUE 1
#endif
typedef uint8_t   UINT8;
typedef uint16_t  UINT16;
typedef uint32_t  UINT32;
typedef uint64_t  UINT64;
typedef int8_t    INT8;
typedef int16_t   INT16;
typedef int32_t   INT32;
typedef int64_t   INT64;
// Note: 'uint' is #defined in m68kcpu.h as 'unsigned int' — do not typedef here

// U64: 64-bit unsigned literal macro (used in m68kfpu.c)
#ifndef U64
#define U64(x) ((uint64_t)(x))
#endif

// STRUCT_SIZE_HELPER: returns offset of member (used in m68kcpu.c for save states)
// Return 0 as we don't support save states in standalone mode
#ifndef STRUCT_SIZE_HELPER
#define STRUCT_SIZE_HELPER(type, member) 0
#endif

#define OPT_OFF             0
#define OPT_ON              1
#define OPT_SPECIFY_HANDLER 2

// ── CPU variants ──────────────────────────────────────────────────────────────
#define M68K_EMULATE_008        OPT_OFF
#define M68K_EMULATE_010        OPT_OFF
#define M68K_EMULATE_EC020      OPT_ON     // 68EC020 — used by Psikyo hardware
#define M68K_EMULATE_020        OPT_OFF
#define M68K_EMULATE_040        OPT_OFF

// ── Memory access ─────────────────────────────────────────────────────────────
// Use separate read paths for PC-relative and immediate addressing.
// This allows the same ROM read path for both instruction fetch and data reads.
#define M68K_SEPARATE_READS     OPT_ON

// ── PD writes: disabled (not needed for Psikyo) ───────────────────────────────
#define M68K_SIMULATE_PD_WRITES OPT_OFF

// ── Interrupt acknowledge: autovector for all levels ──────────────────────────
// Psikyo uses autovectored interrupts (VBLANK = level 4).
#define M68K_EMULATE_INT_ACK        OPT_SPECIFY_HANDLER
#define M68K_INT_ACK_CALLBACK(A)    psikyo_int_ack(A)

// ── No breakpoint ACK ────────────────────────────────────────────────────────
#define M68K_EMULATE_BKPT_ACK   OPT_OFF

// ── No trace ─────────────────────────────────────────────────────────────────
#define M68K_EMULATE_TRACE      OPT_OFF

// ── Reset instruction callback ───────────────────────────────────────────────
#define M68K_EMULATE_RESET          OPT_SPECIFY_HANDLER
#define M68K_RESET_CALLBACK()       /* nothing */

// ── CMPILD, RTE, TAS callbacks: specify handlers to avoid empty macros ────────
// (OPT_OFF would leave the callback macro undefined, but FBNeo Musashi still
// expands m68ki_tas_callback() in m68kops.c even when OPT_OFF — must provide
// a proper handler that returns an int)
#define M68K_CMPILD_HAS_CALLBACK    OPT_OFF
#define M68K_RTE_HAS_CALLBACK       OPT_OFF
#define M68K_TAS_HAS_CALLBACK       OPT_SPECIFY_HANDLER
#define M68K_TAS_CALLBACK()         (1)    // TAS always succeeds (return non-zero)

// ── No function code callback ────────────────────────────────────────────────
#define M68K_EMULATE_FC             OPT_OFF

// ── No PC change callback ────────────────────────────────────────────────────
#define M68K_MONITOR_PC             OPT_OFF

// ── No instruction hook ──────────────────────────────────────────────────────
#define M68K_INSTRUCTION_HOOK       OPT_OFF

// ── Prefetch queue: enabled (required for EC020 mode) ────────────────────────
#define M68K_EMULATE_PREFETCH       OPT_ON

// ── Address error: disabled (68020 does not generate address errors) ──────────
#define M68K_EMULATE_ADDRESS_ERROR  OPT_OFF

// ── No logging ───────────────────────────────────────────────────────────────
#define M68K_LOG_ENABLE             OPT_OFF
#define M68K_LOG_1010_1111          OPT_OFF
#define M68K_LOG_FILEHANDLE         stderr

// ── 64-bit ops: off (not needed for our platform) ────────────────────────────
#define M68K_USE_64_BIT             OPT_OFF

// ── Inline ───────────────────────────────────────────────────────────────────
#ifndef INLINE
#define INLINE static inline
#endif

// ── Cycle counter alias ────────────────────────────────────────────────────────
// m68kops.c references m68ki_remaining_cycles; it is the same as m68k_ICount.
#define m68ki_remaining_cycles m68k_ICount

// ── Memory access macros (implemented in tb_system.cpp) ──────────────────────
#ifdef __cplusplus
extern "C" {
#endif

// Immediate / PC-relative reads (same backing store as regular reads for ROM)
unsigned int psikyo_read8(unsigned int address);
unsigned int psikyo_read16(unsigned int address);
unsigned int psikyo_read32(unsigned int address);
void         psikyo_write8(unsigned int address, unsigned int data);
void         psikyo_write16(unsigned int address, unsigned int data);
void         psikyo_write32(unsigned int address, unsigned int data);
int          psikyo_int_ack(int level);

#ifdef __cplusplus
}
#endif

// Memory read macros (Musashi callbacks)
#define m68k_read_immediate_16(addr)    psikyo_read16(addr)
#define m68k_read_immediate_32(addr)    psikyo_read32(addr)
#define m68k_read_pcrelative_8(addr)    psikyo_read8(addr)
#define m68k_read_pcrelative_16(addr)   psikyo_read16(addr)
#define m68k_read_pcrelative_32(addr)   psikyo_read32(addr)

#define m68k_read_memory_8(addr)        psikyo_read8(addr)
#define m68k_read_memory_16(addr)       psikyo_read16(addr)
#define m68k_read_memory_32(addr)       psikyo_read32(addr)

#define m68k_write_memory_8(addr, val)  psikyo_write8(addr, val)
#define m68k_write_memory_16(addr, val) psikyo_write16(addr, val)
#define m68k_write_memory_32(addr, val) psikyo_write32(addr, val)

// Disassembler (optional; use same path)
#define m68k_read_disassembler_8(addr)  psikyo_read8(addr)
#define m68k_read_disassembler_16(addr) psikyo_read16(addr)
#define m68k_read_disassembler_32(addr) psikyo_read32(addr)

#endif // M68KCONF__HEADER
