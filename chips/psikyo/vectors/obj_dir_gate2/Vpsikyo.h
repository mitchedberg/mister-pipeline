// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Primary model header
//
// This header should be included by all source files instantiating the design.
// The class here is then constructed to instantiate the design.
// See the Verilator manual for examples.

#ifndef VERILATED_VPSIKYO_H_
#define VERILATED_VPSIKYO_H_  // guard

#include "verilated.h"

class Vpsikyo__Syms;
class Vpsikyo___024root;
class Vpsikyo_psikyo;


// This class is the main interface to the Verilated model
class alignas(VL_CACHE_LINE_BYTES) Vpsikyo VL_NOT_FINAL : public VerilatedModel {
  private:
    // Symbol table holding complete model state (owned by this class)
    Vpsikyo__Syms* const vlSymsp;

  public:

    // CONSTEXPR CAPABILITIES
    // Verilated with --trace?
    static constexpr bool traceCapable = false;

    // PORTS
    // The application code writes and reads these signals to
    // propagate new values into/out from the Verilated model.
    VL_IN8(&clk,0,0);
    VL_IN8(&rst_n,0,0);
    VL_IN8(&cs_n,0,0);
    VL_IN8(&rd_n,0,0);
    VL_IN8(&wr_n,0,0);
    VL_IN8(&dsn,1,0);
    VL_IN8(&vsync_n,0,0);
    VL_OUT8(&nmi_n,0,0);
    VL_OUT8(&irq1_n,0,0);
    VL_OUT8(&irq2_n,0,0);
    VL_OUT8(&irq3_n,0,0);
    VL_OUT8(&spr_dma_enable,1,0);
    VL_OUT8(&spr_render_enable,1,0);
    VL_OUT8(&spr_mode,1,0);
    VL_OUT8(&spr_palette_bank,1,0);
    VL_OUT8(&spr_y_offset,7,0);
    VL_OUT8(&display_list_count,7,0);
    VL_OUT8(&display_list_ready,0,0);
    VL_OUT8(&bg_enable,3,0);
    VL_OUT8(&bg_tile_size,3,0);
    VL_OUT8(&bg_priority,7,0);
    VL_OUT8(&color_key_ctrl,7,0);
    VL_OUT8(&color_key_color,7,0);
    VL_OUT8(&color_key_mask,7,0);
    VL_OUT8(&z80_busy,0,0);
    VL_OUT8(&z80_irq_pending,0,0);
    VL_OUT8(&z80_cmd_reply,7,0);
    VL_OUT8(&sprite_ram_wsel,1,0);
    VL_OUT8(&sprite_ram_wr_en,0,0);
    VL_IN16(&din,15,0);
    VL_OUT16(&dout,15,0);
    VL_OUT16(&spr_count,15,0);
    VL_OUT16(&vsync_irq_line,8,0);
    VL_OUT16(&hsync_irq_col,8,0);
    VL_OUT16(&sprite_ram_addr,15,0);
    VL_OUT16(&sprite_ram_din,15,0);
    VL_IN(&addr,23,1);
    VL_OUT(&spr_table_base,31,0);
    VL_IN(&sprite_ram_dout,31,0);
    VL_OUT64(&priority_table,63,0);
    VL_OUT16((&display_list_x)[256],9,0);
    VL_OUT16((&display_list_y)[256],9,0);
    VL_OUT16((&display_list_tile)[256],15,0);
    VL_OUT8((&display_list_palette)[256],3,0);
    VL_OUT8((&display_list_flip_x)[256],0,0);
    VL_OUT8((&display_list_flip_y)[256],0,0);
    VL_OUT8((&display_list_priority)[256],1,0);
    VL_OUT8((&display_list_size)[256],2,0);
    VL_OUT8((&display_list_valid)[256],0,0);
    VL_OUT16((&bg_chr_bank)[4],15,0);
    VL_OUT16((&bg_scroll_x)[4],15,0);
    VL_OUT16((&bg_scroll_y)[4],15,0);
    VL_OUT((&bg_tilemap_base)[4],31,0);

    // CELLS
    // Public to allow access to /* verilator public */ items.
    // Otherwise the application code can consider these internals.
    Vpsikyo_psikyo* const __PVT__psikyo;

    // Root instance pointer to allow access to model internals,
    // including inlined /* verilator public_flat_* */ items.
    Vpsikyo___024root* const rootp;

    // CONSTRUCTORS
    /// Construct the model; called by application code
    /// If contextp is null, then the model will use the default global context
    /// If name is "", then makes a wrapper with a
    /// single model invisible with respect to DPI scope names.
    explicit Vpsikyo(VerilatedContext* contextp, const char* name = "TOP");
    explicit Vpsikyo(const char* name = "TOP");
    /// Destroy the model; called (often implicitly) by application code
    virtual ~Vpsikyo();
  private:
    VL_UNCOPYABLE(Vpsikyo);  ///< Copying not allowed

  public:
    // API METHODS
    /// Evaluate the model.  Application must call when inputs change.
    void eval() { eval_step(); }
    /// Evaluate when calling multiple units/models per time step.
    void eval_step();
    /// Evaluate at end of a timestep for tracing, when using eval_step().
    /// Application must call after all eval() and before time changes.
    void eval_end_step() {}
    /// Simulation complete, run final blocks.  Application must call on completion.
    void final();
    /// Are there scheduled events to handle?
    bool eventsPending();
    /// Returns time at next time slot. Aborts if !eventsPending()
    uint64_t nextTimeSlot();
    /// Trace signals in the model; called by application code
    void trace(VerilatedTraceBaseC* tfp, int levels, int options = 0) { contextp()->trace(tfp, levels, options); }
    /// Retrieve name of this model instance (as passed to constructor).
    const char* name() const;

    // Abstract methods from VerilatedModel
    const char* hierName() const override final;
    const char* modelName() const override final;
    unsigned threads() const override final;
    /// Prepare for cloning the model at the process level (e.g. fork in Linux)
    /// Release necessary resources. Called before cloning.
    void prepareClone() const;
    /// Re-init after cloning the model at the process level (e.g. fork in Linux)
    /// Re-allocate necessary resources. Called after cloning.
    void atClone() const;
  private:
    // Internal functions - trace registration
    void traceBaseModel(VerilatedTraceBaseC* tfp, int levels, int options);
};

#endif  // guard
