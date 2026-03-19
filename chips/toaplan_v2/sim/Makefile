# =============================================================================
# Makefile — Toaplan V2 (Batsugun) Verilator simulation
#
# Builds sim_toaplan_v2 from toaplan_v2.sv and its dependencies.
#
# Usage:
#   make          — build the simulator
#   make run      — run with default settings (30 frames, no ROMs)
#   make clean    — remove build artifacts
#
# ROM paths can be set via env vars:
#   ROM_PROG  — CPU program ROM binary  (SDRAM 0x000000)
#   ROM_GFX   — GFX ROM binary (32-bit, SDRAM 0x100000)
#   ROM_ADPCM — ADPCM ROM binary        (SDRAM 0x500000)
#   ROM_Z80   — Z80 sound ROM binary    (SDRAM 0x600000)
# =============================================================================

VERILATOR      ?= verilator
CXX            ?= g++

# Project root (two levels up from chips/toaplan_v2/sim/)
ROOT           := ../../..

# ── RTL Sources ──────────────────────────────────────────────────────────────

# Toaplan V2 integration top
RTL_TOP        := ../rtl/toaplan_v2.sv
RTL_SDRAM_B    := ../rtl/sdram_b.sv

# GP9001 graphics processor
RTL_GP9001     := $(ROOT)/chips/gp9001/rtl/gp9001.sv

# fx68k MC68000 CPU
RTL_FX68K      := $(ROOT)/chips/m68000/hdl/fx68k/fx68kAlu.sv \
                  $(ROOT)/chips/m68000/hdl/fx68k/uaddrPla.sv \
                  $(ROOT)/chips/m68000/hdl/fx68k/fx68k.sv

# Z80 sound CPU (T80s, single self-contained file)
RTL_T80        := ../rtl/t80/T80s.v

# YM2151 FM synthesizer (jt51) — all sub-modules
RTL_JT51       := $(ROOT)/vendor/audio/jt51/jt51.v \
                  $(ROOT)/vendor/audio/jt51/jt51_acc.v \
                  $(ROOT)/vendor/audio/jt51/jt51_csr_op.v \
                  $(ROOT)/vendor/audio/jt51/jt51_eg.v \
                  $(ROOT)/vendor/audio/jt51/jt51_exp2lin.v \
                  $(ROOT)/vendor/audio/jt51/jt51_exprom.v \
                  $(ROOT)/vendor/audio/jt51/jt51_kon.v \
                  $(ROOT)/vendor/audio/jt51/jt51_lfo.v \
                  $(ROOT)/vendor/audio/jt51/jt51_lin2exp.v \
                  $(ROOT)/vendor/audio/jt51/jt51_mmr.v \
                  $(ROOT)/vendor/audio/jt51/jt51_mod.v \
                  $(ROOT)/vendor/audio/jt51/jt51_noise.v \
                  $(ROOT)/vendor/audio/jt51/jt51_noise_lfsr.v \
                  $(ROOT)/vendor/audio/jt51/jt51_op.v \
                  $(ROOT)/vendor/audio/jt51/jt51_pg.v \
                  $(ROOT)/vendor/audio/jt51/jt51_phinc_rom.v \
                  $(ROOT)/vendor/audio/jt51/jt51_phrom.v \
                  $(ROOT)/vendor/audio/jt51/jt51_pm.v \
                  $(ROOT)/vendor/audio/jt51/jt51_reg.v \
                  $(ROOT)/vendor/audio/jt51/jt51_reg_ch.v \
                  $(ROOT)/vendor/audio/jt51/jt51_sh.v \
                  $(ROOT)/vendor/audio/jt51/jt51_timers.v

