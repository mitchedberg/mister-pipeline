# =============================================================================
# Makefile — Kaneko16 Arcade Verilator simulation
#
# Builds sim_kaneko_arcade from kaneko_arcade.sv and its dependencies.
#
# Usage:
#   make          — build the simulator
#   make run      — run with default settings (30 frames, no ROMs)
#   make clean    — remove build artifacts
#
# ROM paths can be set via env vars: ROM_PROG, ROM_GFX, ROM_ADPCM, ROM_Z80
# =============================================================================

VERILATOR      ?= verilator
CXX            ?= g++

# Project root (two levels up from chips/kaneko_arcade/sim/)
ROOT           := ../../..

# RTL source files
RTL_TOP        := ../rtl/kaneko_arcade.sv
RTL_KANEKO16   := $(ROOT)/chips/kaneko/rtl/kaneko16.sv

# T80 Z80 core (bundled with kaneko_arcade)
RTL_T80        := ../rtl/t80/T80s.v

# Audio IP cores — Kaneko16 uses OKI M6295 (jt6295) only
RTL_JT6295     := $(ROOT)/vendor/audio/jt6295/jt6295.v

# fx68k MC68000 CPU (Jorge Cwik) — direct instantiation (no adapter in tb_top)
RTL_FX68K      := $(ROOT)/chips/m68000/hdl/fx68k/fx68kAlu.sv \
                  $(ROOT)/chips/m68000/hdl/fx68k/uaddrPla.sv \
                  $(ROOT)/chips/m68000/hdl/fx68k/fx68k.sv

# Simulation top (wraps kaneko_arcade + fx68k)
RTL_TB_TOP     := ../rtl/tb_top.sv

# All RTL sources (full system)
SRCS = \
    $(RTL_KANEKO16) \
    $(RTL_T80) \
    $(RTL_JT6295) \
    $(RTL_FX68K) \
    $(RTL_TOP) \
    $(RTL_TB_TOP)

# Include paths
INCDIRS = \
    -I../rtl \
    -I../rtl/t80 \
    -I$(ROOT)/chips/kaneko/rtl \
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
    -Wno-TIMESCALEMOD -O2

# C++ flags
CFLAGS = -O2 -std=c++17

SIM_NAME   = sim_kaneko_arcade
# Verilator 5 places the binary in obj_dir/ regardless of -o; we symlink it out.
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

# Print a summary of what was built
info:
	@echo "Binary : $(OBJ_BIN) (symlinked as ./$(SIM_BINARY))"
	@echo "RTL    : $(SRCS)"
	@echo "Verilator: $$($(VERILATOR) --version 2>/dev/null | head -1)"
