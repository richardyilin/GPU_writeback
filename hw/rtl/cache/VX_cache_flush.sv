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

// cache flush_begin unit
module VX_cache_flush #(
    // Size of line inside a bank in bytes
    parameter LINE_SIZE     = 16,     
    // Size of a word in bytes
    parameter WORD_SIZE             = `XLEN/8,
    // Number of banks
    parameter NUM_BANKS     = 1,
    // Number of Word requests per cycle
    parameter NUM_REQS              = 4,
    // Request debug identifier
    parameter UUID_WIDTH            = 0,
    // core request tag size
    parameter TAG_WIDTH             = UUID_WIDTH + 1
) (
    input  wire clk,
    input  wire reset,
    VX_mem_bus_if.slave     core_bus_in_if [NUM_REQS],
    VX_mem_bus_if.master     core_bus_out_if [NUM_REQS],
    input  wire [NUM_BANKS-1:0] flush_banks_complete
);
    localparam RUN = 0;
    localparam ISSUE_BANK_FLUSHES = 1;
    localparam WAIT_BANK_FLUSH = 2;
    localparam RESUME = 3;

    localparam WORDS_PER_LINE  = LINE_SIZE / WORD_SIZE;
    localparam WORD_SEL_BITS   = `CLOG2(WORDS_PER_LINE);
    // localparam BANK_SEL_BITS   = `CLOG2(NUM_BANKS);
    // localparam LINE_ADDR_WIDTH = (`CS_WORD_ADDR_WIDTH - BANK_SEL_BITS - WORD_SEL_BITS);
    localparam CS_BANK_SEL_BITS_WIDTH = `UP(`CS_BANK_SEL_BITS);

    wire all_banks_flushed = &flush_banks_done;
    reg [1:0] state, state_n;
    reg flush_begin;
    reg [CS_BANK_SEL_BITS_WIDTH-1:0] bank_ctr, bank_ctr_n;
    // if (NUM_BANKS > 1) begin
    // end else begin
    //     reg bank_ctr, bank_ctr_n;
    // end
    reg [NUM_BANKS-1:0] flush_banks_done, flush_banks_done_n;
    reg flush_pass;

    reg [NUM_REQS-1:0]                     core_bus_out_if_core_req_valid;
    reg [NUM_REQS-1:0][`CS_WORD_ADDR_WIDTH-1:0] core_bus_out_if_core_req_addr;
    reg [NUM_REQS-1:0]                     core_bus_out_if_core_req_rw;    
    reg [NUM_REQS-1:0][WORD_SIZE-1:0]      core_bus_out_if_core_req_byteen;
    reg [NUM_REQS-1:0][`CS_WORD_WIDTH-1:0] core_bus_out_if_core_req_data;
    reg [NUM_REQS-1:0][TAG_WIDTH-1:0]      core_bus_out_if_core_req_tag;
    reg [NUM_REQS-1:0]                     core_bus_out_if_core_req_ready;
    reg [NUM_REQS-1:0][`ADDR_TYPE_WIDTH-1:0] core_bus_out_if_core_req_atype;

    reg [NUM_REQS-1:0]                     core_bus_in_if_core_req_valid;
    reg [NUM_REQS-1:0][`CS_WORD_ADDR_WIDTH-1:0] core_bus_in_if_core_req_addr;
    reg [NUM_REQS-1:0]                     core_bus_in_if_core_req_rw;    
    reg [NUM_REQS-1:0][WORD_SIZE-1:0]      core_bus_in_if_core_req_byteen;
    reg [NUM_REQS-1:0][`CS_WORD_WIDTH-1:0] core_bus_in_if_core_req_data;
    reg [NUM_REQS-1:0][TAG_WIDTH-1:0]      core_bus_in_if_core_req_tag;
    reg [NUM_REQS-1:0][`ADDR_TYPE_WIDTH-1:0] core_bus_in_if_core_req_atype;
    reg [NUM_REQS-1:0]                     core_bus_in_if_core_req_ready;



    for (genvar i = 0; i < NUM_REQS; ++i) begin
        assign core_bus_out_if[i].req_valid  = core_bus_out_if_core_req_valid[i];
        assign core_bus_out_if[i].req_data.rw    = core_bus_out_if_core_req_rw[i];
        assign core_bus_out_if[i].req_data.byteen = core_bus_out_if_core_req_byteen[i];
        assign core_bus_out_if[i].req_data.addr   = core_bus_out_if_core_req_addr[i];
        assign core_bus_out_if[i].req_data.data   = core_bus_out_if_core_req_data[i];
        assign core_bus_out_if[i].req_data.tag   = core_bus_out_if_core_req_tag[i];
        assign core_bus_out_if[i].req_data.atype = core_bus_out_if_core_req_atype[i];
        assign core_bus_out_if_core_req_ready[i] = core_bus_out_if[i].req_ready;
    end
    
    for (genvar i = 0; i < NUM_REQS; ++i) begin
        assign core_bus_in_if_core_req_valid[i] = core_bus_in_if[i].req_valid;
        assign core_bus_in_if_core_req_rw[i] = core_bus_in_if[i].req_data.rw;
        assign core_bus_in_if_core_req_byteen[i] = core_bus_in_if[i].req_data.byteen;
        assign core_bus_in_if_core_req_addr[i] = core_bus_in_if[i].req_data.addr;
        assign core_bus_in_if_core_req_data[i] = core_bus_in_if[i].req_data.data;
        assign core_bus_in_if_core_req_tag[i] = core_bus_in_if[i].req_data.tag;
        assign core_bus_in_if_core_req_atype[i] = core_bus_in_if[i].req_data.atype;
        assign core_bus_in_if[i].req_ready = core_bus_in_if_core_req_ready[i];
    end
    
    for (genvar i = 0; i < NUM_REQS; ++i) begin
        assign core_bus_in_if[i].rsp_valid = core_bus_out_if[i].rsp_valid;
        assign core_bus_in_if[i].rsp_data = core_bus_out_if[i].rsp_data;
        assign core_bus_out_if[i].rsp_ready = core_bus_in_if[i].rsp_ready;
    end

    always @(*) begin
        for (int i = 0; i < NUM_REQS; i++) begin
            core_bus_out_if_core_req_valid[i]  = core_bus_in_if_core_req_valid[i];
            core_bus_out_if_core_req_rw[i]    = core_bus_in_if_core_req_rw[i];
            core_bus_out_if_core_req_byteen[i] = core_bus_in_if_core_req_byteen[i];
            core_bus_out_if_core_req_addr[i]   = core_bus_in_if_core_req_addr[i];
            core_bus_out_if_core_req_data[i]   = core_bus_in_if_core_req_data[i];
            core_bus_out_if_core_req_tag[i]   = core_bus_in_if_core_req_tag[i];
            core_bus_out_if_core_req_atype[i] = core_bus_in_if_core_req_atype[i];
            core_bus_in_if_core_req_ready[i] = core_bus_out_if_core_req_ready[i];
        end
        flush_begin = 1'b0;
        for (int i = 0; i < NUM_REQS; i++) begin
            flush_begin = flush_begin || (core_bus_in_if_core_req_valid[i] && core_bus_in_if_core_req_atype[i][`ADDR_TYPE_FLUSH]);
        end
        state_n = state;
        bank_ctr_n = bank_ctr;
        flush_banks_done_n = 'd0;
        flush_pass = 1'b0;
        for (int i = 0; i < NUM_REQS; ++i) begin
            flush_pass = flush_pass || (core_bus_out_if_core_req_valid[i] && core_bus_out_if_core_req_ready[0] && core_bus_in_if_core_req_atype[i][`ADDR_TYPE_FLUSH]);
        end
        case (state)
            RUN: begin
                if (flush_begin) begin
                    state_n = ISSUE_BANK_FLUSHES;
                end
                bank_ctr_n = 'd0;
                for (int i = 0; i < NUM_REQS; ++i) begin
                    core_bus_out_if_core_req_valid[i]  = core_bus_in_if_core_req_valid[i] && (~core_bus_in_if_core_req_atype[i][`ADDR_TYPE_FLUSH]); // do not let flush pass through
                    core_bus_in_if_core_req_ready[i]  = core_bus_out_if_core_req_ready[i] && (~core_bus_in_if_core_req_atype[i][`ADDR_TYPE_FLUSH]);
                end
            end
            ISSUE_BANK_FLUSHES: begin
                if (bank_ctr == CS_BANK_SEL_BITS_WIDTH'(NUM_BANKS-1) && core_bus_out_if_core_req_ready[0]) begin
                    state_n = WAIT_BANK_FLUSH;
                end
                core_bus_out_if_core_req_valid[0]  = 1'b1;
                // core_bus_out_if_core_req_addr[0] = {{LINE_ADDR_WIDTH{1'b0}}, bank_ctr, {WORD_SEL_BITS{1'b0}}};
                core_bus_out_if_core_req_addr[0] = `CS_WORD_ADDR_WIDTH'(bank_ctr) << WORD_SEL_BITS;
                core_bus_out_if_core_req_rw[0]    = 1'b1;
                for (int i = 1; i < NUM_REQS; ++i) begin
                    core_bus_out_if_core_req_valid[i]  = 1'b0;
                end
                for (int i = 0; i < NUM_REQS; ++i) begin
                    core_bus_in_if_core_req_ready[i]  = 1'b0;
                end
                if (core_bus_out_if_core_req_valid[0] && core_bus_out_if_core_req_ready[0]) begin
                    bank_ctr_n = bank_ctr + 1;
                end
                flush_banks_done_n = flush_banks_done | flush_banks_complete;
            end
            WAIT_BANK_FLUSH: begin
                if (all_banks_flushed) begin
                    state_n = RESUME;
                end
                for (int i = 0; i < NUM_REQS; ++i) begin
                    core_bus_out_if_core_req_valid[i] = 1'b0;
                end
                for (int i = 0; i < NUM_REQS; ++i) begin
                    core_bus_in_if_core_req_ready[i]  = 1'b0;
                end
                bank_ctr_n = 'd0;
                flush_banks_done_n = flush_banks_done | flush_banks_complete;
            end
            RESUME: begin
                if (flush_pass) begin
                    state_n = RUN;
                end
            end
        endcase
    end
    always @(posedge clk) begin
        if (reset) begin
            state <= RUN;
            flush_banks_done <= 'd0;
            bank_ctr <= 'd0;
        end else begin
            state <= state_n;
            flush_banks_done <= flush_banks_done_n;
            bank_ctr <= bank_ctr_n;
        end
    end


endmodule
