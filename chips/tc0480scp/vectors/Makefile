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
VEC5       := $(VEC_DIR)/step5_vectors.jsonl
VEC6       := $(VEC_DIR)/step6_vectors.jsonl
VEC7       := $(VEC_DIR)/step7_vectors.jsonl
VEC8       := $(VEC_DIR)/step8_vectors.jsonl
ALL_VECS   := $(VEC1) $(VEC2) $(VEC3) $(VEC4) $(VEC5) $(VEC6) $(VEC7) $(VEC8)
SIM_BIN    := $(OBJ_DIR)/Vtc0480scp

.PHONY: all vectors build run clean test
all: vectors build run

test: all

vectors: $(ALL_VECS)

# All vector files are regenerated together by generate_vectors.py
$(ALL_VECS): $(VEC_DIR)/generate_vectors.py $(VEC_DIR)/scp_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_vectors.py

build: $(SIM_BIN)
$(SIM_BIN): $(TB) $(RTL)
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR) -Wall --top-module tc0480scp \
	    $(RTL) \
	    $(TB) --build -CFLAGS "-O2 -std=c++17" 2>&1

run: $(SIM_BIN) $(ALL_VECS)
	cd $(VEC_DIR) && $(SIM_BIN) $(ALL_VECS)

clean:
	rm -rf $(OBJ_DIR)
	rm -f $(ALL_VECS)
