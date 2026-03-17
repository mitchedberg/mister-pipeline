CHIP_DIR   := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))/..

RTL        := $(CHIP_DIR)/rtl/tc0480scp.sv \
              $(CHIP_DIR)/rtl/tc0480scp_vram.sv \
              $(CHIP_DIR)/rtl/tc0480scp_textlayer.sv \
              $(CHIP_DIR)/rtl/tc0480scp_colmix.sv \
              $(CHIP_DIR)/rtl/tc0480scp_bg.sv
VEC_DIR    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TB         := $(VEC_DIR)/tb_tc0480scp.cpp
OBJ_DIR    := $(VEC_DIR)/obj_dir
VERILATOR  := verilator
PYTHON     := python3
VEC1       := $(VEC_DIR)/step1_vectors.jsonl
VEC2       := $(VEC_DIR)/step2_vectors.jsonl
VEC3       := $(VEC_DIR)/step3_vectors.jsonl
VEC4       := $(VEC_DIR)/step4_vectors.jsonl
SIM_BIN    := $(OBJ_DIR)/Vtc0480scp

.PHONY: all vectors build run clean test
all: vectors build run

test: all

vectors: $(VEC1) $(VEC2) $(VEC3) $(VEC4)

$(VEC1): $(VEC_DIR)/generate_vectors.py $(VEC_DIR)/scp_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_vectors.py

$(VEC2): $(VEC_DIR)/generate_vectors.py $(VEC_DIR)/scp_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_vectors.py

$(VEC3): $(VEC_DIR)/generate_vectors.py $(VEC_DIR)/scp_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_vectors.py

$(VEC4): $(VEC_DIR)/generate_vectors.py $(VEC_DIR)/scp_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_vectors.py

build: $(SIM_BIN)
$(SIM_BIN): $(TB) $(RTL)
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR) -Wall --top-module tc0480scp \
	    $(RTL) \
	    $(TB) --build -CFLAGS "-O2 -std=c++17" 2>&1

run: $(SIM_BIN) $(VEC1) $(VEC2) $(VEC3) $(VEC4)
	cd $(VEC_DIR) && $(SIM_BIN) $(VEC1) $(VEC2) $(VEC3) $(VEC4)

clean:
	rm -rf $(OBJ_DIR)
	rm -f $(VEC1) $(VEC2) $(VEC3) $(VEC4)
