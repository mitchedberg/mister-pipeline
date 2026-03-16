`default_nettype none
module pass_clean (
    input  logic        clk,
    input  logic        async_rst_n,  // active-low async reset input
    input  logic        en,
    output logic [7:0]  count
);

// SECTION 5: Required reset synchronizer (async assert, sync deassert)
// Async assert  — rst_pipe clears immediately when async_rst_n deasserts
// Sync deassert — rst_pipe shifts in 1'b1 on clock edges, avoiding metastability
logic [1:0] rst_pipe;
always_ff @(posedge clk or negedge async_rst_n)
    if (!async_rst_n) rst_pipe <= 2'b00;
    else              rst_pipe <= {rst_pipe[0], 1'b1};
logic rst_n;
assign rst_n = rst_pipe[1];

// Synchronous counter with synchronous enable
// Does NOT use a logic-gated clock — enable is a data signal
always_ff @(posedge clk) begin
    if (!rst_n)  count <= 8'h00;
    else if (en) count <= count + 1'b1;
end

endmodule
