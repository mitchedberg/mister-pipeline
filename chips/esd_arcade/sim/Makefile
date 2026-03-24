# =============================================================================
# Makefile — ESD 16-bit Arcade Verilator simulation
#
# Builds sim_esd_arcade from esd_arcade.sv and its dependencies.
#
# Usage:
#   make          — build the simulator
#   make run      — run with default settings (30 frames)
#   make clean    — remove build artifacts
#
# ROM paths set via env vars:
#   ROM_PROG — 68000 program ROM (even/odd interleaved pair, 512KB total)
#   ROM_SPR  — sprite ROM (pre-interleaved 5-plane, up to 1.25MB)
#   ROM_BG   — BG tile ROM (8bpp raw, up to 512KB)
# =============================================================================

VERILATOR      ?= verilator
CXX            ?= g++
NPROC          := $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

# Project root (three levels up from chips/esd_arcade/sim/)
ROOT           := ../../..

# RTL source files
RTL_TOP        := ../rtl/esd_arcade.sv
RTL_VIDEO      := ../rtl/esd_video.sv

# fx68k MC68000 CPU (JTFPGA fork — Verilator-compatible)
RTL_FX68K      := $(ROOT)/chips/m68000/hdl/fx68k/fx68kAlu.sv \
                  $(ROOT)/chips/m68000/hdl/fx68k/uaddrPla.sv \
                  $(ROOT)/chips/m68000/hdl/fx68k/fx68k.sv

# Simulation top (wraps esd_arcade + fx68k)
RTL_TB_TOP     := tb_top.sv

# All RTL sources
SRCS = \
    $(RTL_FX68K) \
    $(RTL_VIDEO) \
    $(RTL_TOP) \
    $(RTL_TB_TOP)

# Include paths
INCDIRS = \
    -I. \
    -I../rtl \
    -I$(ROOT)/chips/m68000/hdl/fx68k \
    -I$(ROOT)/chips/m68000/rtl

# Verilator flags
VLFLAGS = \
    --sv --cc --exe --build --trace \
    --top-module tb_top \
    -j $(NPROC) \
    --compiler clang \
    -Wno-PINMISSING -Wno-MODMISSING -Wno-UNUSED -Wno-UNDRIVEN \
    -Wno-SYNCASYNCNET -Wno-IMPLICIT -Wno-UNSIGNED -Wno-CASEINCOMPLETE \
    -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-COMBDLY -Wno-INITIALDLY \
    -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-DECLFILENAME \
    -Wno-VARHIDDEN -Wno-PINCONNECTEMPTY -Wno-SYMRSVDWORD -Wno-ALWCOMBORDER \
    -Wno-TIMESCALEMOD -O2

# C++ flags — ccache for incremental rebuilds
CFLAGS = -O2 -std=c++17
ifneq ($(shell which ccache 2>/dev/null),)
    CXX := ccache $(CXX)
endif

SIM_NAME   = sim_esd_arcade
OBJ_BIN    = obj_dir/$(SIM_NAME)
SIM_BINARY = $(SIM_NAME)

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
