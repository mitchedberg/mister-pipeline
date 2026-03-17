// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design internal header
// See Vpsikyo.h for the primary calling header

#ifndef VERILATED_VPSIKYO___024ROOT_H_
#define VERILATED_VPSIKYO___024ROOT_H_  // guard

#include "verilated.h"
class Vpsikyo_psikyo;


class Vpsikyo__Syms;

class alignas(VL_CACHE_LINE_BYTES) Vpsikyo___024root final {
  public:
    // CELLS
    Vpsikyo_psikyo* __PVT__psikyo;

    // DESIGN SPECIFIC STATE
    // Anonymous structures to workaround compiler member-count bugs
    struct {
        VL_IN8(clk,0,0);
        VL_IN8(rst_n,0,0);
        VL_IN8(cs_n,0,0);
        VL_IN8(rd_n,0,0);
        VL_IN8(wr_n,0,0);
        VL_IN8(dsn,1,0);
        VL_IN8(vsync_n,0,0);
        VL_OUT8(nmi_n,0,0);
        VL_OUT8(irq1_n,0,0);
        VL_OUT8(irq2_n,0,0);
        VL_OUT8(irq3_n,0,0);
        VL_OUT8(spr_dma_enable,1,0);
        VL_OUT8(spr_render_enable,1,0);
        VL_OUT8(spr_mode,1,0);
        VL_OUT8(spr_palette_bank,1,0);
        VL_OUT8(spr_y_offset,7,0);
        VL_OUT8(display_list_count,7,0);
        VL_OUT8(display_list_ready,0,0);
        VL_OUT8(bg_enable,3,0);
        VL_OUT8(bg_tile_size,3,0);
        VL_OUT8(bg_priority,7,0);
        VL_OUT8(color_key_ctrl,7,0);
        VL_OUT8(color_key_color,7,0);
        VL_OUT8(color_key_mask,7,0);
        VL_OUT8(z80_busy,0,0);
        VL_OUT8(z80_irq_pending,0,0);
        VL_OUT8(z80_cmd_reply,7,0);
        VL_OUT8(sprite_ram_wsel,1,0);
        VL_OUT8(sprite_ram_wr_en,0,0);
        CData/*0:0*/ __VstlExecute;
        CData/*0:0*/ __VstlFirstIteration;
        CData/*0:0*/ __VstlPhaseResult;
        CData/*0:0*/ __VicoExecute;
        CData/*0:0*/ __VicoFirstIteration;
        CData/*0:0*/ __VicoPhaseResult;
        CData/*0:0*/ __Vtrigprevexpr___TOP__psikyo__clk__0;
        CData/*0:0*/ __Vtrigprevexpr___TOP__psikyo__rst_n__0;
        CData/*0:0*/ __VactFirstIteration;
        CData/*0:0*/ __VactPhaseResult;
        CData/*0:0*/ __VnbaExecute;
        CData/*0:0*/ __VnbaFirstIteration;
        CData/*0:0*/ __VnbaPhaseResult;
        VL_IN16(din,15,0);
        VL_OUT16(dout,15,0);
        VL_OUT16(spr_count,15,0);
        VL_OUT16(vsync_irq_line,8,0);
        VL_OUT16(hsync_irq_col,8,0);
        VL_OUT16(sprite_ram_addr,15,0);
        VL_OUT16(sprite_ram_din,15,0);
        VL_IN(addr,23,1);
        VL_OUT(spr_table_base,31,0);
        VL_IN(sprite_ram_dout,31,0);
        IData/*31:0*/ __VstlIterCount;
        IData/*31:0*/ __VicoIterCount;
        IData/*31:0*/ __VactIterCount;
        IData/*31:0*/ __VnbaIterCount;
        VL_OUT64(priority_table,63,0);
        VL_OUT16(display_list_x[256],9,0);
        VL_OUT16(display_list_y[256],9,0);
        VL_OUT16(display_list_tile[256],15,0);
        VL_OUT8(display_list_palette[256],3,0);
        VL_OUT8(display_list_flip_x[256],0,0);
        VL_OUT8(display_list_flip_y[256],0,0);
        VL_OUT8(display_list_priority[256],1,0);
    };
    struct {
        VL_OUT8(display_list_size[256],2,0);
        VL_OUT8(display_list_valid[256],0,0);
        VL_OUT16(bg_chr_bank[4],15,0);
        VL_OUT16(bg_scroll_x[4],15,0);
        VL_OUT16(bg_scroll_y[4],15,0);
        VL_OUT(bg_tilemap_base[4],31,0);
        VlUnpacked<QData/*63:0*/, 1> __VstlTriggered;
        VlUnpacked<QData/*63:0*/, 1> __VicoTriggered;
        VlUnpacked<QData/*63:0*/, 1> __VactTriggered;
        VlUnpacked<QData/*63:0*/, 1> __VnbaTriggered;
    };

    // INTERNAL VARIABLES
    Vpsikyo__Syms* vlSymsp;
    const char* vlNamep;

    // CONSTRUCTORS
    Vpsikyo___024root(Vpsikyo__Syms* symsp, const char* namep);
    ~Vpsikyo___024root();
    VL_UNCOPYABLE(Vpsikyo___024root);

    // INTERNAL METHODS
    void __Vconfigure(bool first);
};


#endif  // guard
