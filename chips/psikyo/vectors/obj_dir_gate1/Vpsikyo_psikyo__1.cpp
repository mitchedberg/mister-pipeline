// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vpsikyo.h for the primary calling header

#include "Vpsikyo__pch.h"

void Vpsikyo_psikyo___nba_sequent__TOP__psikyo__1(Vpsikyo_psikyo* vlSelf) {
    VL_DEBUG_IF(VL_DBG_MSGF("+      Vpsikyo_psikyo___nba_sequent__TOP__psikyo__1\n"); );
    Vpsikyo__Syms* const __restrict vlSymsp VL_ATTR_UNUSED = vlSelf->vlSymsp;
    auto& vlSelfRef = std::ref(*vlSelf).get();
    // Body
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
    vlSelfRef.display_list_priority[243U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[243U], 8U, 2));
    vlSelfRef.display_list_size[243U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[243U], 5U, 3));
    vlSelfRef.display_list_valid[243U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[243U], 0U));
    vlSelfRef.display_list_x[244U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[244U], 0x00000026U, 10));
    vlSelfRef.display_list_y[244U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[244U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[244U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[244U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[244U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[244U], 1U, 4));
    vlSelfRef.display_list_flip_x[244U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[244U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[244U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[244U], 0x0000000aU));
    vlSelfRef.display_list_priority[244U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[244U], 8U, 2));
    vlSelfRef.display_list_size[244U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[244U], 5U, 3));
    vlSelfRef.display_list_valid[244U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[244U], 0U));
    vlSelfRef.display_list_x[245U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[245U], 0x00000026U, 10));
    vlSelfRef.display_list_y[245U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[245U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[245U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[245U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[245U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[245U], 1U, 4));
    vlSelfRef.display_list_flip_x[245U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[245U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[245U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[245U], 0x0000000aU));
    vlSelfRef.display_list_priority[245U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[245U], 8U, 2));
    vlSelfRef.display_list_size[245U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[245U], 5U, 3));
    vlSelfRef.display_list_valid[245U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[245U], 0U));
    vlSelfRef.display_list_x[246U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[246U], 0x00000026U, 10));
    vlSelfRef.display_list_y[246U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[246U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[246U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[246U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[246U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[246U], 1U, 4));
    vlSelfRef.display_list_flip_x[246U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[246U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[246U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[246U], 0x0000000aU));
    vlSelfRef.display_list_priority[246U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[246U], 8U, 2));
    vlSelfRef.display_list_size[246U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[246U], 5U, 3));
    vlSelfRef.display_list_valid[246U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[246U], 0U));
    vlSelfRef.display_list_x[247U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[247U], 0x00000026U, 10));
    vlSelfRef.display_list_y[247U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[247U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[247U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[247U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[247U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[247U], 1U, 4));
    vlSelfRef.display_list_flip_x[247U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[247U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[247U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[247U], 0x0000000aU));
    vlSelfRef.display_list_priority[247U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[247U], 8U, 2));
    vlSelfRef.display_list_size[247U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[247U], 5U, 3));
    vlSelfRef.display_list_valid[247U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[247U], 0U));
    vlSelfRef.display_list_x[248U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[248U], 0x00000026U, 10));
    vlSelfRef.display_list_y[248U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[248U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[248U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[248U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[248U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[248U], 1U, 4));
    vlSelfRef.display_list_flip_x[248U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[248U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[248U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[248U], 0x0000000aU));
    vlSelfRef.display_list_priority[248U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[248U], 8U, 2));
    vlSelfRef.display_list_size[248U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[248U], 5U, 3));
    vlSelfRef.display_list_valid[248U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[248U], 0U));
    vlSelfRef.display_list_x[249U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[249U], 0x00000026U, 10));
    vlSelfRef.display_list_y[249U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[249U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[249U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[249U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[249U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[249U], 1U, 4));
    vlSelfRef.display_list_flip_x[249U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[249U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[249U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[249U], 0x0000000aU));
    vlSelfRef.display_list_priority[249U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[249U], 8U, 2));
    vlSelfRef.display_list_size[249U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[249U], 5U, 3));
    vlSelfRef.display_list_valid[249U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[249U], 0U));
    vlSelfRef.display_list_x[250U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[250U], 0x00000026U, 10));
    vlSelfRef.display_list_y[250U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[250U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[250U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[250U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[250U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[250U], 1U, 4));
    vlSelfRef.display_list_flip_x[250U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[250U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[250U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[250U], 0x0000000aU));
    vlSelfRef.display_list_priority[250U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[250U], 8U, 2));
    vlSelfRef.display_list_size[250U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[250U], 5U, 3));
    vlSelfRef.display_list_valid[250U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[250U], 0U));
    vlSelfRef.display_list_x[251U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[251U], 0x00000026U, 10));
    vlSelfRef.display_list_y[251U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[251U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[251U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[251U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[251U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[251U], 1U, 4));
    vlSelfRef.display_list_flip_x[251U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[251U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[251U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[251U], 0x0000000aU));
    vlSelfRef.display_list_priority[251U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[251U], 8U, 2));
    vlSelfRef.display_list_size[251U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[251U], 5U, 3));
    vlSelfRef.display_list_valid[251U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[251U], 0U));
    vlSelfRef.display_list_x[252U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[252U], 0x00000026U, 10));
    vlSelfRef.display_list_y[252U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[252U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[252U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[252U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[252U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[252U], 1U, 4));
    vlSelfRef.display_list_flip_x[252U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[252U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[252U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[252U], 0x0000000aU));
    vlSelfRef.display_list_priority[252U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[252U], 8U, 2));
    vlSelfRef.display_list_size[252U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[252U], 5U, 3));
    vlSelfRef.display_list_valid[252U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[252U], 0U));
    vlSelfRef.display_list_x[253U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[253U], 0x00000026U, 10));
    vlSelfRef.display_list_y[253U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[253U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[253U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[253U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[253U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[253U], 1U, 4));
    vlSelfRef.display_list_flip_x[253U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[253U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[253U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[253U], 0x0000000aU));
    vlSelfRef.display_list_priority[253U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[253U], 8U, 2));
    vlSelfRef.display_list_size[253U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[253U], 5U, 3));
    vlSelfRef.display_list_valid[253U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[253U], 0U));
    vlSelfRef.display_list_x[254U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[254U], 0x00000026U, 10));
    vlSelfRef.display_list_y[254U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[254U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[254U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[254U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[254U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[254U], 1U, 4));
    vlSelfRef.display_list_flip_x[254U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[254U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[254U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[254U], 0x0000000aU));
    vlSelfRef.display_list_priority[254U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[254U], 8U, 2));
    vlSelfRef.display_list_size[254U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[254U], 5U, 3));
    vlSelfRef.display_list_valid[254U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[254U], 0U));
    vlSelfRef.display_list_x[255U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[255U], 0x00000026U, 10));
    vlSelfRef.display_list_y[255U] = (0x000003ffU & 
                                      VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[255U], 0x0000001cU, 10));
    vlSelfRef.display_list_tile[255U] = (0x0000ffffU 
                                         & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[255U], 0x0000000cU, 16));
    vlSelfRef.display_list_palette[255U] = (0x0000000fU 
                                            & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[255U], 1U, 4));
    vlSelfRef.display_list_flip_x[255U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[255U], 0x0000000bU));
    vlSelfRef.display_list_flip_y[255U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[255U], 0x0000000aU));
    vlSelfRef.display_list_priority[255U] = (3U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[255U], 8U, 2));
    vlSelfRef.display_list_size[255U] = (7U & VL_SEL_IQII(48, vlSelfRef.__PVT__display_list_internal[255U], 5U, 3));
    vlSelfRef.display_list_valid[255U] = (1U & VL_BITSEL_IQII(48, vlSelfRef.__PVT__display_list_internal[255U], 0U));
    vlSelfRef.__PVT__ps2001b_table_base_active = vlSelfRef.__Vdly__ps2001b_table_base_active;
    vlSelfRef.__PVT__ps2001b_count_active = vlSelfRef.__Vdly__ps2001b_count_active;
    vlSelfRef.__PVT__ps2001b_y_offset_active = vlSelfRef.__Vdly__ps2001b_y_offset_active;
    vlSelfRef.__PVT__ps3305_priority_active = vlSelfRef.__Vdly__ps3305_priority_active;
    vlSelfRef.__PVT__ps3305_color_key_ctrl_active = vlSelfRef.__Vdly__ps3305_color_key_ctrl_active;
    vlSelfRef.__PVT__ps3305_color_key_active = vlSelfRef.__Vdly__ps3305_color_key_active;
    vlSelfRef.__PVT__ps3305_vsync_irq_line_active = vlSelfRef.__Vdly__ps3305_vsync_irq_line_active;
    vlSelfRef.__PVT__ps3305_hsync_irq_col_active = vlSelfRef.__Vdly__ps3305_hsync_irq_col_active;
    vlSelfRef.__PVT__ps2001b_ctrl_active = vlSelfRef.__Vdly__ps2001b_ctrl_active;
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v0) {
        vlSelfRef.__PVT__ps3103_scroll_x_active[0U] 
            = vlSelfRef.__VdlyVal__ps3103_scroll_x_active__v0;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v1) {
        vlSelfRef.__PVT__ps3103_scroll_x_active[1U] 
            = vlSelfRef.__VdlyVal__ps3103_scroll_x_active__v1;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v2) {
        vlSelfRef.__PVT__ps3103_scroll_x_active[2U] 
            = vlSelfRef.__VdlyVal__ps3103_scroll_x_active__v2;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v3) {
        vlSelfRef.__PVT__ps3103_scroll_x_active[3U] 
            = vlSelfRef.__VdlyVal__ps3103_scroll_x_active__v3;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v4) {
        vlSelfRef.__PVT__ps3103_scroll_x_active[0U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v5) {
        vlSelfRef.__PVT__ps3103_scroll_x_active[1U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v6) {
        vlSelfRef.__PVT__ps3103_scroll_x_active[2U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v7) {
        vlSelfRef.__PVT__ps3103_scroll_x_active[3U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v0) {
        vlSelfRef.__PVT__ps3103_scroll_y_active[0U] 
            = vlSelfRef.__VdlyVal__ps3103_scroll_y_active__v0;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v1) {
        vlSelfRef.__PVT__ps3103_scroll_y_active[1U] 
            = vlSelfRef.__VdlyVal__ps3103_scroll_y_active__v1;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v2) {
        vlSelfRef.__PVT__ps3103_scroll_y_active[2U] 
            = vlSelfRef.__VdlyVal__ps3103_scroll_y_active__v2;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v3) {
        vlSelfRef.__PVT__ps3103_scroll_y_active[3U] 
            = vlSelfRef.__VdlyVal__ps3103_scroll_y_active__v3;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v4) {
        vlSelfRef.__PVT__ps3103_scroll_y_active[0U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v5) {
        vlSelfRef.__PVT__ps3103_scroll_y_active[1U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v6) {
        vlSelfRef.__PVT__ps3103_scroll_y_active[2U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v7) {
        vlSelfRef.__PVT__ps3103_scroll_y_active[3U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v0) {
        vlSelfRef.__PVT__ps3103_tilemap_base_active[0U] 
            = vlSelfRef.__VdlyVal__ps3103_tilemap_base_active__v0;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v1) {
        vlSelfRef.__PVT__ps3103_tilemap_base_active[1U] 
            = vlSelfRef.__VdlyVal__ps3103_tilemap_base_active__v1;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v2) {
        vlSelfRef.__PVT__ps3103_tilemap_base_active[2U] 
            = vlSelfRef.__VdlyVal__ps3103_tilemap_base_active__v2;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v3) {
        vlSelfRef.__PVT__ps3103_tilemap_base_active[3U] 
            = vlSelfRef.__VdlyVal__ps3103_tilemap_base_active__v3;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v4) {
        vlSelfRef.__PVT__ps3103_tilemap_base_active[0U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v5) {
        vlSelfRef.__PVT__ps3103_tilemap_base_active[1U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v6) {
        vlSelfRef.__PVT__ps3103_tilemap_base_active[2U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v7) {
        vlSelfRef.__PVT__ps3103_tilemap_base_active[3U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v0) {
        vlSelfRef.__PVT__ps3103_ctrl_active[0U] = vlSelfRef.__VdlyVal__ps3103_ctrl_active__v0;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v1) {
        vlSelfRef.__PVT__ps3103_ctrl_active[1U] = vlSelfRef.__VdlyVal__ps3103_ctrl_active__v1;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v2) {
        vlSelfRef.__PVT__ps3103_ctrl_active[2U] = vlSelfRef.__VdlyVal__ps3103_ctrl_active__v2;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v3) {
        vlSelfRef.__PVT__ps3103_ctrl_active[3U] = vlSelfRef.__VdlyVal__ps3103_ctrl_active__v3;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v4) {
        vlSelfRef.__PVT__ps3103_ctrl_active[0U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v5) {
        vlSelfRef.__PVT__ps3103_ctrl_active[1U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v6) {
        vlSelfRef.__PVT__ps3103_ctrl_active[2U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_active__v7) {
        vlSelfRef.__PVT__ps3103_ctrl_active[3U] = 0U;
    }
    vlSelfRef.__Vdly__ps2001b_ctrl_shadow = vlSelfRef.__PVT__ps2001b_ctrl_shadow;
    vlSelfRef.__Vdly__ps2001b_table_base_shadow = vlSelfRef.__PVT__ps2001b_table_base_shadow;
    vlSelfRef.__Vdly__ps2001b_count_shadow = vlSelfRef.__PVT__ps2001b_count_shadow;
    vlSelfRef.__Vdly__ps2001b_y_offset_shadow = vlSelfRef.__PVT__ps2001b_y_offset_shadow;
    vlSelfRef.__Vdly__ps3305_priority_shadow = vlSelfRef.__PVT__ps3305_priority_shadow;
    vlSelfRef.__Vdly__ps3305_color_key_ctrl_shadow 
        = vlSelfRef.__PVT__ps3305_color_key_ctrl_shadow;
    vlSelfRef.__Vdly__ps3305_color_key_shadow = vlSelfRef.__PVT__ps3305_color_key_shadow;
    vlSelfRef.__Vdly__ps3305_vsync_irq_line_shadow 
        = vlSelfRef.__PVT__ps3305_vsync_irq_line_shadow;
    vlSelfRef.__Vdly__ps3305_hsync_irq_col_shadow = vlSelfRef.__PVT__ps3305_hsync_irq_col_shadow;
    vlSelfRef.spr_table_base = vlSelfRef.__PVT__ps2001b_table_base_active;
    vlSelfRef.spr_count = vlSelfRef.__PVT__ps2001b_count_active;
    vlSelfRef.spr_y_offset = vlSelfRef.__PVT__ps2001b_y_offset_active;
    vlSelfRef.priority_table = vlSelfRef.__PVT__ps3305_priority_active;
    vlSelfRef.color_key_ctrl = vlSelfRef.__PVT__ps3305_color_key_ctrl_active;
    vlSelfRef.color_key_color = vlSelfRef.__PVT__ps3305_color_key_active;
    vlSelfRef.vsync_irq_line = vlSelfRef.__PVT__ps3305_vsync_irq_line_active;
    vlSelfRef.hsync_irq_col = vlSelfRef.__PVT__ps3305_hsync_irq_col_active;
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
    if (vlSelfRef.rst_n) {
        if (vlSelfRef.__PVT__write_strobe) {
            if (vlSelfRef.__PVT__cs_ps2001b) {
                if ((0U == (7U & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 3)))) {
                    vlSelfRef.__Vdly__ps2001b_ctrl_shadow 
                        = (0x000000ffU & VL_SEL_IIII(16, (IData)(vlSelfRef.din), 0U, 8));
                } else if ((1U == (7U & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 3)))) {
                    VL_ASSIGNSEL_II(32, 16, 0U, vlSelfRef.__Vdly__ps2001b_table_base_shadow, vlSelfRef.din);
                } else if ((2U == (7U & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 3)))) {
                    VL_ASSIGNSEL_II(32, 16, 0x10U, vlSelfRef.__Vdly__ps2001b_table_base_shadow, vlSelfRef.din);
                } else if ((3U == (7U & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 3)))) {
                    vlSelfRef.__Vdly__ps2001b_count_shadow 
                        = vlSelfRef.din;
                } else if ((4U == (7U & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 3)))) {
                    vlSelfRef.__Vdly__ps2001b_y_offset_shadow 
                        = (0x000000ffU & VL_SEL_IIII(16, (IData)(vlSelfRef.din), 0U, 8));
                }
            } else if (vlSelfRef.__PVT__cs_ps3103) {
                if ((0U == (IData)(vlSelfRef.__PVT__unnamedblk2__DOT__reg_offset))) {
                    vlSelfRef.__VdlyVal__ps3103_ctrl_shadow__v0 
                        = (0x000000ffU & VL_SEL_IIII(16, (IData)(vlSelfRef.din), 0U, 8));
                    vlSelfRef.__VdlyDim0__ps3103_ctrl_shadow__v0 
                        = vlSelfRef.__PVT__unnamedblk2__DOT__layer_idx;
                    vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v0 = 1U;
                } else if ((1U == (IData)(vlSelfRef.__PVT__unnamedblk2__DOT__reg_offset))) {
                    vlSelfRef.__VdlyVal__ps3103_scroll_x_shadow__v0 
                        = vlSelfRef.din;
                    vlSelfRef.__VdlyDim0__ps3103_scroll_x_shadow__v0 
                        = vlSelfRef.__PVT__unnamedblk2__DOT__layer_idx;
                    vlSelfRef.__VdlySet__ps3103_scroll_x_shadow__v0 = 1U;
                } else if ((2U == (IData)(vlSelfRef.__PVT__unnamedblk2__DOT__reg_offset))) {
                    vlSelfRef.__VdlyVal__ps3103_scroll_y_shadow__v0 
                        = vlSelfRef.din;
                    vlSelfRef.__VdlyDim0__ps3103_scroll_y_shadow__v0 
                        = vlSelfRef.__PVT__unnamedblk2__DOT__layer_idx;
                    vlSelfRef.__VdlySet__ps3103_scroll_y_shadow__v0 = 1U;
                } else if ((3U == (IData)(vlSelfRef.__PVT__unnamedblk2__DOT__reg_offset))) {
                    vlSelfRef.__VdlyVal__ps3103_tilemap_base_shadow__v0 
                        = vlSelfRef.din;
                    vlSelfRef.__VdlyDim0__ps3103_tilemap_base_shadow__v0 
                        = vlSelfRef.__PVT__unnamedblk2__DOT__layer_idx;
                    vlSelfRef.__VdlySet__ps3103_tilemap_base_shadow__v0 = 1U;
                } else if ((4U == (IData)(vlSelfRef.__PVT__unnamedblk2__DOT__reg_offset))) {
                    vlSelfRef.__VdlyVal__ps3103_tilemap_base_shadow__v1 
                        = vlSelfRef.din;
                    vlSelfRef.__VdlyDim0__ps3103_tilemap_base_shadow__v1 
                        = vlSelfRef.__PVT__unnamedblk2__DOT__layer_idx;
                    vlSelfRef.__VdlySet__ps3103_tilemap_base_shadow__v1 = 1U;
                }
            } else if (vlSelfRef.__PVT__cs_ps3305) {
                if (((((((((0U == (0x0000001fU & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5))) 
                           | (1U == (0x0000001fU & 
                                     VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))) 
                          | (2U == (0x0000001fU & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))) 
                         | (3U == (0x0000001fU & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))) 
                        | (0x10U == (0x0000001fU & 
                                     VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))) 
                       | (0x11U == (0x0000001fU & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))) 
                      | (0x12U == (0x0000001fU & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))) 
                     | (0x13U == (0x0000001fU & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5))))) {
                    if ((0U == (0x0000001fU & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))) {
                        VL_ASSIGNSEL_QI(64, 16, 0U, vlSelfRef.__Vdly__ps3305_priority_shadow, vlSelfRef.din);
                    } else if ((1U == (0x0000001fU 
                                       & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))) {
                        VL_ASSIGNSEL_QI(64, 16, 0x10U, vlSelfRef.__Vdly__ps3305_priority_shadow, vlSelfRef.din);
                    } else if ((2U == (0x0000001fU 
                                       & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))) {
                        VL_ASSIGNSEL_QI(64, 16, 0x20U, vlSelfRef.__Vdly__ps3305_priority_shadow, vlSelfRef.din);
                    } else if ((3U == (0x0000001fU 
                                       & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))) {
                        VL_ASSIGNSEL_QI(64, 16, 0x30U, vlSelfRef.__Vdly__ps3305_priority_shadow, vlSelfRef.din);
                    } else if ((0x10U == (0x0000001fU 
                                          & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))) {
                        vlSelfRef.__Vdly__ps3305_color_key_ctrl_shadow 
                            = (0x000000ffU & VL_SEL_IIII(16, (IData)(vlSelfRef.din), 0U, 8));
                    } else if ((0x11U == (0x0000001fU 
                                          & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))) {
                        vlSelfRef.__Vdly__ps3305_color_key_shadow 
                            = (0x000000ffU & VL_SEL_IIII(16, (IData)(vlSelfRef.din), 0U, 8));
                    } else if ((0x12U == (0x0000001fU 
                                          & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))) {
                        vlSelfRef.__Vdly__ps3305_vsync_irq_line_shadow 
                            = (0x000001ffU & VL_SEL_IIII(16, (IData)(vlSelfRef.din), 0U, 9));
                    } else {
                        vlSelfRef.__Vdly__ps3305_hsync_irq_col_shadow 
                            = (0x000001ffU & VL_SEL_IIII(16, (IData)(vlSelfRef.din), 0U, 9));
                    }
                }
            } else if (vlSelfRef.__PVT__cs_z80) {
                if ((0U != (7U & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 3)))) {
                    if ((1U != (7U & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 3)))) {
                        if ((2U != (7U & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 3)))) {
                            if ((3U != (7U & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 3)))) {
                                if ((5U == (7U & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 3)))) {
                                    vlSelfRef.__Vdly__z80_cmd_reply_reg 
                                        = (0x000000ffU 
                                           & VL_SEL_IIII(16, (IData)(vlSelfRef.din), 0U, 8));
                                }
                            }
                        }
                    }
                }
            }
        }
    } else {
        vlSelfRef.__Vdly__ps2001b_ctrl_shadow = 0U;
        vlSelfRef.__Vdly__ps2001b_table_base_shadow = 0U;
        vlSelfRef.__Vdly__ps2001b_count_shadow = 0U;
        vlSelfRef.__Vdly__ps2001b_y_offset_shadow = 0U;
        vlSelfRef.__PVT__unnamedblk1__DOT__i = 0U;
        vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v1 = 1U;
        vlSelfRef.__PVT__unnamedblk1__DOT__i = 1U;
        vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v2 = 1U;
        vlSelfRef.__PVT__unnamedblk1__DOT__i = 2U;
        vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v3 = 1U;
        vlSelfRef.__PVT__unnamedblk1__DOT__i = 3U;
        vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v4 = 1U;
        vlSelfRef.__PVT__unnamedblk1__DOT__i = 4U;
        vlSelfRef.__Vdly__ps3305_priority_shadow = 0x0001020304050607ULL;
        vlSelfRef.__Vdly__ps3305_color_key_ctrl_shadow = 0U;
        vlSelfRef.__Vdly__ps3305_color_key_shadow = 0U;
        vlSelfRef.__Vdly__ps3305_vsync_irq_line_shadow = 0x00f0U;
        vlSelfRef.__Vdly__ps3305_hsync_irq_col_shadow = 0x0140U;
        vlSelfRef.__Vdly__z80_status_reg = 0U;
        vlSelfRef.__Vdly__z80_cmd_reply_reg = 0U;
    }
    vlSelfRef.__PVT__ps2001b_ctrl_shadow = vlSelfRef.__Vdly__ps2001b_ctrl_shadow;
    vlSelfRef.__PVT__ps2001b_table_base_shadow = vlSelfRef.__Vdly__ps2001b_table_base_shadow;
    vlSelfRef.__PVT__ps2001b_count_shadow = vlSelfRef.__Vdly__ps2001b_count_shadow;
    vlSelfRef.__PVT__ps2001b_y_offset_shadow = vlSelfRef.__Vdly__ps2001b_y_offset_shadow;
    vlSelfRef.__PVT__ps3305_priority_shadow = vlSelfRef.__Vdly__ps3305_priority_shadow;
    vlSelfRef.__PVT__ps3305_color_key_ctrl_shadow = vlSelfRef.__Vdly__ps3305_color_key_ctrl_shadow;
    vlSelfRef.__PVT__ps3305_color_key_shadow = vlSelfRef.__Vdly__ps3305_color_key_shadow;
    vlSelfRef.__PVT__ps3305_vsync_irq_line_shadow = vlSelfRef.__Vdly__ps3305_vsync_irq_line_shadow;
    vlSelfRef.__PVT__ps3305_hsync_irq_col_shadow = vlSelfRef.__Vdly__ps3305_hsync_irq_col_shadow;
    vlSelfRef.__PVT__z80_cmd_reply_reg = vlSelfRef.__Vdly__z80_cmd_reply_reg;
    vlSelfRef.__PVT__z80_status_reg = vlSelfRef.__Vdly__z80_status_reg;
    if (vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v0) {
        vlSelfRef.__PVT__ps3103_ctrl_shadow[vlSelfRef.__VdlyDim0__ps3103_ctrl_shadow__v0] 
            = vlSelfRef.__VdlyVal__ps3103_ctrl_shadow__v0;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v1) {
        vlSelfRef.__PVT__ps3103_ctrl_shadow[0U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v2) {
        vlSelfRef.__PVT__ps3103_ctrl_shadow[1U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v3) {
        vlSelfRef.__PVT__ps3103_ctrl_shadow[2U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v4) {
        vlSelfRef.__PVT__ps3103_ctrl_shadow[3U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_scroll_x_shadow__v0) {
        vlSelfRef.__PVT__ps3103_scroll_x_shadow[vlSelfRef.__VdlyDim0__ps3103_scroll_x_shadow__v0] 
            = vlSelfRef.__VdlyVal__ps3103_scroll_x_shadow__v0;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v1) {
        vlSelfRef.__PVT__ps3103_scroll_x_shadow[0U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v2) {
        vlSelfRef.__PVT__ps3103_scroll_x_shadow[1U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v3) {
        vlSelfRef.__PVT__ps3103_scroll_x_shadow[2U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v4) {
        vlSelfRef.__PVT__ps3103_scroll_x_shadow[3U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_scroll_y_shadow__v0) {
        vlSelfRef.__PVT__ps3103_scroll_y_shadow[vlSelfRef.__VdlyDim0__ps3103_scroll_y_shadow__v0] 
            = vlSelfRef.__VdlyVal__ps3103_scroll_y_shadow__v0;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v1) {
        vlSelfRef.__PVT__ps3103_scroll_y_shadow[0U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v2) {
        vlSelfRef.__PVT__ps3103_scroll_y_shadow[1U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v3) {
        vlSelfRef.__PVT__ps3103_scroll_y_shadow[2U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v4) {
        vlSelfRef.__PVT__ps3103_scroll_y_shadow[3U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_tilemap_base_shadow__v0) {
        VL_ASSIGNSEL_II(32, 16, 0U, vlSelfRef.__PVT__ps3103_tilemap_base_shadow
                        [vlSelfRef.__VdlyDim0__ps3103_tilemap_base_shadow__v0], vlSelfRef.__VdlyVal__ps3103_tilemap_base_shadow__v0);
    }
    if (vlSelfRef.__VdlySet__ps3103_tilemap_base_shadow__v1) {
        VL_ASSIGNSEL_II(32, 16, 0x10U, vlSelfRef.__PVT__ps3103_tilemap_base_shadow
                        [vlSelfRef.__VdlyDim0__ps3103_tilemap_base_shadow__v1], vlSelfRef.__VdlyVal__ps3103_tilemap_base_shadow__v1);
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v1) {
        vlSelfRef.__PVT__ps3103_tilemap_base_shadow[0U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v2) {
        vlSelfRef.__PVT__ps3103_tilemap_base_shadow[1U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v3) {
        vlSelfRef.__PVT__ps3103_tilemap_base_shadow[2U] = 0U;
    }
    if (vlSelfRef.__VdlySet__ps3103_ctrl_shadow__v4) {
        vlSelfRef.__PVT__ps3103_tilemap_base_shadow[3U] = 0U;
    }
    vlSelfRef.z80_cmd_reply = vlSelfRef.__PVT__z80_cmd_reply_reg;
    vlSelfRef.z80_busy = (1U & VL_BITSEL_IIII(8, (IData)(vlSelfRef.__PVT__z80_status_reg), 7U));
    vlSelfRef.z80_irq_pending = (1U & VL_BITSEL_IIII(8, (IData)(vlSelfRef.__PVT__z80_status_reg), 6U));
    vlSelfRef.dout = 0U;
    if (vlSelfRef.__PVT__read_strobe) {
        vlSelfRef.dout = (0x0000ffffU & (((((((((IData)(vlSelfRef.__PVT__cs_ps2001b) 
                                                | (IData)(vlSelfRef.__PVT__cs_ps3103)) 
                                               | (IData)(vlSelfRef.__PVT__cs_ps3305)) 
                                              | (IData)(vlSelfRef.__PVT__cs_z80)) 
                                             | (IData)(vlSelfRef.__PVT__cs_workram)) 
                                            | (IData)(vlSelfRef.__PVT__cs_spriteram)) 
                                           | (IData)(vlSelfRef.__PVT__cs_tilemapram)) 
                                          | (IData)(vlSelfRef.__PVT__cs_paletteram))
                                          ? ((IData)(vlSelfRef.__PVT__cs_ps2001b)
                                              ? ((0U 
                                                  == 
                                                  (7U 
                                                   & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 3)))
                                                  ? 
                                                 VL_EXTEND_II(16,8, (IData)(vlSelfRef.__PVT__ps2001b_ctrl_shadow))
                                                  : 
                                                 ((1U 
                                                   == 
                                                   (7U 
                                                    & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 3)))
                                                   ? 
                                                  VL_SEL_IIII(32, vlSelfRef.__PVT__ps2001b_table_base_shadow, 0U, 16)
                                                   : 
                                                  ((2U 
                                                    == 
                                                    (7U 
                                                     & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 3)))
                                                    ? 
                                                   VL_SEL_IIII(32, vlSelfRef.__PVT__ps2001b_table_base_shadow, 0x10U, 16)
                                                    : 
                                                   ((3U 
                                                     == 
                                                     (7U 
                                                      & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 3)))
                                                     ? (IData)(vlSelfRef.__PVT__ps2001b_count_shadow)
                                                     : 
                                                    ((4U 
                                                      == 
                                                      (7U 
                                                       & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 3)))
                                                      ? 
                                                     VL_EXTEND_II(16,8, (IData)(vlSelfRef.__PVT__ps2001b_y_offset_shadow))
                                                      : 
                                                     ((5U 
                                                       == 
                                                       (7U 
                                                        & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 3)))
                                                       ? 1U
                                                       : 0U))))))
                                              : ((IData)(vlSelfRef.__PVT__cs_ps3103)
                                                  ? 
                                                 ((0U 
                                                   == (IData)(vlSelfRef.__PVT__unnamedblk6__DOT__reg_offset))
                                                   ? 
                                                  VL_EXTEND_II(16,8, vlSelfRef.__PVT__ps3103_ctrl_shadow
                                                               [vlSelfRef.__PVT__unnamedblk6__DOT__layer_idx])
                                                   : 
                                                  ((1U 
                                                    == (IData)(vlSelfRef.__PVT__unnamedblk6__DOT__reg_offset))
                                                    ? vlSelfRef.__PVT__ps3103_scroll_x_shadow
                                                   [vlSelfRef.__PVT__unnamedblk6__DOT__layer_idx]
                                                    : 
                                                   ((2U 
                                                     == (IData)(vlSelfRef.__PVT__unnamedblk6__DOT__reg_offset))
                                                     ? vlSelfRef.__PVT__ps3103_scroll_y_shadow
                                                    [vlSelfRef.__PVT__unnamedblk6__DOT__layer_idx]
                                                     : 
                                                    ((3U 
                                                      == (IData)(vlSelfRef.__PVT__unnamedblk6__DOT__reg_offset))
                                                      ? 
                                                     VL_SEL_IIII(32, vlSelfRef.__PVT__ps3103_tilemap_base_shadow
                                                                 [vlSelfRef.__PVT__unnamedblk6__DOT__layer_idx], 0U, 16)
                                                      : 
                                                     ((4U 
                                                       == (IData)(vlSelfRef.__PVT__unnamedblk6__DOT__reg_offset))
                                                       ? 
                                                      VL_SEL_IIII(32, vlSelfRef.__PVT__ps3103_tilemap_base_shadow
                                                                  [vlSelfRef.__PVT__unnamedblk6__DOT__layer_idx], 0x10U, 16)
                                                       : 0U)))))
                                                  : 
                                                 ((IData)(vlSelfRef.__PVT__cs_ps3305)
                                                   ? 
                                                  (((((((((0U 
                                                           == 
                                                           (0x0000001fU 
                                                            & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5))) 
                                                          | (1U 
                                                             == 
                                                             (0x0000001fU 
                                                              & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))) 
                                                         | (2U 
                                                            == 
                                                            (0x0000001fU 
                                                             & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))) 
                                                        | (3U 
                                                           == 
                                                           (0x0000001fU 
                                                            & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))) 
                                                       | (0x10U 
                                                          == 
                                                          (0x0000001fU 
                                                           & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))) 
                                                      | (0x11U 
                                                         == 
                                                         (0x0000001fU 
                                                          & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))) 
                                                     | (0x12U 
                                                        == 
                                                        (0x0000001fU 
                                                         & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))) 
                                                    | (0x13U 
                                                       == 
                                                       (0x0000001fU 
                                                        & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5))))
                                                    ? 
                                                   ((0U 
                                                     == 
                                                     (0x0000001fU 
                                                      & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))
                                                     ? 
                                                    VL_SEL_IQII(64, vlSelfRef.__PVT__ps3305_priority_shadow, 0U, 16)
                                                     : 
                                                    ((1U 
                                                      == 
                                                      (0x0000001fU 
                                                       & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))
                                                      ? 
                                                     VL_SEL_IQII(64, vlSelfRef.__PVT__ps3305_priority_shadow, 0x10U, 16)
                                                      : 
                                                     ((2U 
                                                       == 
                                                       (0x0000001fU 
                                                        & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))
                                                       ? 
                                                      VL_SEL_IQII(64, vlSelfRef.__PVT__ps3305_priority_shadow, 0x20U, 16)
                                                       : 
                                                      ((3U 
                                                        == 
                                                        (0x0000001fU 
                                                         & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))
                                                        ? 
                                                       VL_SEL_IQII(64, vlSelfRef.__PVT__ps3305_priority_shadow, 0x30U, 16)
                                                        : 
                                                       ((0x10U 
                                                         == 
                                                         (0x0000001fU 
                                                          & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))
                                                         ? 
                                                        VL_EXTEND_II(16,8, (IData)(vlSelfRef.__PVT__ps3305_color_key_ctrl_shadow))
                                                         : 
                                                        ((0x11U 
                                                          == 
                                                          (0x0000001fU 
                                                           & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))
                                                          ? 
                                                         VL_EXTEND_II(16,8, (IData)(vlSelfRef.__PVT__ps3305_color_key_shadow))
                                                          : 
                                                         ((0x12U 
                                                           == 
                                                           (0x0000001fU 
                                                            & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 5)))
                                                           ? 
                                                          VL_EXTEND_II(16,9, (IData)(vlSelfRef.__PVT__ps3305_vsync_irq_line_shadow))
                                                           : 
                                                          VL_EXTEND_II(16,9, (IData)(vlSelfRef.__PVT__ps3305_hsync_irq_col_shadow)))))))))
                                                    : 0U)
                                                   : 
                                                  ((IData)(vlSelfRef.__PVT__cs_z80)
                                                    ? 
                                                   ((2U 
                                                     == 
                                                     (7U 
                                                      & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 3)))
                                                     ? 
                                                    VL_EXTEND_II(16,8, (IData)(vlSelfRef.__PVT__z80_status_reg))
                                                     : 
                                                    ((5U 
                                                      == 
                                                      (7U 
                                                       & VL_SEL_IIII(23, vlSelfRef.addr, 0U, 3)))
                                                      ? 
                                                     VL_EXTEND_II(16,8, (IData)(vlSelfRef.__PVT__z80_cmd_reply_reg))
                                                      : 0U))
                                                    : 0U))))
                                          : 0U));
    }
}
