`default_nettype none
module fail_async_rst (
    input  logic       clk,
    input  logic       rst,     // async reset
    output logic [7:0] count
);
// INTENTIONALLY BROKEN: async reset deassertion (forbidden on Cyclone V)
// The counter deasserts reset asynchronously — no two-flop synchronizer.
// Gate 2.5 must catch this pattern.
always_ff @(posedge clk or posedge rst) begin
    if (rst) count <= 8'h00;
    else     count <= count + 1'b1;
end
endmodule
