# =============================================================================
# Makefile — Raizing Arcade (Battle Garegga) Verilator simulation
#
# NOTE: raizing_arcade.sv is currently a SCAFFOLD — all outputs tied to safe
# defaults. This harness verifies RTL compiles and runs (gate-1 check).
# Meaningful frame validation requires the scaffold to be replaced with real
# CPU + GP9001 + memory system logic (gate-2+).
#
# Usage:
#   make          — build the simulator
#   make run      — run with default settings (50 frames)
#   make clean    — remove build artifacts
#
# ROM paths (Battle Garegga / bgaregga):
#   ROM_PROG  — 68K program ROM binary  (SDRAM 0x000000, 1MB)
#   ROM_GFX   — GP9001 tile ROM binary  (SDRAM 0x100000, 8MB, 32-bit)
#   ROM_SND   — Z80 audio ROM binary    (SDRAM 0x900000, 128KB)
#   ROM_ADPCM — OKI ADPCM samples       (SDRAM 0x920000, 1MB)
# =============================================================================

VERILATOR      ?= /opt/homebrew/bin/verilator
CXX            ?= g++

# Project root (two levels up from chips/raizing_arcade/sim/)
ROOT           := ../../..

# ── RTL Sources ──────────────────────────────────────────────────────────────

# Raizing system top (scaffold)
RTL_TOP        := ../rtl/raizing_arcade.sv

# GAL OKI bank controller
RTL_GAL        := ../rtl/gal_oki_bank.sv

# Simulation wrapper top
RTL_TB_TOP     := tb_top.sv

# All RTL sources (Battle Garegga: no YMZ280B — that's Batrider/Bakraid only)
SRCS = \
    $(RTL_GAL) \
    $(RTL_TOP) \
    $(RTL_TB_TOP)

# Include paths
INCDIRS = \
    -I../rtl \
    -I.

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

SIM_NAME   = sim_raizing
OBJ_BIN    = obj_dir/$(SIM_NAME)
SIM_BINARY = $(SIM_NAME)

.PHONY: all run clean info

all: $(SIM_BINARY)

$(SIM_BINARY): tb_system.cpp $(SRCS)
	$(VERILATOR) $(VLFLAGS) $(INCDIRS) \
	    -CFLAGS "$(CFLAGS)" \
	    --Mdir obj_dir \
	    $(SRCS) tb_system.cpp \
	    -o $(SIM_NAME)
	@ln -sf $(OBJ_BIN) $(SIM_BINARY) 2>/dev/null || cp $(OBJ_BIN) $(SIM_BINARY)

run: $(SIM_BINARY)
	N_FRAMES=$${N_FRAMES:-50} ./$(SIM_BINARY)

clean:
	rm -rf obj_dir $(SIM_BINARY) *.ppm *.vcd

info:
	@echo "Binary : $(OBJ_BIN) (symlinked as ./$(SIM_BINARY))"
	@echo "RTL    : $(SRCS)"
	@echo "NOTE   : raizing_arcade.sv is a SCAFFOLD — all outputs tied to defaults"
	@echo "         This harness verifies gate-1 (Verilator build) only."
	@echo "Verilator: $$($(VERILATOR) --version 2>/dev/null | head -1)"
