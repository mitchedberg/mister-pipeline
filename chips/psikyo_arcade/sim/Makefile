# =============================================================================
# Makefile — Psikyo Arcade Verilator simulation
#
# Builds sim_psikyo_arcade from psikyo_arcade.sv and its dependencies.
# CPU (MC68EC020) is emulated by Musashi in C++ (tb_system.cpp).
# No fx68k / TG68K RTL needed.
#
# Usage:
#   make          — build the simulator
#   make run      — run with default settings (30 frames, no ROMs)
#   make clean    — remove build artifacts
#
# ROM paths via env vars: ROM_PROG, ROM_SPR, ROM_BG, ROM_ADPCM, ROM_Z80
# =============================================================================

VERILATOR      ?= verilator
CXX            ?= g++
CC             ?= gcc

# Absolute path to this sim directory (for resolving Musashi .o paths)
SIM_DIR        := $(abspath .)

# Project root (two levels up from chips/psikyo_arcade/sim/)
ROOT           := ../../..

# Psikyo arcade top-level
RTL_TOP        := ../rtl/psikyo_arcade.sv

# Psikyo chip gates (Gate 1/2 in psikyo/, Gate 3/4/5 in psikyo_arcade/rtl/)
RTL_PSIKYO     := $(ROOT)/chips/psikyo/rtl/psikyo.sv \
                  $(ROOT)/chips/psikyo/rtl/psikyo_gate3.sv \
                  $(ROOT)/chips/psikyo/rtl/psikyo_gate4.sv \
                  $(ROOT)/chips/psikyo/rtl/psikyo_gate5.sv

# T80 Z80 core
RTL_T80        := ../rtl/t80/T80s.v

# Audio IP: jt10 (YM2610B = YM2610 = OPN2 + ADPCM-A + ADPCM-B)
RTL_JT10       := $(ROOT)/vendor/audio/jt12/jt10.v

# Simulation top (thin wrapper: psikyo_arcade only, no CPU RTL)
RTL_TB_TOP     := ../rtl/tb_top.sv

# All RTL sources (no CPU RTL — MC68EC020 is in Musashi C model)
SRCS = \
    $(RTL_PSIKYO) \
    $(RTL_T80) \
    $(RTL_JT10) \
    $(RTL_TOP) \
    $(RTL_TB_TOP)

# Musashi object files (compiled as C, not C++)
# Use absolute paths so Verilator linker (running from obj_dir/) can find them
MUSASHI_OPS   := $(SIM_DIR)/musashi/m68kops.o
MUSASHI_CPU   := $(SIM_DIR)/musashi/m68kcpu.o
MUSASHI_OBJS  := $(MUSASHI_OPS) $(MUSASHI_CPU)

# Include paths
INCDIRS = \
    -I../rtl \
    -I../rtl/t80 \
    -I$(ROOT)/chips/psikyo/rtl \
    -I$(ROOT)/vendor/audio/jt12 \
    -I$(ROOT)/vendor/audio/jt12/mixer \
    -I$(ROOT)/vendor/audio/jt12/dac \
    -I$(ROOT)/vendor/audio/jt12/adpcm \
    -Imusashi

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

# C++ flags for tb_system.cpp (must include Musashi dir for m68kconf.h)
CXXFLAGS = -O2 -std=c++17 -I$(SIM_DIR)/musashi

# C flags for Musashi (pure C, not C++)
# m68kfpu.c is #include'd by m68kcpu.c — do NOT compile separately
MUSASHI_CFLAGS = -O2 -I$(SIM_DIR)/musashi -Wno-parentheses

SIM_NAME   = sim_psikyo_arcade
OBJ_BIN    = obj_dir/$(SIM_NAME)
SIM_BINARY = $(SIM_NAME)

.PHONY: all run clean info

all: $(SIM_BINARY)

# ── Musashi C object files ──────────────────────────────────────────────────
$(MUSASHI_OPS): $(SIM_DIR)/musashi/m68kops.c $(SIM_DIR)/musashi/m68kconf.h
	$(CC) $(MUSASHI_CFLAGS) -c $< -o $@

$(MUSASHI_CPU): $(SIM_DIR)/musashi/m68kcpu.c $(SIM_DIR)/musashi/m68kconf.h
	$(CC) $(MUSASHI_CFLAGS) -c $< -o $@

# ── Main Verilator build ───────────────────────────────────────────────────
$(SIM_BINARY): tb_system.cpp sdram_model.h $(SRCS) $(MUSASHI_OBJS)
	$(VERILATOR) $(VLFLAGS) $(INCDIRS) \
	    -CFLAGS "$(CXXFLAGS)" \
	    --Mdir obj_dir \
	    $(SRCS) tb_system.cpp \
	    $(MUSASHI_OBJS) \
	    -o $(SIM_NAME)
	@ln -sf $(OBJ_BIN) $(SIM_BINARY) 2>/dev/null || cp $(OBJ_BIN) $(SIM_BINARY)

run: $(SIM_BINARY)
	N_FRAMES=$${N_FRAMES:-30} ./$(SIM_BINARY)

clean:
	rm -rf obj_dir $(SIM_BINARY) *.ppm *.vcd $(MUSASHI_OBJS)

info:
	@echo "SIM_DIR: $(SIM_DIR)"
	@echo "Binary : $(OBJ_BIN) (symlinked as ./$(SIM_BINARY))"
	@echo "RTL    : $(SRCS)"
	@echo "Musashi: $(MUSASHI_OBJS)"
	@echo "Verilator: $$($(VERILATOR) --version 2>/dev/null | head -1)"
