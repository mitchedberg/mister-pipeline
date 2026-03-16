`default_nettype none
module fail_multidriver (
    input  logic clk,
    input  logic a, b,
    output logic out
);
// INTENTIONALLY BROKEN: two always_ff blocks driving the same signal 'out'
// Gate 3a (Yosys) must catch this as a multi-driver error.
always_ff @(posedge clk) begin
    if (a) out <= 1'b1;
end
always_ff @(posedge clk) begin
    if (b) out <= 1'b0;
end
endmodule
