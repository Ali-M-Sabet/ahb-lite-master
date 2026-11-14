// AHB-Lite master for aligned 32-bit SINGLE and INCR transfers.
module AHB_master (
    input  logic        HCLK,
    input  logic        HRESETn,

    // user side
    input  logic        send,          // start a beat
    input  logic [31:0] addr,
    input  logic        wr_en,         // 1=write, 0=read
    input  logic [2:0]  size,          // 010 = word
    input  logic [2:0]  burst,         // 000 single, 001 incr
    input  logic [31:0] data_w,
    input  logic        continue_burst, // 0=start, 1=continue INCR
    input  logic        sender_busy,   // stall incr with busy

    output logic [31:0] data_r,
    output logic        data_r_valid,
    output logic        boundary_reached, // final address of this 1 KB region accepted
    output logic        rsp_valid,
    output logic [1:0]  rsp_status,
    output logic        master_ready,  // user can send next beat

    // bus side
    input  logic        HREADY,
    input  logic        HRESP,
    input  logic [31:0] HRDATA,

    output logic [31:0] HADDR,
    output logic [2:0]  HBURST,
    output logic        HMASTLOCK,
    output logic [3:0]  HPROT,
    output logic [2:0]  HSIZE,
    output logic [1:0]  HTRANS,
    output logic [31:0] HWDATA,
    output logic        HWRITE
);

    // htrans values (same as state here)
    localparam logic [1:0] IDLE   = 2'b00;
    localparam logic [1:0] BUSY   = 2'b01;
    localparam logic [1:0] NONSEQ = 2'b10;
    localparam logic [1:0] SEQ    = 2'b11;

    localparam logic [2:0] SINGLE = 3'b000;
    localparam logic [2:0] INCR   = 3'b001;

    localparam logic [2:0] WORD = 3'b010;

    logic [1:0] state, next_state;
    logic [2:0] next_burst;

    logic [31:0] next_addr;
    logic        in_transfer;
    logic        hit_1kb;
    logic [31:0] wdata_hold;
    localparam logic [1:0] OKAY = 2'b00, BUS_ERROR = 2'b01,
                           CANCELED = 2'b10, INVALID_REQUEST = 2'b11;

    logic data_pending, data_is_read;
    logic cancel_pending;
    logic new_request, valid_request, accept, issue;

    assign in_transfer = (state == NONSEQ) || (state == SEQ);
    assign next_addr   = HADDR + 32'd4;
    assign hit_1kb     = (HADDR[31:10] != next_addr[31:10]);

    assign HMASTLOCK = 1'b0;
    assign HPROT     = 4'b0011;
    assign HSIZE     = WORD;
    assign HTRANS    = state;

    assign new_request = (state == IDLE) || (in_transfer && HBURST == SINGLE);
    assign valid_request = (burst == SINGLE || burst == INCR) &&
                           size == WORD && addr[1:0] == 2'b00;

    always_comb begin
        master_ready = 1'b0;
        if (HRESETn && !HRESP && !cancel_pending &&
            (!send || continue_burst == !new_request)) begin
            if (new_request) begin
                if (send && !valid_request)
                    master_ready = state == IDLE && !data_pending;
                else
                    master_ready = state == IDLE || HREADY;
            end else if (!sender_busy) begin
                master_ready = state == BUSY || (HREADY && in_transfer && !hit_1kb);
            end
        end
    end

    assign accept = send && master_ready;
    assign issue = accept && (!new_request || valid_request);

    always_ff @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn)
            state <= IDLE;
        else
            state <= next_state;
    end

    // address + control (address phase)
    always_ff @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            HADDR  <= 32'h0;
            HBURST <= SINGLE;
            HWRITE <= 1'b0;
        end else begin
            HBURST <= next_burst;

            if (!HRESP) begin
                // new transfer or back-to-back single
                if (issue && new_request) begin
                    HADDR  <= addr;
                    HWRITE <= wr_en;
                end
                // Advance to the next INCR address, including a BUSY slot.
                else if (HREADY && in_transfer && (HBURST == INCR) &&
                         !hit_1kb && (issue || sender_busy)) begin
                    HADDR <= next_addr;
                end
            end
        end
    end

    // write data (data phase, one cycle after address)
    always_ff @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            HWDATA     <= 32'h0;
            wdata_hold <= 32'h0;
        end else begin
            if (HREADY && in_transfer && HWRITE && !HRESP)
                HWDATA <= wdata_hold;

            if (!HRESP) begin
                if (issue && (new_request ? wr_en : HWRITE))
                    wdata_hold <= data_w;
            end
        end
    end

    // The data phase belongs to the previously accepted bus address.
    always_ff @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            data_r <= '0;
            data_r_valid <= 1'b0;
            rsp_valid <= 1'b0;
            rsp_status <= OKAY;
            data_pending <= 1'b0;
            data_is_read <= 1'b0;
            cancel_pending <= 1'b0;
            boundary_reached <= 1'b0;
        end else begin
            boundary_reached <= HREADY && !HRESP && in_transfer &&
                                HBURST == INCR && hit_1kb;
            rsp_valid <= 1'b0;
            data_r_valid <= 1'b0;

            if (HREADY) begin
                data_pending <= in_transfer && !HRESP;
                data_is_read <= !HWRITE;
            end

            if (HRESP && !HREADY && in_transfer)
                cancel_pending <= 1'b1;

            if (HREADY && data_pending) begin
                rsp_valid <= 1'b1;
                rsp_status <= HRESP ? BUS_ERROR : OKAY;
                if (!HRESP && data_is_read) begin
                    data_r <= HRDATA;
                    data_r_valid <= 1'b1;
                end
            end else if (cancel_pending && !HRESP) begin
                rsp_valid <= 1'b1;
                rsp_status <= CANCELED;
                cancel_pending <= 1'b0;
            end else if (accept && !issue) begin
                rsp_valid <= 1'b1;
                rsp_status <= INVALID_REQUEST;
            end
        end
    end

    always_comb begin
        next_state = state;
        next_burst = HBURST;

        // Hold a real address phase during a wait. IDLE and BUSY can advance.
        if (HRESP) begin
            next_state = IDLE;
            next_burst = SINGLE;
        end else if (!in_transfer || HREADY) begin
            if (new_request) begin
                next_state = issue ? NONSEQ : IDLE;
                next_burst = issue ? burst : SINGLE;
            end else if (in_transfer && hit_1kb) begin
                next_state = IDLE;
                next_burst = SINGLE;
            end else if (sender_busy) begin
                next_state = BUSY;
            end else if (issue) begin
                next_state = SEQ;
            end else begin
                next_state = IDLE;
                next_burst = SINGLE;
            end
        end
    end

endmodule
