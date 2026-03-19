# =============================================================================
# Makefile — Taito B (Nastar Warrior) Verilator simulation
#
# Builds sim_taito_b from taito_b.sv and its dependencies.
#
# Usage:
#   make          — build the simulator
#   make run      — run with default settings (30 frames, no ROMs)
#   make clean    — remove build artifacts
#
# ROM paths via env: ROM_PROG, ROM_Z80, ROM_GFX, ROM_ADPCM
# Or use run_sim.py --nastar-zip to auto-extract from nastar.zip
# =============================================================================

VERILATOR      ?= verilator
CXX            ?= g++

# Project root (two levels up from chips/taito_b/sim/)
ROOT           := ../../..

# ── RTL source files ─────────────────────────────────────────────────────────

# Taito B top-level and SDRAM controller
RTL_TAITO_B    := ../rtl/taito_b.sv

# Taito B chip set (TC0180VCU video, TC0260DAR palette, TC0220IOC I/O, TC0140SYT sound)
RTL_TC0180VCU  := $(ROOT)/chips/tc0180vcu/rtl/tc0180vcu.sv \
                  $(ROOT)/chips/tc0180vcu/rtl/tc0180vcu_bg.sv \
                  $(ROOT)/chips/tc0180vcu/rtl/tc0180vcu_tx.sv \
                  $(ROOT)/chips/tc0180vcu/rtl/tc0180vcu_sprite.sv
RTL_TAITO_SUP  := $(ROOT)/chips/taito_support/tc0260dar.sv \
                  $(ROOT)/chips/taito_support/tc0220ioc.sv \
                  $(ROOT)/chips/taito_support/tc0140syt.sv

# T80 Z80 core (used internally by taito_b.sv for the Z80 sound CPU)
RTL_T80        := $(ROOT)/vendor/t80/T80s.v

# Audio: YM2610 (jt10) — used by taito_b for TC0140SYT/ADPCM playback
RTL_JT10       := $(ROOT)/vendor/audio/jt12/jt10.v

# fx68k MC68000 CPU (instantiated in tb_top, NOT fx68k_adapter)
RTL_FX68K      := $(ROOT)/chips/m68000/hdl/fx68k/fx68kAlu.sv \
                  $(ROOT)/chips/m68000/hdl/fx68k/uaddrPla.sv \
                  $(ROOT)/chips/m68000/hdl/fx68k/fx68k.sv

# Simulation top-level (wraps taito_b + fx68k)
RTL_TB_TOP     := ../rtl/tb_top.sv

# All RTL sources (full system)
SRCS = \
    $(RTL_TC0180VCU) \
    $(RTL_TAITO_SUP) \
    $(RTL_T80) \
    $(RTL_JT10) \
    $(RTL_FX68K) \
    $(RTL_TAITO_B) \
    $(RTL_TB_TOP)

# ── Include paths ─────────────────────────────────────────────────────────────
INCDIRS = \
    -I../rtl \
    -I$(ROOT)/chips/tc0180vcu/rtl \
    -I$(ROOT)/chips/taito_support \
    -I$(ROOT)/vendor/t80 \
    -I$(ROOT)/vendor/audio/jt12 \
    -I$(ROOT)/vendor/audio/jt12/mixer \
    -I$(ROOT)/vendor/audio/jt12/dac \
    -I$(ROOT)/vendor/audio/jt12/adpcm \
    -I$(ROOT)/chips/m68000/hdl/fx68k \
    -I$(ROOT)/chips/m68000/rtl

# ── Verilator flags ───────────────────────────────────────────────────────────
VLFLAGS = \
    --sv --cc --exe --build --trace \
    --top-module tb_top \
    -Wno-PINMISSING -Wno-MODMISSING -Wno-UNUSED -Wno-UNDRIVEN \
    -Wno-SYNCASYNCNET -Wno-IMPLICIT -Wno-UNSIGNED -Wno-CASEINCOMPLETE \
    -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-COMBDLY -Wno-INITIALDLY \
    -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-DECLFILENAME \
    -Wno-VARHIDDEN -Wno-PINCONNECTEMPTY -Wno-SYMRSVDWORD -Wno-ALWCOMBORDER \
    -Wno-TIMESCALEMOD -O2

# ── C++ flags ─────────────────────────────────────────────────────────────────
CFLAGS = -O2 -std=c++17

SIM_NAME   = sim_taito_b
SIM_BINARY = $(SIM_NAME)
OBJ_BIN    = obj_dir/$(SIM_NAME)

.PHONY: all run clean info

all: $(SIM_BINARY)

$(SIM_BINARY): tb_system.cpp sdram_model.h $(SRCS)
	$(VERILATOR) $(VLFLAGS) $(INCDIRS) \
	    -CFLAGS "$(CFLAGS)" \
	    --Mdir obj_dir \
	    $(SRCS) tb_system.cpp \
	    -o $(SIM_NAME)
	@ln -sf $(OBJ_BIN) $(SIM_BINARY) 2>/dev/null || cp $(OBJ_BIN) $(SIM_BINARY)

run: $(SIM_BINARY)
	N_FRAMES=$${N_FRAMES:-30} ./$(SIM_BINARY)

clean:
	rm -rf obj_dir $(SIM_BINARY) *.ppm *.vcd

info:
	@echo "Binary : $(OBJ_BIN) (symlinked as ./$(SIM_BINARY))"
	@echo "RTL    : $(SRCS)"
	@echo "Verilator: $$($(VERILATOR) --version 2>/dev/null | head -1)"
