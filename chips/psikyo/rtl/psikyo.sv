// Psikyo Gate 1: CPU Interface & Register File
// 68EC020 address decode, register maps, interrupt control, ROM/RAM bus arbitration

/* verilator lint_off UNUSEDSIGNAL */
module psikyo (
  // Clock & reset
  input  logic         clk,
  input  logic         rst_n,

  // 68EC020 CPU interface
  input  logic [23:1]  addr,          // CPU address bus (word-addressed)
  input  logic [15:0]  din,           // CPU write data
  output logic [15:0]  dout,          // CPU read data
  input  logic         cs_n,          // Chip select (active low)
  input  logic         rd_n,          // Read strobe (active low)
  input  logic         wr_n,          // Write strobe (active low)
  input  logic [1:0]   dsn,           // Data select (byte selects)

  // VBLANK/interrupt signals
  input  logic         vsync_n,       // Video VBLANK (active low)
  output logic         nmi_n,         // NMI output to CPU (active low)
  output logic         irq1_n,        // Sprite engine complete (active low)
  output logic         irq2_n,        // Sprite DMA ready (active low)
  output logic         irq3_n,        // Z80 sound IRQ acknowledge (active low)

  // PS2001B (Sprite Control) outputs
  output logic [1:0]   spr_dma_enable,
  output logic [1:0]   spr_render_enable,
  output logic [1:0]   spr_mode,           // [0]=8-sprite, [1]=4-sprite
  output logic [1:0]   spr_palette_bank,
  output logic [31:0]  spr_table_base,
  output logic [15:0]  spr_count,
  output logic [7:0]   spr_y_offset,

  // PS2001B (Sprite Scanner) outputs
  // Display list and related signals
  output logic [255:0][9:0]    display_list_x,
  output logic [255:0][9:0]    display_list_y,
  output logic [255:0][15:0]   display_list_tile,
  output logic [255:0][3:0]    display_list_palette,
  output logic [255:0]         display_list_flip_x,
  output logic [255:0]         display_list_flip_y,
  output logic [255:0][1:0]    display_list_priority,
  output logic [255:0][2:0]    display_list_size,
  output logic [255:0]         display_list_valid,
  output logic [7:0]   display_list_count,
  output logic         display_list_ready,

  // PS3103 (Tilemap Control) outputs (4 layers)
  output logic [3:0]   bg_enable,
  output logic [3:0]   bg_tile_size,       // [0]=16x16, [1]=8x8
  output logic [7:0]   bg_priority,        // [7:6]=layer 3, [5:4]=layer 2, [3:2]=layer 1, [1:0]=layer 0
  output logic [3:0][15:0]  bg_chr_bank,
  output logic [3:0][15:0]  bg_scroll_x,
  output logic [3:0][15:0]  bg_scroll_y,
  output logic [3:0][31:0]  bg_tilemap_base,

  // PS3305 (Colmix/Priority) outputs
  output logic [63:0]  priority_table,     // 8 × 8-bit entries
  output logic [7:0]   color_key_ctrl,
  output logic [7:0]   color_key_color,
  output logic [7:0]   color_key_mask,
  output logic [8:0]   vsync_irq_line,     // [8:0] for 9-bit scanline
  output logic [8:0]   hsync_irq_col,

  // Z80 Status signals
  output logic         z80_busy,
  output logic         z80_irq_pending,
  output logic [7:0]   z80_cmd_reply,

  // Sprite list RAM dual-port interface
  output logic [15:0]  sprite_ram_addr,
  output logic [15:0]  sprite_ram_din,
  output logic [1:0]   sprite_ram_wsel,    // Word write select for 32-bit data
  output logic         sprite_ram_wr_en,
  input  logic [31:0]  sprite_ram_dout
);

  // ====== Address Decode ======

  // Register chip select logic
  logic cs_ps2001b;
  logic cs_ps3103;
  logic cs_ps3204;
  logic cs_ps3305;
  logic cs_z80;
  logic cs_int;
  logic cs_workram;
  logic cs_spriteram;
  logic cs_tilemapram;
  logic cs_paletteram;

  always_comb begin
    // Base decode on upper address bits
    // 0x00000000 – 0x0001FFFF  Work RAM
    cs_workram    = (addr[23:17] == 7'h00) & ~addr[16];
    // 0x00020000 – 0x0003FFFF  Sprite/Graphics RAM
    cs_spriteram  = (addr[23:17] == 7'h00) & addr[16] & ~addr[15];
    // 0x00040000 – 0x0005FFFF  Tile Map RAM
    cs_tilemapram = (addr[23:17] == 7'h00) & addr[16] & addr[15] & ~addr[14];
    // 0x00060000 – 0x0007FFFF  Palette RAM
    cs_paletteram = (addr[23:17] == 7'h00) & addr[16] & addr[15] & addr[14] & ~addr[13];

    // Register decode (byte 0x00080000 – 0x0009FFFF = word 0x00040000 – 0x0004FFFF)
    if (addr[23:17] == 7'h02) begin
      // Word 0x00040000  PS2001B
      cs_ps2001b = (addr[14:12] == 3'b000);
      // Word 0x00042000  PS3103
      cs_ps3103  = (addr[14:12] == 3'b001);
      // Word 0x00044000  PS3204
      cs_ps3204  = (addr[14:12] == 3'b010);
      // Word 0x00046000  PS3305
      cs_ps3305  = (addr[14:12] == 3'b011);
      // Word 0x00048000  Z80 Sound Interface
      cs_z80     = (addr[14:12] == 3'b100);
      // Reserved
      cs_int     = (addr[14:12] == 3'b101);
    end else begin
      cs_ps2001b = 1'b0;
      cs_ps3103  = 1'b0;
      cs_ps3204  = 1'b0;
      cs_ps3305  = 1'b0;
      cs_z80     = 1'b0;
      cs_int     = 1'b0;
    end
  end

  // ====== PS2001B Sprite Control Shadow Registers ======

  logic [7:0]   ps2001b_ctrl_shadow;
  logic [31:0]  ps2001b_table_base_shadow;
  logic [15:0]  ps2001b_count_shadow;
  logic [7:0]   ps2001b_y_offset_shadow;

  logic [7:0]   ps2001b_ctrl_active;
  logic [31:0]  ps2001b_table_base_active;
  logic [15:0]  ps2001b_count_active;
  logic [7:0]   ps2001b_y_offset_active;

  // Unused signals (plain declarations + assign; Quartus 17.0 forbids non-constant initializers)
  /* verilator lint_off UNUSED */
  logic _unused_ctrl_active;
  logic _unused_ps3204;
  logic _unused_cs_int;
  logic _unused_sprite_ram_dout;
  /* verilator lint_on UNUSED */
  assign _unused_ctrl_active    = &ps2001b_ctrl_active[3:0];
  assign _unused_ps3204         = cs_ps3204;
  assign _unused_cs_int         = cs_int;
  assign _unused_sprite_ram_dout = |sprite_ram_dout;

  // ====== PS3103 Tilemap Control Shadow Registers (4 layers × 4 registers each) ======

  logic [3:0][7:0]   ps3103_ctrl_shadow;
  logic [3:0][15:0]  ps3103_scroll_x_shadow;
  logic [3:0][15:0]  ps3103_scroll_y_shadow;
  logic [3:0][31:0]  ps3103_tilemap_base_shadow;

  logic [3:0][7:0]   ps3103_ctrl_active;
  logic [3:0][15:0]  ps3103_scroll_x_active;
  logic [3:0][15:0]  ps3103_scroll_y_active;
  logic [3:0][31:0]  ps3103_tilemap_base_active;

  // ====== PS3305 Colmix/Priority Shadow Registers ======

  logic [63:0]  ps3305_priority_shadow;
  logic [7:0]   ps3305_color_key_ctrl_shadow;
  logic [7:0]   ps3305_color_key_shadow;
  logic [8:0]   ps3305_vsync_irq_line_shadow;
  logic [8:0]   ps3305_hsync_irq_col_shadow;

  logic [63:0]  ps3305_priority_active;
  logic [7:0]   ps3305_color_key_ctrl_active;
  logic [7:0]   ps3305_color_key_active;
  logic [8:0]   ps3305_vsync_irq_line_active;
  logic [8:0]   ps3305_hsync_irq_col_active;

  // ====== Z80 Status/Mailbox ======

  logic [7:0]   z80_status_reg;
  logic [7:0]   z80_cmd_reply_reg;

  // ====== Write Logic ======

  logic write_strobe;
  logic read_strobe;
  assign write_strobe = ~wr_n & ~cs_n;
  assign read_strobe  = ~rd_n & ~cs_n;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // PS2001B shadow regs
      ps2001b_ctrl_shadow <= 8'h00;
      ps2001b_table_base_shadow <= 32'h00000000;
      ps2001b_count_shadow <= 16'h0000;
      ps2001b_y_offset_shadow <= 8'h00;

      // PS3103 shadow regs
      for (int i = 0; i < 4; i++) begin
        ps3103_ctrl_shadow[i] <= 8'h00;
        ps3103_scroll_x_shadow[i] <= 16'h0000;
        ps3103_scroll_y_shadow[i] <= 16'h0000;
        ps3103_tilemap_base_shadow[i] <= 32'h00000000;
      end

      // PS3305 shadow regs
      ps3305_priority_shadow <= 64'h0001020304050607;
      ps3305_color_key_ctrl_shadow <= 8'h00;
      ps3305_color_key_shadow <= 8'h00;
      ps3305_vsync_irq_line_shadow <= 9'hF0;  // Line 240 (VBLANK)
      ps3305_hsync_irq_col_shadow <= 9'h140;   // Column 320 (HSYNC end)

      // Z80 regs
      z80_status_reg <= 8'h00;
      z80_cmd_reply_reg <= 8'h00;
    end else if (write_strobe) begin
      case (1'b1)
        cs_ps2001b: begin
          // PS2001B sprite control registers
          case (addr[3:1])
            3'b000: ps2001b_ctrl_shadow <= din[7:0];           // 0x080000
            3'b001: ps2001b_table_base_shadow[15:0] <= din;    // 0x080002 (low word)
            3'b010: ps2001b_table_base_shadow[31:16] <= din;   // 0x080004 (high word)
            3'b011: begin
              ps2001b_count_shadow <= din;                      // 0x080006
            end
            3'b100: ps2001b_y_offset_shadow <= din[7:0];       // 0x080008
            default: ;
          endcase
        end

        cs_ps3103: begin
          // PS3103 tilemap control registers (4 layers)
          // Each layer has 4 registers spaced at 0x10 bytes (8 words)
          // addr[5:4] = layer_idx (0..3), addr[3:1] = reg_offset (0..4)
          // Inline local variable declarations removed (Error 10748 in Quartus 17.0)
          case (addr[3:1])
            3'b000: ps3103_ctrl_shadow[addr[5:4]] <= din[7:0];
            3'b001: ps3103_scroll_x_shadow[addr[5:4]] <= din;
            3'b010: ps3103_scroll_y_shadow[addr[5:4]] <= din;
            3'b011: ps3103_tilemap_base_shadow[addr[5:4]][15:0] <= din;
            3'b100: ps3103_tilemap_base_shadow[addr[5:4]][31:16] <= din;
            default: ;
          endcase
        end

        cs_ps3305: begin
          // PS3305 colmix/priority registers
          case (addr[5:1])
            5'b00000: ps3305_priority_shadow[15:0] <= din;     // Entries 0–1
            5'b00001: ps3305_priority_shadow[31:16] <= din;    // Entries 2–3
            5'b00010: ps3305_priority_shadow[47:32] <= din;    // Entries 4–5
            5'b00011: ps3305_priority_shadow[63:48] <= din;    // Entries 6–7
            5'b10000: ps3305_color_key_ctrl_shadow <= din[7:0];  // 0x8C020
            5'b10001: ps3305_color_key_shadow <= din[7:0];       // 0x8C024
            5'b10010: ps3305_vsync_irq_line_shadow <= din[8:0];  // 0x8C028
            5'b10011: ps3305_hsync_irq_col_shadow <= din[8:0];   // 0x8C02C
            default: ;
          endcase
        end

        cs_z80: begin
          // Z80 sound interface
          case (addr[3:1])
            3'b000: ;  // YM2610_ADDR_A (write only)
            3'b001: ;  // YM2610_DATA_A (write only)
            3'b010: ;  // YM2610_ADDR_B (write only)
            3'b011: ;  // YM2610_DATA_B (write only)
            3'b101: z80_cmd_reply_reg <= din[7:0];  // Z80_CMD / Z80_REPLY
            default: ;
          endcase
        end

        default: ;
      endcase
    end
  end

  // ====== VSYNC Latch (Rising Edge Detection) ======

  logic vsync_n_r;
  logic vsync_n_scan_r;
  logic vsync_scan_falling;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vsync_n_r <= 1'b1;
    end else begin
      vsync_n_r <= vsync_n;
    end
  end

  logic vsync_rising_edge;
  assign vsync_rising_edge = vsync_n_r & ~vsync_n;

  // Copy shadow → active on VSYNC rising edge
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ps2001b_ctrl_active <= 8'h00;
      ps2001b_table_base_active <= 32'h00000000;
      ps2001b_count_active <= 16'h0000;
      ps2001b_y_offset_active <= 8'h00;

      for (int i = 0; i < 4; i++) begin
        ps3103_ctrl_active[i] <= 8'h00;
        ps3103_scroll_x_active[i] <= 16'h0000;
        ps3103_scroll_y_active[i] <= 16'h0000;
        ps3103_tilemap_base_active[i] <= 32'h00000000;
      end

      ps3305_priority_active <= 64'h0001020304050607;
      ps3305_color_key_ctrl_active <= 8'h00;
      ps3305_color_key_active <= 8'h00;
      ps3305_vsync_irq_line_active <= 9'hF0;
      ps3305_hsync_irq_col_active <= 9'h140;
    end else if (vsync_rising_edge) begin
      ps2001b_ctrl_active <= ps2001b_ctrl_shadow;
      ps2001b_table_base_active <= ps2001b_table_base_shadow;
      ps2001b_count_active <= ps2001b_count_shadow;
      ps2001b_y_offset_active <= ps2001b_y_offset_shadow;

      for (int i = 0; i < 4; i++) begin
        ps3103_ctrl_active[i] <= ps3103_ctrl_shadow[i];
        ps3103_scroll_x_active[i] <= ps3103_scroll_x_shadow[i];
        ps3103_scroll_y_active[i] <= ps3103_scroll_y_shadow[i];
        ps3103_tilemap_base_active[i] <= ps3103_tilemap_base_shadow[i];
      end

      ps3305_priority_active <= ps3305_priority_shadow;
      ps3305_color_key_ctrl_active <= ps3305_color_key_ctrl_shadow;
      ps3305_color_key_active <= ps3305_color_key_shadow;
      ps3305_vsync_irq_line_active <= ps3305_vsync_irq_line_shadow;
      ps3305_hsync_irq_col_active <= ps3305_hsync_irq_col_shadow;
    end
  end

  // ====== Output Assignment ======

  assign spr_dma_enable = {ps2001b_ctrl_active[7], 1'b0};
  assign spr_render_enable = {ps2001b_ctrl_active[6], 1'b0};
  assign spr_mode = {ps2001b_ctrl_active[5], 1'b0};
  assign spr_palette_bank = {ps2001b_ctrl_active[4], 1'b0};
  assign spr_table_base = ps2001b_table_base_active;
  assign spr_count = ps2001b_count_active;
  assign spr_y_offset = ps2001b_y_offset_active;

  assign bg_enable = {ps3103_ctrl_active[3][7], ps3103_ctrl_active[2][7],
                      ps3103_ctrl_active[1][7], ps3103_ctrl_active[0][7]};
  assign bg_tile_size = {ps3103_ctrl_active[3][6], ps3103_ctrl_active[2][6],
                         ps3103_ctrl_active[1][6], ps3103_ctrl_active[0][6]};
  assign bg_priority = {ps3103_ctrl_active[3][5:4], ps3103_ctrl_active[2][5:4],
                        ps3103_ctrl_active[1][5:4], ps3103_ctrl_active[0][5:4]};
  assign bg_chr_bank[0] = {12'h000, ps3103_ctrl_active[0][3:0]};
  assign bg_chr_bank[1] = {12'h000, ps3103_ctrl_active[1][3:0]};
  assign bg_chr_bank[2] = {12'h000, ps3103_ctrl_active[2][3:0]};
  assign bg_chr_bank[3] = {12'h000, ps3103_ctrl_active[3][3:0]};

  assign bg_scroll_x[0] = ps3103_scroll_x_active[0];
  assign bg_scroll_x[1] = ps3103_scroll_x_active[1];
  assign bg_scroll_x[2] = ps3103_scroll_x_active[2];
  assign bg_scroll_x[3] = ps3103_scroll_x_active[3];
  assign bg_scroll_y[0] = ps3103_scroll_y_active[0];
  assign bg_scroll_y[1] = ps3103_scroll_y_active[1];
  assign bg_scroll_y[2] = ps3103_scroll_y_active[2];
  assign bg_scroll_y[3] = ps3103_scroll_y_active[3];

  assign bg_tilemap_base[0] = ps3103_tilemap_base_active[0];
  assign bg_tilemap_base[1] = ps3103_tilemap_base_active[1];
  assign bg_tilemap_base[2] = ps3103_tilemap_base_active[2];
  assign bg_tilemap_base[3] = ps3103_tilemap_base_active[3];

  assign priority_table = ps3305_priority_active;
  assign color_key_ctrl = ps3305_color_key_ctrl_active;
  assign color_key_color = ps3305_color_key_active;
  assign color_key_mask = 8'hFF;  // Full mask by default
  assign vsync_irq_line = ps3305_vsync_irq_line_active;
  assign hsync_irq_col = ps3305_hsync_irq_col_active;

  assign z80_busy = z80_status_reg[7];
  assign z80_irq_pending = z80_status_reg[6];
  assign z80_cmd_reply = z80_cmd_reply_reg;

  // ====== PS2001B Sprite Scanner (Gate 2) ======

  // Display list struct typedef
  typedef struct packed {
    logic [9:0]  x;
    logic [9:0]  y;
    logic [15:0] tile_num;
    logic        flip_x;
    logic        flip_y;
    logic [1:0]  prio;
    logic [2:0]  size;
    logic [3:0]  palette;
    logic        valid;
  } psikyo_sprite_t;

  psikyo_sprite_t display_list_internal [0:255];
  logic [7:0] display_list_count_internal;
  logic display_list_ready_internal;

  // Simplified scanner: on VSYNC rising edge, mark all ps2001b_count_active sprites as valid
  // Full implementation would read sprite_ram_dout and check Y != 0x3FF for each
  integer i;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vsync_n_scan_r <= 1'b1;
      vsync_scan_falling <= 1'b0;
      display_list_count_internal <= 8'h00;
      display_list_ready_internal <= 1'b0;

      for (int j = 0; j < 256; j++) begin
        display_list_internal[j] <= '0;
      end
    end else begin
      vsync_scan_falling <= vsync_n_scan_r & ~vsync_n;  // capture edge BEFORE latch updates
      vsync_n_scan_r <= vsync_n;                          // update latch
      display_list_ready_internal <= 1'b0;  // Pulse signal

      // On VSYNC rising edge, scan and populate display list
      if (vsync_scan_falling) begin
        // Mark all sprites up to ps2001b_count_shadow as valid (read shadow, not active)
        for (i = 0; i < 256; i++) begin
          if (i < ps2001b_count_shadow[7:0]) begin
            display_list_internal[i].valid <= 1'b1;
            display_list_internal[i].x <= 10'h000;
            display_list_internal[i].y <= 10'h000;
            display_list_internal[i].tile_num <= 16'h0000;
            display_list_internal[i].palette <= 4'h0;
            display_list_internal[i].flip_x <= 1'b0;
            display_list_internal[i].flip_y <= 1'b0;
            display_list_internal[i].prio <= 2'h0;
            display_list_internal[i].size <= 3'h0;
          end else begin
            display_list_internal[i].valid <= 1'b0;
          end
        end

        // Latch count and pulse ready
        display_list_count_internal <= ps2001b_count_shadow[7:0];
        display_list_ready_internal <= 1'b1;
      end
    end
  end

  // Output assignment from internal display list
  generate
    genvar k;
    for (k = 0; k < 256; k++) begin : display_list_assign
      assign display_list_x[k] = display_list_internal[k].x;
      assign display_list_y[k] = display_list_internal[k].y;
      assign display_list_tile[k] = display_list_internal[k].tile_num;
      assign display_list_palette[k] = display_list_internal[k].palette;
      assign display_list_flip_x[k] = display_list_internal[k].flip_x;
      assign display_list_flip_y[k] = display_list_internal[k].flip_y;
      assign display_list_priority[k] = display_list_internal[k].prio;
      assign display_list_size[k] = display_list_internal[k].size;
      assign display_list_valid[k] = display_list_internal[k].valid;
    end
  endgenerate

  assign display_list_count = display_list_count_internal;
  assign display_list_ready = display_list_ready_internal;

  // Interrupt outputs (stub: always inactive)
  assign nmi_n = 1'b1;
  assign irq1_n = 1'b1;
  assign irq2_n = 1'b1;
  assign irq3_n = 1'b1;

  // Sprite RAM interface (stub: no DMA currently)
  assign sprite_ram_addr = 16'h0000;
  assign sprite_ram_din = 16'h0000;
  assign sprite_ram_wsel = 2'b00;
  assign sprite_ram_wr_en = 1'b0;

  // ====== Read Logic ======

  always_comb begin
    dout = 16'h0000;

    if (read_strobe) begin
      case (1'b1)
        cs_ps2001b: begin
          case (addr[3:1])
            3'b000: dout = {8'h00, ps2001b_ctrl_shadow};
            3'b001: dout = ps2001b_table_base_shadow[15:0];
            3'b010: dout = ps2001b_table_base_shadow[31:16];
            3'b011: dout = ps2001b_count_shadow;
            3'b100: dout = {8'h00, ps2001b_y_offset_shadow};
            3'b101: dout = {12'h000, 4'h1};  // SPRITE_STATUS (stub: ready bit)
            default: dout = 16'h0000;
          endcase
        end

        cs_ps3103: begin
          /* verilator lint_off IMPLICITSTATIC */
          logic [1:0] layer_idx = addr[5:4];
          logic [2:0] reg_offset = addr[3:1];
          /* verilator lint_on IMPLICITSTATIC */

          case (reg_offset)
            3'b000: dout = {8'h00, ps3103_ctrl_shadow[layer_idx]};
            3'b001: dout = ps3103_scroll_x_shadow[layer_idx];
            3'b010: dout = ps3103_scroll_y_shadow[layer_idx];
            3'b011: dout = ps3103_tilemap_base_shadow[layer_idx][15:0];
            3'b100: dout = ps3103_tilemap_base_shadow[layer_idx][31:16];
            default: dout = 16'h0000;
          endcase
        end

        cs_ps3305: begin
          case (addr[5:1])
            5'b00000: dout = ps3305_priority_shadow[15:0];
            5'b00001: dout = ps3305_priority_shadow[31:16];
            5'b00010: dout = ps3305_priority_shadow[47:32];
            5'b00011: dout = ps3305_priority_shadow[63:48];
            5'b10000: dout = {8'h00, ps3305_color_key_ctrl_shadow};
            5'b10001: dout = {8'h00, ps3305_color_key_shadow};
            5'b10010: dout = {{7'h00}, ps3305_vsync_irq_line_shadow};
            5'b10011: dout = {{7'h00}, ps3305_hsync_irq_col_shadow};
            default: dout = 16'h0000;
          endcase
        end

        cs_z80: begin
          case (addr[3:1])
            3'b010: dout = {8'h00, z80_status_reg};
            3'b101: dout = {8'h00, z80_cmd_reply_reg};
            default: dout = 16'h0000;
          endcase
        end

        cs_workram: dout = 16'h0000;     // Stub: RAM interface not handled here
        cs_spriteram: dout = 16'h0000;   // Stub: RAM interface not handled here
        cs_tilemapram: dout = 16'h0000;  // Stub: RAM interface not handled here
        cs_paletteram: dout = 16'h0000;  // Stub: RAM interface not handled here
        default: dout = 16'h0000;
      endcase
    end
  end

  // ====== Lint suppression ======
  logic _unused_dsn;
  assign _unused_dsn = &{dsn, 1'b0};

endmodule
/* verilator lint_on UNUSEDSIGNAL */
