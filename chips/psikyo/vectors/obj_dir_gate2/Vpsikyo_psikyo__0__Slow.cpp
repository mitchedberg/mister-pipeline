// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vpsikyo.h for the primary calling header

#include "Vpsikyo__pch.h"

VL_ATTR_COLD void Vpsikyo_psikyo___eval_static__TOP__psikyo(Vpsikyo_psikyo* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+      Vpsikyo_psikyo___eval_static__TOP__psikyo\n"); );
    Vpsikyo__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    vlSelfRef.__PVT___unused_ctrl_active = VL_REDAND_II(4, 
                                                        (0x0000000fU 
                                                         & VL_SEL_IIII(8, (IData)(vlSelfRef.__PVT__ps2001b_ctrl_active), 0U, 4)));
    vlSelfRef.__PVT___unused_ps3204 = vlSelfRef.__PVT__cs_ps3204;
    vlSelfRef.__PVT___unused_cs_int = vlSelfRef.__PVT__cs_int;
    vlSelfRef.__PVT___unused_sprite_ram_dout = VL_REDOR_I(vlSelfRef.sprite_ram_dout);
    vlSelfRef.__PVT__write_strobe = (1U & ((~ (IData)(vlSelfRef.wr_n)) 
                                           & (~ (IData)(vlSelfRef.cs_n))));
    vlSelfRef.__PVT__read_strobe = (1U & ((~ (IData)(vlSelfRef.rd_n)) 
                                          & (~ (IData)(vlSelfRef.cs_n))));
    vlSelfRef.__PVT__unnamedblk2__DOT__layer_idx = 
        (3U & VL_SEL_IIII(23, vlSelfRef.addr, 3U, 2));
    vlSelfRef.__PVT__unnamedblk2__DOT__reg_offset = 
        (7U & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 3));
    vlSelfRef.__PVT__vsync_rising_edge = ((IData)(vlSelfRef.__PVT__vsync_n_r) 
                                          & (~ (IData)(vlSelfRef.vsync_n)));
    vlSelfRef.__PVT__unnamedblk6__DOT__layer_idx = 
        (3U & VL_SEL_IIII(23, vlSelfRef.addr, 3U, 2));
    vlSelfRef.__PVT__unnamedblk6__DOT__reg_offset = 
        (7U & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 3));
    vlSelfRef.__PVT___unused_dsn = 0U;
}

VL_ATTR_COLD void Vpsikyo_psikyo___eval_initial__TOP__psikyo(Vpsikyo_psikyo* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+      Vpsikyo_psikyo___eval_initial__TOP__psikyo\n"); );
    Vpsikyo__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    vlSelfRef.color_key_mask = 0xffU;
    vlSelfRef.nmi_n = 1U;
    vlSelfRef.irq1_n = 1U;
    vlSelfRef.irq2_n = 1U;
    vlSelfRef.irq3_n = 1U;
    vlSelfRef.sprite_ram_addr = 0U;
    vlSelfRef.sprite_ram_din = 0U;
    vlSelfRef.sprite_ram_wsel = 0U;
    vlSelfRef.sprite_ram_wr_en = 0U;
}

