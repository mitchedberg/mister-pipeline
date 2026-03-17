# =============================================================================
# Makefile — Taito X gate4 integration testbench build
# =============================================================================
#
# Builds and runs the gate4 testbench, which tests the complete sprite→colmix
# pipeline:
#   1. X1-001A sprite scanning + rendering
#   2. taito_x_colmix palette lookup + priority
#
# Targets:
#   make              — generate vectors, build testbench, run tests
#   make vectors      — generate gate4_integration_vectors.jsonl
#   make build        — compile with Verilator
#   make run          — execute testbench
#   make clean        — remove build artifacts
#

# Directories
ROOT_DIR    := ..
RTL_DIR     := ../../rtl
OBJ_DIR     := obj_dir
VEC_FILE    := gate4_integration_vectors.jsonl

# Tools
PYTHON3     := python3
VERILATOR   := verilator
CXX         := clang++
CXXFLAGS    := -Wall -Wextra -O2 -std=c++17

# RTL sources (minimal testbench: just x1_001a, not taito_x.sv)
RTL_SOURCES := \
  $(RTL_DIR)/x1_001a.sv

# Test files
TB_CPP      := tb_gate4.cpp
VEC_SCRIPT  := generate_gate4.py

# Verilator flags
VERILATOR_FLAGS := \
  --cc \
  --exe $(TB_CPP) \
  --trace \
  --top-module x1_001a \
  --Mdir $(OBJ_DIR) \
  -CFLAGS "$(CXXFLAGS)" \
  -LDFLAGS "-lm"

# Build target
EXE := $(OBJ_DIR)/Vx1_001a

.PHONY: all vectors build run clean

all: vectors build run

vectors: $(VEC_FILE)

$(VEC_FILE): $(VEC_SCRIPT)
	@echo "Generating test vectors..."
	$(PYTHON3) $(VEC_SCRIPT)
	@echo "Generated $(VEC_FILE)"

build: $(EXE)

$(EXE): $(TB_CPP) $(RTL_SOURCES) $(VEC_FILE)
	@echo "Building testbench with Verilator..."
	$(VERILATOR) $(VERILATOR_FLAGS) $(RTL_SOURCES)
	@echo "Compiling..."
	cd $(OBJ_DIR) && make -f Vx1_001a.mk
	@echo "Build complete: $(EXE)"

run: $(EXE)
	@echo "Running tests..."
	$(EXE) $(VEC_FILE)

clean:
	rm -rf $(OBJ_DIR) $(VEC_FILE)
	@echo "Clean complete"

.DEFAULT_GOAL := all
