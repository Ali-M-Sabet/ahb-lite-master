// testbench for master + interconnect
// slaves are fake (just drive hreadyout/hresp/hrdata by hand)
module tb_master_interconnect;

    logic HCLK, HRESETn;

    // master user inputs
    logic        send, wr_en, sender_busy;
    logic [31:0] addr;
    logic [2:0]  size, burst;
    logic [31:0] data_w;
    logic [31:0] data_r;
    logic        data_r_valid, master_ready;

    // system bus
    logic        HREADY, HRESP, HWRITE;
    logic [31:0] HRDATA, HADDR, HWDATA;
    logic [2:0]  HBURST, HSIZE;
    logic        HMASTLOCK;
    logic [3:0]  HPROT;
    logic [1:0]  HTRANS;

    // interconnect to slave side
    logic        HSEL0, HSEL1, S_HREADY, S_HWRITE;
    logic [31:0] S_HADDR, S_HWDATA;
    logic [2:0]  S_HBURST, S_HSIZE;
    logic        S_HMASTLOCK;
    logic [3:0]  S_HPROT;
    logic [1:0]  S_HTRANS;

    // fake slave returns
    logic [31:0] HRDATA0, HRDATA1;
    logic        HREADYOUT0, HREADYOUT1, HRESP0, HRESP1;

    logic continue_burst, boundary_reached;
    logic rsp_valid;
    logic [1:0] rsp_status;

    AHB_master u_master (.*);

    AHB_interconnect u_ic (
        .HCLK(HCLK), .HRESETn(HRESETn),
        .HADDR(HADDR), .HBURST(HBURST), .HMASTLOCK(HMASTLOCK), .HPROT(HPROT),
        .HSIZE(HSIZE), .HTRANS(HTRANS), .HWDATA(HWDATA), .HWRITE(HWRITE),
        .HREADY(HREADY), .HRESP(HRESP), .HRDATA(HRDATA),
        .HSEL0(HSEL0), .HSEL1(HSEL1),
        .S_HADDR(S_HADDR), .S_HBURST(S_HBURST), .S_HMASTLOCK(S_HMASTLOCK),
        .S_HPROT(S_HPROT), .S_HSIZE(S_HSIZE), .S_HTRANS(S_HTRANS),
        .S_HWDATA(S_HWDATA), .S_HWRITE(S_HWRITE), .S_HREADY(S_HREADY),
        .HRDATA0(HRDATA0), .HREADYOUT0(HREADYOUT0), .HRESP0(HRESP0),
        .HRDATA1(HRDATA1), .HREADYOUT1(HREADYOUT1), .HRESP1(HRESP1)
    );

    localparam logic [1:0] OKAY = 0, BUS_ERROR = 1,
                           CANCELED = 2, INVALID_REQUEST = 3;

    typedef struct packed {
        logic [1:0] status;
        logic       read_valid;
        logic [31:0] read_data;
    } response_t;

    bit passed;
    int accepted_count, response_count;
    response_t expected [19];

    always @(posedge HCLK) begin
        if (HRESETn) begin
            if (rsp_valid === 1'b1) begin
                if (response_count >= accepted_count || response_count >= $size(expected))
                    $fatal(1, "Unexpected response at index %0d", response_count);
                if (rsp_status !== expected[response_count].status)
                    $fatal(1, "Response %0d: expected status %0d, got %0d",
                           response_count, expected[response_count].status, rsp_status);
                if (data_r_valid !== expected[response_count].read_valid)
                    $fatal(1, "Response %0d: unexpected read-valid flag", response_count);
                if (data_r_valid && data_r !== expected[response_count].read_data)
                    $fatal(1, "Response %0d: expected data %h, got %h",
                           response_count, expected[response_count].read_data, data_r);
                response_count++;
            end else if (rsp_valid !== 1'b0 || data_r_valid !== 1'b0) begin
                $fatal(1, "Invalid response or read-valid flag");
            end
            if (send && master_ready)
                accepted_count++;
        end
    end

    initial HCLK = 0;
    always #5 HCLK = ~HCLK;

    initial begin
        #2000;
        $fatal(1, "Integration timeout");
    end

    task check(input logic cond, input string msg);
        if (cond !== 1'b1)
            $fatal(1, "%s", msg);
    endtask

    task reset_inputs;
        send = 0;
        addr = 0;
        wr_en = 0;
        size = 3'b010;
        burst = 3'b000;
        data_w = 0;
        sender_busy = 0;
        continue_burst = 0;
    endtask

    task reset_slaves;
        HRDATA0 = 0; HREADYOUT0 = 1; HRESP0 = 0;
        HRDATA1 = 0; HREADYOUT1 = 1; HRESP1 = 0;
    endtask

    task start_beat(input [31:0] a, input bit w, input [2:0] b, input [31:0] d);
        @(negedge HCLK);
        send = 1;
        continue_burst = 0;
        addr = a;
        wr_en = w;
        burst = b;
        size = 3'b010;
        data_w = d;
    endtask

    initial begin
        expected = '{
            {OKAY, 1'b0, 32'b0}, {OKAY, 1'b1, 32'hFEED_BEEF}, // Single write and read
            {OKAY, 1'b0, 32'b0}, {OKAY, 1'b0, 32'b0}, // Stalled writes
            {OKAY, 1'b0, 32'b0}, {OKAY, 1'b0, 32'b0}, {OKAY, 1'b0, 32'b0}, // INCR
            {BUS_ERROR, 1'b0, 32'b0}, {BUS_ERROR, 1'b0, 32'b0},
            {INVALID_REQUEST, 1'b0, 32'b0}, {INVALID_REQUEST, 1'b0, 32'b0},
            {INVALID_REQUEST, 1'b0, 32'b0},
            {OKAY, 1'b0, 32'b0}, {OKAY, 1'b0, 32'b0}, {OKAY, 1'b0, 32'b0}, // Boundary and restart
            {BUS_ERROR, 1'b0, 32'b0}, {CANCELED, 1'b0, 32'b0},
            {OKAY, 1'b1, 32'h1122_3344}, {OKAY, 1'b1, 32'h5566_7788}
        };

        HRESETn = 0;
        reset_inputs();
        reset_slaves();

        repeat (3) @(negedge HCLK);
        HRESETn = 1;
        @(posedge HCLK); #1;

        // t1 reset
        check(HTRANS == 2'b00, "t1 htrans idle after reset");
        check(HSEL0 == 0 && HSEL1 == 0, "t1 no slave selected");

        // t2 single write to slave0
        start_beat(32'h0000_0010, 1, 3'b000, 32'hDEAD_0001);
        @(posedge HCLK); #1;
        check(HSEL0 && !HSEL1, "t2 slave0 selected");
        check(S_HADDR == 32'h0000_0010 && S_HWRITE && S_HTRANS == 2'b10,
              "t2 addr phase ok");
        @(negedge HCLK);
        send = 0;
        @(posedge HCLK); #1;
        check(S_HWDATA == 32'hDEAD_0001, "t2 write data ok");

        // t3 single read from slave1
        wait (master_ready);
        HRDATA1 = 32'hFEED_BEEF;
        start_beat(32'h0000_1000, 0, 3'b000, 0);
        @(posedge HCLK); #1;
        check(HSEL1 && !HSEL0, "t3 slave1 selected");
        check(S_HADDR == 32'h0000_1000 && !S_HWRITE, "t3 read addr ok");
        @(negedge HCLK);
        send = 0;
        repeat (2) @(posedge HCLK); #1;
        check(data_r_valid && data_r == 32'hFEED_BEEF, "t3 read data ok");

        // t4 wait state (back to back beats)
        reset_slaves();
        wait (master_ready);
        start_beat(32'h0000_0020, 1, 3'b000, 32'h1111_2222);
        @(posedge HCLK); #1;
        check(HSEL0, "t4 slave0 selected");

        @(negedge HCLK);
        addr = 32'h0000_0024;
        data_w = 32'h3333_4444;
        send = 1;
        HREADYOUT0 = 0;
        @(posedge HCLK); #1;
        check(!HREADY, "t4 hready low from slave");
        check(HWDATA == 32'h1111_2222, "t4 first write data while stalled");
        check(HADDR == 32'h0000_0024 && HTRANS == 2'b10,
              "t4 master holds addr/htrans");
        @(posedge HCLK); #1;
        check(!HREADY && HADDR == 32'h0000_0024 && HTRANS == 2'b10,
              "t4 still holding on wait");
        check(HWDATA == 32'h1111_2222, "t4 write data held through wait");
        @(negedge HCLK);
        HREADYOUT0 = 1;
        send = 0;
        @(posedge HCLK); #1;

        // t5 incr burst on slave0
        reset_slaves();
        wait (master_ready);
        start_beat(32'h0000_0100, 1, 3'b001, 32'hA0);
        @(posedge HCLK); #1;
        check(HSEL0 && !HSEL1 && S_HADDR == 32'h0000_0100, "t5 beat1");
        @(negedge HCLK);
        continue_burst = 1;
        data_w = 32'hA1;
        @(posedge HCLK); #1;
        check(HSEL0 && S_HADDR == 32'h0000_0104 && HTRANS == 2'b11 && HWDATA == 32'hA0, "t5 beat2");
        @(negedge HCLK);
        data_w = 32'hA2;
        @(posedge HCLK); #1;
        check(HSEL0 && S_HADDR == 32'h0000_0108 && HTRANS == 2'b11 && HWDATA == 32'hA1, "t5 beat3");
        @(negedge HCLK);
        send = 0;
        @(posedge HCLK); #1;

        check(HWDATA == 32'hA2, "t5 final write data");

        // t6 bad address -> default slave error
        reset_slaves();
        wait (master_ready);
        start_beat(32'h0000_3000, 0, 3'b000, 0);
        @(posedge HCLK); #1;
        check(!HSEL0 && !HSEL1, "t6 no slave for bad addr");
        @(negedge HCLK);
        send = 0;
        @(posedge HCLK); #1;
        check(HRESP && !HREADY, "t6 error cycle 1");
        check(HTRANS == 2'b00, "t6 master goes idle");
        @(posedge HCLK); #1;
        check(HRESP && HREADY, "t6 error cycle 2");
        @(posedge HCLK); #1;
        check(!HRESP && HREADY, "t6 back to okay");

        // t7 slave0 returns error (mux test)
        reset_slaves();
        wait (master_ready);
        start_beat(32'h0000_0040, 1, 3'b000, 32'hABCD_0001);
        @(posedge HCLK); #1;
        check(HSEL0, "t7 slave0 selected");
        @(negedge HCLK);
        send = 0;
        HRESP0 = 1;
        HREADYOUT0 = 0;
        @(posedge HCLK); #1;
        check(HRESP && !HREADY, "t7 slave error cycle 1");
        check(HTRANS == 2'b00, "t7 master idle on error");
        @(posedge HCLK);
        HREADYOUT0 <= 1;
        #1;
        check(HRESP && HREADY, "t7 slave error cycle 2");
        @(posedge HCLK);
        HRESP0 <= 0;
        #1;
        check(!HRESP, "t7 okay again");

        // Invalid burst, size, and alignment are rejected without a bus beat.
        for (int invalid = 0; invalid < 3; invalid++) begin
            start_beat(invalid == 2 ? 32'h21 : 32'h20, 1,
                       invalid == 0 ? 3'b011 : 3'b000, 32'h1234);
            if (invalid == 1) size = 3'b001;
            @(posedge HCLK); #1;
            check(rsp_valid && rsp_status == 3 && HTRANS == 0, "invalid request");
        end
        @(negedge HCLK);
        send = 0;

        // A BUSY address is followed by SEQ, carrying its own write word.
        start_beat(32'h0000_03F8, 1, 3'b001, 32'h1111);
        @(negedge HCLK);
        send = 0;
        sender_busy = 1;
        @(posedge HCLK); #1;
        check(HTRANS == 1 && HADDR == 32'h3FC && HWDATA == 32'h1111, "BUSY and first write");
        @(negedge HCLK);
        send = 1;
        sender_busy = 0;
        continue_burst = 1;
        data_w = 32'h2222;
        @(posedge HCLK); #1;
        check(HTRANS == 3 && HADDR == 32'h3FC, "resume INCR");
        @(negedge HCLK);
        data_w = 32'h3333;
        #1;
        check(!master_ready && !boundary_reached, "boundary beat still in address phase");
        @(posedge HCLK); #1;
        check(boundary_reached && HTRANS == 0 && HWDATA == 32'h2222,
              "notify on boundary and drive last word");
        repeat (3) begin
            @(posedge HCLK); #1;
            check(!boundary_reached && !master_ready && HTRANS == 0,
                  "held continuation cannot restart at the old address");
        end
        @(negedge HCLK);
        continue_burst = 0; // Withdraw the continuation and explicitly start at the same addr.
        #1;
        check(master_ready, "explicit start accepted after boundary");
        @(posedge HCLK); #1;
        check(HTRANS == 2 && HADDR == 32'h3F8, "restart at original address with NONSEQ");
        @(negedge HCLK);
        send = 0;
        repeat (3) @(posedge HCLK);
        #1;

        // A read to the default slave fails with a following write queued.
        start_beat(32'h3000, 0, 3'b000, 0);
        start_beat(32'h40, 1, 3'b000, 32'hBAD);
        @(posedge HCLK); #1;
        check(HRESP && !HREADY && HSEL0 && HTRANS == 2, "queued address during first ERROR cycle");
        @(negedge HCLK);
        send = 0;
        @(posedge HCLK); #1;
        check(HRESP && HREADY && !HSEL0 && HTRANS == 0, "cancel before slave accepts address");
        repeat (3) @(posedge HCLK);
        #1;

        // The next address selects slave 1 while slave 0 owns the data phase.
        reset_slaves();
        HRDATA0 = 32'h1122_3344;
        HRDATA1 = 32'h5566_7788;
        start_beat(32'h10, 0, 3'b000, 0);
        start_beat(32'h1000, 0, 3'b000, 0);
        HREADYOUT0 = 0;
        @(posedge HCLK); #1;
        check(HSEL1 && !HREADY && HRDATA == HRDATA0 && !rsp_valid,
              "slave 0 owns the stalled data phase");
        @(negedge HCLK);
        send = 0;
        @(posedge HCLK); #1;
        check(HSEL1 && !HREADY && !rsp_valid, "no response before the stall ends");
        @(negedge HCLK);
        HREADYOUT0 = 1;
        @(posedge HCLK); #1;
        check(rsp_valid && rsp_status == 0 && data_r_valid && data_r == 32'h1122_3344,
              "first response returns slave 0 data");
        @(posedge HCLK); #1;
        check(rsp_valid && rsp_status == 0 && data_r_valid && data_r == 32'h5566_7788,
              "second response returns slave 1 data");
        @(posedge HCLK); #1;
        check(!rsp_valid, "no extra response after the two reads");

        check(response_count == $size(expected) && response_count == accepted_count, "one response per accepted request");

        passed = 1;
        $display("INTEGRATION_PASS");
        $finish;
    end

endmodule
