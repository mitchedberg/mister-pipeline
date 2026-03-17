CHIP_DIR   := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))/..

RTL        := $(CHIP_DIR)/rtl/tc0630fdp.sv \
              $(CHIP_DIR)/rtl/tc0630fdp_text.sv \
              $(CHIP_DIR)/rtl/tc0630fdp_bg.sv \
              $(CHIP_DIR)/rtl/tc0630fdp_lineram.sv \
              $(CHIP_DIR)/rtl/tc0630fdp_sprite_scan.sv \
              $(CHIP_DIR)/rtl/tc0630fdp_sprite_render.sv
TB         := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))tb_tc0630fdp.cpp)
VEC_DIR    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
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
SIM_BIN    := $(OBJ_DIR)/Vtc0630fdp

.PHONY: all vectors build run clean test
all: vectors build run

test: all

vectors: $(VEC1) $(VEC2) $(VEC3) $(VEC4) $(VEC5) $(VEC6) $(VEC7) $(VEC8)

$(VEC1): $(VEC_DIR)/generate_vectors.py $(VEC_DIR)/fdp_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_vectors.py

$(VEC2): $(VEC_DIR)/generate_step2_vectors.py $(VEC_DIR)/fdp_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_step2_vectors.py

$(VEC3): $(VEC_DIR)/generate_step3_vectors.py $(VEC_DIR)/fdp_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_step3_vectors.py

$(VEC4): $(VEC_DIR)/generate_step4_vectors.py $(VEC_DIR)/fdp_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_step4_vectors.py

$(VEC5): $(VEC_DIR)/generate_step5_vectors.py $(VEC_DIR)/fdp_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_step5_vectors.py

$(VEC6): $(VEC_DIR)/generate_step6_vectors.py $(VEC_DIR)/fdp_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_step6_vectors.py

$(VEC7): $(VEC_DIR)/generate_step7_vectors.py $(VEC_DIR)/fdp_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_step7_vectors.py

$(VEC8): $(VEC_DIR)/generate_step8_vectors.py $(VEC_DIR)/fdp_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_step8_vectors.py

build: $(SIM_BIN)
$(SIM_BIN): $(TB) $(RTL)
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR) -Wall --top-module tc0630fdp \
	    $(RTL) \
	    $(TB) --build -CFLAGS "-O2 -std=c++17" 2>&1

run: $(SIM_BIN) $(VEC1) $(VEC2) $(VEC3) $(VEC4) $(VEC5) $(VEC6) $(VEC7) $(VEC8)
	cd $(VEC_DIR) && $(SIM_BIN) $(VEC1) $(VEC2) $(VEC3) $(VEC4) $(VEC5) $(VEC6) $(VEC7) $(VEC8)

clean:
	rm -rf $(OBJ_DIR)
	rm -f $(VEC1) $(VEC2) $(VEC3) $(VEC4) $(VEC5) $(VEC6) $(VEC7) $(VEC8)
