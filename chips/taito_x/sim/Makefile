# =============================================================================
# Makefile — Taito X (Gigandes) Verilator simulation
#
# Builds sim_taito_x from taito_x.sv and its dependencies.
# Instantiates fx68k (MC68000) and T80s (Z80 sound CPU) inside tb_top.sv.
#
# Usage:
#   make          — build the simulator
#   make run      — run with default settings (30 frames, no ROMs)
#   make clean    — remove build artifacts
#
# ROM paths via env vars: ROM_PROG, ROM_Z80, ROM_GFX
# =============================================================================

VERILATOR      ?= verilator
CXX            ?= g++
NPROC          := $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

# Project root (three levels up from chips/taito_x/sim/)
ROOT           := ../../..

# RTL source files
RTL_TOP        := ../rtl/taito_x.sv
RTL_X1_001A    := ../rtl/x1_001a.sv
RTL_COLMIX     := ../rtl/taito_x_colmix.sv

# T80s Z80 core (single bundled file)
RTL_T80        := $(ROOT)/vendor/t80/T80s.v

# fx68k MC68000 CPU (Jorge Cwik) — no adapter needed; direct instantiation in tb_top
RTL_FX68K      := $(ROOT)/chips/m68000/hdl/fx68k/fx68kAlu.sv \
                  $(ROOT)/chips/m68000/hdl/fx68k/uaddrPla.sv \
                  $(ROOT)/chips/m68000/hdl/fx68k/fx68k.sv

# Simulation top (wraps taito_x + fx68k + T80s)
RTL_TB_TOP     := ../rtl/tb_top.sv

# All RTL sources
# NOTE: sdram_x.sv is a stub for synthesis only — DO NOT include it.
# The simulation uses the behavioral SdramModel in sdram_model.h.
SRCS = \
    $(RTL_X1_001A) \
    $(RTL_COLMIX) \
    $(RTL_T80) \
    $(RTL_FX68K) \
    $(RTL_TOP) \
    $(RTL_TB_TOP)

# Include paths
INCDIRS = \
    -I../rtl \
    -I$(ROOT)/vendor/t80 \
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

# C++ flags
CFLAGS = -O2 -std=c++17

SIM_NAME   = sim_taito_x
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
