# Makefile — Minimal fx68k Verilator testbench
#
# Isolates the fx68k CPU from all NMK arcade/SDRAM complexity.
# Usage:
#   make           — build sim_minimal binary
#   make run       — build and run (requires ROM_FILE env var)
#   make clean     — remove build artifacts

FX68K_DIR := /Volumes/2TB_20260220/Projects/MiSTer_Pipeline/chips/m68000/hdl/fx68k
SIM_DIR   := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))

VERILATOR := verilator
CXX       := clang++
CXXFLAGS  := -O2 -std=c++17

VERILATOR_ROOT := $(shell $(VERILATOR) --getenv VERILATOR_ROOT 2>/dev/null)

# fx68k RTL sources (order matters: ALU and PLA first, then top-level)
FX68K_SRC := \
    $(FX68K_DIR)/fx68kAlu.sv \
    $(FX68K_DIR)/uaddrPla.sv \
    $(FX68K_DIR)/fx68k.sv

.PHONY: all run clean

all: sim_minimal

# Step 1: Run Verilator to generate C++ from SystemVerilog
obj_dir/Vtb_minimal.mk: tb_minimal.sv $(FX68K_SRC)
	@echo "==> Running Verilator..."
	$(VERILATOR) \
		--cc \
		-Wno-fatal \
		--top-module tb_minimal \
		-I$(FX68K_DIR) \
		tb_minimal.sv \
		$(FX68K_SRC) \
		--Mdir obj_dir \
		--exe sim_minimal.cpp
	@echo "==> Verilator done."

# Step 2: Build the generated C++ + testbench
sim_minimal: obj_dir/Vtb_minimal.mk sim_minimal.cpp
	@echo "==> Building sim_minimal..."
	$(MAKE) -C obj_dir -f Vtb_minimal.mk \
		"CXX=$(CXX)" \
		"CXXFLAGS=$(CXXFLAGS)" \
		VM_PARALLEL_BUILDS=1
	cp obj_dir/Vtb_minimal sim_minimal
	@echo "==> Build complete: sim_minimal"

run: sim_minimal
	@if [ -z "$$ROM_FILE" ]; then \
		echo "Error: ROM_FILE not set. Usage: ROM_FILE=/path/to/prog.bin make run"; \
		exit 1; \
	fi
	ROM_FILE="$$ROM_FILE" ./sim_minimal

clean:
	rm -rf obj_dir sim_minimal
