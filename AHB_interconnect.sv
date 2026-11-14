// Decode two slave address ranges and route the data-phase response.
module AHB_interconnect (
    input  logic        HCLK,
    input  logic        HRESETn,

    // from master
    input  logic [31:0] HADDR,
    input  logic [2:0]  HBURST,
    input  logic        HMASTLOCK,
    input  logic [3:0]  HPROT,
    input  logic [2:0]  HSIZE,
    input  logic [1:0]  HTRANS,
    input  logic [31:0] HWDATA,
    input  logic        HWRITE,

    // back to master
    output logic        HREADY,
    output logic        HRESP,
    output logic [31:0] HRDATA,

    output logic        HSEL0,
    output logic        HSEL1,

    // to all slaves (broadcast)
    output logic [31:0] S_HADDR,
    output logic [2:0]  S_HBURST,
    output logic        S_HMASTLOCK,
    output logic [3:0]  S_HPROT,
    output logic [2:0]  S_HSIZE,
    output logic [1:0]  S_HTRANS,
    output logic [31:0] S_HWDATA,
    output logic        S_HWRITE,
    output logic        S_HREADY,

    // from slave 0
    input  logic [31:0] HRDATA0,
    input  logic        HREADYOUT0,
    input  logic        HRESP0,

    // from slave 1
    input  logic [31:0] HRDATA1,
    input  logic        HREADYOUT1,
    input  logic        HRESP1
);

    // slave 0: 0x0000_0000 - 0x0000_0fff
    // slave 1: 0x0000_1000 - 0x0000_1fff
    localparam [19:0] S0_BASE = 20'h0_0000;
    localparam [19:0] S1_BASE = 20'h0_0001;

    localparam SEL_NONE    = 2'd0;
    localparam SEL_S0      = 2'd1;
    localparam SEL_S1      = 2'd2;
    localparam SEL_DEFAULT = 2'd3;

    logic [1:0] pick_now;      // decode in address phase
    logic [1:0] pick_data;     // saved for data phase (pipeline)
    logic       real_xfer;
    logic       err_step;      // 0 then 1 for default slave error

    assign real_xfer = HTRANS[1];   // nonseq or seq

    // address decode
    always_comb begin
        if (!real_xfer)
            pick_now = SEL_NONE;
        else if (HADDR[31:12] == S0_BASE)
            pick_now = SEL_S0;
        else if (HADDR[31:12] == S1_BASE)
            pick_now = SEL_S1;
        else
            pick_now = SEL_DEFAULT;
    end

    assign HSEL0 = (pick_now == SEL_S0);
    assign HSEL1 = (pick_now == SEL_S1);

    // pass master signals to slave side
    assign S_HADDR     = HADDR;
    assign S_HBURST    = HBURST;
    assign S_HMASTLOCK = HMASTLOCK;
    assign S_HPROT     = HPROT;
    assign S_HSIZE     = HSIZE;
    assign S_HTRANS    = HTRANS;
    assign S_HWDATA    = HWDATA;
    assign S_HWRITE    = HWRITE;
    assign S_HREADY    = HREADY;

    // remember who was selected when address went out
    always_ff @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn)
            pick_data <= SEL_NONE;
        else if (HREADY)
            pick_data <= pick_now;
    end

    // default slave error is always 2 cycles:
    // cycle1 hresp=1 hready=0, cycle2 hresp=1 hready=1
    always_ff @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn)
            err_step <= 1'b0;
        else if (pick_data != SEL_DEFAULT)
            err_step <= 1'b0;
        else if (!err_step)
            err_step <= 1'b1;
        else if (HREADY)
            err_step <= 1'b0;
    end

    // mux slave response back to master
    always_comb begin
        HREADY = 1'b1;
        HRESP  = 1'b0;
        HRDATA = 32'h0;

        case (pick_data)
            SEL_S0: begin
                HREADY = HREADYOUT0;
                HRESP  = HRESP0;
                HRDATA = HRDATA0;
            end

            SEL_S1: begin
                HREADY = HREADYOUT1;
                HRESP  = HRESP1;
                HRDATA = HRDATA1;
            end

            SEL_DEFAULT: begin
                HRESP  = 1'b1;
                HREADY = err_step;
                HRDATA = 32'h0;
            end

            default: begin
                HREADY = 1'b1;
                HRESP  = 1'b0;
                HRDATA = 32'h0;
            end
        endcase
    end

endmodule
