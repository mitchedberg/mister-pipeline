# =============================================================================
# Makefile — Kaneko 16 Verilator simulation (berlwall)
#
# Usage:
#   make          — build the simulator
#   make run      — run with default settings (10 frames)
#   make clean    — remove build artifacts
#
# ROM paths:
#   ROM_PROG      — path to interleaved program ROM (prog.bin, 256 KB)
#   ROM_SPR       — path to sprite ROM binary (spr.bin)
#   ROM_BG        — path to BG tile ROM binary (bg.bin)
# =============================================================================

VERILATOR      ?= verilator
CXX            ?= g++

# Project root (three levels up from chips/kaneko/sim/)
ROOT           := ../../..

# RTL sources
RTL_K16        := ../rtl/kaneko16.sv

# fx68k MC68000 CPU (JTFPGA fork — GUARDRAILS Rule 14)
# Note: fx68k.sv sits alongside fx68kAlu.sv and uaddrPla.sv
RTL_FX68K      := $(ROOT)/chips/m68000/hdl/fx68k/fx68kAlu.sv \
                  $(ROOT)/chips/m68000/hdl/fx68k/uaddrPla.sv \
                  $(ROOT)/chips/m68000/hdl/fx68k/fx68k.sv

# Simulation top
RTL_TB_TOP     := ../rtl/tb_top.sv

# All RTL sources (no Z80/T80 — Kaneko16 doesn't need one in the sim)
SRCS = \
    $(RTL_FX68K) \
    $(RTL_K16) \
    $(RTL_TB_TOP)

# Include paths
INCDIRS = \
    -I../rtl \
    -I$(ROOT)/chips/m68000/hdl/fx68k \
    -I$(ROOT)/chips/m68000/rtl

# Verilator flags
VLFLAGS = \
    --sv --cc --exe --build --trace \
    --top-module tb_top \
    -Wno-REDEFMACRO -Wno-PINMISSING -Wno-MODMISSING -Wno-UNUSED -Wno-UNDRIVEN \
    -Wno-SYNCASYNCNET -Wno-IMPLICIT -Wno-UNSIGNED -Wno-CASEINCOMPLETE \
    -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-COMBDLY -Wno-INITIALDLY \
    -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-DECLFILENAME \
    -Wno-VARHIDDEN -Wno-PINCONNECTEMPTY -Wno-SYMRSVDWORD -Wno-ALWCOMBORDER \
    -Wno-TIMESCALEMOD -O2

# C++ flags
CFLAGS = -O2 -std=c++17

SIM_NAME   = sim_kaneko16
OBJ_BIN    = obj_dir/$(SIM_NAME)

.PHONY: all run roms clean info

all: $(SIM_NAME)

$(SIM_NAME): tb_system.cpp sdram_model.h $(SRCS)
	$(VERILATOR) $(VLFLAGS) $(INCDIRS) \
	    -CFLAGS "$(CFLAGS)" \
	    --Mdir obj_dir \
	    $(SRCS) tb_system.cpp \
	    -o $(SIM_NAME)
	@ln -sf $(OBJ_BIN) $(SIM_NAME) 2>/dev/null || cp $(OBJ_BIN) $(SIM_NAME)

# Run with default ROM paths (assuming roms/ was populated by extract_roms.sh)
run: $(SIM_NAME)
	N_FRAMES=$${N_FRAMES:-10} \
	ROM_PROG=roms/prog.bin \
	ROM_SPR=roms/spr.bin \
	ROM_BG=roms/bg.bin \
	./$(SIM_NAME)

# Extract and prepare berlwall ROMs from the zip
# Run: make roms   (only needed once; ROMs are already in roms/ if extracted)
roms/prog.bin: extract_roms.sh
	bash extract_roms.sh

roms: roms/prog.bin

clean:
	rm -rf obj_dir $(SIM_NAME) *.ppm *.vcd

info:
	@echo "Binary : $(OBJ_BIN)"
	@echo "RTL    : $(SRCS)"
	@echo "Verilator: $$($(VERILATOR) --version 2>/dev/null | head -1)"
