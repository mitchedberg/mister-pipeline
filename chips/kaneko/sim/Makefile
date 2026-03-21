# =============================================================================
# Makefile — Kaneko16 Arcade (berlwall) Verilator simulation
#
# Uses the FULL kaneko_arcade RTL (kaneko_arcade.sv wrapping kaneko16 GPU,
# T80s Z80, jt6295 ADPCM, work RAM, palette, I/O decode).
#
# Usage:
#   make          — build the simulator
#   make run      — run with default settings (30 frames)
#   make clean    — remove build artifacts
# =============================================================================

VERILATOR      ?= verilator
CXX            ?= g++

# Project root (three levels up from chips/kaneko/sim/)
ROOT           := ../../..

# ── RTL sources ──────────────────────────────────────────────────────────────

# fx68k MC68000 CPU
RTL_FX68K      := $(ROOT)/chips/m68000/hdl/fx68k/fx68kAlu.sv \
                  $(ROOT)/chips/m68000/hdl/fx68k/uaddrPla.sv \
                  $(ROOT)/chips/m68000/hdl/fx68k/fx68k.sv

# Kaneko16 GPU (VU-001, VU-002, VIEW2-CHIP)
RTL_K16        := $(ROOT)/chips/kaneko/rtl/kaneko16.sv

# Full Kaneko arcade system (wraps kaneko16 + Z80 + OKI + I/O + palette + WRAM)
RTL_ARCADE     := $(ROOT)/chips/kaneko_arcade/rtl/kaneko_arcade.sv

# T80s Z80 CPU (all modules in one file)
RTL_T80        := $(ROOT)/chips/kaneko_arcade/rtl/t80/T80s.v

# jt6295 ADPCM sound
RTL_JT6295     := $(ROOT)/vendor/audio/jt6295/jt6295.v \
                  $(ROOT)/vendor/audio/jt6295/jt6295_acc.v \
                  $(ROOT)/vendor/audio/jt6295/jt6295_adpcm.v \
                  $(ROOT)/vendor/audio/jt6295/jt6295_ctrl.v \
                  $(ROOT)/vendor/audio/jt6295/jt6295_rom.v \
                  $(ROOT)/vendor/audio/jt6295/jt6295_serial.v \
                  $(ROOT)/vendor/audio/jt6295/jt6295_sh_rst.v \
                  $(ROOT)/vendor/audio/jt6295/jt6295_timing.v

# Simulation top-level (kaneko_arcade + fx68k wrapper)
RTL_TB_TOP     := $(ROOT)/chips/kaneko_arcade/rtl/tb_top.sv

# All RTL sources
SRCS = \
    $(RTL_FX68K) \
    $(RTL_T80) \
    $(RTL_JT6295) \
    $(RTL_K16) \
    $(RTL_ARCADE) \
    $(RTL_TB_TOP)

# Include paths
INCDIRS = \
    -I$(ROOT)/chips/kaneko/rtl \
    -I$(ROOT)/chips/kaneko_arcade/rtl \
    -I$(ROOT)/chips/m68000/hdl/fx68k \
    -I$(ROOT)/chips/m68000/rtl \
    -I$(ROOT)/vendor/audio/jt6295

# Verilator flags
VLFLAGS = \
    --sv --cc --exe --build --trace \
    --top-module tb_top \
    -Wno-REDEFMACRO -Wno-PINMISSING -Wno-MODMISSING -Wno-UNUSED -Wno-UNDRIVEN \
    -Wno-SYNCASYNCNET -Wno-IMPLICIT -Wno-UNSIGNED -Wno-CASEINCOMPLETE \
    -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-COMBDLY -Wno-INITIALDLY \
    -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-DECLFILENAME \
    -Wno-VARHIDDEN -Wno-PINCONNECTEMPTY -Wno-SYMRSVDWORD -Wno-ALWCOMBORDER \
    -Wno-TIMESCALEMOD -Wno-LITENDIAN -Wno-LATCH -O2

# C++ flags
CFLAGS = -O2 -std=c++17

SIM_NAME   = sim_kaneko16
OBJ_BIN    = obj_dir/$(SIM_NAME)

.PHONY: all run clean info

all: $(SIM_NAME)

$(SIM_NAME): tb_system.cpp sdram_model.h $(SRCS)
	$(VERILATOR) $(VLFLAGS) $(INCDIRS) \
	    -CFLAGS "$(CFLAGS)" \
	    --Mdir obj_dir \
	    $(SRCS) tb_system.cpp \
	    -o $(SIM_NAME)
	@ln -sf $(OBJ_BIN) $(SIM_NAME) 2>/dev/null || cp $(OBJ_BIN) $(SIM_NAME)

run: $(SIM_NAME)
	N_FRAMES=$${N_FRAMES:-30} \
	ROM_PROG=roms/prog.bin \
	ROM_GFX=roms/gfx.bin \
	ROM_Z80=roms/z80.bin \
	ROM_ADPCM=roms/adpcm.bin \
	./$(SIM_NAME)

clean:
	rm -rf obj_dir $(SIM_NAME) *.ppm *.vcd

info:
	@echo "Binary : $(OBJ_BIN)"
	@echo "RTL    : $(SRCS)"
	@echo "Verilator: $$($(VERILATOR) --version 2>/dev/null | head -1)"