VL_ATTR_COLD void Vpsikyo_psikyo___stl_sequent__TOP__psikyo__0(Vpsikyo_psikyo* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+      Vpsikyo_psikyo___stl_sequent__TOP__psikyo__0\n"); );
    Vpsikyo__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
    vlSelfRef.spr_dma_enable = VL_CONCAT_III(2,1,1, 
                                             (1U & 
                                              VL_BITSEL_IIII(8, (IData)(vlSelfRef.__PVT__ps2001b_ctrl_active), 7U)), 0U);
    vlSelfRef.spr_render_enable = VL_CONCAT_III(2,1,1, 
                                                (1U 
                                                 & VL_BITSEL_IIII(8, (IData)(vlSelfRef.__PVT__ps2001b_ctrl_active), 6U)), 0U);
    vlSelfRef.spr_mode = VL_CONCAT_III(2,1,1, (1U & 
                                               VL_BITSEL_IIII(8, (IData)(vlSelfRef.__PVT__ps2001b_ctrl_active), 5U)), 0U);
    vlSelfRef.spr_palette_bank = VL_CONCAT_III(2,1,1, 
                                               (1U 
                                                & VL_BITSEL_IIII(8, (IData)(vlSelfRef.__PVT__ps2001b_ctrl_active), 4U)), 0U);
    vlSelfRef.spr_table_base = vlSelfRef.__PVT__ps2001b_table_base_active;
    vlSelfRef.spr_count = vlSelfRef.__PVT__ps2001b_count_active;
    vlSelfRef.spr_y_offset = vlSelfRef.__PVT__ps2001b_y_offset_active;
    vlSelfRef.bg_enable = VL_CONCAT_III(4,2,2, VL_CONCAT_III(2,1,1, 
                                                             (1U 
                                                              & VL_BITSEL_IIII(8, vlSelfRef.__PVT__ps3103_ctrl_active[3U], 7U)), 
                                                             (1U 
                                                              & VL_BITSEL_IIII(8, vlSelfRef.__PVT__ps3103_ctrl_active[2U], 7U))), 
                                        VL_CONCAT_III(2,1,1, 
                                                      (1U 
                                                       & VL_BITSEL_IIII(8, vlSelfRef.__PVT__ps3103_ctrl_active[1U], 7U)), 
                                                      (1U 
                                                       & VL_BITSEL_IIII(8, vlSelfRef.__PVT__ps3103_ctrl_active[0U], 7U))));
    vlSelfRef.bg_tile_size = VL_CONCAT_III(4,2,2, VL_CONCAT_III(2,1,1, 
                                                                (1U 
                                                                 & VL_BITSEL_IIII(8, vlSelfRef.__PVT__ps3103_ctrl_active[3U], 6U)), 
                                                                (1U 
                                                                 & VL_BITSEL_IIII(8, vlSelfRef.__PVT__ps3103_ctrl_active[2U], 6U))), 
                                           VL_CONCAT_III(2,1,1, 
                                                         (1U 
                                                          & VL_BITSEL_IIII(8, vlSelfRef.__PVT__ps3103_ctrl_active[1U], 6U)), 
                                                         (1U 
                                                          & VL_BITSEL_IIII(8, vlSelfRef.__PVT__ps3103_ctrl_active[0U], 6U))));
    vlSelfRef.bg_priority = VL_CONCAT_III(8,4,4, VL_CONCAT_III(4,2,2, 
                                                               (3U 
                                                                & VL_SEL_IIII(8, vlSelfRef.__PVT__ps3103_ctrl_active[3U], 4U, 2)), 
                                                               (3U 
                                                                & VL_SEL_IIII(8, vlSelfRef.__PVT__ps3103_ctrl_active[2U], 4U, 2))), 
                                          VL_CONCAT_III(4,2,2, 
                                                        (3U 
                                                         & VL_SEL_IIII(8, vlSelfRef.__PVT__ps3103_ctrl_active[1U], 4U, 2)), 
                                                        (3U 
                                                         & VL_SEL_IIII(8, vlSelfRef.__PVT__ps3103_ctrl_active[0U], 4U, 2))));
    vlSelfRef.priority_table = vlSelfRef.__PVT__ps3305_priority_active;
    vlSelfRef.color_key_ctrl = vlSelfRef.__PVT__ps3305_color_key_ctrl_active;
    vlSelfRef.color_key_color = vlSelfRef.__PVT__ps3305_color_key_active;
    vlSelfRef.vsync_irq_line = vlSelfRef.__PVT__ps3305_vsync_irq_line_active;
    vlSelfRef.hsync_irq_col = vlSelfRef.__PVT__ps3305_hsync_irq_col_active;
    vlSelfRef.z80_busy = (1U & VL_BITSEL_IIII(8, (IData)(vlSelfRef.__PVT__z80_status_reg), 7U));
    vlSelfRef.z80_irq_pending = (1U & VL_BITSEL_IIII(8, (IData)(vlSelfRef.__PVT__z80_status_reg), 6U));
    vlSelfRef.z80_cmd_reply = vlSelfRef.__PVT__z80_cmd_reply_reg;
    vlSelfRef.display_list_count = vlSelfRef.__PVT__display_list_count_internal;
    vlSelfRef.display_list_ready = vlSelfRef.__PVT__display_list_ready_internal;
    vlSelfRef.bg_chr_bank[0U] = VL_EXTEND_II(16,4, 
                                             (0x0000000fU 
                                              & VL_SEL_IIII(8, vlSelfRef.__PVT__ps3103_ctrl_active[0U], 0U, 4)));
    vlSelfRef.bg_chr_bank[1U] = VL_EXTEND_II(16,4, 
                                             (0x0000000fU 
                                              & VL_SEL_IIII(8, vlSelfRef.__PVT__ps3103_ctrl_active[1U], 0U, 4)));
    vlSelfRef.bg_chr_bank[2U] = VL_EXTEND_II(16,4, 
                                             (0x0000000fU 
                                              & VL_SEL_IIII(8, vlSelfRef.__PVT__ps3103_ctrl_active[2U], 0U, 4)));
    vlSelfRef.bg_chr_bank[3U] = VL_EXTEND_II(16,4, 
                                             (0x0000000fU 
                                              & VL_SEL_IIII(8, vlSelfRef.__PVT__ps3103_ctrl_active[3U], 0U, 4)));
    vlSelfRef.bg_scroll_x[0U] = vlSelfRef.__PVT__ps3103_scroll_x_active[0U];
    vlSelfRef.bg_scroll_x[1U] = vlSelfRef.__PVT__ps3103_scroll_x_active[1U];
    vlSelfRef.bg_scroll_x[2U] = vlSelfRef.__PVT__ps3103_scroll_x_active[2U];
    vlSelfRef.bg_scroll_x[3U] = vlSelfRef.__PVT__ps3103_scroll_x_active[3U];
    vlSelfRef.bg_scroll_y[0U] = vlSelfRef.__PVT__ps3103_scroll_y_active[0U];
    vlSelfRef.bg_scroll_y[1U] = vlSelfRef.__PVT__ps3103_scroll_y_active[1U];
    vlSelfRef.bg_scroll_y[2U] = vlSelfRef.__PVT__ps3103_scroll_y_active[2U];
    vlSelfRef.bg_scroll_y[3U] = vlSelfRef.__PVT__ps3103_scroll_y_active[3U];
    vlSelfRef.bg_tilemap_base[0U] = vlSelfRef.__PVT__ps3103_tilemap_base_active[0U];
    vlSelfRef.bg_tilemap_base[1U] = vlSelfRef.__PVT__ps3103_tilemap_base_active[1U];
    vlSelfRef.bg_tilemap_base[2U] = vlSelfRef.__PVT__ps3103_tilemap_base_active[2U];
    vlSelfRef.bg_tilemap_base[3U] = vlSelfRef.__PVT__ps3103_tilemap_base_active[3U];
    vlSelfRef.display_list_x[0U] = (0x000003ffU & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[0U], 0x00000026U, 10));
    vlSelfRef.display_list_y[0U] = (0x000003ffU & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[0U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[0U] = (0x0000ffffU 
                                       & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[0U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[0U] = (0x0000000fU 
                                          & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[0U], 1U, 4));
    vlSelfRef.display_list_flip_x[0U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[0U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[0U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[0U], 0x0000000aU));
    vlSelfRef.display_list_priority[0U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[0U], 8U, 2));
    vlSelfRef.display_list_size[0U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[0U], 5U, 3));
    vlSelfRef.display_list_valid[0U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[0U], 0U));
    vlSelfRef.display_list_x[1U] = (0x000003ffU & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[1U], 0x00000026U, 10));
    vlSelfRef.display_list_y[1U] = (0x000003ffU & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[1U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[1U] = (0x0000ffffU 
                                       & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[1U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[1U] = (0x0000000fU 
                                          & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[1U], 1U, 4));
    vlSelfRef.display_list_flip_x[1U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[1U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[1U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[1U], 0x0000000aU));
    vlSelfRef.display_list_priority[1U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[1U], 8U, 2));
    vlSelfRef.display_list_size[1U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[1U], 5U, 3));
    vlSelfRef.display_list_valid[1U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[1U], 0U));
    vlSelfRef.display_list_x[2U] = (0x000003ffU & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[2U], 0x00000026U, 10));
    vlSelfRef.display_list_y[2U] = (0x000003ffU & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[2U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[2U] = (0x0000ffffU 
                                       & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[2U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[2U] = (0x0000000fU 
                                          & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[2U], 1U, 4));
    vlSelfRef.display_list_flip_x[2U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[2U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[2U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[2U], 0x0000000aU));
    vlSelfRef.display_list_priority[2U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[2U], 8U, 2));
    vlSelfRef.display_list_size[2U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[2U], 5U, 3));
    vlSelfRef.display_list_valid[2U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[2U], 0U));
    vlSelfRef.display_list_x[3U] = (0x000003ffU & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[3U], 0x00000026U, 10));
    vlSelfRef.display_list_y[3U] = (0x000003ffU & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[3U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[3U] = (0x0000ffffU 
                                       & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[3U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[3U] = (0x0000000fU 
                                          & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[3U], 1U, 4));
    vlSelfRef.display_list_flip_x[3U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[3U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[3U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[3U], 0x0000000aU));
    vlSelfRef.display_list_priority[3U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[3U], 8U, 2));
    vlSelfRef.display_list_size[3U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[3U], 5U, 3));
    vlSelfRef.display_list_valid[3U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[3U], 0U));
    vlSelfRef.display_list_x[4U] = (0x000003ffU & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[4U], 0x00000026U, 10));
    vlSelfRef.display_list_y[4U] = (0x000003ffU & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[4U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[4U] = (0x0000ffffU 
                                       & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[4U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[4U] = (0x0000000fU 
                                          & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[4U], 1U, 4));
    vlSelfRef.display_list_flip_x[4U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[4U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[4U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[4U], 0x0000000aU));
    vlSelfRef.display_list_priority[4U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[4U], 8U, 2));
    vlSelfRef.display_list_size[4U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[4U], 5U, 3));
    vlSelfRef.display_list_valid[4U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[4U], 0U));
    vlSelfRef.display_list_x[5U] = (0x000003ffU & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[5U], 0x00000026U, 10));
    vlSelfRef.display_list_y[5U] = (0x000003ffU & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[5U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[5U] = (0x0000ffffU 
                                       & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[5U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[5U] = (0x0000000fU 
                                          & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[5U], 1U, 4));
    vlSelfRef.display_list_flip_x[5U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[5U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[5U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[5U], 0x0000000aU));
    vlSelfRef.display_list_priority[5U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[5U], 8U, 2));
    vlSelfRef.display_list_size[5U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[5U], 5U, 3));
    vlSelfRef.display_list_valid[5U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[5U], 0U));
    vlSelfRef.display_list_x[6U] = (0x000003ffU & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[6U], 0x00000026U, 10));
    vlSelfRef.display_list_y[6U] = (0x000003ffU & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[6U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[6U] = (0x0000ffffU 
                                       & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[6U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[6U] = (0x0000000fU 
                                          & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[6U], 1U, 4));
    vlSelfRef.display_list_flip_x[6U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[6U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[6U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[6U], 0x0000000aU));
    vlSelfRef.display_list_priority[6U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[6U], 8U, 2));
    vlSelfRef.display_list_size[6U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[6U], 5U, 3));
    vlSelfRef.display_list_valid[6U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[6U], 0U));
    vlSelfRef.display_list_x[7U] = (0x000003ffU & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[7U], 0x00000026U, 10));
    vlSelfRef.display_list_y[7U] = (0x000003ffU & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[7U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[7U] = (0x0000ffffU 
                                       & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[7U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[7U] = (0x0000000fU 
                                          & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[7U], 1U, 4));
    vlSelfRef.display_list_flip_x[7U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[7U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[7U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[7U], 0x0000000aU));
    vlSelfRef.display_list_priority[7U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[7U], 8U, 2));
    vlSelfRef.display_list_size[7U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[7U], 5U, 3));
    vlSelfRef.display_list_valid[7U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[7U], 0U));
    vlSelfRef.display_list_x[8U] = (0x000003ffU & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[8U], 0x00000026U, 10));
    vlSelfRef.display_list_y[8U] = (0x000003ffU & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[8U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[8U] = (0x0000ffffU 
                                       & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[8U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[8U] = (0x0000000fU 
                                          & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[8U], 1U, 4));
    vlSelfRef.display_list_flip_x[8U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[8U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[8U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[8U], 0x0000000aU));
    vlSelfRef.display_list_priority[8U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[8U], 8U, 2));
    vlSelfRef.display_list_size[8U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[8U], 5U, 3));
    vlSelfRef.display_list_valid[8U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[8U], 0U));
    vlSelfRef.display_list_x[9U] = (0x000003ffU & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[9U], 0x00000026U, 10));
    vlSelfRef.display_list_y[9U] = (0x000003ffU & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[9U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[9U] = (0x0000ffffU 
                                       & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[9U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[9U] = (0x0000000fU 
                                          & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[9U], 1U, 4));
    vlSelfRef.display_list_flip_x[9U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[9U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[9U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[9U], 0x0000000aU));
    vlSelfRef.display_list_priority[9U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[9U], 8U, 2));
    vlSelfRef.display_list_size[9U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[9U], 5U, 3));
    vlSelfRef.display_list_valid[9U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[9U], 0U));
    vlSelfRef.display_list_x[10U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[10U], 0x00000026U, 10));
    vlSelfRef.display_list_y[10U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[10U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[10U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[10U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[10U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[10U], 1U, 4));
    vlSelfRef.display_list_flip_x[10U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[10U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[10U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[10U], 0x0000000aU));
    vlSelfRef.display_list_priority[10U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[10U], 8U, 2));
    vlSelfRef.display_list_size[10U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[10U], 5U, 3));
    vlSelfRef.display_list_valid[10U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[10U], 0U));
    vlSelfRef.display_list_x[11U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[11U], 0x00000026U, 10));
    vlSelfRef.display_list_y[11U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[11U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[11U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[11U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[11U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[11U], 1U, 4));
    vlSelfRef.display_list_flip_x[11U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[11U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[11U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[11U], 0x0000000aU));
    vlSelfRef.display_list_priority[11U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[11U], 8U, 2));
    vlSelfRef.display_list_size[11U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[11U], 5U, 3));
    vlSelfRef.display_list_valid[11U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[11U], 0U));
    vlSelfRef.display_list_x[12U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[12U], 0x00000026U, 10));
    vlSelfRef.display_list_y[12U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[12U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[12U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[12U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[12U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[12U], 1U, 4));
    vlSelfRef.display_list_flip_x[12U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[12U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[12U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[12U], 0x0000000aU));
    vlSelfRef.display_list_priority[12U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[12U], 8U, 2));
    vlSelfRef.display_list_size[12U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[12U], 5U, 3));
    vlSelfRef.display_list_valid[12U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[12U], 0U));
    vlSelfRef.display_list_x[13U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[13U], 0x00000026U, 10));
    vlSelfRef.display_list_y[13U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[13U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[13U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[13U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[13U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[13U], 1U, 4));
    vlSelfRef.display_list_flip_x[13U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[13U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[13U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[13U], 0x0000000aU));
    vlSelfRef.display_list_priority[13U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[13U], 8U, 2));
    vlSelfRef.display_list_size[13U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[13U], 5U, 3));
    vlSelfRef.display_list_valid[13U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[13U], 0U));
    vlSelfRef.display_list_x[14U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[14U], 0x00000026U, 10));
    vlSelfRef.display_list_y[14U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[14U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[14U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[14U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[14U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[14U], 1U, 4));
    vlSelfRef.display_list_flip_x[14U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[14U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[14U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[14U], 0x0000000aU));
    vlSelfRef.display_list_priority[14U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[14U], 8U, 2));
    vlSelfRef.display_list_size[14U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[14U], 5U, 3));
    vlSelfRef.display_list_valid[14U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[14U], 0U));
    vlSelfRef.display_list_x[15U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[15U], 0x00000026U, 10));
    vlSelfRef.display_list_y[15U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[15U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[15U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[15U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[15U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[15U], 1U, 4));
    vlSelfRef.display_list_flip_x[15U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[15U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[15U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[15U], 0x0000000aU));
    vlSelfRef.display_list_priority[15U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[15U], 8U, 2));
    vlSelfRef.display_list_size[15U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[15U], 5U, 3));
    vlSelfRef.display_list_valid[15U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[15U], 0U));
    vlSelfRef.display_list_x[16U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[16U], 0x00000026U, 10));
    vlSelfRef.display_list_y[16U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[16U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[16U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[16U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[16U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[16U], 1U, 4));
    vlSelfRef.display_list_flip_x[16U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[16U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[16U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[16U], 0x0000000aU));
    vlSelfRef.display_list_priority[16U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[16U], 8U, 2));
    vlSelfRef.display_list_size[16U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[16U], 5U, 3));
    vlSelfRef.display_list_valid[16U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[16U], 0U));
    vlSelfRef.display_list_x[17U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[17U], 0x00000026U, 10));
    vlSelfRef.display_list_y[17U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[17U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[17U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[17U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[17U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[17U], 1U, 4));
    vlSelfRef.display_list_flip_x[17U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[17U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[17U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[17U], 0x0000000aU));
    vlSelfRef.display_list_priority[17U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[17U], 8U, 2));
    vlSelfRef.display_list_size[17U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[17U], 5U, 3));
    vlSelfRef.display_list_valid[17U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[17U], 0U));
    vlSelfRef.display_list_x[18U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[18U], 0x00000026U, 10));
    vlSelfRef.display_list_y[18U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[18U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[18U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[18U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[18U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[18U], 1U, 4));
    vlSelfRef.display_list_flip_x[18U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[18U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[18U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[18U], 0x0000000aU));
    vlSelfRef.display_list_priority[18U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[18U], 8U, 2));
    vlSelfRef.display_list_size[18U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[18U], 5U, 3));
    vlSelfRef.display_list_valid[18U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[18U], 0U));
    vlSelfRef.display_list_x[19U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[19U], 0x00000026U, 10));
    vlSelfRef.display_list_y[19U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[19U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[19U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[19U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[19U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[19U], 1U, 4));
    vlSelfRef.display_list_flip_x[19U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[19U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[19U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[19U], 0x0000000aU));
    vlSelfRef.display_list_priority[19U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[19U], 8U, 2));
    vlSelfRef.display_list_size[19U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[19U], 5U, 3));
    vlSelfRef.display_list_valid[19U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[19U], 0U));
    vlSelfRef.display_list_x[20U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[20U], 0x00000026U, 10));
    vlSelfRef.display_list_y[20U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[20U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[20U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[20U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[20U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[20U], 1U, 4));
    vlSelfRef.display_list_flip_x[20U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[20U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[20U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[20U], 0x0000000aU));
    vlSelfRef.display_list_priority[20U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[20U], 8U, 2));
    vlSelfRef.display_list_size[20U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[20U], 5U, 3));
    vlSelfRef.display_list_valid[20U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[20U], 0U));
    vlSelfRef.display_list_x[21U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[21U], 0x00000026U, 10));
    vlSelfRef.display_list_y[21U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[21U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[21U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[21U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[21U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[21U], 1U, 4));
    vlSelfRef.display_list_flip_x[21U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[21U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[21U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[21U], 0x0000000aU));
    vlSelfRef.display_list_priority[21U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[21U], 8U, 2));
    vlSelfRef.display_list_size[21U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[21U], 5U, 3));
    vlSelfRef.display_list_valid[21U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[21U], 0U));
    vlSelfRef.display_list_x[22U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[22U], 0x00000026U, 10));
    vlSelfRef.display_list_y[22U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[22U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[22U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[22U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[22U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[22U], 1U, 4));
    vlSelfRef.display_list_flip_x[22U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[22U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[22U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[22U], 0x0000000aU));
    vlSelfRef.display_list_priority[22U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[22U], 8U, 2));
    vlSelfRef.display_list_size[22U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[22U], 5U, 3));
    vlSelfRef.display_list_valid[22U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[22U], 0U));
    vlSelfRef.display_list_x[23U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[23U], 0x00000026U, 10));
    vlSelfRef.display_list_y[23U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[23U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[23U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[23U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[23U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[23U], 1U, 4));
    vlSelfRef.display_list_flip_x[23U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[23U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[23U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[23U], 0x0000000aU));
    vlSelfRef.display_list_priority[23U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[23U], 8U, 2));
    vlSelfRef.display_list_size[23U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[23U], 5U, 3));
    vlSelfRef.display_list_valid[23U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[23U], 0U));
    vlSelfRef.display_list_x[24U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[24U], 0x00000026U, 10));
    vlSelfRef.display_list_y[24U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[24U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[24U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[24U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[24U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[24U], 1U, 4));
    vlSelfRef.display_list_flip_x[24U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[24U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[24U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[24U], 0x0000000aU));
    vlSelfRef.display_list_priority[24U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[24U], 8U, 2));
    vlSelfRef.display_list_size[24U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[24U], 5U, 3));
    vlSelfRef.display_list_valid[24U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[24U], 0U));
    vlSelfRef.display_list_x[25U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[25U], 0x00000026U, 10));
    vlSelfRef.display_list_y[25U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[25U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[25U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[25U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[25U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[25U], 1U, 4));
    vlSelfRef.display_list_flip_x[25U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[25U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[25U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[25U], 0x0000000aU));
    vlSelfRef.display_list_priority[25U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[25U], 8U, 2));
    vlSelfRef.display_list_size[25U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[25U], 5U, 3));
    vlSelfRef.display_list_valid[25U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[25U], 0U));
    vlSelfRef.display_list_x[26U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[26U], 0x00000026U, 10));
    vlSelfRef.display_list_y[26U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[26U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[26U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[26U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[26U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[26U], 1U, 4));
    vlSelfRef.display_list_flip_x[26U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[26U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[26U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[26U], 0x0000000aU));
    vlSelfRef.display_list_priority[26U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[26U], 8U, 2));
    vlSelfRef.display_list_size[26U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[26U], 5U, 3));
    vlSelfRef.display_list_valid[26U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[26U], 0U));
    vlSelfRef.display_list_x[27U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[27U], 0x00000026U, 10));
    vlSelfRef.display_list_y[27U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[27U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[27U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[27U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[27U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[27U], 1U, 4));
    vlSelfRef.display_list_flip_x[27U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[27U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[27U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[27U], 0x0000000aU));
    vlSelfRef.display_list_priority[27U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[27U], 8U, 2));
    vlSelfRef.display_list_size[27U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[27U], 5U, 3));
    vlSelfRef.display_list_valid[27U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[27U], 0U));
    vlSelfRef.display_list_x[28U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[28U], 0x00000026U, 10));
    vlSelfRef.display_list_y[28U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[28U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[28U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[28U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[28U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[28U], 1U, 4));
    vlSelfRef.display_list_flip_x[28U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[28U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[28U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[28U], 0x0000000aU));
    vlSelfRef.display_list_priority[28U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[28U], 8U, 2));
    vlSelfRef.display_list_size[28U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[28U], 5U, 3));
    vlSelfRef.display_list_valid[28U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[28U], 0U));
    vlSelfRef.display_list_x[29U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[29U], 0x00000026U, 10));
    vlSelfRef.display_list_y[29U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[29U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[29U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[29U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[29U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[29U], 1U, 4));
    vlSelfRef.display_list_flip_x[29U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[29U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[29U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[29U], 0x0000000aU));
    vlSelfRef.display_list_priority[29U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[29U], 8U, 2));
    vlSelfRef.display_list_size[29U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[29U], 5U, 3));
    vlSelfRef.display_list_valid[29U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[29U], 0U));
    vlSelfRef.display_list_x[30U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[30U], 0x00000026U, 10));
    vlSelfRef.display_list_y[30U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[30U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[30U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[30U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[30U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[30U], 1U, 4));
    vlSelfRef.display_list_flip_x[30U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[30U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[30U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[30U], 0x0000000aU));
    vlSelfRef.display_list_priority[30U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[30U], 8U, 2));
    vlSelfRef.display_list_size[30U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[30U], 5U, 3));
    vlSelfRef.display_list_valid[30U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[30U], 0U));
    vlSelfRef.display_list_x[31U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[31U], 0x00000026U, 10));
    vlSelfRef.display_list_y[31U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[31U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[31U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[31U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[31U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[31U], 1U, 4));
    vlSelfRef.display_list_flip_x[31U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[31U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[31U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[31U], 0x0000000aU));
    vlSelfRef.display_list_priority[31U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[31U], 8U, 2));
    vlSelfRef.display_list_size[31U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[31U], 5U, 3));
    vlSelfRef.display_list_valid[31U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[31U], 0U));
    vlSelfRef.display_list_x[32U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[32U], 0x00000026U, 10));
    vlSelfRef.display_list_y[32U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[32U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[32U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[32U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[32U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[32U], 1U, 4));
    vlSelfRef.display_list_flip_x[32U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[32U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[32U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[32U], 0x0000000aU));
    vlSelfRef.display_list_priority[32U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[32U], 8U, 2));
    vlSelfRef.display_list_size[32U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[32U], 5U, 3));
    vlSelfRef.display_list_valid[32U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[32U], 0U));
    vlSelfRef.display_list_x[33U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[33U], 0x00000026U, 10));
    vlSelfRef.display_list_y[33U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[33U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[33U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[33U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[33U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[33U], 1U, 4));
    vlSelfRef.display_list_flip_x[33U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[33U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[33U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[33U], 0x0000000aU));
    vlSelfRef.display_list_priority[33U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[33U], 8U, 2));
    vlSelfRef.display_list_size[33U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[33U], 5U, 3));
    vlSelfRef.display_list_valid[33U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[33U], 0U));
    vlSelfRef.display_list_x[34U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[34U], 0x00000026U, 10));
    vlSelfRef.display_list_y[34U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[34U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[34U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[34U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[34U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[34U], 1U, 4));
    vlSelfRef.display_list_flip_x[34U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[34U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[34U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[34U], 0x0000000aU));
    vlSelfRef.display_list_priority[34U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[34U], 8U, 2));
    vlSelfRef.display_list_size[34U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[34U], 5U, 3));
    vlSelfRef.display_list_valid[34U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[34U], 0U));
    vlSelfRef.display_list_x[35U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[35U], 0x00000026U, 10));
    vlSelfRef.display_list_y[35U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[35U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[35U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[35U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[35U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[35U], 1U, 4));
    vlSelfRef.display_list_flip_x[35U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[35U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[35U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[35U], 0x0000000aU));
    vlSelfRef.display_list_priority[35U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[35U], 8U, 2));
    vlSelfRef.display_list_size[35U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[35U], 5U, 3));
    vlSelfRef.display_list_valid[35U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[35U], 0U));
    vlSelfRef.display_list_x[36U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[36U], 0x00000026U, 10));
    vlSelfRef.display_list_y[36U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[36U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[36U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[36U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[36U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[36U], 1U, 4));
    vlSelfRef.display_list_flip_x[36U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[36U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[36U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[36U], 0x0000000aU));
    vlSelfRef.display_list_priority[36U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[36U], 8U, 2));
    vlSelfRef.display_list_size[36U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[36U], 5U, 3));
    vlSelfRef.display_list_valid[36U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[36U], 0U));
    vlSelfRef.display_list_x[37U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[37U], 0x00000026U, 10));
    vlSelfRef.display_list_y[37U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[37U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[37U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[37U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[37U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[37U], 1U, 4));
    vlSelfRef.display_list_flip_x[37U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[37U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[37U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[37U], 0x0000000aU));
    vlSelfRef.display_list_priority[37U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[37U], 8U, 2));
    vlSelfRef.display_list_size[37U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[37U], 5U, 3));
    vlSelfRef.display_list_valid[37U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[37U], 0U));
    vlSelfRef.display_list_x[38U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[38U], 0x00000026U, 10));
    vlSelfRef.display_list_y[38U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[38U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[38U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[38U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[38U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[38U], 1U, 4));
    vlSelfRef.display_list_flip_x[38U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[38U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[38U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[38U], 0x0000000aU));
    vlSelfRef.display_list_priority[38U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[38U], 8U, 2));
    vlSelfRef.display_list_size[38U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[38U], 5U, 3));
    vlSelfRef.display_list_valid[38U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[38U], 0U));
    vlSelfRef.display_list_x[39U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[39U], 0x00000026U, 10));
    vlSelfRef.display_list_y[39U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[39U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[39U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[39U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[39U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[39U], 1U, 4));
    vlSelfRef.display_list_flip_x[39U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[39U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[39U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[39U], 0x0000000aU));
    vlSelfRef.display_list_priority[39U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[39U], 8U, 2));
    vlSelfRef.display_list_size[39U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[39U], 5U, 3));
    vlSelfRef.display_list_valid[39U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[39U], 0U));
    vlSelfRef.display_list_x[40U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[40U], 0x00000026U, 10));
    vlSelfRef.display_list_y[40U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[40U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[40U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[40U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[40U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[40U], 1U, 4));
    vlSelfRef.display_list_flip_x[40U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[40U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[40U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[40U], 0x0000000aU));
    vlSelfRef.display_list_priority[40U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[40U], 8U, 2));
    vlSelfRef.display_list_size[40U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[40U], 5U, 3));
    vlSelfRef.display_list_valid[40U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[40U], 0U));
    vlSelfRef.display_list_x[41U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[41U], 0x00000026U, 10));
    vlSelfRef.display_list_y[41U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[41U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[41U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[41U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[41U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[41U], 1U, 4));
    vlSelfRef.display_list_flip_x[41U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[41U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[41U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[41U], 0x0000000aU));
    vlSelfRef.display_list_priority[41U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[41U], 8U, 2));
    vlSelfRef.display_list_size[41U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[41U], 5U, 3));
    vlSelfRef.display_list_valid[41U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[41U], 0U));
    vlSelfRef.display_list_x[42U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[42U], 0x00000026U, 10));
    vlSelfRef.display_list_y[42U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[42U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[42U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[42U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[42U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[42U], 1U, 4));
    vlSelfRef.display_list_flip_x[42U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[42U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[42U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[42U], 0x0000000aU));
    vlSelfRef.display_list_priority[42U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[42U], 8U, 2));
    vlSelfRef.display_list_size[42U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[42U], 5U, 3));
    vlSelfRef.display_list_valid[42U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[42U], 0U));
    vlSelfRef.display_list_x[43U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[43U], 0x00000026U, 10));
    vlSelfRef.display_list_y[43U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[43U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[43U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[43U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[43U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[43U], 1U, 4));
    vlSelfRef.display_list_flip_x[43U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[43U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[43U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[43U], 0x0000000aU));
    vlSelfRef.display_list_priority[43U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[43U], 8U, 2));
    vlSelfRef.display_list_size[43U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[43U], 5U, 3));
    vlSelfRef.display_list_valid[43U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[43U], 0U));
    vlSelfRef.display_list_x[44U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[44U], 0x00000026U, 10));
    vlSelfRef.display_list_y[44U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[44U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[44U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[44U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[44U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[44U], 1U, 4));
    vlSelfRef.display_list_flip_x[44U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[44U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[44U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[44U], 0x0000000aU));
    vlSelfRef.display_list_priority[44U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[44U], 8U, 2));
    vlSelfRef.display_list_size[44U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[44U], 5U, 3));
    vlSelfRef.display_list_valid[44U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[44U], 0U));
    vlSelfRef.display_list_x[45U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[45U], 0x00000026U, 10));
    vlSelfRef.display_list_y[45U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[45U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[45U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[45U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[45U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[45U], 1U, 4));
    vlSelfRef.display_list_flip_x[45U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[45U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[45U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[45U], 0x0000000aU));
    vlSelfRef.display_list_priority[45U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[45U], 8U, 2));
    vlSelfRef.display_list_size[45U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[45U], 5U, 3));
    vlSelfRef.display_list_valid[45U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[45U], 0U));
    vlSelfRef.display_list_x[46U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[46U], 0x00000026U, 10));
    vlSelfRef.display_list_y[46U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[46U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[46U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[46U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[46U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[46U], 1U, 4));
    vlSelfRef.display_list_flip_x[46U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[46U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[46U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[46U], 0x0000000aU));
    vlSelfRef.display_list_priority[46U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[46U], 8U, 2));
    vlSelfRef.display_list_size[46U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[46U], 5U, 3));
    vlSelfRef.display_list_valid[46U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[46U], 0U));
    vlSelfRef.display_list_x[47U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[47U], 0x00000026U, 10));
    vlSelfRef.display_list_y[47U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[47U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[47U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[47U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[47U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[47U], 1U, 4));
    vlSelfRef.display_list_flip_x[47U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[47U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[47U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[47U], 0x0000000aU));
    vlSelfRef.display_list_priority[47U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[47U], 8U, 2));
    vlSelfRef.display_list_size[47U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[47U], 5U, 3));
    vlSelfRef.display_list_valid[47U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[47U], 0U));
    vlSelfRef.display_list_x[48U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[48U], 0x00000026U, 10));
    vlSelfRef.display_list_y[48U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[48U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[48U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[48U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[48U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[48U], 1U, 4));
    vlSelfRef.display_list_flip_x[48U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[48U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[48U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[48U], 0x0000000aU));
    vlSelfRef.display_list_priority[48U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[48U], 8U, 2));
    vlSelfRef.display_list_size[48U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[48U], 5U, 3));
    vlSelfRef.display_list_valid[48U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[48U], 0U));
    vlSelfRef.display_list_x[49U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[49U], 0x00000026U, 10));
    vlSelfRef.display_list_y[49U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[49U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[49U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[49U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[49U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[49U], 1U, 4));
    vlSelfRef.display_list_flip_x[49U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[49U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[49U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[49U], 0x0000000aU));
    vlSelfRef.display_list_priority[49U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[49U], 8U, 2));
    vlSelfRef.display_list_size[49U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[49U], 5U, 3));
    vlSelfRef.display_list_valid[49U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[49U], 0U));
    vlSelfRef.display_list_x[50U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[50U], 0x00000026U, 10));
    vlSelfRef.display_list_y[50U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[50U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[50U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[50U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[50U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[50U], 1U, 4));
    vlSelfRef.display_list_flip_x[50U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[50U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[50U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[50U], 0x0000000aU));
    vlSelfRef.display_list_priority[50U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[50U], 8U, 2));
    vlSelfRef.display_list_size[50U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[50U], 5U, 3));
    vlSelfRef.display_list_valid[50U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[50U], 0U));
    vlSelfRef.display_list_x[51U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[51U], 0x00000026U, 10));
    vlSelfRef.display_list_y[51U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[51U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[51U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[51U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[51U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[51U], 1U, 4));
    vlSelfRef.display_list_flip_x[51U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[51U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[51U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[51U], 0x0000000aU));
    vlSelfRef.display_list_priority[51U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[51U], 8U, 2));
    vlSelfRef.display_list_size[51U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[51U], 5U, 3));
    vlSelfRef.display_list_valid[51U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[51U], 0U));
    vlSelfRef.display_list_x[52U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[52U], 0x00000026U, 10));
    vlSelfRef.display_list_y[52U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[52U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[52U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[52U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[52U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[52U], 1U, 4));
    vlSelfRef.display_list_flip_x[52U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[52U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[52U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[52U], 0x0000000aU));
    vlSelfRef.display_list_priority[52U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[52U], 8U, 2));
    vlSelfRef.display_list_size[52U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[52U], 5U, 3));
    vlSelfRef.display_list_valid[52U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[52U], 0U));
    vlSelfRef.display_list_x[53U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[53U], 0x00000026U, 10));
    vlSelfRef.display_list_y[53U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[53U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[53U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[53U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[53U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[53U], 1U, 4));
    vlSelfRef.display_list_flip_x[53U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[53U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[53U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[53U], 0x0000000aU));
    vlSelfRef.display_list_priority[53U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[53U], 8U, 2));
    vlSelfRef.display_list_size[53U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[53U], 5U, 3));
    vlSelfRef.display_list_valid[53U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[53U], 0U));
    vlSelfRef.display_list_x[54U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[54U], 0x00000026U, 10));
    vlSelfRef.display_list_y[54U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[54U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[54U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[54U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[54U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[54U], 1U, 4));
    vlSelfRef.display_list_flip_x[54U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[54U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[54U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[54U], 0x0000000aU));
    vlSelfRef.display_list_priority[54U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[54U], 8U, 2));
    vlSelfRef.display_list_size[54U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[54U], 5U, 3));
    vlSelfRef.display_list_valid[54U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[54U], 0U));
    vlSelfRef.display_list_x[55U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[55U], 0x00000026U, 10));
    vlSelfRef.display_list_y[55U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[55U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[55U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[55U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[55U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[55U], 1U, 4));
    vlSelfRef.display_list_flip_x[55U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[55U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[55U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[55U], 0x0000000aU));
    vlSelfRef.display_list_priority[55U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[55U], 8U, 2));
    vlSelfRef.display_list_size[55U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[55U], 5U, 3));
    vlSelfRef.display_list_valid[55U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[55U], 0U));
    vlSelfRef.display_list_x[56U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[56U], 0x00000026U, 10));
    vlSelfRef.display_list_y[56U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[56U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[56U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[56U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[56U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[56U], 1U, 4));
    vlSelfRef.display_list_flip_x[56U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[56U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[56U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[56U], 0x0000000aU));
    vlSelfRef.display_list_priority[56U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[56U], 8U, 2));
    vlSelfRef.display_list_size[56U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[56U], 5U, 3));
    vlSelfRef.display_list_valid[56U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[56U], 0U));
    vlSelfRef.display_list_x[57U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[57U], 0x00000026U, 10));
    vlSelfRef.display_list_y[57U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[57U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[57U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[57U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[57U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[57U], 1U, 4));
    vlSelfRef.display_list_flip_x[57U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[57U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[57U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[57U], 0x0000000aU));
    vlSelfRef.display_list_priority[57U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[57U], 8U, 2));
    vlSelfRef.display_list_size[57U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[57U], 5U, 3));
    vlSelfRef.display_list_valid[57U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[57U], 0U));
    vlSelfRef.display_list_x[58U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[58U], 0x00000026U, 10));
    vlSelfRef.display_list_y[58U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[58U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[58U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[58U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[58U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[58U], 1U, 4));
    vlSelfRef.display_list_flip_x[58U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[58U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[58U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[58U], 0x0000000aU));
    vlSelfRef.display_list_priority[58U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[58U], 8U, 2));
    vlSelfRef.display_list_size[58U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[58U], 5U, 3));
    vlSelfRef.display_list_valid[58U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[58U], 0U));
    vlSelfRef.display_list_x[59U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[59U], 0x00000026U, 10));
    vlSelfRef.display_list_y[59U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[59U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[59U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[59U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[59U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[59U], 1U, 4));
    vlSelfRef.display_list_flip_x[59U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[59U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[59U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[59U], 0x0000000aU));
    vlSelfRef.display_list_priority[59U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[59U], 8U, 2));
    vlSelfRef.display_list_size[59U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[59U], 5U, 3));
    vlSelfRef.display_list_valid[59U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[59U], 0U));
    vlSelfRef.display_list_x[60U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[60U], 0x00000026U, 10));
    vlSelfRef.display_list_y[60U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[60U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[60U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[60U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[60U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[60U], 1U, 4));
    vlSelfRef.display_list_flip_x[60U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[60U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[60U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[60U], 0x0000000aU));
    vlSelfRef.display_list_priority[60U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[60U], 8U, 2));
    vlSelfRef.display_list_size[60U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[60U], 5U, 3));
    vlSelfRef.display_list_valid[60U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[60U], 0U));
    vlSelfRef.display_list_x[61U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[61U], 0x00000026U, 10));
    vlSelfRef.display_list_y[61U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[61U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[61U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[61U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[61U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[61U], 1U, 4));
    vlSelfRef.display_list_flip_x[61U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[61U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[61U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[61U], 0x0000000aU));
    vlSelfRef.display_list_priority[61U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[61U], 8U, 2));
    vlSelfRef.display_list_size[61U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[61U], 5U, 3));
    vlSelfRef.display_list_valid[61U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[61U], 0U));
    vlSelfRef.display_list_x[62U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[62U], 0x00000026U, 10));
    vlSelfRef.display_list_y[62U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[62U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[62U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[62U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[62U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[62U], 1U, 4));
    vlSelfRef.display_list_flip_x[62U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[62U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[62U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[62U], 0x0000000aU));
    vlSelfRef.display_list_priority[62U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[62U], 8U, 2));
    vlSelfRef.display_list_size[62U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[62U], 5U, 3));
    vlSelfRef.display_list_valid[62U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[62U], 0U));
    vlSelfRef.display_list_x[63U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[63U], 0x00000026U, 10));
    vlSelfRef.display_list_y[63U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[63U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[63U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[63U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[63U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[63U], 1U, 4));
    vlSelfRef.display_list_flip_x[63U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[63U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[63U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[63U], 0x0000000aU));
    vlSelfRef.display_list_priority[63U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[63U], 8U, 2));
    vlSelfRef.display_list_size[63U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[63U], 5U, 3));
    vlSelfRef.display_list_valid[63U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[63U], 0U));
    vlSelfRef.display_list_x[64U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[64U], 0x00000026U, 10));
    vlSelfRef.display_list_y[64U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[64U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[64U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[64U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[64U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[64U], 1U, 4));
    vlSelfRef.display_list_flip_x[64U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[64U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[64U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[64U], 0x0000000aU));
    vlSelfRef.display_list_priority[64U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[64U], 8U, 2));
    vlSelfRef.display_list_size[64U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[64U], 5U, 3));
    vlSelfRef.display_list_valid[64U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[64U], 0U));
    vlSelfRef.display_list_x[65U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[65U], 0x00000026U, 10));
    vlSelfRef.display_list_y[65U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[65U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[65U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[65U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[65U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[65U], 1U, 4));
    vlSelfRef.display_list_flip_x[65U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[65U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[65U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[65U], 0x0000000aU));
    vlSelfRef.display_list_priority[65U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[65U], 8U, 2));
    vlSelfRef.display_list_size[65U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[65U], 5U, 3));
    vlSelfRef.display_list_valid[65U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[65U], 0U));
    vlSelfRef.display_list_x[66U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[66U], 0x00000026U, 10));
    vlSelfRef.display_list_y[66U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[66U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[66U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[66U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[66U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[66U], 1U, 4));
    vlSelfRef.display_list_flip_x[66U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[66U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[66U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[66U], 0x0000000aU));
    vlSelfRef.display_list_priority[66U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[66U], 8U, 2));
    vlSelfRef.display_list_size[66U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[66U], 5U, 3));
    vlSelfRef.display_list_valid[66U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[66U], 0U));
    vlSelfRef.display_list_x[67U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[67U], 0x00000026U, 10));
    vlSelfRef.display_list_y[67U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[67U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[67U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[67U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[67U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[67U], 1U, 4));
    vlSelfRef.display_list_flip_x[67U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[67U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[67U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[67U], 0x0000000aU));
    vlSelfRef.display_list_priority[67U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[67U], 8U, 2));
    vlSelfRef.display_list_size[67U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[67U], 5U, 3));
    vlSelfRef.display_list_valid[67U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[67U], 0U));
    vlSelfRef.display_list_x[68U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[68U], 0x00000026U, 10));
    vlSelfRef.display_list_y[68U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[68U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[68U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[68U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[68U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[68U], 1U, 4));
    vlSelfRef.display_list_flip_x[68U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[68U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[68U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[68U], 0x0000000aU));
    vlSelfRef.display_list_priority[68U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[68U], 8U, 2));
    vlSelfRef.display_list_size[68U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[68U], 5U, 3));
    vlSelfRef.display_list_valid[68U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[68U], 0U));
    vlSelfRef.display_list_x[69U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[69U], 0x00000026U, 10));
    vlSelfRef.display_list_y[69U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[69U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[69U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[69U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[69U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[69U], 1U, 4));
    vlSelfRef.display_list_flip_x[69U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[69U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[69U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[69U], 0x0000000aU));
    vlSelfRef.display_list_priority[69U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[69U], 8U, 2));
    vlSelfRef.display_list_size[69U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[69U], 5U, 3));
    vlSelfRef.display_list_valid[69U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[69U], 0U));
    vlSelfRef.display_list_x[70U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[70U], 0x00000026U, 10));
    vlSelfRef.display_list_y[70U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[70U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[70U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[70U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[70U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[70U], 1U, 4));
    vlSelfRef.display_list_flip_x[70U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[70U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[70U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[70U], 0x0000000aU));
    vlSelfRef.display_list_priority[70U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[70U], 8U, 2));
    vlSelfRef.display_list_size[70U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[70U], 5U, 3));
    vlSelfRef.display_list_valid[70U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[70U], 0U));
    vlSelfRef.display_list_x[71U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[71U], 0x00000026U, 10));
    vlSelfRef.display_list_y[71U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[71U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[71U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[71U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[71U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[71U], 1U, 4));
    vlSelfRef.display_list_flip_x[71U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[71U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[71U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[71U], 0x0000000aU));
    vlSelfRef.display_list_priority[71U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[71U], 8U, 2));
    vlSelfRef.display_list_size[71U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[71U], 5U, 3));
    vlSelfRef.display_list_valid[71U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[71U], 0U));
    vlSelfRef.display_list_x[72U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[72U], 0x00000026U, 10));
    vlSelfRef.display_list_y[72U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[72U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[72U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[72U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[72U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[72U], 1U, 4));
    vlSelfRef.display_list_flip_x[72U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[72U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[72U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[72U], 0x0000000aU));
    vlSelfRef.display_list_priority[72U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[72U], 8U, 2));
    vlSelfRef.display_list_size[72U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[72U], 5U, 3));
    vlSelfRef.display_list_valid[72U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[72U], 0U));
    vlSelfRef.display_list_x[73U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[73U], 0x00000026U, 10));
    vlSelfRef.display_list_y[73U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[73U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[73U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[73U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[73U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[73U], 1U, 4));
    vlSelfRef.display_list_flip_x[73U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[73U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[73U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[73U], 0x0000000aU));
    vlSelfRef.display_list_priority[73U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[73U], 8U, 2));
    vlSelfRef.display_list_size[73U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[73U], 5U, 3));
    vlSelfRef.display_list_valid[73U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[73U], 0U));
    vlSelfRef.display_list_x[74U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[74U], 0x00000026U, 10));
    vlSelfRef.display_list_y[74U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[74U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[74U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[74U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[74U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[74U], 1U, 4));
    vlSelfRef.display_list_flip_x[74U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[74U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[74U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[74U], 0x0000000aU));
    vlSelfRef.display_list_priority[74U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[74U], 8U, 2));
    vlSelfRef.display_list_size[74U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[74U], 5U, 3));
    vlSelfRef.display_list_valid[74U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[74U], 0U));
    vlSelfRef.display_list_x[75U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[75U], 0x00000026U, 10));
    vlSelfRef.display_list_y[75U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[75U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[75U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[75U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[75U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[75U], 1U, 4));
    vlSelfRef.display_list_flip_x[75U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[75U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[75U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[75U], 0x0000000aU));
    vlSelfRef.display_list_priority[75U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[75U], 8U, 2));
    vlSelfRef.display_list_size[75U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[75U], 5U, 3));
    vlSelfRef.display_list_valid[75U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[75U], 0U));
    vlSelfRef.display_list_x[76U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[76U], 0x00000026U, 10));
    vlSelfRef.display_list_y[76U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[76U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[76U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[76U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[76U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[76U], 1U, 4));
    vlSelfRef.display_list_flip_x[76U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[76U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[76U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[76U], 0x0000000aU));
    vlSelfRef.display_list_priority[76U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[76U], 8U, 2));
    vlSelfRef.display_list_size[76U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[76U], 5U, 3));
    vlSelfRef.display_list_valid[76U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[76U], 0U));
    vlSelfRef.display_list_x[77U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[77U], 0x00000026U, 10));
    vlSelfRef.display_list_y[77U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[77U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[77U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[77U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[77U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[77U], 1U, 4));
    vlSelfRef.display_list_flip_x[77U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[77U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[77U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[77U], 0x0000000aU));
    vlSelfRef.display_list_priority[77U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[77U], 8U, 2));
    vlSelfRef.display_list_size[77U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[77U], 5U, 3));
    vlSelfRef.display_list_valid[77U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[77U], 0U));
    vlSelfRef.display_list_x[78U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[78U], 0x00000026U, 10));
    vlSelfRef.display_list_y[78U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[78U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[78U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[78U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[78U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[78U], 1U, 4));
    vlSelfRef.display_list_flip_x[78U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[78U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[78U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[78U], 0x0000000aU));
    vlSelfRef.display_list_priority[78U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[78U], 8U, 2));
    vlSelfRef.display_list_size[78U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[78U], 5U, 3));
    vlSelfRef.display_list_valid[78U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[78U], 0U));
    vlSelfRef.display_list_x[79U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[79U], 0x00000026U, 10));
    vlSelfRef.display_list_y[79U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[79U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[79U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[79U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[79U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[79U], 1U, 4));
    vlSelfRef.display_list_flip_x[79U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[79U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[79U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[79U], 0x0000000aU));
    vlSelfRef.display_list_priority[79U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[79U], 8U, 2));
    vlSelfRef.display_list_size[79U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[79U], 5U, 3));
    vlSelfRef.display_list_valid[79U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[79U], 0U));
    vlSelfRef.display_list_x[80U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[80U], 0x00000026U, 10));
    vlSelfRef.display_list_y[80U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[80U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[80U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[80U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[80U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[80U], 1U, 4));
    vlSelfRef.display_list_flip_x[80U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[80U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[80U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[80U], 0x0000000aU));
    vlSelfRef.display_list_priority[80U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[80U], 8U, 2));
    vlSelfRef.display_list_size[80U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[80U], 5U, 3));
    vlSelfRef.display_list_valid[80U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[80U], 0U));
    vlSelfRef.display_list_x[81U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[81U], 0x00000026U, 10));
    vlSelfRef.display_list_y[81U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[81U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[81U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[81U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[81U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[81U], 1U, 4));
    vlSelfRef.display_list_flip_x[81U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[81U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[81U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[81U], 0x0000000aU));
    vlSelfRef.display_list_priority[81U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[81U], 8U, 2));
    vlSelfRef.display_list_size[81U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[81U], 5U, 3));
    vlSelfRef.display_list_valid[81U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[81U], 0U));
    vlSelfRef.display_list_x[82U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[82U], 0x00000026U, 10));
    vlSelfRef.display_list_y[82U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[82U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[82U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[82U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[82U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[82U], 1U, 4));
    vlSelfRef.display_list_flip_x[82U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[82U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[82U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[82U], 0x0000000aU));
    vlSelfRef.display_list_priority[82U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[82U], 8U, 2));
    vlSelfRef.display_list_size[82U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[82U], 5U, 3));
    vlSelfRef.display_list_valid[82U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[82U], 0U));
    vlSelfRef.display_list_x[83U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[83U], 0x00000026U, 10));
    vlSelfRef.display_list_y[83U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[83U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[83U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[83U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[83U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[83U], 1U, 4));
    vlSelfRef.display_list_flip_x[83U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[83U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[83U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[83U], 0x0000000aU));
    vlSelfRef.display_list_priority[83U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[83U], 8U, 2));
    vlSelfRef.display_list_size[83U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[83U], 5U, 3));
    vlSelfRef.display_list_valid[83U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[83U], 0U));
    vlSelfRef.display_list_x[84U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[84U], 0x00000026U, 10));
    vlSelfRef.display_list_y[84U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[84U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[84U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[84U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[84U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[84U], 1U, 4));
    vlSelfRef.display_list_flip_x[84U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[84U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[84U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[84U], 0x0000000aU));
    vlSelfRef.display_list_priority[84U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[84U], 8U, 2));
    vlSelfRef.display_list_size[84U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[84U], 5U, 3));
    vlSelfRef.display_list_valid[84U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[84U], 0U));
    vlSelfRef.display_list_x[85U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[85U], 0x00000026U, 10));
    vlSelfRef.display_list_y[85U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[85U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[85U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[85U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[85U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[85U], 1U, 4));
    vlSelfRef.display_list_flip_x[85U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[85U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[85U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[85U], 0x0000000aU));
    vlSelfRef.display_list_priority[85U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[85U], 8U, 2));
    vlSelfRef.display_list_size[85U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[85U], 5U, 3));
    vlSelfRef.display_list_valid[85U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[85U], 0U));
    vlSelfRef.display_list_x[86U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[86U], 0x00000026U, 10));
    vlSelfRef.display_list_y[86U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[86U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[86U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[86U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[86U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[86U], 1U, 4));
    vlSelfRef.display_list_flip_x[86U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[86U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[86U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[86U], 0x0000000aU));
    vlSelfRef.display_list_priority[86U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[86U], 8U, 2));
    vlSelfRef.display_list_size[86U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[86U], 5U, 3));
    vlSelfRef.display_list_valid[86U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[86U], 0U));
    vlSelfRef.display_list_x[87U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[87U], 0x00000026U, 10));
    vlSelfRef.display_list_y[87U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[87U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[87U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[87U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[87U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[87U], 1U, 4));
    vlSelfRef.display_list_flip_x[87U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[87U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[87U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[87U], 0x0000000aU));
    vlSelfRef.display_list_priority[87U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[87U], 8U, 2));
    vlSelfRef.display_list_size[87U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[87U], 5U, 3));
    vlSelfRef.display_list_valid[87U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[87U], 0U));
    vlSelfRef.display_list_x[88U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[88U], 0x00000026U, 10));
    vlSelfRef.display_list_y[88U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[88U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[88U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[88U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[88U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[88U], 1U, 4));
    vlSelfRef.display_list_flip_x[88U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[88U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[88U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[88U], 0x0000000aU));
    vlSelfRef.display_list_priority[88U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[88U], 8U, 2));
    vlSelfRef.display_list_size[88U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[88U], 5U, 3));
    vlSelfRef.display_list_valid[88U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[88U], 0U));
    vlSelfRef.display_list_x[89U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[89U], 0x00000026U, 10));
    vlSelfRef.display_list_y[89U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[89U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[89U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[89U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[89U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[89U], 1U, 4));
    vlSelfRef.display_list_flip_x[89U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[89U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[89U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[89U], 0x0000000aU));
    vlSelfRef.display_list_priority[89U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[89U], 8U, 2));
    vlSelfRef.display_list_size[89U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[89U], 5U, 3));
    vlSelfRef.display_list_valid[89U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[89U], 0U));
    vlSelfRef.display_list_x[90U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[90U], 0x00000026U, 10));
    vlSelfRef.display_list_y[90U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[90U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[90U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[90U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[90U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[90U], 1U, 4));
    vlSelfRef.display_list_flip_x[90U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[90U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[90U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[90U], 0x0000000aU));
    vlSelfRef.display_list_priority[90U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[90U], 8U, 2));
    vlSelfRef.display_list_size[90U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[90U], 5U, 3));
    vlSelfRef.display_list_valid[90U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[90U], 0U));
    vlSelfRef.display_list_x[91U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[91U], 0x00000026U, 10));
    vlSelfRef.display_list_y[91U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[91U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[91U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[91U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[91U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[91U], 1U, 4));
    vlSelfRef.display_list_flip_x[91U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[91U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[91U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[91U], 0x0000000aU));
    vlSelfRef.display_list_priority[91U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[91U], 8U, 2));
    vlSelfRef.display_list_size[91U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[91U], 5U, 3));
    vlSelfRef.display_list_valid[91U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[91U], 0U));
    vlSelfRef.display_list_x[92U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[92U], 0x00000026U, 10));
    vlSelfRef.display_list_y[92U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[92U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[92U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[92U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[92U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[92U], 1U, 4));
    vlSelfRef.display_list_flip_x[92U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[92U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[92U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[92U], 0x0000000aU));
    vlSelfRef.display_list_priority[92U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[92U], 8U, 2));
    vlSelfRef.display_list_size[92U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[92U], 5U, 3));
    vlSelfRef.display_list_valid[92U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[92U], 0U));
    vlSelfRef.display_list_x[93U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[93U], 0x00000026U, 10));
    vlSelfRef.display_list_y[93U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[93U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[93U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[93U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[93U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[93U], 1U, 4));
    vlSelfRef.display_list_flip_x[93U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[93U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[93U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[93U], 0x0000000aU));
    vlSelfRef.display_list_priority[93U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[93U], 8U, 2));
    vlSelfRef.display_list_size[93U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[93U], 5U, 3));
    vlSelfRef.display_list_valid[93U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[93U], 0U));
    vlSelfRef.display_list_x[94U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[94U], 0x00000026U, 10));
    vlSelfRef.display_list_y[94U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[94U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[94U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[94U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[94U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[94U], 1U, 4));
    vlSelfRef.display_list_flip_x[94U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[94U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[94U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[94U], 0x0000000aU));
    vlSelfRef.display_list_priority[94U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[94U], 8U, 2));
    vlSelfRef.display_list_size[94U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[94U], 5U, 3));
    vlSelfRef.display_list_valid[94U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[94U], 0U));
    vlSelfRef.display_list_x[95U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[95U], 0x00000026U, 10));
    vlSelfRef.display_list_y[95U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[95U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[95U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[95U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[95U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[95U], 1U, 4));
    vlSelfRef.display_list_flip_x[95U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[95U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[95U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[95U], 0x0000000aU));
    vlSelfRef.display_list_priority[95U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[95U], 8U, 2));
    vlSelfRef.display_list_size[95U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[95U], 5U, 3));
    vlSelfRef.display_list_valid[95U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[95U], 0U));
    vlSelfRef.display_list_x[96U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[96U], 0x00000026U, 10));
    vlSelfRef.display_list_y[96U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[96U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[96U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[96U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[96U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[96U], 1U, 4));
    vlSelfRef.display_list_flip_x[96U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[96U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[96U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[96U], 0x0000000aU));
    vlSelfRef.display_list_priority[96U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[96U], 8U, 2));
    vlSelfRef.display_list_size[96U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[96U], 5U, 3));
    vlSelfRef.display_list_valid[96U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[96U], 0U));
    vlSelfRef.display_list_x[97U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[97U], 0x00000026U, 10));
    vlSelfRef.display_list_y[97U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[97U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[97U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[97U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[97U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[97U], 1U, 4));
    vlSelfRef.display_list_flip_x[97U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[97U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[97U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[97U], 0x0000000aU));
    vlSelfRef.display_list_priority[97U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[97U], 8U, 2));
    vlSelfRef.display_list_size[97U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[97U], 5U, 3));
    vlSelfRef.display_list_valid[97U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[97U], 0U));
    vlSelfRef.display_list_x[98U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[98U], 0x00000026U, 10));
    vlSelfRef.display_list_y[98U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[98U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[98U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[98U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[98U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[98U], 1U, 4));
    vlSelfRef.display_list_flip_x[98U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[98U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[98U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[98U], 0x0000000aU));
    vlSelfRef.display_list_priority[98U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[98U], 8U, 2));
    vlSelfRef.display_list_size[98U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[98U], 5U, 3));
    vlSelfRef.display_list_valid[98U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[98U], 0U));
    vlSelfRef.display_list_x[99U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[99U], 0x00000026U, 10));
    vlSelfRef.display_list_y[99U] = (0x000003ffU & 
                                     VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[99U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[99U] = (0x0000ffffU 
                                        & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[99U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[99U] = (0x0000000fU 
                                           & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[99U], 1U, 4));
    vlSelfRef.display_list_flip_x[99U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[99U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[99U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[99U], 0x0000000aU));
    vlSelfRef.display_list_priority[99U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[99U], 8U, 2));
    vlSelfRef.display_list_size[99U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[99U], 5U, 3));
    vlSelfRef.display_list_valid[99U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[99U], 0U));
    vlSelfRef.display_list_x[100U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[100U], 0x00000026U, 10));
    vlSelfRef.display_list_y[100U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[100U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[100U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[100U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[100U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[100U], 1U, 4));
    vlSelfRef.display_list_flip_x[100U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[100U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[100U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[100U], 0x0000000aU));
    vlSelfRef.display_list_priority[100U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[100U], 8U, 2));
    vlSelfRef.display_list_size[100U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[100U], 5U, 3));
    vlSelfRef.display_list_valid[100U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[100U], 0U));
    vlSelfRef.display_list_x[101U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[101U], 0x00000026U, 10));
    vlSelfRef.display_list_y[101U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[101U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[101U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[101U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[101U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[101U], 1U, 4));
    vlSelfRef.display_list_flip_x[101U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[101U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[101U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[101U], 0x0000000aU));
    vlSelfRef.display_list_priority[101U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[101U], 8U, 2));
    vlSelfRef.display_list_size[101U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[101U], 5U, 3));
    vlSelfRef.display_list_valid[101U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[101U], 0U));
    vlSelfRef.display_list_x[102U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[102U], 0x00000026U, 10));
    vlSelfRef.display_list_y[102U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[102U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[102U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[102U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[102U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[102U], 1U, 4));
    vlSelfRef.display_list_flip_x[102U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[102U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[102U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[102U], 0x0000000aU));
    vlSelfRef.display_list_priority[102U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[102U], 8U, 2));
    vlSelfRef.display_list_size[102U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[102U], 5U, 3));
    vlSelfRef.display_list_valid[102U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[102U], 0U));
    vlSelfRef.display_list_x[103U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[103U], 0x00000026U, 10));
    vlSelfRef.display_list_y[103U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[103U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[103U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[103U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[103U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[103U], 1U, 4));
    vlSelfRef.display_list_flip_x[103U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[103U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[103U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[103U], 0x0000000aU));
    vlSelfRef.display_list_priority[103U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[103U], 8U, 2));
    vlSelfRef.display_list_size[103U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[103U], 5U, 3));
    vlSelfRef.display_list_valid[103U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[103U], 0U));
    vlSelfRef.display_list_x[104U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[104U], 0x00000026U, 10));
    vlSelfRef.display_list_y[104U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[104U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[104U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[104U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[104U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[104U], 1U, 4));
    vlSelfRef.display_list_flip_x[104U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[104U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[104U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[104U], 0x0000000aU));
    vlSelfRef.display_list_priority[104U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[104U], 8U, 2));
    vlSelfRef.display_list_size[104U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[104U], 5U, 3));
    vlSelfRef.display_list_valid[104U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[104U], 0U));
    vlSelfRef.display_list_x[105U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[105U], 0x00000026U, 10));
    vlSelfRef.display_list_y[105U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[105U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[105U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[105U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[105U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[105U], 1U, 4));
    vlSelfRef.display_list_flip_x[105U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[105U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[105U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[105U], 0x0000000aU));
    vlSelfRef.display_list_priority[105U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[105U], 8U, 2));
    vlSelfRef.display_list_size[105U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[105U], 5U, 3));
    vlSelfRef.display_list_valid[105U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[105U], 0U));
    vlSelfRef.display_list_x[106U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[106U], 0x00000026U, 10));
    vlSelfRef.display_list_y[106U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[106U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[106U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[106U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[106U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[106U], 1U, 4));
    vlSelfRef.display_list_flip_x[106U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[106U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[106U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[106U], 0x0000000aU));
    vlSelfRef.display_list_priority[106U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[106U], 8U, 2));
    vlSelfRef.display_list_size[106U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[106U], 5U, 3));
    vlSelfRef.display_list_valid[106U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[106U], 0U));
    vlSelfRef.display_list_x[107U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[107U], 0x00000026U, 10));
    vlSelfRef.display_list_y[107U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[107U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[107U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[107U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[107U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[107U], 1U, 4));
    vlSelfRef.display_list_flip_x[107U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[107U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[107U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[107U], 0x0000000aU));
    vlSelfRef.display_list_priority[107U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[107U], 8U, 2));
    vlSelfRef.display_list_size[107U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[107U], 5U, 3));
    vlSelfRef.display_list_valid[107U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[107U], 0U));
    vlSelfRef.display_list_x[108U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[108U], 0x00000026U, 10));
    vlSelfRef.display_list_y[108U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[108U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[108U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[108U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[108U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[108U], 1U, 4));
    vlSelfRef.display_list_flip_x[108U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[108U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[108U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[108U], 0x0000000aU));
    vlSelfRef.display_list_priority[108U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[108U], 8U, 2));
    vlSelfRef.display_list_size[108U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[108U], 5U, 3));
    vlSelfRef.display_list_valid[108U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[108U], 0U));
    vlSelfRef.display_list_x[109U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[109U], 0x00000026U, 10));
    vlSelfRef.display_list_y[109U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[109U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[109U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[109U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[109U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[109U], 1U, 4));
    vlSelfRef.display_list_flip_x[109U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[109U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[109U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[109U], 0x0000000aU));
    vlSelfRef.display_list_priority[109U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[109U], 8U, 2));
    vlSelfRef.display_list_size[109U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[109U], 5U, 3));
    vlSelfRef.display_list_valid[109U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[109U], 0U));
    vlSelfRef.display_list_x[110U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[110U], 0x00000026U, 10));
    vlSelfRef.display_list_y[110U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[110U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[110U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[110U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[110U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[110U], 1U, 4));
    vlSelfRef.display_list_flip_x[110U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[110U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[110U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[110U], 0x0000000aU));
    vlSelfRef.display_list_priority[110U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[110U], 8U, 2));
    vlSelfRef.display_list_size[110U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[110U], 5U, 3));
    vlSelfRef.display_list_valid[110U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[110U], 0U));
    vlSelfRef.display_list_x[111U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[111U], 0x00000026U, 10));
    vlSelfRef.display_list_y[111U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[111U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[111U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[111U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[111U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[111U], 1U, 4));
    vlSelfRef.display_list_flip_x[111U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[111U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[111U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[111U], 0x0000000aU));
    vlSelfRef.display_list_priority[111U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[111U], 8U, 2));
    vlSelfRef.display_list_size[111U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[111U], 5U, 3));
    vlSelfRef.display_list_valid[111U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[111U], 0U));
    vlSelfRef.display_list_x[112U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[112U], 0x00000026U, 10));
    vlSelfRef.display_list_y[112U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[112U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[112U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[112U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[112U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[112U], 1U, 4));
    vlSelfRef.display_list_flip_x[112U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[112U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[112U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[112U], 0x0000000aU));
    vlSelfRef.display_list_priority[112U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[112U], 8U, 2));
    vlSelfRef.display_list_size[112U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[112U], 5U, 3));
    vlSelfRef.display_list_valid[112U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[112U], 0U));
    vlSelfRef.display_list_x[113U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[113U], 0x00000026U, 10));
    vlSelfRef.display_list_y[113U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[113U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[113U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[113U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[113U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[113U], 1U, 4));
    vlSelfRef.display_list_flip_x[113U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[113U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[113U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[113U], 0x0000000aU));
    vlSelfRef.display_list_priority[113U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[113U], 8U, 2));
    vlSelfRef.display_list_size[113U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[113U], 5U, 3));
    vlSelfRef.display_list_valid[113U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[113U], 0U));
    vlSelfRef.display_list_x[114U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[114U], 0x00000026U, 10));
    vlSelfRef.display_list_y[114U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[114U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[114U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[114U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[114U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[114U], 1U, 4));
    vlSelfRef.display_list_flip_x[114U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[114U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[114U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[114U], 0x0000000aU));
    vlSelfRef.display_list_priority[114U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[114U], 8U, 2));
    vlSelfRef.display_list_size[114U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[114U], 5U, 3));
    vlSelfRef.display_list_valid[114U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[114U], 0U));
    vlSelfRef.display_list_x[115U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[115U], 0x00000026U, 10));
    vlSelfRef.display_list_y[115U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[115U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[115U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[115U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[115U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[115U], 1U, 4));
    vlSelfRef.display_list_flip_x[115U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[115U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[115U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[115U], 0x0000000aU));
    vlSelfRef.display_list_priority[115U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[115U], 8U, 2));
    vlSelfRef.display_list_size[115U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[115U], 5U, 3));
    vlSelfRef.display_list_valid[115U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[115U], 0U));
    vlSelfRef.display_list_x[116U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[116U], 0x00000026U, 10));
    vlSelfRef.display_list_y[116U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[116U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[116U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[116U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[116U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[116U], 1U, 4));
    vlSelfRef.display_list_flip_x[116U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[116U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[116U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[116U], 0x0000000aU));
    vlSelfRef.display_list_priority[116U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[116U], 8U, 2));
    vlSelfRef.display_list_size[116U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[116U], 5U, 3));
    vlSelfRef.display_list_valid[116U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[116U], 0U));
    vlSelfRef.display_list_x[117U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[117U], 0x00000026U, 10));
    vlSelfRef.display_list_y[117U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[117U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[117U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[117U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[117U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[117U], 1U, 4));
    vlSelfRef.display_list_flip_x[117U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[117U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[117U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[117U], 0x0000000aU));
    vlSelfRef.display_list_priority[117U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[117U], 8U, 2));
    vlSelfRef.display_list_size[117U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[117U], 5U, 3));
    vlSelfRef.display_list_valid[117U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[117U], 0U));
    vlSelfRef.display_list_x[118U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[118U], 0x00000026U, 10));
    vlSelfRef.display_list_y[118U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[118U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[118U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[118U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[118U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[118U], 1U, 4));
    vlSelfRef.display_list_flip_x[118U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[118U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[118U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[118U], 0x0000000aU));
    vlSelfRef.display_list_priority[118U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[118U], 8U, 2));
    vlSelfRef.display_list_size[118U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[118U], 5U, 3));
    vlSelfRef.display_list_valid[118U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[118U], 0U));
    vlSelfRef.display_list_x[119U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[119U], 0x00000026U, 10));
    vlSelfRef.display_list_y[119U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[119U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[119U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[119U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[119U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[119U], 1U, 4));
    vlSelfRef.display_list_flip_x[119U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[119U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[119U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[119U], 0x0000000aU));
    vlSelfRef.display_list_priority[119U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[119U], 8U, 2));
    vlSelfRef.display_list_size[119U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[119U], 5U, 3));
    vlSelfRef.display_list_valid[119U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[119U], 0U));
    vlSelfRef.display_list_x[120U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[120U], 0x00000026U, 10));
    vlSelfRef.display_list_y[120U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[120U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[120U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[120U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[120U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[120U], 1U, 4));
    vlSelfRef.display_list_flip_x[120U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[120U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[120U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[120U], 0x0000000aU));
    vlSelfRef.display_list_priority[120U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[120U], 8U, 2));
    vlSelfRef.display_list_size[120U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[120U], 5U, 3));
    vlSelfRef.display_list_valid[120U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[120U], 0U));
    vlSelfRef.display_list_x[121U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[121U], 0x00000026U, 10));
    vlSelfRef.display_list_y[121U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[121U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[121U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[121U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[121U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[121U], 1U, 4));
    vlSelfRef.display_list_flip_x[121U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[121U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[121U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[121U], 0x0000000aU));
    vlSelfRef.display_list_priority[121U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[121U], 8U, 2));
    vlSelfRef.display_list_size[121U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[121U], 5U, 3));
    vlSelfRef.display_list_valid[121U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[121U], 0U));
    vlSelfRef.display_list_x[122U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[122U], 0x00000026U, 10));
    vlSelfRef.display_list_y[122U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[122U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[122U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[122U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[122U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[122U], 1U, 4));
    vlSelfRef.display_list_flip_x[122U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[122U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[122U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[122U], 0x0000000aU));
    vlSelfRef.display_list_priority[122U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[122U], 8U, 2));
    vlSelfRef.display_list_size[122U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[122U], 5U, 3));
    vlSelfRef.display_list_valid[122U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[122U], 0U));
    vlSelfRef.display_list_x[123U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[123U], 0x00000026U, 10));
    vlSelfRef.display_list_y[123U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[123U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[123U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[123U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[123U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[123U], 1U, 4));
    vlSelfRef.display_list_flip_x[123U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[123U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[123U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[123U], 0x0000000aU));
    vlSelfRef.display_list_priority[123U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[123U], 8U, 2));
    vlSelfRef.display_list_size[123U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[123U], 5U, 3));
    vlSelfRef.display_list_valid[123U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[123U], 0U));
    vlSelfRef.display_list_x[124U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[124U], 0x00000026U, 10));
    vlSelfRef.display_list_y[124U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[124U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[124U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[124U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[124U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[124U], 1U, 4));
    vlSelfRef.display_list_flip_x[124U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[124U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[124U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[124U], 0x0000000aU));
    vlSelfRef.display_list_priority[124U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[124U], 8U, 2));
    vlSelfRef.display_list_size[124U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[124U], 5U, 3));
    vlSelfRef.display_list_valid[124U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[124U], 0U));
    vlSelfRef.display_list_x[125U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[125U], 0x00000026U, 10));
    vlSelfRef.display_list_y[125U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[125U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[125U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[125U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[125U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[125U], 1U, 4));
    vlSelfRef.display_list_flip_x[125U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[125U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[125U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[125U], 0x0000000aU));
    vlSelfRef.display_list_priority[125U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[125U], 8U, 2));
    vlSelfRef.display_list_size[125U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[125U], 5U, 3));
    vlSelfRef.display_list_valid[125U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[125U], 0U));
    vlSelfRef.display_list_x[126U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[126U], 0x00000026U, 10));
    vlSelfRef.display_list_y[126U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[126U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[126U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[126U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[126U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[126U], 1U, 4));
    vlSelfRef.display_list_flip_x[126U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[126U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[126U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[126U], 0x0000000aU));
    vlSelfRef.display_list_priority[126U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[126U], 8U, 2));
    vlSelfRef.display_list_size[126U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[126U], 5U, 3));
    vlSelfRef.display_list_valid[126U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[126U], 0U));
    vlSelfRef.display_list_x[127U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[127U], 0x00000026U, 10));
    vlSelfRef.display_list_y[127U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[127U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[127U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[127U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[127U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[127U], 1U, 4));
    vlSelfRef.display_list_flip_x[127U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[127U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[127U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[127U], 0x0000000aU));
    vlSelfRef.display_list_priority[127U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[127U], 8U, 2));
    vlSelfRef.display_list_size[127U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[127U], 5U, 3));
    vlSelfRef.display_list_valid[127U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[127U], 0U));
    vlSelfRef.display_list_x[128U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[128U], 0x00000026U, 10));
    vlSelfRef.display_list_y[128U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[128U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[128U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[128U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[128U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[128U], 1U, 4));
    vlSelfRef.display_list_flip_x[128U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[128U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[128U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[128U], 0x0000000aU));
    vlSelfRef.display_list_priority[128U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[128U], 8U, 2));
    vlSelfRef.display_list_size[128U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[128U], 5U, 3));
    vlSelfRef.display_list_valid[128U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[128U], 0U));
    vlSelfRef.display_list_x[129U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[129U], 0x00000026U, 10));
    vlSelfRef.display_list_y[129U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[129U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[129U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[129U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[129U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[129U], 1U, 4));
    vlSelfRef.display_list_flip_x[129U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[129U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[129U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[129U], 0x0000000aU));
    vlSelfRef.display_list_priority[129U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[129U], 8U, 2));
    vlSelfRef.display_list_size[129U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[129U], 5U, 3));
    vlSelfRef.display_list_valid[129U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[129U], 0U));
    vlSelfRef.display_list_x[130U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[130U], 0x00000026U, 10));
    vlSelfRef.display_list_y[130U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[130U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[130U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[130U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[130U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[130U], 1U, 4));
    vlSelfRef.display_list_flip_x[130U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[130U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[130U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[130U], 0x0000000aU));
    vlSelfRef.display_list_priority[130U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[130U], 8U, 2));
    vlSelfRef.display_list_size[130U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[130U], 5U, 3));
    vlSelfRef.display_list_valid[130U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[130U], 0U));
    vlSelfRef.display_list_x[131U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[131U], 0x00000026U, 10));
    vlSelfRef.display_list_y[131U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[131U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[131U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[131U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[131U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[131U], 1U, 4));
    vlSelfRef.display_list_flip_x[131U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[131U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[131U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[131U], 0x0000000aU));
    vlSelfRef.display_list_priority[131U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[131U], 8U, 2));
    vlSelfRef.display_list_size[131U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[131U], 5U, 3));
    vlSelfRef.display_list_valid[131U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[131U], 0U));
    vlSelfRef.display_list_x[132U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[132U], 0x00000026U, 10));
    vlSelfRef.display_list_y[132U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[132U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[132U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[132U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[132U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[132U], 1U, 4));
    vlSelfRef.display_list_flip_x[132U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[132U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[132U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[132U], 0x0000000aU));
    vlSelfRef.display_list_priority[132U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[132U], 8U, 2));
    vlSelfRef.display_list_size[132U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[132U], 5U, 3));
    vlSelfRef.display_list_valid[132U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[132U], 0U));
    vlSelfRef.display_list_x[133U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[133U], 0x00000026U, 10));
    vlSelfRef.display_list_y[133U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[133U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[133U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[133U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[133U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[133U], 1U, 4));
    vlSelfRef.display_list_flip_x[133U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[133U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[133U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[133U], 0x0000000aU));
    vlSelfRef.display_list_priority[133U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[133U], 8U, 2));
    vlSelfRef.display_list_size[133U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[133U], 5U, 3));
    vlSelfRef.display_list_valid[133U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[133U], 0U));
    vlSelfRef.display_list_x[134U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[134U], 0x00000026U, 10));
    vlSelfRef.display_list_y[134U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[134U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[134U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[134U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[134U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[134U], 1U, 4));
    vlSelfRef.display_list_flip_x[134U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[134U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[134U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[134U], 0x0000000aU));
    vlSelfRef.display_list_priority[134U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[134U], 8U, 2));
    vlSelfRef.display_list_size[134U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[134U], 5U, 3));
    vlSelfRef.display_list_valid[134U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[134U], 0U));
    vlSelfRef.display_list_x[135U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[135U], 0x00000026U, 10));
    vlSelfRef.display_list_y[135U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[135U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[135U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[135U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[135U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[135U], 1U, 4));
    vlSelfRef.display_list_flip_x[135U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[135U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[135U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[135U], 0x0000000aU));
    vlSelfRef.display_list_priority[135U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[135U], 8U, 2));
    vlSelfRef.display_list_size[135U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[135U], 5U, 3));
    vlSelfRef.display_list_valid[135U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[135U], 0U));
    vlSelfRef.display_list_x[136U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[136U], 0x00000026U, 10));
    vlSelfRef.display_list_y[136U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[136U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[136U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[136U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[136U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[136U], 1U, 4));
    vlSelfRef.display_list_flip_x[136U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[136U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[136U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[136U], 0x0000000aU));
    vlSelfRef.display_list_priority[136U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[136U], 8U, 2));
    vlSelfRef.display_list_size[136U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[136U], 5U, 3));
    vlSelfRef.display_list_valid[136U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[136U], 0U));
    vlSelfRef.display_list_x[137U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[137U], 0x00000026U, 10));
    vlSelfRef.display_list_y[137U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[137U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[137U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[137U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[137U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[137U], 1U, 4));
    vlSelfRef.display_list_flip_x[137U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[137U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[137U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[137U], 0x0000000aU));
    vlSelfRef.display_list_priority[137U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[137U], 8U, 2));
    vlSelfRef.display_list_size[137U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[137U], 5U, 3));
    vlSelfRef.display_list_valid[137U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[137U], 0U));
    vlSelfRef.display_list_x[138U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[138U], 0x00000026U, 10));
    vlSelfRef.display_list_y[138U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[138U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[138U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[138U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[138U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[138U], 1U, 4));
    vlSelfRef.display_list_flip_x[138U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[138U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[138U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[138U], 0x0000000aU));
    vlSelfRef.display_list_priority[138U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[138U], 8U, 2));
    vlSelfRef.display_list_size[138U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[138U], 5U, 3));
    vlSelfRef.display_list_valid[138U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[138U], 0U));
    vlSelfRef.display_list_x[139U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[139U], 0x00000026U, 10));
    vlSelfRef.display_list_y[139U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[139U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[139U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[139U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[139U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[139U], 1U, 4));
    vlSelfRef.display_list_flip_x[139U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[139U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[139U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[139U], 0x0000000aU));
    vlSelfRef.display_list_priority[139U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[139U], 8U, 2));
    vlSelfRef.display_list_size[139U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[139U], 5U, 3));
    vlSelfRef.display_list_valid[139U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[139U], 0U));
    vlSelfRef.display_list_x[140U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[140U], 0x00000026U, 10));
    vlSelfRef.display_list_y[140U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[140U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[140U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[140U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[140U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[140U], 1U, 4));
    vlSelfRef.display_list_flip_x[140U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[140U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[140U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[140U], 0x0000000aU));
    vlSelfRef.display_list_priority[140U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[140U], 8U, 2));
    vlSelfRef.display_list_size[140U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[140U], 5U, 3));
    vlSelfRef.display_list_valid[140U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[140U], 0U));
    vlSelfRef.display_list_x[141U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[141U], 0x00000026U, 10));
    vlSelfRef.display_list_y[141U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[141U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[141U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[141U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[141U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[141U], 1U, 4));
    vlSelfRef.display_list_flip_x[141U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[141U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[141U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[141U], 0x0000000aU));
    vlSelfRef.display_list_priority[141U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[141U], 8U, 2));
    vlSelfRef.display_list_size[141U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[141U], 5U, 3));
    vlSelfRef.display_list_valid[141U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[141U], 0U));
    vlSelfRef.display_list_x[142U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[142U], 0x00000026U, 10));
    vlSelfRef.display_list_y[142U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[142U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[142U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[142U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[142U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[142U], 1U, 4));
    vlSelfRef.display_list_flip_x[142U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[142U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[142U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[142U], 0x0000000aU));
    vlSelfRef.display_list_priority[142U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[142U], 8U, 2));
    vlSelfRef.display_list_size[142U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[142U], 5U, 3));
    vlSelfRef.display_list_valid[142U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[142U], 0U));
    vlSelfRef.display_list_x[143U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[143U], 0x00000026U, 10));
    vlSelfRef.display_list_y[143U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[143U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[143U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[143U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[143U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[143U], 1U, 4));
    vlSelfRef.display_list_flip_x[143U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[143U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[143U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[143U], 0x0000000aU));
    vlSelfRef.display_list_priority[143U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[143U], 8U, 2));
    vlSelfRef.display_list_size[143U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[143U], 5U, 3));
    vlSelfRef.display_list_valid[143U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[143U], 0U));
    vlSelfRef.display_list_x[144U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[144U], 0x00000026U, 10));
    vlSelfRef.display_list_y[144U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[144U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[144U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[144U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[144U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[144U], 1U, 4));
    vlSelfRef.display_list_flip_x[144U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[144U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[144U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[144U], 0x0000000aU));
    vlSelfRef.display_list_priority[144U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[144U], 8U, 2));
    vlSelfRef.display_list_size[144U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[144U], 5U, 3));
    vlSelfRef.display_list_valid[144U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[144U], 0U));
    vlSelfRef.display_list_x[145U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[145U], 0x00000026U, 10));
    vlSelfRef.display_list_y[145U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[145U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[145U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[145U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[145U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[145U], 1U, 4));
    vlSelfRef.display_list_flip_x[145U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[145U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[145U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[145U], 0x0000000aU));
    vlSelfRef.display_list_priority[145U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[145U], 8U, 2));
    vlSelfRef.display_list_size[145U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[145U], 5U, 3));
    vlSelfRef.display_list_valid[145U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[145U], 0U));
    vlSelfRef.display_list_x[146U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[146U], 0x00000026U, 10));
    vlSelfRef.display_list_y[146U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[146U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[146U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[146U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[146U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[146U], 1U, 4));
    vlSelfRef.display_list_flip_x[146U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[146U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[146U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[146U], 0x0000000aU));
    vlSelfRef.display_list_priority[146U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[146U], 8U, 2));
    vlSelfRef.display_list_size[146U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[146U], 5U, 3));
    vlSelfRef.display_list_valid[146U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[146U], 0U));
    vlSelfRef.display_list_x[147U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[147U], 0x00000026U, 10));
    vlSelfRef.display_list_y[147U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[147U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[147U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[147U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[147U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[147U], 1U, 4));
    vlSelfRef.display_list_flip_x[147U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[147U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[147U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[147U], 0x0000000aU));
    vlSelfRef.display_list_priority[147U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[147U], 8U, 2));
    vlSelfRef.display_list_size[147U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[147U], 5U, 3));
    vlSelfRef.display_list_valid[147U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[147U], 0U));
    vlSelfRef.display_list_x[148U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[148U], 0x00000026U, 10));
    vlSelfRef.display_list_y[148U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[148U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[148U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[148U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[148U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[148U], 1U, 4));
    vlSelfRef.display_list_flip_x[148U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[148U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[148U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[148U], 0x0000000aU));
    vlSelfRef.display_list_priority[148U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[148U], 8U, 2));
    vlSelfRef.display_list_size[148U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[148U], 5U, 3));
    vlSelfRef.display_list_valid[148U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[148U], 0U));
    vlSelfRef.display_list_x[149U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[149U], 0x00000026U, 10));
    vlSelfRef.display_list_y[149U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[149U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[149U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[149U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[149U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[149U], 1U, 4));
    vlSelfRef.display_list_flip_x[149U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[149U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[149U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[149U], 0x0000000aU));
    vlSelfRef.display_list_priority[149U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[149U], 8U, 2));
    vlSelfRef.display_list_size[149U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[149U], 5U, 3));
    vlSelfRef.display_list_valid[149U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[149U], 0U));
    vlSelfRef.display_list_x[150U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[150U], 0x00000026U, 10));
    vlSelfRef.display_list_y[150U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[150U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[150U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[150U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[150U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[150U], 1U, 4));
    vlSelfRef.display_list_flip_x[150U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[150U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[150U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[150U], 0x0000000aU));
    vlSelfRef.display_list_priority[150U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[150U], 8U, 2));
    vlSelfRef.display_list_size[150U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[150U], 5U, 3));
    vlSelfRef.display_list_valid[150U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[150U], 0U));
    vlSelfRef.display_list_x[151U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[151U], 0x00000026U, 10));
    vlSelfRef.display_list_y[151U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[151U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[151U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[151U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[151U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[151U], 1U, 4));
    vlSelfRef.display_list_flip_x[151U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[151U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[151U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[151U], 0x0000000aU));
    vlSelfRef.display_list_priority[151U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[151U], 8U, 2));
    vlSelfRef.display_list_size[151U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[151U], 5U, 3));
    vlSelfRef.display_list_valid[151U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[151U], 0U));
    vlSelfRef.display_list_x[152U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[152U], 0x00000026U, 10));
    vlSelfRef.display_list_y[152U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[152U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[152U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[152U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[152U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[152U], 1U, 4));
    vlSelfRef.display_list_flip_x[152U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[152U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[152U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[152U], 0x0000000aU));
    vlSelfRef.display_list_priority[152U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[152U], 8U, 2));
    vlSelfRef.display_list_size[152U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[152U], 5U, 3));
    vlSelfRef.display_list_valid[152U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[152U], 0U));
    vlSelfRef.display_list_x[153U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[153U], 0x00000026U, 10));
    vlSelfRef.display_list_y[153U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[153U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[153U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[153U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[153U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[153U], 1U, 4));
    vlSelfRef.display_list_flip_x[153U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[153U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[153U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[153U], 0x0000000aU));
    vlSelfRef.display_list_priority[153U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[153U], 8U, 2));
    vlSelfRef.display_list_size[153U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[153U], 5U, 3));
    vlSelfRef.display_list_valid[153U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[153U], 0U));
    vlSelfRef.display_list_x[154U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[154U], 0x00000026U, 10));
    vlSelfRef.display_list_y[154U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[154U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[154U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[154U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[154U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[154U], 1U, 4));
    vlSelfRef.display_list_flip_x[154U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[154U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[154U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[154U], 0x0000000aU));
    vlSelfRef.display_list_priority[154U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[154U], 8U, 2));
    vlSelfRef.display_list_size[154U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[154U], 5U, 3));
    vlSelfRef.display_list_valid[154U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[154U], 0U));
    vlSelfRef.display_list_x[155U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[155U], 0x00000026U, 10));
    vlSelfRef.display_list_y[155U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[155U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[155U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[155U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[155U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[155U], 1U, 4));
    vlSelfRef.display_list_flip_x[155U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[155U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[155U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[155U], 0x0000000aU));
    vlSelfRef.display_list_priority[155U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[155U], 8U, 2));
    vlSelfRef.display_list_size[155U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[155U], 5U, 3));
    vlSelfRef.display_list_valid[155U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[155U], 0U));
    vlSelfRef.display_list_x[156U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[156U], 0x00000026U, 10));
    vlSelfRef.display_list_y[156U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[156U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[156U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[156U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[156U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[156U], 1U, 4));
    vlSelfRef.display_list_flip_x[156U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[156U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[156U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[156U], 0x0000000aU));
    vlSelfRef.display_list_priority[156U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[156U], 8U, 2));
    vlSelfRef.display_list_size[156U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[156U], 5U, 3));
    vlSelfRef.display_list_valid[156U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[156U], 0U));
    vlSelfRef.display_list_x[157U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[157U], 0x00000026U, 10));
    vlSelfRef.display_list_y[157U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[157U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[157U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[157U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[157U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[157U], 1U, 4));
    vlSelfRef.display_list_flip_x[157U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[157U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[157U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[157U], 0x0000000aU));
    vlSelfRef.display_list_priority[157U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[157U], 8U, 2));
    vlSelfRef.display_list_size[157U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[157U], 5U, 3));
    vlSelfRef.display_list_valid[157U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[157U], 0U));
    vlSelfRef.display_list_x[158U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[158U], 0x00000026U, 10));
    vlSelfRef.display_list_y[158U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[158U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[158U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[158U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[158U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[158U], 1U, 4));
    vlSelfRef.display_list_flip_x[158U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[158U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[158U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[158U], 0x0000000aU));
    vlSelfRef.display_list_priority[158U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[158U], 8U, 2));
    vlSelfRef.display_list_size[158U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[158U], 5U, 3));
    vlSelfRef.display_list_valid[158U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[158U], 0U));
    vlSelfRef.display_list_x[159U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[159U], 0x00000026U, 10));
    vlSelfRef.display_list_y[159U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[159U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[159U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[159U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[159U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[159U], 1U, 4));
    vlSelfRef.display_list_flip_x[159U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[159U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[159U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[159U], 0x0000000aU));
    vlSelfRef.display_list_priority[159U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[159U], 8U, 2));
    vlSelfRef.display_list_size[159U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[159U], 5U, 3));
    vlSelfRef.display_list_valid[159U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[159U], 0U));
    vlSelfRef.display_list_x[160U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[160U], 0x00000026U, 10));
    vlSelfRef.display_list_y[160U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[160U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[160U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[160U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[160U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[160U], 1U, 4));
    vlSelfRef.display_list_flip_x[160U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[160U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[160U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[160U], 0x0000000aU));
    vlSelfRef.display_list_priority[160U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[160U], 8U, 2));
    vlSelfRef.display_list_size[160U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[160U], 5U, 3));
    vlSelfRef.display_list_valid[160U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[160U], 0U));
    vlSelfRef.display_list_x[161U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[161U], 0x00000026U, 10));
    vlSelfRef.display_list_y[161U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[161U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[161U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[161U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[161U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[161U], 1U, 4));
    vlSelfRef.display_list_flip_x[161U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[161U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[161U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[161U], 0x0000000aU));
    vlSelfRef.display_list_priority[161U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[161U], 8U, 2));
    vlSelfRef.display_list_size[161U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[161U], 5U, 3));
    vlSelfRef.display_list_valid[161U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[161U], 0U));
    vlSelfRef.display_list_x[162U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[162U], 0x00000026U, 10));
    vlSelfRef.display_list_y[162U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[162U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[162U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[162U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[162U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[162U], 1U, 4));
    vlSelfRef.display_list_flip_x[162U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[162U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[162U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[162U], 0x0000000aU));
    vlSelfRef.display_list_priority[162U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[162U], 8U, 2));
    vlSelfRef.display_list_size[162U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[162U], 5U, 3));
    vlSelfRef.display_list_valid[162U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[162U], 0U));
    vlSelfRef.display_list_x[163U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[163U], 0x00000026U, 10));
    vlSelfRef.display_list_y[163U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[163U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[163U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[163U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[163U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[163U], 1U, 4));
    vlSelfRef.display_list_flip_x[163U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[163U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[163U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[163U], 0x0000000aU));
    vlSelfRef.display_list_priority[163U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[163U], 8U, 2));
    vlSelfRef.display_list_size[163U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[163U], 5U, 3));
    vlSelfRef.display_list_valid[163U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[163U], 0U));
    vlSelfRef.display_list_x[164U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[164U], 0x00000026U, 10));
    vlSelfRef.display_list_y[164U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[164U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[164U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[164U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[164U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[164U], 1U, 4));
    vlSelfRef.display_list_flip_x[164U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[164U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[164U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[164U], 0x0000000aU));
    vlSelfRef.display_list_priority[164U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[164U], 8U, 2));
    vlSelfRef.display_list_size[164U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[164U], 5U, 3));
    vlSelfRef.display_list_valid[164U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[164U], 0U));
    vlSelfRef.display_list_x[165U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[165U], 0x00000026U, 10));
    vlSelfRef.display_list_y[165U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[165U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[165U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[165U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[165U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[165U], 1U, 4));
    vlSelfRef.display_list_flip_x[165U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[165U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[165U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[165U], 0x0000000aU));
    vlSelfRef.display_list_priority[165U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[165U], 8U, 2));
    vlSelfRef.display_list_size[165U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[165U], 5U, 3));
    vlSelfRef.display_list_valid[165U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[165U], 0U));
    vlSelfRef.display_list_x[166U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[166U], 0x00000026U, 10));
    vlSelfRef.display_list_y[166U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[166U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[166U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[166U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[166U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[166U], 1U, 4));
    vlSelfRef.display_list_flip_x[166U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[166U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[166U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[166U], 0x0000000aU));
    vlSelfRef.display_list_priority[166U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[166U], 8U, 2));
    vlSelfRef.display_list_size[166U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[166U], 5U, 3));
    vlSelfRef.display_list_valid[166U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[166U], 0U));
    vlSelfRef.display_list_x[167U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[167U], 0x00000026U, 10));
    vlSelfRef.display_list_y[167U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[167U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[167U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[167U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[167U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[167U], 1U, 4));
    vlSelfRef.display_list_flip_x[167U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[167U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[167U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[167U], 0x0000000aU));
    vlSelfRef.display_list_priority[167U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[167U], 8U, 2));
    vlSelfRef.display_list_size[167U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[167U], 5U, 3));
    vlSelfRef.display_list_valid[167U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[167U], 0U));
    vlSelfRef.display_list_x[168U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[168U], 0x00000026U, 10));
    vlSelfRef.display_list_y[168U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[168U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[168U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[168U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[168U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[168U], 1U, 4));
    vlSelfRef.display_list_flip_x[168U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[168U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[168U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[168U], 0x0000000aU));
    vlSelfRef.display_list_priority[168U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[168U], 8U, 2));
    vlSelfRef.display_list_size[168U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[168U], 5U, 3));
    vlSelfRef.display_list_valid[168U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[168U], 0U));
    vlSelfRef.display_list_x[169U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[169U], 0x00000026U, 10));
    vlSelfRef.display_list_y[169U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[169U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[169U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[169U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[169U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[169U], 1U, 4));
    vlSelfRef.display_list_flip_x[169U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[169U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[169U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[169U], 0x0000000aU));
    vlSelfRef.display_list_priority[169U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[169U], 8U, 2));
    vlSelfRef.display_list_size[169U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[169U], 5U, 3));
    vlSelfRef.display_list_valid[169U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[169U], 0U));
    vlSelfRef.display_list_x[170U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[170U], 0x00000026U, 10));
    vlSelfRef.display_list_y[170U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[170U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[170U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[170U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[170U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[170U], 1U, 4));
    vlSelfRef.display_list_flip_x[170U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[170U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[170U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[170U], 0x0000000aU));
    vlSelfRef.display_list_priority[170U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[170U], 8U, 2));
    vlSelfRef.display_list_size[170U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[170U], 5U, 3));
    vlSelfRef.display_list_valid[170U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[170U], 0U));
    vlSelfRef.display_list_x[171U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[171U], 0x00000026U, 10));
    vlSelfRef.display_list_y[171U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[171U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[171U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[171U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[171U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[171U], 1U, 4));
    vlSelfRef.display_list_flip_x[171U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[171U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[171U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[171U], 0x0000000aU));
    vlSelfRef.display_list_priority[171U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[171U], 8U, 2));
    vlSelfRef.display_list_size[171U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[171U], 5U, 3));
    vlSelfRef.display_list_valid[171U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[171U], 0U));
    vlSelfRef.display_list_x[172U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[172U], 0x00000026U, 10));
    vlSelfRef.display_list_y[172U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[172U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[172U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[172U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[172U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[172U], 1U, 4));
    vlSelfRef.display_list_flip_x[172U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[172U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[172U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[172U], 0x0000000aU));
    vlSelfRef.display_list_priority[172U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[172U], 8U, 2));
    vlSelfRef.display_list_size[172U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[172U], 5U, 3));
    vlSelfRef.display_list_valid[172U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[172U], 0U));
    vlSelfRef.display_list_x[173U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[173U], 0x00000026U, 10));
    vlSelfRef.display_list_y[173U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[173U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[173U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[173U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[173U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[173U], 1U, 4));
    vlSelfRef.display_list_flip_x[173U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[173U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[173U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[173U], 0x0000000aU));
    vlSelfRef.display_list_priority[173U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[173U], 8U, 2));
    vlSelfRef.display_list_size[173U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[173U], 5U, 3));
    vlSelfRef.display_list_valid[173U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[173U], 0U));
    vlSelfRef.display_list_x[174U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[174U], 0x00000026U, 10));
    vlSelfRef.display_list_y[174U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[174U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[174U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[174U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[174U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[174U], 1U, 4));
    vlSelfRef.display_list_flip_x[174U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[174U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[174U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[174U], 0x0000000aU));
    vlSelfRef.display_list_priority[174U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[174U], 8U, 2));
    vlSelfRef.display_list_size[174U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[174U], 5U, 3));
    vlSelfRef.display_list_valid[174U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[174U], 0U));
    vlSelfRef.display_list_x[175U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[175U], 0x00000026U, 10));
    vlSelfRef.display_list_y[175U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[175U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[175U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[175U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[175U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[175U], 1U, 4));
    vlSelfRef.display_list_flip_x[175U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[175U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[175U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[175U], 0x0000000aU));
    vlSelfRef.display_list_priority[175U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[175U], 8U, 2));
    vlSelfRef.display_list_size[175U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[175U], 5U, 3));
    vlSelfRef.display_list_valid[175U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[175U], 0U));
    vlSelfRef.display_list_x[176U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[176U], 0x00000026U, 10));
    vlSelfRef.display_list_y[176U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[176U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[176U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[176U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[176U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[176U], 1U, 4));
    vlSelfRef.display_list_flip_x[176U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[176U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[176U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[176U], 0x0000000aU));
    vlSelfRef.display_list_priority[176U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[176U], 8U, 2));
    vlSelfRef.display_list_size[176U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[176U], 5U, 3));
    vlSelfRef.display_list_valid[176U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[176U], 0U));
    vlSelfRef.display_list_x[177U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[177U], 0x00000026U, 10));
    vlSelfRef.display_list_y[177U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[177U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[177U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[177U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[177U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[177U], 1U, 4));
    vlSelfRef.display_list_flip_x[177U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[177U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[177U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[177U], 0x0000000aU));
    vlSelfRef.display_list_priority[177U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[177U], 8U, 2));
    vlSelfRef.display_list_size[177U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[177U], 5U, 3));
    vlSelfRef.display_list_valid[177U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[177U], 0U));
    vlSelfRef.display_list_x[178U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[178U], 0x00000026U, 10));
    vlSelfRef.display_list_y[178U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[178U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[178U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[178U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[178U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[178U], 1U, 4));
    vlSelfRef.display_list_flip_x[178U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[178U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[178U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[178U], 0x0000000aU));
    vlSelfRef.display_list_priority[178U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[178U], 8U, 2));
    vlSelfRef.display_list_size[178U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[178U], 5U, 3));
    vlSelfRef.display_list_valid[178U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[178U], 0U));
    vlSelfRef.display_list_x[179U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[179U], 0x00000026U, 10));
    vlSelfRef.display_list_y[179U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[179U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[179U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[179U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[179U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[179U], 1U, 4));
    vlSelfRef.display_list_flip_x[179U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[179U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[179U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[179U], 0x0000000aU));
    vlSelfRef.display_list_priority[179U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[179U], 8U, 2));
    vlSelfRef.display_list_size[179U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[179U], 5U, 3));
    vlSelfRef.display_list_valid[179U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[179U], 0U));
    vlSelfRef.display_list_x[180U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[180U], 0x00000026U, 10));
    vlSelfRef.display_list_y[180U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[180U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[180U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[180U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[180U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[180U], 1U, 4));
    vlSelfRef.display_list_flip_x[180U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[180U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[180U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[180U], 0x0000000aU));
    vlSelfRef.display_list_priority[180U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[180U], 8U, 2));
    vlSelfRef.display_list_size[180U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[180U], 5U, 3));
    vlSelfRef.display_list_valid[180U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[180U], 0U));
    vlSelfRef.display_list_x[181U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[181U], 0x00000026U, 10));
    vlSelfRef.display_list_y[181U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[181U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[181U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[181U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[181U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[181U], 1U, 4));
    vlSelfRef.display_list_flip_x[181U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[181U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[181U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[181U], 0x0000000aU));
    vlSelfRef.display_list_priority[181U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[181U], 8U, 2));
    vlSelfRef.display_list_size[181U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[181U], 5U, 3));
    vlSelfRef.display_list_valid[181U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[181U], 0U));
    vlSelfRef.display_list_x[182U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[182U], 0x00000026U, 10));
    vlSelfRef.display_list_y[182U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[182U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[182U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[182U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[182U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[182U], 1U, 4));
    vlSelfRef.display_list_flip_x[182U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[182U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[182U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[182U], 0x0000000aU));
    vlSelfRef.display_list_priority[182U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[182U], 8U, 2));
    vlSelfRef.display_list_size[182U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[182U], 5U, 3));
    vlSelfRef.display_list_valid[182U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[182U], 0U));
    vlSelfRef.display_list_x[183U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[183U], 0x00000026U, 10));
    vlSelfRef.display_list_y[183U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[183U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[183U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[183U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[183U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[183U], 1U, 4));
    vlSelfRef.display_list_flip_x[183U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[183U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[183U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[183U], 0x0000000aU));
    vlSelfRef.display_list_priority[183U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[183U], 8U, 2));
    vlSelfRef.display_list_size[183U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[183U], 5U, 3));
    vlSelfRef.display_list_valid[183U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[183U], 0U));
    vlSelfRef.display_list_x[184U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[184U], 0x00000026U, 10));
    vlSelfRef.display_list_y[184U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[184U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[184U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[184U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[184U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[184U], 1U, 4));
    vlSelfRef.display_list_flip_x[184U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[184U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[184U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[184U], 0x0000000aU));
    vlSelfRef.display_list_priority[184U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[184U], 8U, 2));
    vlSelfRef.display_list_size[184U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[184U], 5U, 3));
    vlSelfRef.display_list_valid[184U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[184U], 0U));
    vlSelfRef.display_list_x[185U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[185U], 0x00000026U, 10));
    vlSelfRef.display_list_y[185U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[185U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[185U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[185U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[185U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[185U], 1U, 4));
    vlSelfRef.display_list_flip_x[185U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[185U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[185U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[185U], 0x0000000aU));
    vlSelfRef.display_list_priority[185U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[185U], 8U, 2));
    vlSelfRef.display_list_size[185U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[185U], 5U, 3));
    vlSelfRef.display_list_valid[185U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[185U], 0U));
    vlSelfRef.display_list_x[186U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[186U], 0x00000026U, 10));
    vlSelfRef.display_list_y[186U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[186U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[186U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[186U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[186U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[186U], 1U, 4));
    vlSelfRef.display_list_flip_x[186U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[186U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[186U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[186U], 0x0000000aU));
    vlSelfRef.display_list_priority[186U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[186U], 8U, 2));
    vlSelfRef.display_list_size[186U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[186U], 5U, 3));
    vlSelfRef.display_list_valid[186U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[186U], 0U));
    vlSelfRef.display_list_x[187U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[187U], 0x00000026U, 10));
    vlSelfRef.display_list_y[187U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[187U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[187U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[187U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[187U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[187U], 1U, 4));
    vlSelfRef.display_list_flip_x[187U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[187U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[187U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[187U], 0x0000000aU));
    vlSelfRef.display_list_priority[187U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[187U], 8U, 2));
    vlSelfRef.display_list_size[187U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[187U], 5U, 3));
    vlSelfRef.display_list_valid[187U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[187U], 0U));
    vlSelfRef.display_list_x[188U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[188U], 0x00000026U, 10));
    vlSelfRef.display_list_y[188U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[188U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[188U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[188U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[188U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[188U], 1U, 4));
    vlSelfRef.display_list_flip_x[188U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[188U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[188U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[188U], 0x0000000aU));
    vlSelfRef.display_list_priority[188U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[188U], 8U, 2));
    vlSelfRef.display_list_size[188U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[188U], 5U, 3));
    vlSelfRef.display_list_valid[188U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[188U], 0U));
    vlSelfRef.display_list_x[189U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[189U], 0x00000026U, 10));
    vlSelfRef.display_list_y[189U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[189U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[189U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[189U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[189U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[189U], 1U, 4));
    vlSelfRef.display_list_flip_x[189U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[189U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[189U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[189U], 0x0000000aU));
    vlSelfRef.display_list_priority[189U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[189U], 8U, 2));
    vlSelfRef.display_list_size[189U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[189U], 5U, 3));
    vlSelfRef.display_list_valid[189U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[189U], 0U));
    vlSelfRef.display_list_x[190U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[190U], 0x00000026U, 10));
    vlSelfRef.display_list_y[190U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[190U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[190U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[190U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[190U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[190U], 1U, 4));
    vlSelfRef.display_list_flip_x[190U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[190U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[190U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[190U], 0x0000000aU));
    vlSelfRef.display_list_priority[190U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[190U], 8U, 2));
    vlSelfRef.display_list_size[190U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[190U], 5U, 3));
    vlSelfRef.display_list_valid[190U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[190U], 0U));
    vlSelfRef.display_list_x[191U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[191U], 0x00000026U, 10));
    vlSelfRef.display_list_y[191U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[191U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[191U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[191U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[191U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[191U], 1U, 4));
    vlSelfRef.display_list_flip_x[191U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[191U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[191U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[191U], 0x0000000aU));
    vlSelfRef.display_list_priority[191U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[191U], 8U, 2));
    vlSelfRef.display_list_size[191U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[191U], 5U, 3));
    vlSelfRef.display_list_valid[191U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[191U], 0U));
    vlSelfRef.display_list_x[192U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[192U], 0x00000026U, 10));
    vlSelfRef.display_list_y[192U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[192U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[192U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[192U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[192U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[192U], 1U, 4));
    vlSelfRef.display_list_flip_x[192U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[192U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[192U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[192U], 0x0000000aU));
    vlSelfRef.display_list_priority[192U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[192U], 8U, 2));
    vlSelfRef.display_list_size[192U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[192U], 5U, 3));
    vlSelfRef.display_list_valid[192U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[192U], 0U));
    vlSelfRef.display_list_x[193U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[193U], 0x00000026U, 10));
    vlSelfRef.display_list_y[193U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[193U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[193U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[193U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[193U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[193U], 1U, 4));
    vlSelfRef.display_list_flip_x[193U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[193U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[193U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[193U], 0x0000000aU));
    vlSelfRef.display_list_priority[193U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[193U], 8U, 2));
    vlSelfRef.display_list_size[193U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[193U], 5U, 3));
    vlSelfRef.display_list_valid[193U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[193U], 0U));
    vlSelfRef.display_list_x[194U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[194U], 0x00000026U, 10));
    vlSelfRef.display_list_y[194U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[194U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[194U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[194U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[194U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[194U], 1U, 4));
    vlSelfRef.display_list_flip_x[194U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[194U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[194U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[194U], 0x0000000aU));
    vlSelfRef.display_list_priority[194U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[194U], 8U, 2));
    vlSelfRef.display_list_size[194U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[194U], 5U, 3));
    vlSelfRef.display_list_valid[194U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[194U], 0U));
    vlSelfRef.display_list_x[195U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[195U], 0x00000026U, 10));
    vlSelfRef.display_list_y[195U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[195U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[195U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[195U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[195U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[195U], 1U, 4));
    vlSelfRef.display_list_flip_x[195U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[195U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[195U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[195U], 0x0000000aU));
    vlSelfRef.display_list_priority[195U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[195U], 8U, 2));
    vlSelfRef.display_list_size[195U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[195U], 5U, 3));
    vlSelfRef.display_list_valid[195U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[195U], 0U));
    vlSelfRef.display_list_x[196U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[196U], 0x00000026U, 10));
    vlSelfRef.display_list_y[196U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[196U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[196U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[196U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[196U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[196U], 1U, 4));
    vlSelfRef.display_list_flip_x[196U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[196U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[196U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[196U], 0x0000000aU));
    vlSelfRef.display_list_priority[196U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[196U], 8U, 2));
    vlSelfRef.display_list_size[196U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[196U], 5U, 3));
    vlSelfRef.display_list_valid[196U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[196U], 0U));
    vlSelfRef.display_list_x[197U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[197U], 0x00000026U, 10));
    vlSelfRef.display_list_y[197U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[197U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[197U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[197U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[197U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[197U], 1U, 4));
    vlSelfRef.display_list_flip_x[197U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[197U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[197U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[197U], 0x0000000aU));
    vlSelfRef.display_list_priority[197U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[197U], 8U, 2));
    vlSelfRef.display_list_size[197U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[197U], 5U, 3));
    vlSelfRef.display_list_valid[197U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[197U], 0U));
    vlSelfRef.display_list_x[198U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[198U], 0x00000026U, 10));
    vlSelfRef.display_list_y[198U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[198U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[198U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[198U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[198U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[198U], 1U, 4));
    vlSelfRef.display_list_flip_x[198U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[198U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[198U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[198U], 0x0000000aU));
    vlSelfRef.display_list_priority[198U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[198U], 8U, 2));
    vlSelfRef.display_list_size[198U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[198U], 5U, 3));
    vlSelfRef.display_list_valid[198U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[198U], 0U));
    vlSelfRef.display_list_x[199U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[199U], 0x00000026U, 10));
    vlSelfRef.display_list_y[199U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[199U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[199U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[199U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[199U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[199U], 1U, 4));
    vlSelfRef.display_list_flip_x[199U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[199U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[199U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[199U], 0x0000000aU));
    vlSelfRef.display_list_priority[199U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[199U], 8U, 2));
    vlSelfRef.display_list_size[199U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[199U], 5U, 3));
    vlSelfRef.display_list_valid[199U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[199U], 0U));
    vlSelfRef.display_list_x[200U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[200U], 0x00000026U, 10));
    vlSelfRef.display_list_y[200U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[200U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[200U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[200U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[200U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[200U], 1U, 4));
    vlSelfRef.display_list_flip_x[200U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[200U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[200U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[200U], 0x0000000aU));
    vlSelfRef.display_list_priority[200U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[200U], 8U, 2));
    vlSelfRef.display_list_size[200U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[200U], 5U, 3));
    vlSelfRef.display_list_valid[200U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[200U], 0U));
    vlSelfRef.display_list_x[201U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[201U], 0x00000026U, 10));
    vlSelfRef.display_list_y[201U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[201U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[201U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[201U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[201U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[201U], 1U, 4));
    vlSelfRef.display_list_flip_x[201U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[201U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[201U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[201U], 0x0000000aU));
    vlSelfRef.display_list_priority[201U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[201U], 8U, 2));
    vlSelfRef.display_list_size[201U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[201U], 5U, 3));
    vlSelfRef.display_list_valid[201U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[201U], 0U));
    vlSelfRef.display_list_x[202U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[202U], 0x00000026U, 10));
    vlSelfRef.display_list_y[202U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[202U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[202U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[202U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[202U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[202U], 1U, 4));
    vlSelfRef.display_list_flip_x[202U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[202U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[202U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[202U], 0x0000000aU));
    vlSelfRef.display_list_priority[202U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[202U], 8U, 2));
    vlSelfRef.display_list_size[202U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[202U], 5U, 3));
    vlSelfRef.display_list_valid[202U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[202U], 0U));
    vlSelfRef.display_list_x[203U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[203U], 0x00000026U, 10));
    vlSelfRef.display_list_y[203U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[203U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[203U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[203U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[203U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[203U], 1U, 4));
    vlSelfRef.display_list_flip_x[203U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[203U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[203U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[203U], 0x0000000aU));
    vlSelfRef.display_list_priority[203U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[203U], 8U, 2));
    vlSelfRef.display_list_size[203U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[203U], 5U, 3));
    vlSelfRef.display_list_valid[203U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[203U], 0U));
    vlSelfRef.display_list_x[204U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[204U], 0x00000026U, 10));
    vlSelfRef.display_list_y[204U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[204U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[204U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[204U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[204U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[204U], 1U, 4));
    vlSelfRef.display_list_flip_x[204U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[204U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[204U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[204U], 0x0000000aU));
    vlSelfRef.display_list_priority[204U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[204U], 8U, 2));
    vlSelfRef.display_list_size[204U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[204U], 5U, 3));
    vlSelfRef.display_list_valid[204U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[204U], 0U));
    vlSelfRef.display_list_x[205U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[205U], 0x00000026U, 10));
    vlSelfRef.display_list_y[205U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[205U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[205U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[205U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[205U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[205U], 1U, 4));
    vlSelfRef.display_list_flip_x[205U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[205U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[205U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[205U], 0x0000000aU));
    vlSelfRef.display_list_priority[205U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[205U], 8U, 2));
    vlSelfRef.display_list_size[205U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[205U], 5U, 3));
    vlSelfRef.display_list_valid[205U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[205U], 0U));
    vlSelfRef.display_list_x[206U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[206U], 0x00000026U, 10));
    vlSelfRef.display_list_y[206U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[206U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[206U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[206U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[206U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[206U], 1U, 4));
    vlSelfRef.display_list_flip_x[206U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[206U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[206U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[206U], 0x0000000aU));
    vlSelfRef.display_list_priority[206U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[206U], 8U, 2));
    vlSelfRef.display_list_size[206U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[206U], 5U, 3));
    vlSelfRef.display_list_valid[206U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[206U], 0U));
    vlSelfRef.display_list_x[207U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[207U], 0x00000026U, 10));
    vlSelfRef.display_list_y[207U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[207U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[207U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[207U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[207U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[207U], 1U, 4));
    vlSelfRef.display_list_flip_x[207U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[207U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[207U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[207U], 0x0000000aU));
    vlSelfRef.display_list_priority[207U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[207U], 8U, 2));
    vlSelfRef.display_list_size[207U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[207U], 5U, 3));
    vlSelfRef.display_list_valid[207U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[207U], 0U));
    vlSelfRef.display_list_x[208U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[208U], 0x00000026U, 10));
    vlSelfRef.display_list_y[208U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[208U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[208U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[208U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[208U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[208U], 1U, 4));
    vlSelfRef.display_list_flip_x[208U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[208U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[208U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[208U], 0x0000000aU));
    vlSelfRef.display_list_priority[208U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[208U], 8U, 2));
    vlSelfRef.display_list_size[208U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[208U], 5U, 3));
    vlSelfRef.display_list_valid[208U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[208U], 0U));
    vlSelfRef.display_list_x[209U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[209U], 0x00000026U, 10));
    vlSelfRef.display_list_y[209U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[209U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[209U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[209U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[209U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[209U], 1U, 4));
    vlSelfRef.display_list_flip_x[209U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[209U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[209U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[209U], 0x0000000aU));
    vlSelfRef.display_list_priority[209U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[209U], 8U, 2));
    vlSelfRef.display_list_size[209U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[209U], 5U, 3));
    vlSelfRef.display_list_valid[209U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[209U], 0U));
    vlSelfRef.display_list_x[210U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[210U], 0x00000026U, 10));
    vlSelfRef.display_list_y[210U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[210U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[210U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[210U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[210U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[210U], 1U, 4));
    vlSelfRef.display_list_flip_x[210U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[210U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[210U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[210U], 0x0000000aU));
    vlSelfRef.display_list_priority[210U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[210U], 8U, 2));
    vlSelfRef.display_list_size[210U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[210U], 5U, 3));
    vlSelfRef.display_list_valid[210U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[210U], 0U));
    vlSelfRef.display_list_x[211U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[211U], 0x00000026U, 10));
    vlSelfRef.display_list_y[211U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[211U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[211U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[211U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[211U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[211U], 1U, 4));
    vlSelfRef.display_list_flip_x[211U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[211U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[211U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[211U], 0x0000000aU));
    vlSelfRef.display_list_priority[211U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[211U], 8U, 2));
    vlSelfRef.display_list_size[211U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[211U], 5U, 3));
    vlSelfRef.display_list_valid[211U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[211U], 0U));
    vlSelfRef.display_list_x[212U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[212U], 0x00000026U, 10));
    vlSelfRef.display_list_y[212U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[212U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[212U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[212U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[212U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[212U], 1U, 4));
    vlSelfRef.display_list_flip_x[212U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[212U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[212U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[212U], 0x0000000aU));
    vlSelfRef.display_list_priority[212U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[212U], 8U, 2));
    vlSelfRef.display_list_size[212U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[212U], 5U, 3));
    vlSelfRef.display_list_valid[212U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[212U], 0U));
    vlSelfRef.display_list_x[213U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[213U], 0x00000026U, 10));
    vlSelfRef.display_list_y[213U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[213U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[213U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[213U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[213U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[213U], 1U, 4));
    vlSelfRef.display_list_flip_x[213U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[213U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[213U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[213U], 0x0000000aU));
    vlSelfRef.display_list_priority[213U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[213U], 8U, 2));
    vlSelfRef.display_list_size[213U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[213U], 5U, 3));
    vlSelfRef.display_list_valid[213U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[213U], 0U));
    vlSelfRef.display_list_x[214U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[214U], 0x00000026U, 10));
    vlSelfRef.display_list_y[214U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[214U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[214U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[214U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[214U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[214U], 1U, 4));
    vlSelfRef.display_list_flip_x[214U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[214U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[214U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[214U], 0x0000000aU));
    vlSelfRef.display_list_priority[214U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[214U], 8U, 2));
    vlSelfRef.display_list_size[214U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[214U], 5U, 3));
    vlSelfRef.display_list_valid[214U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[214U], 0U));
    vlSelfRef.display_list_x[215U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[215U], 0x00000026U, 10));
    vlSelfRef.display_list_y[215U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[215U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[215U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[215U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[215U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[215U], 1U, 4));
    vlSelfRef.display_list_flip_x[215U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[215U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[215U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[215U], 0x0000000aU));
    vlSelfRef.display_list_priority[215U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[215U], 8U, 2));
    vlSelfRef.display_list_size[215U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[215U], 5U, 3));
    vlSelfRef.display_list_valid[215U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[215U], 0U));
    vlSelfRef.display_list_x[216U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[216U], 0x00000026U, 10));
    vlSelfRef.display_list_y[216U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[216U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[216U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[216U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[216U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[216U], 1U, 4));
    vlSelfRef.display_list_flip_x[216U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[216U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[216U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[216U], 0x0000000aU));
    vlSelfRef.display_list_priority[216U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[216U], 8U, 2));
    vlSelfRef.display_list_size[216U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[216U], 5U, 3));
    vlSelfRef.display_list_valid[216U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[216U], 0U));
    vlSelfRef.display_list_x[217U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[217U], 0x00000026U, 10));
    vlSelfRef.display_list_y[217U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[217U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[217U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[217U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[217U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[217U], 1U, 4));
    vlSelfRef.display_list_flip_x[217U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[217U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[217U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[217U], 0x0000000aU));
    vlSelfRef.display_list_priority[217U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[217U], 8U, 2));
    vlSelfRef.display_list_size[217U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[217U], 5U, 3));
    vlSelfRef.display_list_valid[217U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[217U], 0U));
    vlSelfRef.display_list_x[218U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[218U], 0x00000026U, 10));
    vlSelfRef.display_list_y[218U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[218U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[218U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[218U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[218U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[218U], 1U, 4));
    vlSelfRef.display_list_flip_x[218U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[218U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[218U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[218U], 0x0000000aU));
    vlSelfRef.display_list_priority[218U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[218U], 8U, 2));
    vlSelfRef.display_list_size[218U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[218U], 5U, 3));
    vlSelfRef.display_list_valid[218U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[218U], 0U));
    vlSelfRef.display_list_x[219U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[219U], 0x00000026U, 10));
    vlSelfRef.display_list_y[219U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[219U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[219U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[219U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[219U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[219U], 1U, 4));
    vlSelfRef.display_list_flip_x[219U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[219U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[219U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[219U], 0x0000000aU));
    vlSelfRef.display_list_priority[219U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[219U], 8U, 2));
    vlSelfRef.display_list_size[219U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[219U], 5U, 3));
    vlSelfRef.display_list_valid[219U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[219U], 0U));
    vlSelfRef.display_list_x[220U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[220U], 0x00000026U, 10));
    vlSelfRef.display_list_y[220U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[220U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[220U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[220U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[220U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[220U], 1U, 4));
    vlSelfRef.display_list_flip_x[220U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[220U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[220U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[220U], 0x0000000aU));
    vlSelfRef.display_list_priority[220U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[220U], 8U, 2));
    vlSelfRef.display_list_size[220U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[220U], 5U, 3));
    vlSelfRef.display_list_valid[220U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[220U], 0U));
    vlSelfRef.display_list_x[221U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[221U], 0x00000026U, 10));
    vlSelfRef.display_list_y[221U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[221U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[221U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[221U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[221U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[221U], 1U, 4));
    vlSelfRef.display_list_flip_x[221U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[221U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[221U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[221U], 0x0000000aU));
    vlSelfRef.display_list_priority[221U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[221U], 8U, 2));
    vlSelfRef.display_list_size[221U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[221U], 5U, 3));
    vlSelfRef.display_list_valid[221U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[221U], 0U));
    vlSelfRef.display_list_x[222U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[222U], 0x00000026U, 10));
    vlSelfRef.display_list_y[222U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[222U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[222U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[222U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[222U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[222U], 1U, 4));
    vlSelfRef.display_list_flip_x[222U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[222U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[222U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[222U], 0x0000000aU));
    vlSelfRef.display_list_priority[222U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[222U], 8U, 2));
    vlSelfRef.display_list_size[222U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[222U], 5U, 3));
    vlSelfRef.display_list_valid[222U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[222U], 0U));
    vlSelfRef.display_list_x[223U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[223U], 0x00000026U, 10));
    vlSelfRef.display_list_y[223U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[223U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[223U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[223U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[223U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[223U], 1U, 4));
    vlSelfRef.display_list_flip_x[223U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[223U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[223U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[223U], 0x0000000aU));
    vlSelfRef.display_list_priority[223U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[223U], 8U, 2));
    vlSelfRef.display_list_size[223U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[223U], 5U, 3));
    vlSelfRef.display_list_valid[223U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[223U], 0U));
    vlSelfRef.display_list_x[224U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[224U], 0x00000026U, 10));
    vlSelfRef.display_list_y[224U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[224U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[224U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[224U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[224U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[224U], 1U, 4));
    vlSelfRef.display_list_flip_x[224U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[224U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[224U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[224U], 0x0000000aU));
    vlSelfRef.display_list_priority[224U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[224U], 8U, 2));
    vlSelfRef.display_list_size[224U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[224U], 5U, 3));
    vlSelfRef.display_list_valid[224U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[224U], 0U));
    vlSelfRef.display_list_x[225U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[225U], 0x00000026U, 10));
    vlSelfRef.display_list_y[225U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[225U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[225U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[225U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[225U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[225U], 1U, 4));
    vlSelfRef.display_list_flip_x[225U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[225U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[225U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[225U], 0x0000000aU));
    vlSelfRef.display_list_priority[225U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[225U], 8U, 2));
    vlSelfRef.display_list_size[225U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[225U], 5U, 3));
    vlSelfRef.display_list_valid[225U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[225U], 0U));
    vlSelfRef.display_list_x[226U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[226U], 0x00000026U, 10));
    vlSelfRef.display_list_y[226U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[226U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[226U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[226U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[226U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[226U], 1U, 4));
    vlSelfRef.display_list_flip_x[226U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[226U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[226U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[226U], 0x0000000aU));
    vlSelfRef.display_list_priority[226U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[226U], 8U, 2));
    vlSelfRef.display_list_size[226U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[226U], 5U, 3));
    vlSelfRef.display_list_valid[226U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[226U], 0U));
    vlSelfRef.display_list_x[227U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[227U], 0x00000026U, 10));
    vlSelfRef.display_list_y[227U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[227U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[227U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[227U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[227U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[227U], 1U, 4));
    vlSelfRef.display_list_flip_x[227U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[227U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[227U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[227U], 0x0000000aU));
    vlSelfRef.display_list_priority[227U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[227U], 8U, 2));
    vlSelfRef.display_list_size[227U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[227U], 5U, 3));
    vlSelfRef.display_list_valid[227U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[227U], 0U));
    vlSelfRef.display_list_x[228U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[228U], 0x00000026U, 10));
    vlSelfRef.display_list_y[228U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[228U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[228U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[228U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[228U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[228U], 1U, 4));
    vlSelfRef.display_list_flip_x[228U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[228U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[228U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[228U], 0x0000000aU));
    vlSelfRef.display_list_priority[228U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[228U], 8U, 2));
    vlSelfRef.display_list_size[228U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[228U], 5U, 3));
    vlSelfRef.display_list_valid[228U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[228U], 0U));
    vlSelfRef.display_list_x[229U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[229U], 0x00000026U, 10));
    vlSelfRef.display_list_y[229U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[229U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[229U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[229U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[229U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[229U], 1U, 4));
    vlSelfRef.display_list_flip_x[229U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[229U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[229U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[229U], 0x0000000aU));
    vlSelfRef.display_list_priority[229U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[229U], 8U, 2));
    vlSelfRef.display_list_size[229U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[229U], 5U, 3));
    vlSelfRef.display_list_valid[229U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[229U], 0U));
    vlSelfRef.display_list_x[230U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[230U], 0x00000026U, 10));
    vlSelfRef.display_list_y[230U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[230U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[230U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[230U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[230U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[230U], 1U, 4));
    vlSelfRef.display_list_flip_x[230U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[230U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[230U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[230U], 0x0000000aU));
    vlSelfRef.display_list_priority[230U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[230U], 8U, 2));
    vlSelfRef.display_list_size[230U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[230U], 5U, 3));
    vlSelfRef.display_list_valid[230U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[230U], 0U));
    vlSelfRef.display_list_x[231U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[231U], 0x00000026U, 10));
    vlSelfRef.display_list_y[231U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[231U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[231U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[231U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[231U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[231U], 1U, 4));
    vlSelfRef.display_list_flip_x[231U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[231U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[231U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[231U], 0x0000000aU));
    vlSelfRef.display_list_priority[231U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[231U], 8U, 2));
    vlSelfRef.display_list_size[231U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[231U], 5U, 3));
    vlSelfRef.display_list_valid[231U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[231U], 0U));
    vlSelfRef.display_list_x[232U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[232U], 0x00000026U, 10));
    vlSelfRef.display_list_y[232U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[232U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[232U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[232U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[232U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[232U], 1U, 4));
    vlSelfRef.display_list_flip_x[232U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[232U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[232U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[232U], 0x0000000aU));
    vlSelfRef.display_list_priority[232U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[232U], 8U, 2));
    vlSelfRef.display_list_size[232U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[232U], 5U, 3));
    vlSelfRef.display_list_valid[232U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[232U], 0U));
    vlSelfRef.display_list_x[233U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[233U], 0x00000026U, 10));
    vlSelfRef.display_list_y[233U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[233U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[233U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[233U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[233U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[233U], 1U, 4));
    vlSelfRef.display_list_flip_x[233U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[233U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[233U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[233U], 0x0000000aU));
    vlSelfRef.display_list_priority[233U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[233U], 8U, 2));
    vlSelfRef.display_list_size[233U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[233U], 5U, 3));
    vlSelfRef.display_list_valid[233U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[233U], 0U));
    vlSelfRef.display_list_x[234U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[234U], 0x00000026U, 10));
    vlSelfRef.display_list_y[234U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[234U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[234U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[234U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[234U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[234U], 1U, 4));
    vlSelfRef.display_list_flip_x[234U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[234U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[234U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[234U], 0x0000000aU));
    vlSelfRef.display_list_priority[234U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[234U], 8U, 2));
    vlSelfRef.display_list_size[234U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[234U], 5U, 3));
    vlSelfRef.display_list_valid[234U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[234U], 0U));
    vlSelfRef.display_list_x[235U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[235U], 0x00000026U, 10));
    vlSelfRef.display_list_y[235U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[235U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[235U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[235U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[235U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[235U], 1U, 4));
    vlSelfRef.display_list_flip_x[235U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[235U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[235U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[235U], 0x0000000aU));
    vlSelfRef.display_list_priority[235U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[235U], 8U, 2));
    vlSelfRef.display_list_size[235U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[235U], 5U, 3));
    vlSelfRef.display_list_valid[235U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[235U], 0U));
    vlSelfRef.display_list_x[236U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[236U], 0x00000026U, 10));
    vlSelfRef.display_list_y[236U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[236U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[236U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[236U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[236U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[236U], 1U, 4));
    vlSelfRef.display_list_flip_x[236U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[236U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[236U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[236U], 0x0000000aU));
    vlSelfRef.display_list_priority[236U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[236U], 8U, 2));
    vlSelfRef.display_list_size[236U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[236U], 5U, 3));
    vlSelfRef.display_list_valid[236U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[236U], 0U));
    vlSelfRef.display_list_x[237U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[237U], 0x00000026U, 10));
    vlSelfRef.display_list_y[237U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[237U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[237U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[237U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[237U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[237U], 1U, 4));
    vlSelfRef.display_list_flip_x[237U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[237U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[237U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[237U], 0x0000000aU));
    vlSelfRef.display_list_priority[237U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[237U], 8U, 2));
    vlSelfRef.display_list_size[237U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[237U], 5U, 3));
    vlSelfRef.display_list_valid[237U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[237U], 0U));
    vlSelfRef.display_list_x[238U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[238U], 0x00000026U, 10));
    vlSelfRef.display_list_y[238U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[238U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[238U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[238U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[238U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[238U], 1U, 4));
    vlSelfRef.display_list_flip_x[238U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[238U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[238U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[238U], 0x0000000aU));
    vlSelfRef.display_list_priority[238U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[238U], 8U, 2));
    vlSelfRef.display_list_size[238U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[238U], 5U, 3));
    vlSelfRef.display_list_valid[238U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[238U], 0U));
    vlSelfRef.display_list_x[239U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[239U], 0x00000026U, 10));
    vlSelfRef.display_list_y[239U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[239U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[239U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[239U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[239U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[239U], 1U, 4));
    vlSelfRef.display_list_flip_x[239U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[239U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[239U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[239U], 0x0000000aU));
    vlSelfRef.display_list_priority[239U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[239U], 8U, 2));
    vlSelfRef.display_list_size[239U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[239U], 5U, 3));
    vlSelfRef.display_list_valid[239U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[239U], 0U));
    vlSelfRef.display_list_x[240U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[240U], 0x00000026U, 10));
    vlSelfRef.display_list_y[240U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[240U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[240U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[240U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[240U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[240U], 1U, 4));
    vlSelfRef.display_list_flip_x[240U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[240U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[240U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[240U], 0x0000000aU));
    vlSelfRef.display_list_priority[240U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[240U], 8U, 2));
    vlSelfRef.display_list_size[240U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[240U], 5U, 3));
    vlSelfRef.display_list_valid[240U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[240U], 0U));
    vlSelfRef.display_list_x[241U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[241U], 0x00000026U, 10));
    vlSelfRef.display_list_y[241U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[241U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[241U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[241U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[241U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[241U], 1U, 4));
    vlSelfRef.display_list_flip_x[241U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[241U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[241U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[241U], 0x0000000aU));
    vlSelfRef.display_list_priority[241U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[241U], 8U, 2));
    vlSelfRef.display_list_size[241U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[241U], 5U, 3));
    vlSelfRef.display_list_valid[241U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[241U], 0U));
    vlSelfRef.display_list_x[242U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[242U], 0x00000026U, 10));
    vlSelfRef.display_list_y[242U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[242U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[242U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[242U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[242U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[242U], 1U, 4));
    vlSelfRef.display_list_flip_x[242U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[242U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[242U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[242U], 0x0000000aU));
    vlSelfRef.display_list_priority[242U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[242U], 8U, 2));
    vlSelfRef.display_list_size[242U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[242U], 5U, 3));
    vlSelfRef.display_list_valid[242U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[242U], 0U));
    vlSelfRef.display_list_x[243U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[243U], 0x00000026U, 10));
    vlSelfRef.display_list_y[243U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[243U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[243U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[243U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[243U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[243U], 1U, 4));
    vlSelfRef.display_list_flip_x[243U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[243U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[243U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[243U], 0x0000000aU));
}