# OKI M6295 ADPCM (jt6295) — all sub-modules
RTL_JT6295     := $(ROOT)/vendor/audio/jt6295/jt6295.v \
                  $(ROOT)/vendor/audio/jt6295/jt6295_acc.v \
                  $(ROOT)/vendor/audio/jt6295/jt6295_adpcm.v \
                  $(ROOT)/vendor/audio/jt6295/jt6295_ctrl.v \
                  $(ROOT)/vendor/audio/jt6295/jt6295_rom.v \
                  $(ROOT)/vendor/audio/jt6295/jt6295_serial.v \
                  $(ROOT)/vendor/audio/jt6295/jt6295_sh_rst.v \
                  $(ROOT)/vendor/audio/jt6295/jt6295_timing.v \
                  $(ROOT)/vendor/audio/jt6295/jt12_comb.v \
                  $(ROOT)/vendor/audio/jt6295/jt12_interpol.v \
                  $(ROOT)/vendor/audio/jt6295/jtframe_fir_mono.v

# Simulation top (wraps toaplan_v2 + fx68k)
RTL_TB_TOP     := ../rtl/tb_top.sv

# All RTL sources (order: dependencies first, top-level last)
SRCS = \
    $(RTL_SDRAM_B) \
    $(RTL_GP9001) \
    $(RTL_T80) \
    $(RTL_JT51) \
    $(RTL_JT6295) \
    $(RTL_FX68K) \
    $(RTL_TOP) \
    $(RTL_TB_TOP)

# Include paths
INCDIRS = \
    -I../rtl \
    -I../rtl/t80 \
    -I$(ROOT)/chips/gp9001/rtl \
    -I$(ROOT)/vendor/audio/jt51 \
    -I$(ROOT)/vendor/audio/jt6295 \
    -I$(ROOT)/chips/m68000/hdl/fx68k \
    -I$(ROOT)/chips/m68000/rtl

# Verilator flags
VLFLAGS = \
    --sv --cc --exe --build --trace \
    --top-module tb_top \
    -Wno-PINMISSING -Wno-MODMISSING -Wno-UNUSED -Wno-UNDRIVEN \
    -Wno-SYNCASYNCNET -Wno-IMPLICIT -Wno-UNSIGNED -Wno-CASEINCOMPLETE \
    -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-COMBDLY -Wno-INITIALDLY \
    -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-DECLFILENAME \
    -Wno-VARHIDDEN -Wno-PINCONNECTEMPTY -Wno-SYMRSVDWORD -Wno-ALWCOMBORDER \
    -Wno-TIMESCALEMOD -Wno-fatal -O2

# C++ flags
CFLAGS = -O2 -std=c++17

SIM_NAME   = sim_toaplan_v2
OBJ_BIN    = obj_dir/$(SIM_NAME)
SIM_BINARY = $(SIM_NAME)

.PHONY: all run clean info

all: $(SIM_BINARY)

# fx68k microcode ROMs — must be in CWD when sim runs (Verilator $readmem uses CWD)
FX68K_DIR := $(ROOT)/chips/m68000/hdl/fx68k
microrom.mem: $(FX68K_DIR)/microrom.mem
	@ln -sf $(FX68K_DIR)/microrom.mem . 2>/dev/null || cp $< $@
nanorom.mem: $(FX68K_DIR)/nanorom.mem
	@ln -sf $(FX68K_DIR)/nanorom.mem . 2>/dev/null || cp $< $@

$(SIM_BINARY): tb_system.cpp sdram_model.h $(SRCS) microrom.mem nanorom.mem
	$(VERILATOR) $(VLFLAGS) $(INCDIRS) \
	    -CFLAGS "$(CFLAGS)" \
	    --Mdir obj_dir \
	    $(SRCS) tb_system.cpp \
	    -o $(SIM_NAME)
	@ln -sf $(OBJ_BIN) $(SIM_BINARY) 2>/dev/null || cp $(OBJ_BIN) $(SIM_BINARY)

run: $(SIM_BINARY)
	N_FRAMES=$${N_FRAMES:-30} ./$(SIM_BINARY)

clean:
	rm -rf obj_dir $(SIM_BINARY) *.ppm *.vcd microrom.mem nanorom.mem

info:
	@echo "Binary : $(OBJ_BIN) (symlinked as ./$(SIM_BINARY))"
	@echo "RTL    : $(SRCS)"
	@echo "Verilator: $$($(VERILATOR) --version 2>/dev/null | head -1)"
