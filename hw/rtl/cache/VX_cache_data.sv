// Copyright © 2019-2023
// 
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
// 
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "VX_cache_define.vh"

module VX_cache_data #(
    parameter `STRING INSTANCE_ID= "",
    parameter BANK_ID           = 0,
    // Size of cache in bytes
    parameter CACHE_SIZE        = 1024, 
    // Size of line inside a bank in bytes
    parameter LINE_SIZE         = 16, 
    // Number of banks
    parameter NUM_BANKS         = 1, 
    // Number of associative ways
    parameter NUM_WAYS          = 1,
    // Size of a word in bytes
    parameter WORD_SIZE         = 1,
    // Enable cache writeable
    parameter WRITE_ENABLE      = 1,
    // Request debug identifier
    parameter UUID_WIDTH        = 0,
    parameter WRITEBACK         = 0
) (
    input wire                          clk,
    input wire                          reset,

`IGNORE_UNUSED_BEGIN
    input wire[`UP(UUID_WIDTH)-1:0]     req_uuid,
`IGNORE_UNUSED_END

    input wire                          stall,

    input wire                          read,
    input wire                          fill, 
    input wire                          write,
    input wire [`CS_LINE_ADDR_WIDTH-1:0] line_addr,
    input wire [`UP(`CS_WORD_SEL_BITS)-1:0] wsel,
    input wire [WORD_SIZE-1:0]          byteen,
    input wire [`CS_WORDS_PER_LINE-1:0][`CS_WORD_WIDTH-1:0] fill_data,
    input wire [`CS_WORD_WIDTH-1:0]     write_data,
    input wire [NUM_WAYS-1:0]           way_sel,

    output wire [`CS_WORD_WIDTH-1:0]    read_data,
    output wire [LINE_SIZE-1:0]         write_byteen,
    `IGNORE_WARNINGS_BEGIN
    output reg [`CS_WORDS_PER_LINE-1:0][`CS_WORD_WIDTH-1:0] evicted_data
    `IGNORE_WARNINGS_END
);
    `UNUSED_SPARAM (INSTANCE_ID)
    `UNUSED_PARAM (BANK_ID)
    `UNUSED_PARAM (WORD_SIZE)
    `UNUSED_VAR (reset)
    `UNUSED_VAR (line_addr)
    `UNUSED_VAR (read)

    localparam BYTEENW = (WRITE_ENABLE != 0 || (NUM_WAYS > 1)) ? (LINE_SIZE * NUM_WAYS) : 1;

    wire [`CS_WORDS_PER_LINE-1:0][NUM_WAYS-1:0][`CS_WORD_WIDTH-1:0] wdata;
    wire [BYTEENW-1:0] wren;

    reg [`CS_WORDS_PER_LINE-1:0][WORD_SIZE-1:0] wren_r;
    always @(*) begin
        wren_r  = '0;
        wren_r[wsel] = byteen;
    end

    reg [`CS_LINES_PER_BANK-1:0][NUM_WAYS-1:0][LINE_SIZE-1:0] dirty_bytes_r;
    reg [`CS_LINES_PER_BANK-1:0][NUM_WAYS-1:0][LINE_SIZE-1:0] dirty_bytes_n;
    reg [LINE_SIZE-1:0] line_byteen0, line_byteen1;
    if (WRITEBACK) begin
        // reg [`CS_LINES_PER_BANK-1:0][NUM_WAYS-1:0][LINE_SIZE-1:0] dirty_bytes_r;
        // reg [`CS_LINES_PER_BANK-1:0][NUM_WAYS-1:0][LINE_SIZE-1:0] dirty_bytes_n;
        // reg [LINE_SIZE-1:0] line_byteen0, line_byteen1;
        integer i, j;
        always @(*) begin
            line_byteen0 = {{(LINE_SIZE-WORD_SIZE){1'b0}}, byteen};
            line_byteen1 = line_byteen0 << (wsel * WORD_SIZE);
            for (i = 0; i < `CS_LINES_PER_BANK; ++i) begin
                for (j = 0; j < NUM_WAYS; ++j) begin
                    dirty_bytes_n[i][j] = dirty_bytes_r[i][j];
                end
            end
            if (fill) begin
                dirty_bytes_n[line_sel][way_idx] = 'd0;
            end else if (write) begin
                dirty_bytes_n[line_sel][way_idx] = dirty_bytes_r[line_sel][way_idx] | line_byteen1;
            end
        end
        integer n, p;
        always @(*) begin
            for (n = 0; n < `CS_WORDS_PER_LINE; ++n) begin
                evicted_data[n] = '0;
                // assign wdata[i] = fill ? {NUM_WAYS{fill_data[i]}} : {NUM_WAYS{wdata_r[i]}};            
                for (p = 0; p < NUM_WAYS; ++p) begin
                    if (way_sel[p]) begin
                        evicted_data[n] = rdata[n][p];
                    end
                end
            end
        end
        integer k, m;
        always @(posedge clk) begin
            if (reset) begin
                for (k = 0; k < `CS_LINES_PER_BANK; ++k) begin
                    for (m = 0; m < NUM_WAYS; ++m) begin
                        dirty_bytes_r[k][m] <= '0;
                    end
                end
            end else begin
                for (k = 0; k < `CS_LINES_PER_BANK; ++k) begin
                    for (m = 0; m < NUM_WAYS; ++m) begin
                        dirty_bytes_r[k][m] <= dirty_bytes_n[k][m];
                    end
                end
            end
        end
        assign write_byteen = dirty_bytes_r[line_sel][way_idx];
    end else begin
        assign write_byteen = wren_r;

        `UNUSED_VAR (dirty_bytes_r)
        `UNUSED_VAR (dirty_bytes_n)
        `UNUSED_VAR (line_byteen0)
        `UNUSED_VAR (line_byteen1)
        always @(*) begin
        `IGNORE_WARNINGS_BEGIN
            for (int k = 0; k < `CS_LINES_PER_BANK; ++k) begin
                for (int m = 0; m < NUM_WAYS; ++m) begin
                    dirty_bytes_r = 'd0;
                    dirty_bytes_n = 'd0;
                end
            end
        `IGNORE_WARNINGS_END
            line_byteen0 = 'x;
            line_byteen1 = 'x;
        end
    end

    if (WRITE_ENABLE != 0 || (NUM_WAYS > 1)) begin
        reg [`CS_WORDS_PER_LINE-1:0][`CS_WORD_WIDTH-1:0] wdata_r;

        always @(*) begin
            wdata_r = {`CS_WORDS_PER_LINE{write_data}};
        end
        
        
        // order the data layout to perform ways multiplexing last 
        // this allows performing onehot encoding of the way index in parallel with BRAM read.
        wire [`CS_WORDS_PER_LINE-1:0][NUM_WAYS-1:0][WORD_SIZE-1:0] wren_w;
        for (genvar i = 0; i < `CS_WORDS_PER_LINE; ++i) begin
            assign wdata[i] = fill ? {NUM_WAYS{fill_data[i]}} : {NUM_WAYS{wdata_r[i]}};            
            for (genvar j = 0; j < NUM_WAYS; ++j) begin
                assign wren_w[i][j] = (fill ? {WORD_SIZE{1'b1}} : wren_r[i])
                                    & {WORD_SIZE{((NUM_WAYS == 1) || way_sel[j])}};
            end
        end
        assign wren = wren_w;
    end else begin
        `UNUSED_VAR (write)
        `UNUSED_VAR (byteen)
        `UNUSED_VAR (write_data)
        assign wdata = fill_data;
        assign wren  = fill;
    end
    
    wire [`LOG2UP(NUM_WAYS)-1:0] way_idx;

    VX_onehot_encoder #(
        .N (NUM_WAYS)
    ) way_enc (
        .data_in  (way_sel),
        .data_out (way_idx),
        `UNUSED_PIN (valid_out)
    );

    wire [`CS_WORDS_PER_LINE-1:0][NUM_WAYS-1:0][`CS_WORD_WIDTH-1:0] rdata;

    wire [`CS_LINE_SEL_BITS-1:0] line_sel = line_addr[`CS_LINE_SEL_BITS-1:0];
    
    VX_sp_ram #(
        .DATAW (`CS_LINE_WIDTH * NUM_WAYS),
        .SIZE  (`CS_LINES_PER_BANK),
        .WRENW (BYTEENW),
        .NO_RWCHECK (1)
    ) data_store (
        .clk   (clk),
        .read  (1'b1),
        .write (write || fill), // it cares about if it is a write time
        .wren  (wren), // it only cares about way selection, byteen, and write type (fill, core/replay write), it does not care about if it is a write time, so it may be set for read
        .addr  (line_sel),
        .wdata (wdata),
        .rdata (rdata) 
    );

    wire [NUM_WAYS-1:0][`CS_WORD_WIDTH-1:0] per_way_rdata;

    if (`CS_WORDS_PER_LINE > 1) begin
        assign per_way_rdata = rdata[wsel];
    end else begin
        `UNUSED_VAR (wsel)
        assign per_way_rdata = rdata;
    end    

    assign read_data = per_way_rdata[way_idx];

    `UNUSED_VAR (stall)
    

`ifdef DBG_TRACE_CACHE
    always @(posedge clk) begin 
        if (fill && ~stall) begin
            `TRACE(3, ("%d: %s-bank%0d data-fill: addr=0x%0h, way=%b, blk_addr=%0d, data=0x%0h\n", $time, INSTANCE_ID, BANK_ID, `CS_LINE_TO_FULL_ADDR(line_addr, BANK_ID), way_sel, line_sel, fill_data));
        end
        if (read && ~stall) begin
            `TRACE(3, ("%d: %s-bank%0d data-read: addr=0x%0h, way=%b, blk_addr=%0d, data=0x%0h (#%0d)\n", $time, INSTANCE_ID, BANK_ID, `CS_LINE_TO_FULL_ADDR(line_addr, BANK_ID), way_sel, line_sel, read_data, req_uuid));
        end 
        if (write && ~stall) begin
            `TRACE(3, ("%d: %s-bank%0d data-write: addr=0x%0h, way=%b, blk_addr=%0d, byteen=%b, data=0x%0h (#%0d)\n", $time, INSTANCE_ID, BANK_ID, `CS_LINE_TO_FULL_ADDR(line_addr, BANK_ID), way_sel, line_sel, byteen, write_data, req_uuid));
        end      
    end    
`endif

endmodule
