CHIP_DIR   := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))/..

RTL        := $(CHIP_DIR)/rtl/gp9001.sv
VEC_DIR    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
OBJ_DIR    := $(VEC_DIR)/obj_dir
VERILATOR  := verilator
PYTHON     := python3

# ── Gate 1 ──────────────────────────────────────────────────────────────────

TB1        := $(VEC_DIR)/tb_gate1.cpp
VEC1       := $(VEC_DIR)/gate1_vectors.jsonl
SIM1       := $(OBJ_DIR)/Vgp9001_gate1

.PHONY: all gate1 gate2 gate3 gate4 vectors build run clean test

all: gate1 gate2 gate3 gate4

test: all

# Gate 1 vectors
$(VEC1): $(VEC_DIR)/generate_gate1.py $(VEC_DIR)/gate1_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_gate1.py

# Gate 1 simulation binary (separate obj dir; RTL change forces rebuild)
$(SIM1): $(TB1) $(RTL)
	mkdir -p $(OBJ_DIR)/gate1
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR)/gate1 -Wall --top-module gp9001 \
	    -O0 -fno-dfg -fno-dfg-peephole \
	    $(RTL) \
	    $(TB1) --build -CFLAGS "-O2 -std=c++17" 2>&1
	cp $(OBJ_DIR)/gate1/Vgp9001 $(SIM1)

gate1: $(VEC1) $(SIM1)
	cd $(VEC_DIR) && $(SIM1) $(VEC1)

# ── Gate 2 ──────────────────────────────────────────────────────────────────

TB2        := $(VEC_DIR)/tb_gate2.cpp
VEC2       := $(VEC_DIR)/gate2_vectors.jsonl
SIM2       := $(OBJ_DIR)/Vgp9001_gate2

# Gate 2 vectors
$(VEC2): $(VEC_DIR)/generate_gate2.py $(VEC_DIR)/gate2_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_gate2.py

# Gate 2 simulation binary (separate obj dir; RTL change forces rebuild)
$(SIM2): $(TB2) $(RTL)
	mkdir -p $(OBJ_DIR)/gate2
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR)/gate2 -Wall --top-module gp9001 \
	    -O0 -fno-dfg -fno-dfg-peephole \
	    $(RTL) \
	    $(TB2) --build -CFLAGS "-O2 -std=c++17" 2>&1
	cp $(OBJ_DIR)/gate2/Vgp9001 $(SIM2)

gate2: $(VEC2) $(SIM2)
	cd $(VEC_DIR) && $(SIM2) $(VEC2)

# ── Gate 3 ──────────────────────────────────────────────────────────────────

TB3        := $(VEC_DIR)/tb_gate3.cpp
VEC3       := $(VEC_DIR)/gate3_vectors.jsonl
SIM3       := $(OBJ_DIR)/Vgp9001_gate3

# Gate 3 vectors
$(VEC3): $(VEC_DIR)/generate_gate3.py $(VEC_DIR)/gate3_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_gate3.py

# Gate 3 simulation binary (separate obj dir; RTL change forces rebuild)
$(SIM3): $(TB3) $(RTL)
	mkdir -p $(OBJ_DIR)/gate3
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR)/gate3 -Wall --top-module gp9001 \
	    -O0 -fno-dfg -fno-dfg-peephole \
	    $(RTL) \
	    $(TB3) --build -CFLAGS "-O2 -std=c++17" 2>&1
	cp $(OBJ_DIR)/gate3/Vgp9001 $(SIM3)

gate3: $(VEC3) $(SIM3)
	cd $(VEC_DIR) && $(SIM3) $(VEC3)

# ── Gate 4 ──────────────────────────────────────────────────────────────────

TB4        := $(VEC_DIR)/tb_gate4.cpp
VEC4       := $(VEC_DIR)/gate4_vectors.jsonl
SIM4       := $(OBJ_DIR)/Vgp9001_gate4

# Gate 4 vectors
$(VEC4): $(VEC_DIR)/generate_gate4.py $(VEC_DIR)/gate4_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_gate4.py

# Gate 4 simulation binary
$(SIM4): $(TB4) $(RTL)
	mkdir -p $(OBJ_DIR)/gate4
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR)/gate4 -Wall --top-module gp9001 \
	    -O0 -fno-dfg -fno-dfg-peephole \
	    $(RTL) \
	    $(TB4) --build -CFLAGS "-O2 -std=c++17" 2>&1
	cp $(OBJ_DIR)/gate4/Vgp9001 $(SIM4)

gate4: $(VEC4) $(SIM4)
	cd $(VEC_DIR) && $(SIM4) $(VEC4)

# ── Misc ────────────────────────────────────────────────────────────────────

vectors: $(VEC1) $(VEC2) $(VEC3) $(VEC4)

clean:
	rm -rf $(OBJ_DIR)
	rm -f $(VEC1) $(VEC2) $(VEC3) $(VEC4)
