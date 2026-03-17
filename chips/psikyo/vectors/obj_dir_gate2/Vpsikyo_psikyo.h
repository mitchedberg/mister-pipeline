// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design internal header
// See Vpsikyo.h for the primary calling header

#ifndef VERILATED_VPSIKYO_PSIKYO_H_
#define VERILATED_VPSIKYO_PSIKYO_H_  // guard

#include "verilated.h"


class Vpsikyo__Syms;

class alignas(VL_CACHE_LINE_BYTES) Vpsikyo_psikyo final {
  public:

    // DESIGN SPECIFIC STATE
    // Anonymous structures to workaround compiler member-count bugs
    struct {
        CData/*0:0*/ clk;
        CData/*0:0*/ rst_n;
        CData/*0:0*/ cs_n;
        CData/*0:0*/ rd_n;
        CData/*0:0*/ wr_n;
        CData/*1:0*/ dsn;
        CData/*0:0*/ vsync_n;
        CData/*0:0*/ nmi_n;
        CData/*0:0*/ irq1_n;
        CData/*0:0*/ irq2_n;
        CData/*0:0*/ irq3_n;
        CData/*1:0*/ spr_dma_enable;
        CData/*1:0*/ spr_render_enable;
        CData/*1:0*/ spr_mode;
        CData/*1:0*/ spr_palette_bank;
        CData/*7:0*/ spr_y_offset;
        CData/*7:0*/ display_list_count;
        CData/*0:0*/ display_list_ready;
        CData/*3:0*/ bg_enable;
        CData/*3:0*/ bg_tile_size;
        CData/*7:0*/ bg_priority;
        CData/*7:0*/ color_key_ctrl;
        CData/*7:0*/ color_key_color;
        CData/*7:0*/ color_key_mask;
        CData/*0:0*/ z80_busy;
        CData/*0:0*/ z80_irq_pending;
        CData/*7:0*/ z80_cmd_reply;
        CData/*1:0*/ sprite_ram_wsel;
        CData/*0:0*/ sprite_ram_wr_en;
        CData/*0:0*/ __PVT__cs_ps2001b;
        CData/*0:0*/ __PVT__cs_ps3103;
        CData/*0:0*/ __PVT__cs_ps3204;
        CData/*0:0*/ __PVT__cs_ps3305;
        CData/*0:0*/ __PVT__cs_z80;
        CData/*0:0*/ __PVT__cs_int;
        CData/*0:0*/ __PVT__cs_workram;
        CData/*0:0*/ __PVT__cs_spriteram;
        CData/*0:0*/ __PVT__cs_tilemapram;
        CData/*0:0*/ __PVT__cs_paletteram;
        CData/*7:0*/ __PVT__ps2001b_ctrl_shadow;
        CData/*7:0*/ __PVT__ps2001b_y_offset_shadow;
        CData/*7:0*/ __PVT__ps2001b_ctrl_active;
        CData/*7:0*/ __PVT__ps2001b_y_offset_active;
        CData/*0:0*/ __PVT___unused_ctrl_active;
        CData/*0:0*/ __PVT___unused_ps3204;
        CData/*0:0*/ __PVT___unused_cs_int;
        CData/*0:0*/ __PVT___unused_sprite_ram_dout;
        CData/*7:0*/ __PVT__ps3305_color_key_ctrl_shadow;
        CData/*7:0*/ __PVT__ps3305_color_key_shadow;
        CData/*7:0*/ __PVT__ps3305_color_key_ctrl_active;
        CData/*7:0*/ __PVT__ps3305_color_key_active;
        CData/*7:0*/ __PVT__z80_status_reg;
        CData/*7:0*/ __PVT__z80_cmd_reply_reg;
        CData/*0:0*/ __PVT__write_strobe;
        CData/*0:0*/ __PVT__read_strobe;
        CData/*0:0*/ __PVT__vsync_n_r;
        CData/*0:0*/ __PVT__vsync_rising_edge;
        CData/*7:0*/ __PVT__display_list_count_internal;
        CData/*0:0*/ __PVT__display_list_ready_internal;
        CData/*0:0*/ __PVT___unused_dsn;
        CData/*1:0*/ __PVT__unnamedblk2__DOT__layer_idx;
        CData/*2:0*/ __PVT__unnamedblk2__DOT__reg_offset;
        CData/*1:0*/ __PVT__unnamedblk6__DOT__layer_idx;
        CData/*2:0*/ __PVT__unnamedblk6__DOT__reg_offset;
    };
    struct {
        CData/*7:0*/ __Vdly__ps2001b_ctrl_shadow;
        CData/*7:0*/ __Vdly__ps2001b_y_offset_shadow;
        CData/*7:0*/ __Vdly__ps3305_color_key_ctrl_shadow;
        CData/*7:0*/ __Vdly__ps3305_color_key_shadow;
        CData/*7:0*/ __Vdly__z80_cmd_reply_reg;
        CData/*7:0*/ __Vdly__z80_status_reg;
        CData/*0:0*/ __Vdly__vsync_n_r;
        CData/*7:0*/ __Vdly__ps2001b_ctrl_active;
        CData/*7:0*/ __Vdly__ps2001b_y_offset_active;
        CData/*7:0*/ __Vdly__ps3305_color_key_ctrl_active;
        CData/*7:0*/ __Vdly__ps3305_color_key_active;
        CData/*0:0*/ __Vdly__display_list_ready_internal;
        CData/*7:0*/ __Vdly__display_list_count_internal;
        CData/*7:0*/ __VdlyVal__ps3103_ctrl_shadow__v0;
        CData/*1:0*/ __VdlyDim0__ps3103_ctrl_shadow__v0;
        CData/*0:0*/ __VdlySet__ps3103_ctrl_shadow__v0;
        CData/*1:0*/ __VdlyDim0__ps3103_scroll_x_shadow__v0;
        CData/*0:0*/ __VdlySet__ps3103_scroll_x_shadow__v0;
        CData/*1:0*/ __VdlyDim0__ps3103_scroll_y_shadow__v0;
        CData/*0:0*/ __VdlySet__ps3103_scroll_y_shadow__v0;
        CData/*1:0*/ __VdlyDim0__ps3103_tilemap_base_shadow__v0;
        CData/*0:0*/ __VdlySet__ps3103_tilemap_base_shadow__v0;
        CData/*1:0*/ __VdlyDim0__ps3103_tilemap_base_shadow__v1;
        CData/*0:0*/ __VdlySet__ps3103_tilemap_base_shadow__v1;
        CData/*0:0*/ __VdlySet__ps3103_ctrl_shadow__v1;
        CData/*0:0*/ __VdlySet__ps3103_ctrl_shadow__v2;
        CData/*0:0*/ __VdlySet__ps3103_ctrl_shadow__v3;
        CData/*0:0*/ __VdlySet__ps3103_ctrl_shadow__v4;
        CData/*7:0*/ __VdlyVal__ps3103_ctrl_active__v0;
        CData/*0:0*/ __VdlySet__ps3103_ctrl_active__v0;
        CData/*7:0*/ __VdlyVal__ps3103_ctrl_active__v1;
        CData/*0:0*/ __VdlySet__ps3103_ctrl_active__v1;
        CData/*7:0*/ __VdlyVal__ps3103_ctrl_active__v2;
        CData/*0:0*/ __VdlySet__ps3103_ctrl_active__v2;
        CData/*7:0*/ __VdlyVal__ps3103_ctrl_active__v3;
        CData/*0:0*/ __VdlySet__ps3103_ctrl_active__v3;
        CData/*0:0*/ __VdlySet__ps3103_ctrl_active__v4;
        CData/*0:0*/ __VdlySet__ps3103_ctrl_active__v5;
        CData/*0:0*/ __VdlySet__ps3103_ctrl_active__v6;
        CData/*0:0*/ __VdlySet__ps3103_ctrl_active__v7;
        CData/*7:0*/ __VdlyDim0__display_list_internal__v0;
        CData/*7:0*/ __VdlyDim0__display_list_internal__v1;
        CData/*7:0*/ __VdlyDim0__display_list_internal__v2;
        CData/*7:0*/ __VdlyDim0__display_list_internal__v3;
        CData/*7:0*/ __VdlyDim0__display_list_internal__v4;
        CData/*7:0*/ __VdlyDim0__display_list_internal__v5;
        CData/*7:0*/ __VdlyDim0__display_list_internal__v6;
        CData/*7:0*/ __VdlyDim0__display_list_internal__v7;
        CData/*7:0*/ __VdlyDim0__display_list_internal__v8;
        CData/*7:0*/ __VdlyDim0__display_list_internal__v9;
        CData/*7:0*/ __VdlyDim0__display_list_internal__v10;
        SData/*15:0*/ din;
        SData/*15:0*/ dout;
        SData/*15:0*/ spr_count;
        SData/*8:0*/ vsync_irq_line;
        SData/*8:0*/ hsync_irq_col;
        SData/*15:0*/ sprite_ram_addr;
        SData/*15:0*/ sprite_ram_din;
        SData/*15:0*/ __PVT__ps2001b_count_shadow;
        SData/*15:0*/ __PVT__ps2001b_count_active;
        SData/*8:0*/ __PVT__ps3305_vsync_irq_line_shadow;
        SData/*8:0*/ __PVT__ps3305_hsync_irq_col_shadow;
        SData/*8:0*/ __PVT__ps3305_vsync_irq_line_active;
        SData/*8:0*/ __PVT__ps3305_hsync_irq_col_active;
    };
    struct {
        SData/*15:0*/ __Vdly__ps2001b_count_shadow;
        SData/*8:0*/ __Vdly__ps3305_vsync_irq_line_shadow;
        SData/*8:0*/ __Vdly__ps3305_hsync_irq_col_shadow;
        SData/*15:0*/ __Vdly__ps2001b_count_active;
        SData/*8:0*/ __Vdly__ps3305_vsync_irq_line_active;
        SData/*8:0*/ __Vdly__ps3305_hsync_irq_col_active;
        SData/*15:0*/ __VdlyVal__ps3103_scroll_x_shadow__v0;
        SData/*15:0*/ __VdlyVal__ps3103_scroll_y_shadow__v0;
        SData/*15:0*/ __VdlyVal__ps3103_tilemap_base_shadow__v0;
        SData/*15:0*/ __VdlyVal__ps3103_tilemap_base_shadow__v1;
        SData/*15:0*/ __VdlyVal__ps3103_scroll_x_active__v0;
        SData/*15:0*/ __VdlyVal__ps3103_scroll_y_active__v0;
        SData/*15:0*/ __VdlyVal__ps3103_scroll_x_active__v1;
        SData/*15:0*/ __VdlyVal__ps3103_scroll_y_active__v1;
        SData/*15:0*/ __VdlyVal__ps3103_scroll_x_active__v2;
        SData/*15:0*/ __VdlyVal__ps3103_scroll_y_active__v2;
        SData/*15:0*/ __VdlyVal__ps3103_scroll_x_active__v3;
        SData/*15:0*/ __VdlyVal__ps3103_scroll_y_active__v3;
        IData/*22:0*/ addr;
        IData/*31:0*/ spr_table_base;
        IData/*31:0*/ sprite_ram_dout;
        IData/*31:0*/ __PVT__ps2001b_table_base_shadow;
        IData/*31:0*/ __PVT__ps2001b_table_base_active;
        IData/*31:0*/ __PVT__i;
        IData/*31:0*/ __PVT__unnamedblk1__DOT__i;
        IData/*31:0*/ __PVT__unnamedblk4__DOT__i;
        IData/*31:0*/ __PVT__unnamedblk3__DOT__i;
        IData/*31:0*/ __PVT__unnamedblk5__DOT__j;
        IData/*31:0*/ __Vdly__ps2001b_table_base_shadow;
        IData/*31:0*/ __Vdly__ps2001b_table_base_active;
        IData/*31:0*/ __VdlyVal__ps3103_tilemap_base_active__v0;
        IData/*31:0*/ __VdlyVal__ps3103_tilemap_base_active__v1;
        IData/*31:0*/ __VdlyVal__ps3103_tilemap_base_active__v2;
        IData/*31:0*/ __VdlyVal__ps3103_tilemap_base_active__v3;
        QData/*63:0*/ priority_table;
        QData/*63:0*/ __PVT__ps3305_priority_shadow;
        QData/*63:0*/ __PVT__ps3305_priority_active;
        QData/*63:0*/ __Vdly__ps3305_priority_shadow;
        QData/*63:0*/ __Vdly__ps3305_priority_active;
        VlUnpacked<SData/*9:0*/, 256> display_list_x;
        VlUnpacked<SData/*9:0*/, 256> display_list_y;
        VlUnpacked<SData/*15:0*/, 256> display_list_tile;
        VlUnpacked<CData/*3:0*/, 256> display_list_palette;
        VlUnpacked<CData/*0:0*/, 256> display_list_flip_x;
        VlUnpacked<CData/*0:0*/, 256> display_list_flip_y;
        VlUnpacked<CData/*1:0*/, 256> display_list_priority;
        VlUnpacked<CData/*2:0*/, 256> display_list_size;
        VlUnpacked<CData/*0:0*/, 256> display_list_valid;
        VlUnpacked<SData/*15:0*/, 4> bg_chr_bank;
        VlUnpacked<SData/*15:0*/, 4> bg_scroll_x;
        VlUnpacked<SData/*15:0*/, 4> bg_scroll_y;
        VlUnpacked<IData/*31:0*/, 4> bg_tilemap_base;
        VlUnpacked<CData/*7:0*/, 4> __PVT__ps3103_ctrl_shadow;
        VlUnpacked<SData/*15:0*/, 4> __PVT__ps3103_scroll_x_shadow;
        VlUnpacked<SData/*15:0*/, 4> __PVT__ps3103_scroll_y_shadow;
        VlUnpacked<IData/*31:0*/, 4> __PVT__ps3103_tilemap_base_shadow;
        VlUnpacked<CData/*7:0*/, 4> __PVT__ps3103_ctrl_active;
        VlUnpacked<SData/*15:0*/, 4> __PVT__ps3103_scroll_x_active;
        VlUnpacked<SData/*15:0*/, 4> __PVT__ps3103_scroll_y_active;
        VlUnpacked<IData/*31:0*/, 4> __PVT__ps3103_tilemap_base_active;
        VlUnpacked<QData/*47:0*/, 256> __PVT__display_list_internal;
    };
    VlNBACommitQueue<VlUnpacked<QData/*47:0*/, 256>, true, QData/*47:0*/, 1> __VdlyCommitQueuedisplay_list_internal;

    // INTERNAL VARIABLES
    Vpsikyo__Syms* vlSymsp;
    const char* vlNamep;

    // CONSTRUCTORS
    Vpsikyo_psikyo();
    ~Vpsikyo_psikyo();
    void ctor(Vpsikyo__Syms* symsp, const char* namep);
    void dtor();
    VL_UNCOPYABLE(Vpsikyo_psikyo);

    // INTERNAL METHODS
    void __Vconfigure(bool first);
};


#endif  // guard
