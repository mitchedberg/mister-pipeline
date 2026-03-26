`default_nettype none

module mister_hw_debug_dump #(
    parameter int FRAME_TARGET = 120,
    parameter logic [7:0] UPLOAD_INDEX = 8'd2
) (
    input  logic        clk,
    input  logic        reset_n,
    input  logic        frame_pulse,
    input  logic        trigger_en,
    input  logic        ioctl_upload,
    input  logic        ioctl_rd,
    input  logic [26:0] ioctl_addr,
    output logic        ioctl_upload_req,
    output logic [7:0]  ioctl_upload_index,
    output logic [7:0]  ioctl_din
);

logic [15:0] frame_count;
logic [15:0] captured_frame;
logic        upload_requested;
logic        upload_seen;
logic        upload_fired;
logic [7:0]  addr_lo;

assign ioctl_upload_index = UPLOAD_INDEX;
assign addr_lo = ioctl_addr[7:0];

always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        frame_count      <= 16'd0;
        captured_frame   <= 16'd0;
        upload_requested <= 1'b0;
        upload_seen      <= 1'b0;
        upload_fired     <= 1'b0;
        ioctl_upload_req <= 1'b0;
    end else begin
        ioctl_upload_req <= 1'b0;

        if (frame_pulse && !upload_requested) begin
            frame_count <= frame_count + 16'd1;
        end

        if (!upload_requested && trigger_en && (frame_count >= FRAME_TARGET)) begin
            captured_frame   <= frame_count;
            upload_requested <= 1'b1;
        end

        if (ioctl_upload) begin
            upload_seen <= 1'b1;
        end

        // MiSTer's hps_io wrapper latches save requests on a rising edge.
        if (upload_requested && !upload_fired) begin
            ioctl_upload_req <= 1'b1;
            upload_fired     <= 1'b1;
        end
    end
end

always_comb begin
    ioctl_din = 8'h00;

    case (addr_lo)
        8'h00: ioctl_din = 8'h44; // D
        8'h01: ioctl_din = 8'h42; // B
        8'h02: ioctl_din = 8'h47; // G
        8'h03: ioctl_din = 8'h31; // 1
        8'h04: ioctl_din = FRAME_TARGET[7:0];
        8'h05: ioctl_din = FRAME_TARGET[15:8];
        8'h06: ioctl_din = captured_frame[7:0];
        8'h07: ioctl_din = captured_frame[15:8];
        8'h08: ioctl_din = frame_count[7:0];
        8'h09: ioctl_din = frame_count[15:8];
        8'h0A: ioctl_din = {5'd0, upload_seen, upload_requested, trigger_en};
        8'h0B: ioctl_din = 8'hA5;
        default: ioctl_din = addr_lo ^ 8'hA5;
    endcase
end

/* verilator lint_off UNUSED */
wire _unused = &{1'b0, ioctl_rd};
/* verilator lint_on UNUSED */

endmodule
