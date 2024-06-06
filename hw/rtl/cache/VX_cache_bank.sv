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

module VX_cache_bank #(
    parameter `STRING INSTANCE_ID= "",
    parameter BANK_ID           = 0,

    // Number of Word requests per cycle
    parameter NUM_REQS          = 1, 

    // Size of cache in bytes
    parameter CACHE_SIZE        = 1024, 
    // Size of line inside a bank in bytes
    parameter LINE_SIZE         = 16, 
    // Number of banks
    parameter NUM_BANKS         = 1,
    // Number of associative ways 
    parameter NUM_WAYS          = 1, 
    // Size of a word in bytes
    parameter WORD_SIZE         = 4, 

    // Core Response Queue Size
    parameter CRSQ_SIZE         = 1,
    // Miss Reserv Queue Knob
    parameter MSHR_SIZE         = 1, 
    // Memory Request Queue Size
    parameter MREQ_SIZE         = 1,

    // Enable cache writeable
    parameter WRITE_ENABLE      = 1,

    // Enable cache writeback
    parameter WRITEBACK         = 0,

    // Request debug identifier
    parameter UUID_WIDTH        = 0,

    // core request tag size
    parameter TAG_WIDTH         = UUID_WIDTH + 1,

    // Core response output buffer
    parameter CORE_OUT_BUF      = 0,

    // Memory request output buffer
    parameter MEM_OUT_BUF       = 0,

    parameter MSHR_ADDR_WIDTH   = `LOG2UP(MSHR_SIZE),
    parameter REQ_SEL_WIDTH     = `UP(`CS_REQ_SEL_BITS),
    parameter WORD_SEL_WIDTH    = `UP(`CS_WORD_SEL_BITS)
) (
    input wire clk,
    input wire reset,

`ifdef PERF_ENABLE
    output wire perf_read_misses,
    output wire perf_write_misses,
    output wire perf_mshr_stalls,
`endif

    // Core Request    
    input wire                          core_req_valid,
    input wire [`CS_LINE_ADDR_WIDTH-1:0] core_req_addr,
    input wire                          core_req_rw, 
    input wire [WORD_SEL_WIDTH-1:0]     core_req_wsel, // select the word in a cacheline, e.g. word size = 4 bytes, cacheline size = 64 bytes, it should have log(64/4)= 4 bits
    input wire [WORD_SIZE-1:0]          core_req_byteen, // each bit represents if you should write a byte (like write enable)
    input wire [`CS_WORD_WIDTH-1:0]     core_req_data, 
    input wire [TAG_WIDTH-1:0]          core_req_tag, // identifier of the request (request id)
    input wire [REQ_SEL_WIDTH-1:0]      core_req_idx, // which of the request is coming
    input wire                          core_req_flush,
    output wire                         core_req_ready,
    
    // Core Response    
    output wire                         core_rsp_valid,
    output wire [`CS_WORD_WIDTH-1:0]    core_rsp_data,
    output wire [TAG_WIDTH-1:0]         core_rsp_tag,
    output wire [REQ_SEL_WIDTH-1:0]     core_rsp_idx,
    input  wire                         core_rsp_ready,

    // Memory request
    output wire                         mem_req_valid,
    output wire [`CS_LINE_ADDR_WIDTH-1:0] mem_req_addr,
    output wire                         mem_req_rw,
    output wire [LINE_SIZE-1:0]         mem_req_byteen,
    output wire [`CS_LINE_WIDTH-1:0]    mem_req_data,
    output wire [MSHR_ADDR_WIDTH-1:0]   mem_req_id,
    output wire                         mem_req_flush,
    input  wire                         mem_req_ready,
    
    // Memory response
    input wire                          mem_rsp_valid,
    input wire [`CS_LINE_WIDTH-1:0]     mem_rsp_data,
    input wire [MSHR_ADDR_WIDTH-1:0]    mem_rsp_id, // index of the head (first) entry in the mshr for all of the requests pending for this repond
    output wire                         mem_rsp_ready,

    output reg flush_done,

    // initialization
    input wire                          init_enable,
    input wire [`CS_LINE_SEL_BITS-1:0]  init_line_sel // choose which cacheline to initialize in this bank
);

`IGNORE_UNUSED_BEGIN
    wire [`UP(UUID_WIDTH)-1:0] req_uuid_sel, req_uuid_st0, req_uuid_st1;
`IGNORE_UNUSED_END

    wire                            crsq_stall;
    wire                            mshr_alm_full;
    wire                            mreq_alm_full;
    
    wire [`CS_LINE_ADDR_WIDTH-1:0]  mem_rsp_addr;
        
    wire                            replay_valid;
    wire [`CS_LINE_ADDR_WIDTH-1:0]  replay_addr;
    wire                            replay_rw;
    wire [WORD_SEL_WIDTH-1:0]       replay_wsel;
    wire [WORD_SIZE-1:0]            replay_byteen;
    wire [`CS_WORD_WIDTH-1:0]       replay_data;
    wire [TAG_WIDTH-1:0]            replay_tag;
    wire [REQ_SEL_WIDTH-1:0]        replay_idx;
    wire [MSHR_ADDR_WIDTH-1:0]      replay_id;
    wire                            replay_ready;
    
    wire [`CS_LINE_ADDR_WIDTH-1:0]  addr_sel, addr_st0, addr_st1;
    wire                            rw_st0, rw_st1;
    wire [WORD_SEL_WIDTH-1:0]       wsel_st0, wsel_st1;
    wire [WORD_SIZE-1:0]            byteen_st0, byteen_st1;
    wire [REQ_SEL_WIDTH-1:0]        req_idx_st0, req_idx_st1;
    wire [TAG_WIDTH-1:0]            tag_st0, tag_st1;
    wire [`CS_WORD_WIDTH-1:0]       read_data_st1;
    wire [`CS_LINE_WIDTH-1:0]       data_sel, data_st0, data_st1;
    wire [MSHR_ADDR_WIDTH-1:0]      replay_id_st0, mshr_id_st0, mshr_id_st1;
    wire                            valid_sel, valid_st0, valid_st1;
    wire                            is_init_st0;
    wire                            is_creq_st0, is_creq_st1;
    wire                            is_fill_st0, is_fill_st1;
    wire                            is_replay_st0, is_replay_st1;
    wire [MSHR_ADDR_WIDTH-1:0]      mshr_alloc_id_st0;
    wire [MSHR_ADDR_WIDTH-1:0]      mshr_tail_st0, mshr_tail_st1;
    wire                            mshr_pending_st0, mshr_pending_st1;

    wire rdw_hazard_st0;
    reg rdw_hazard_st1;

     // flush unit
    wire flush_begin;
    wire mshr_empty;
    wire init_enable2;
    wire [`CS_LINE_SEL_BITS-1:0]  init_line_sel2;
    reg [`CS_LINE_SEL_BITS-1:0] line_ctr;
    wire flush_line_enable;
    reg [NUM_WAYS-1:0] flush_way_sel_pre;
    wire mem_req_flush_pre;
    wire mem_req_flush_s0, mem_req_flush_s1;
    wire creq_grant, creq_enable;
    assign creq_grant  = ~init_enable2 && ~replay_enable && ~fill_enable;
    assign core_req_ready = creq_grant
                        && ~mreq_alm_full
                        && ~mshr_alm_full
                        && ~pipe_stall;
    reg [2:0] state;
    if (WRITEBACK) begin
        localparam INIT = 0;
        localparam RUN = 1;
        localparam WAIT_MSHR = 2;
        localparam FLUSH_LINES = 3;
        
        // reg [2:0] state, state_n;
        reg [2:0] state_n;
        reg [`CS_LINE_SEL_BITS-1:0] line_ctr_n;
        reg [NUM_WAYS-1:0] flush_way_sel_pre_n;
        assign init_enable2 = state == INIT;
        assign init_line_sel2 = line_ctr;
        // assign flush_done = state == DONE;
        assign flush_line_enable = state == FLUSH_LINES;
        assign mem_req_flush_pre = core_req_flush && ~core_req_rw && core_req_valid;
        assign flush_begin = core_req_flush && core_req_rw && core_req_valid && core_req_ready; // first_flush = core_req_flush && core_req_rw

        always @(*) begin
            state_n = state;
            line_ctr_n = line_ctr;
            flush_way_sel_pre_n = flush_way_sel_pre;
            flush_done = 1'b0;
            case (state)
                INIT: begin
                    if (line_ctr == ((2 ** `CS_LINE_SEL_BITS)-1)) begin
                        state_n = RUN;
                    end
                    if (~pipe_stall) begin
                        line_ctr_n = line_ctr + 1;
                    end
                    flush_way_sel_pre_n = 'd0;
                end
                RUN: begin
                    if (flush_begin) begin
                        state_n = WAIT_MSHR;
                    end
                    line_ctr_n = '0;
                    flush_way_sel_pre_n = 'd0;
                end
                WAIT_MSHR: begin
                    flush_way_sel_pre_n = 'd0;
                    if (mshr_empty) begin
                        state_n = FLUSH_LINES;
                        flush_way_sel_pre_n = 'd1;
                    end
                    line_ctr_n = '0;
                end
                FLUSH_LINES: begin
                    if (line_ctr == ((2 ** `CS_LINE_SEL_BITS)-1) && (flush_way_sel_pre[NUM_WAYS-1]) && ~pipe_stall) begin // disputable, pipeline depth may matter
                        state_n = RUN;
                        flush_done = 1'b1;
                    end
                    if (~pipe_stall) begin
                        if (flush_way_sel_pre[NUM_WAYS-1]) begin
                            line_ctr_n = line_ctr + 1;
                        end
                        if (flush_way_sel_pre[NUM_WAYS-1]) begin
                            flush_way_sel_pre_n = 'd1;
                        end else begin
                            flush_way_sel_pre_n = flush_way_sel_pre << 1;
                        end
                    end
                end
                default:;
            endcase
        end
        always @(posedge clk) begin
            if (reset) begin
                state <= INIT;
                line_ctr <= 'd0;
                flush_way_sel_pre <= 'd0;
            end else begin
                state <= state_n;
                line_ctr <= line_ctr_n;
                flush_way_sel_pre <= flush_way_sel_pre_n;
            end
        end
        
        `UNUSED_VAR(init_line_sel)
        `UNUSED_VAR(init_enable)
    end else begin
        assign init_enable2 = init_enable;
        assign init_line_sel2 = init_line_sel;
        `UNUSED_VAR(flush_begin)
        assign line_ctr = 'x;
        `UNUSED_VAR(line_ctr)
        assign flush_line_enable = 'x;
        `UNUSED_VAR(flush_line_enable)
        assign flush_way_sel_pre = 'x;
        `UNUSED_VAR(flush_way_sel_pre)
        `UNUSED_VAR(core_req_flush)
        assign mem_req_flush = 'x;
        assign flush_done = 'x;
        assign flush_begin = 'x;
        assign mem_req_flush_pre = 'x;
        assign mem_req_flush_s0 = 'x;
        assign mem_req_flush_s1 = 'x;
        // assign  = 'x;
        `UNUSED_VAR(mem_req_flush_pre)
        `UNUSED_VAR(mem_req_flush_s0)
        `UNUSED_VAR(mem_req_flush_s1)
        `UNUSED_VAR(mreq_flush)
        `UNUSED_VAR(state)
        assign state = 'x;
        //`UNUSED_VAR()
    end

    wire pipe_stall = crsq_stall || rdw_hazard_st1;

    // inputs arbitration:
    // mshr replay has highest priority to maximize utilization since there is no miss.
    // handle memory responses next to prevent deadlock with potential memory request from a miss.
    wire replay_grant = ~init_enable2;
    wire replay_enable = replay_grant && replay_valid; 

    wire fill_grant  = ~init_enable2 && ~replay_enable;
    wire fill_enable = fill_grant && mem_rsp_valid;
    wire core_req_fire;

    if (WRITEBACK) begin
        wire first_flush;
        assign first_flush = core_req_flush && core_req_rw;
        assign creq_enable = creq_grant && core_req_valid && ~(first_flush);
        assign core_req_fire = core_req_valid && core_req_ready && ~(first_flush);;
    end else begin
        assign creq_enable = creq_grant && core_req_valid;    
        assign core_req_fire = core_req_valid && core_req_ready;
    end

    assign replay_ready = replay_grant
                         && ~rdw_hazard_st0
                         && ~pipe_stall;

    assign mem_rsp_ready = fill_grant
                        && ~pipe_stall;


    wire init_fire     = init_enable2;
    wire replay_fire = replay_valid && replay_ready;
    wire mem_rsp_fire  = mem_rsp_valid && mem_rsp_ready;

    wire [TAG_WIDTH-1:0] mshr_creq_tag = replay_enable ? replay_tag : core_req_tag;
    
    if (UUID_WIDTH != 0) begin
        assign req_uuid_sel = mshr_creq_tag[TAG_WIDTH-1 -: UUID_WIDTH];
    end else begin
        assign req_uuid_sel = 0;
    end

    `UNUSED_VAR (mshr_creq_tag)

    if (WRITEBACK) begin
        
        assign valid_sel = init_fire || replay_fire || mem_rsp_fire || core_req_fire || flush_line_enable;

        assign addr_sel = (init_enable2) ? `CS_LINE_ADDR_WIDTH'(init_line_sel2) :
                        (flush_line_enable) ? `CS_LINE_ADDR_WIDTH'(line_ctr) :
                        (replay_valid ? replay_addr : 
                            (mem_rsp_valid ? mem_rsp_addr : core_req_addr));
    end else begin
        
        assign valid_sel = init_fire || replay_fire || mem_rsp_fire || core_req_fire;

        assign addr_sel = init_enable2 ? `CS_LINE_ADDR_WIDTH'(init_line_sel2) :
                        (replay_valid ? replay_addr : 
                            (mem_rsp_valid ? mem_rsp_addr : core_req_addr));
    end

    assign data_sel[`CS_WORD_WIDTH-1:0] = (mem_rsp_valid || !WRITE_ENABLE) ? mem_rsp_data[`CS_WORD_WIDTH-1:0] : (replay_valid ? replay_data : core_req_data);
    for (genvar i = `CS_WORD_WIDTH; i < `CS_LINE_WIDTH; ++i) begin
        assign data_sel[i] = mem_rsp_data[i];
    end

    wire flush_line_s0;
    wire [NUM_WAYS-1:0] flush_way_sel_s0;
    if (WRITEBACK) begin
        VX_pipe_register #(
            .DATAW  (1 + 1 + 1 + 1 + 1 + `CS_LINE_ADDR_WIDTH + `CS_LINE_WIDTH + 1 + WORD_SIZE + WORD_SEL_WIDTH + REQ_SEL_WIDTH + TAG_WIDTH + MSHR_ADDR_WIDTH + 1 + NUM_WAYS + 1),
            .RESETW (1)
        ) pipe_reg0 (
            .clk      (clk),
            .reset    (reset),
            .enable   (~pipe_stall),
            .data_in  ({
                valid_sel,
                init_enable2,
                replay_enable,
                fill_enable,
                creq_enable,
                addr_sel,
                data_sel,
                replay_valid ? replay_rw : core_req_rw,
                replay_valid ? replay_byteen : core_req_byteen,
                replay_valid ? replay_wsel : core_req_wsel, 
                replay_valid ? replay_idx : core_req_idx,
                replay_valid ? replay_tag : core_req_tag,
                replay_id,
                flush_line_enable,
                flush_way_sel_pre,
                mem_req_flush_pre
            }),
            .data_out ({valid_st0, is_init_st0, is_replay_st0, is_fill_st0, is_creq_st0, addr_st0, data_st0, rw_st0, byteen_st0, wsel_st0, req_idx_st0, tag_st0, replay_id_st0, flush_line_s0, flush_way_sel_s0, mem_req_flush_s0})
        );
    end else begin
         VX_pipe_register #(
            .DATAW  (1 + 1 + 1 + 1 + 1 + `CS_LINE_ADDR_WIDTH + `CS_LINE_WIDTH + 1 + WORD_SIZE + WORD_SEL_WIDTH + REQ_SEL_WIDTH + TAG_WIDTH + MSHR_ADDR_WIDTH),
            .RESETW (1)
        ) pipe_reg0 (
            .clk      (clk),
            .reset    (reset),
            .enable   (~pipe_stall),
            .data_in  ({
                valid_sel,
                init_enable,
                replay_enable,
                fill_enable,
                creq_enable,
                addr_sel,
                data_sel,
                replay_valid ? replay_rw : core_req_rw,
                replay_valid ? replay_byteen : core_req_byteen,
                replay_valid ? replay_wsel : core_req_wsel, 
                replay_valid ? replay_idx : core_req_idx,
                replay_valid ? replay_tag : core_req_tag,
                replay_id
            }),
            .data_out ({valid_st0, is_init_st0, is_replay_st0, is_fill_st0, is_creq_st0, addr_st0, data_st0, rw_st0, byteen_st0, wsel_st0, req_idx_st0, tag_st0, replay_id_st0})
        );
        assign flush_line_s0 = 'x;
        `UNUSED_VAR(flush_line_s0)
        assign flush_way_sel_s0 = 'x;
        `UNUSED_VAR(flush_way_sel_s0)
        // assign  = 'x;
        // `UNUSED_VAR()
        //`UNUSED_VAR()

    end
    

    if (UUID_WIDTH != 0) begin
        assign req_uuid_st0 = tag_st0[TAG_WIDTH-1 -: UUID_WIDTH];
    end else begin
        assign req_uuid_st0 = 0;
    end

    wire do_creq_rd_st0 = valid_st0 && is_creq_st0 && ~rw_st0;
    wire do_fill_st0    = valid_st0 && is_fill_st0;
    wire do_init_st0    = valid_st0 && is_init_st0;
    wire do_lookup_st0  = valid_st0 && ~(is_fill_st0 || is_init_st0);
    `IGNORE_WARNINGS_BEGIN
    // wire do_replay_wr_st0, do_creq_wr_st0;
    // `IGNORE_WARNINGS_END
    // if (WRITEBACK) begin
    //     assign do_replay_wr_st0 = valid_st0 && is_replay_st0 && rw_st0;
    //     assign do_creq_wr_st0   = valid_st0 && is_creq_st0 && rw_st0;
    // end

    wire [`CS_WORD_WIDTH-1:0] write_data_st0 = data_st0[`CS_WORD_WIDTH-1:0];

    wire [NUM_WAYS-1:0] tag_matches_st0, tag_matches_st1;
    wire [NUM_WAYS-1:0] way_sel_st0, way_sel_st1;
    wire eviction_s0, eviction_s1;
    wire [`CS_TAG_SEL_BITS-1:0] evicted_tag_s0, evicted_tag_s1;

    `RESET_RELAY (tag_reset, reset);

    VX_cache_tags #(
        .INSTANCE_ID(INSTANCE_ID),
        .BANK_ID    (BANK_ID), 
        .CACHE_SIZE (CACHE_SIZE),
        .LINE_SIZE  (LINE_SIZE),
        .NUM_BANKS  (NUM_BANKS),
        .NUM_WAYS   (NUM_WAYS),
        .WORD_SIZE  (WORD_SIZE), 
        .UUID_WIDTH (UUID_WIDTH),
        .WRITEBACK(WRITEBACK)
    ) cache_tags (
        .clk        (clk),
        .reset      (tag_reset),

        .req_uuid   (req_uuid_st0),
        
        .stall      (pipe_stall),

        // read/Fill
        .lookup     (do_lookup_st0),
        .line_addr  (addr_st0),
        .fill       (do_fill_st0),
        .init       (do_init_st0),
        .way_sel    (way_sel_st0),
        .tag_matches(tag_matches_st0),
        .eviction   (eviction_s0),
        .evicted_tag(evicted_tag_s0),
        .replay     (is_replay_st0),
        .creq       (is_creq_st0),
        .rw         (rw_st0),
        .flush_line (flush_line_s0),
        .flush_way_sel (flush_way_sel_s0)
    );

    assign mshr_id_st0 = is_creq_st0 ? mshr_alloc_id_st0 : replay_id_st0;

    if (WRITEBACK) begin
        VX_pipe_register #(
            .DATAW  (1 + 1 + 1 + 1 + 1 + `CS_LINE_ADDR_WIDTH + `CS_LINE_WIDTH + WORD_SIZE + WORD_SEL_WIDTH + REQ_SEL_WIDTH + TAG_WIDTH + MSHR_ADDR_WIDTH + MSHR_ADDR_WIDTH + NUM_WAYS + NUM_WAYS + 1 + 1 + `CS_TAG_SEL_BITS + 1),
            .RESETW (1)
        ) pipe_reg1 (
            .clk      (clk),
            .reset    (reset),
            .enable   (~pipe_stall),
            .data_in  ({valid_st0, is_replay_st0, is_fill_st0, is_creq_st0, rw_st0, addr_st0, data_st0, byteen_st0, wsel_st0, req_idx_st0, tag_st0, mshr_id_st0, mshr_tail_st0, tag_matches_st0, way_sel_st0, mshr_pending_st0, eviction_s0, evicted_tag_s0, mem_req_flush_s0}),
            .data_out ({valid_st1, is_replay_st1, is_fill_st1, is_creq_st1, rw_st1, addr_st1, data_st1, byteen_st1, wsel_st1, req_idx_st1, tag_st1, mshr_id_st1, mshr_tail_st1, tag_matches_st1, way_sel_st1, mshr_pending_st1, eviction_s1, evicted_tag_s1, mem_req_flush_s1})
        );
    end else begin
        VX_pipe_register #(
        .DATAW  (1 + 1 + 1 + 1 + 1 + `CS_LINE_ADDR_WIDTH + `CS_LINE_WIDTH + WORD_SIZE + WORD_SEL_WIDTH + REQ_SEL_WIDTH + TAG_WIDTH + MSHR_ADDR_WIDTH + MSHR_ADDR_WIDTH + NUM_WAYS + NUM_WAYS + 1),
        .RESETW (1)
        ) pipe_reg1 (
            .clk      (clk),
            .reset    (reset),
            .enable   (~pipe_stall),
            .data_in  ({valid_st0, is_replay_st0, is_fill_st0, is_creq_st0, rw_st0, addr_st0, data_st0, byteen_st0, wsel_st0, req_idx_st0, tag_st0, mshr_id_st0, mshr_tail_st0, tag_matches_st0, way_sel_st0, mshr_pending_st0}),
            .data_out ({valid_st1, is_replay_st1, is_fill_st1, is_creq_st1, rw_st1, addr_st1, data_st1, byteen_st1, wsel_st1, req_idx_st1, tag_st1, mshr_id_st1, mshr_tail_st1, tag_matches_st1, way_sel_st1, mshr_pending_st1})
        );

    end

    // we have a tag hit
    wire is_hit_st1 = (| tag_matches_st1);

    if (UUID_WIDTH != 0) begin
        assign req_uuid_st1 = tag_st1[TAG_WIDTH-1 -: UUID_WIDTH];
    end else begin
        assign req_uuid_st1 = 0;
    end

    wire do_creq_rd_st1   = valid_st1 && is_creq_st1 && ~rw_st1;
    wire do_creq_wr_st1   = valid_st1 && is_creq_st1 && rw_st1;
    wire do_fill_st1      = valid_st1 && is_fill_st1;
    wire do_replay_rd_st1 = valid_st1 && is_replay_st1 && ~rw_st1;
    wire do_replay_wr_st1 = valid_st1 && is_replay_st1 && rw_st1;

    wire do_read_hit_st1  = do_creq_rd_st1 && is_hit_st1;
    wire do_read_miss_st1 = do_creq_rd_st1 && ~is_hit_st1;

    wire do_write_hit_st1 = do_creq_wr_st1 && is_hit_st1;
    wire do_write_miss_st1= do_creq_wr_st1 && ~is_hit_st1;

    wire [LINE_SIZE-1:0] line_byteen_st1;

    `UNUSED_VAR (do_write_miss_st1)

    // ensure mshr replay always get a hit
    `RUNTIME_ASSERT (~(valid_st1 && is_replay_st1) || is_hit_st1, ("runtime error: invalid mshr replay"));

    // detect BRAM's read-during-write hazard
    assign rdw_hazard_st0 = do_fill_st0; // after a fill
    wire do_replay_rd_st0;
    if (WRITEBACK) begin
        
        assign do_replay_rd_st0 = valid_st0 && is_replay_st0 && ~rw_st0;
        always @(posedge clk) begin
            rdw_hazard_st1 <= ((do_creq_rd_st0 || do_replay_rd_st0)
                            && (do_write_hit_st1 || do_replay_wr_st1) 
                            && (addr_st0 == addr_st1))
                            && ~rdw_hazard_st1; // after a write to same address
        end
    end else begin
        
        always @(posedge clk) begin
            rdw_hazard_st1 <= (do_creq_rd_st0 && do_write_hit_st1 && (addr_st0 == addr_st1))
                        && ~rdw_hazard_st1; // after a write to same address
        end
        `UNUSED_VAR(do_replay_rd_st0)
        assign do_replay_rd_st0 = 'x;
    end

    wire [`CS_WORD_WIDTH-1:0] write_data_st1 = data_st1[`CS_WORD_WIDTH-1:0];
    wire [`CS_LINE_WIDTH-1:0] fill_data_st1 = data_st1;

    wire [`CS_LINE_WIDTH-1:0] evicted_data_s1;

    `RESET_RELAY (data_reset, reset);
 
    VX_cache_data #(
        .INSTANCE_ID  (INSTANCE_ID),
        .BANK_ID      (BANK_ID), 
        .CACHE_SIZE   (CACHE_SIZE),
        .LINE_SIZE    (LINE_SIZE),
        .NUM_BANKS    (NUM_BANKS),
        .NUM_WAYS     (NUM_WAYS),
        .WORD_SIZE    (WORD_SIZE),
        .WRITE_ENABLE (WRITE_ENABLE),
        .UUID_WIDTH   (UUID_WIDTH),
        .WRITEBACK    (WRITEBACK)
    ) cache_data (
        .clk        (clk),
        .reset      (data_reset),

        .req_uuid   (req_uuid_st1),

        .stall      (pipe_stall),

        .read       (do_read_hit_st1 || do_replay_rd_st1), 
        .fill       (do_fill_st1), 
        .write      (do_write_hit_st1 || do_replay_wr_st1),
        .way_sel    (way_sel_st1 | tag_matches_st1),
        .line_addr  (addr_st1),
        .wsel       (wsel_st1),
        .byteen     (byteen_st1),
        .fill_data  (fill_data_st1), 
        .write_data (write_data_st1),
        .read_data  (read_data_st1),
        .write_byteen(line_byteen_st1),
        .evicted_data(evicted_data_s1)
    );
    
    wire [MSHR_SIZE-1:0] mshr_matches_st0;
    wire mshr_allocate_st0 = valid_st0 && is_creq_st0 && ~pipe_stall;
    wire mshr_lookup_st0   = mshr_allocate_st0;
    wire mshr_finalize_st1 = valid_st1 && is_creq_st1 && ~pipe_stall;
    wire mshr_release_st1;
    if (WRITEBACK) begin
        assign mshr_release_st1  = is_hit_st1;
    end else begin
        assign mshr_release_st1  = is_hit_st1 || (rw_st1 && ~mshr_pending_st1); // For writemiss, if there is no entry for this cacheline in MSHR, we do not allocate the entry
    end

    VX_pending_size #( 
        .SIZE (MSHR_SIZE)
    ) mshr_pending_size (
        .clk   (clk),
        .reset (reset),
        .incr  (core_req_fire),
        .decr  (replay_fire || (mshr_finalize_st1 && mshr_release_st1)),
        .full  (mshr_alm_full),
        `UNUSED_PIN (size),
        .empty (mshr_empty)
    );

    if (!WRITEBACK) begin
        `UNUSED_VAR (mshr_empty)
    end

    `RESET_RELAY (mshr_reset, reset);

    VX_cache_mshr #(
        .INSTANCE_ID (INSTANCE_ID),
        .BANK_ID     (BANK_ID), 
        .LINE_SIZE   (LINE_SIZE),
        .NUM_BANKS   (NUM_BANKS),
        .MSHR_SIZE   (MSHR_SIZE),
        .UUID_WIDTH  (UUID_WIDTH),
        .DATA_WIDTH  (WORD_SEL_WIDTH + WORD_SIZE + `CS_WORD_WIDTH + TAG_WIDTH + REQ_SEL_WIDTH),
        .WRITEBACK(WRITEBACK)
    ) cache_mshr (
        .clk            (clk),
        .reset          (mshr_reset),

        .deq_req_uuid   (req_uuid_sel),
        .lkp_req_uuid   (req_uuid_st0),
        .fin_req_uuid   (req_uuid_st1),

        // memory fill
        .fill_valid     (mem_rsp_fire),
        .fill_id        (mem_rsp_id),
        .fill_addr      (mem_rsp_addr),

        // dequeue
        .dequeue_valid  (replay_valid),
        .dequeue_addr   (replay_addr),
        .dequeue_rw     (replay_rw),        
        .dequeue_data   ({replay_wsel, replay_byteen, replay_data, replay_tag, replay_idx}),
        .dequeue_id     (replay_id),
        .dequeue_ready  (replay_ready),

        // allocate
        .allocate_valid (mshr_allocate_st0),
        .allocate_addr  (addr_st0),
        .allocate_rw    (rw_st0),
        .allocate_data  ({wsel_st0, byteen_st0, write_data_st0, tag_st0, req_idx_st0}),
        .allocate_id    (mshr_alloc_id_st0),
        .allocate_tail  (mshr_tail_st0),
        `UNUSED_PIN     (allocate_ready),

        // lookup
        .lookup_valid   (mshr_lookup_st0),
        .lookup_addr    (addr_st0),
        .lookup_matches (mshr_matches_st0),

        // finalize
        .finalize_valid (mshr_finalize_st1),
        .finalize_release(mshr_release_st1),
        .finalize_pending(mshr_pending_st1),
        .finalize_id    (mshr_id_st1),
        .finalize_tail  (mshr_tail_st1)
    );

    // ignore allocated id from mshr matches
    wire [MSHR_SIZE-1:0] lookup_matches;
    for (genvar i = 0; i < MSHR_SIZE; ++i) begin
        assign lookup_matches[i] = (i != mshr_alloc_id_st0) && mshr_matches_st0[i];
    end
    assign mshr_pending_st0 = (| lookup_matches);

    // schedule core response
    
    wire crsq_valid, crsq_ready;
    wire [`CS_WORD_WIDTH-1:0] crsq_data;
    wire [REQ_SEL_WIDTH-1:0] crsq_idx;
    wire [TAG_WIDTH-1:0] crsq_tag;

    assign crsq_valid = do_read_hit_st1 || do_replay_rd_st1;
    assign crsq_idx   = req_idx_st1;
    assign crsq_data  = read_data_st1;
    assign crsq_tag   = tag_st1;

    `RESET_RELAY (crsp_reset, reset);

    VX_elastic_buffer #(
        .DATAW   (TAG_WIDTH + `CS_WORD_WIDTH + REQ_SEL_WIDTH),
        .SIZE    (CRSQ_SIZE),
        .OUT_REG (`TO_OUT_BUF_REG(CORE_OUT_BUF))
    ) core_rsp_queue (
        .clk       (clk),
        .reset     (crsp_reset),
        .valid_in  (crsq_valid && ~rdw_hazard_st1),
        .ready_in  (crsq_ready),
        .data_in   ({crsq_tag, crsq_data, crsq_idx}), 
        .data_out  ({core_rsp_tag, core_rsp_data, core_rsp_idx}),
        .valid_out (core_rsp_valid),
        .ready_out (core_rsp_ready)
    );

    assign crsq_stall = crsq_valid && ~crsq_ready;

    // schedule memory request

    wire mreq_push, mreq_pop, mreq_empty;
    wire [`CS_LINE_WIDTH-1:0] mreq_data;
    wire [LINE_SIZE-1:0] mreq_byteen;
    wire [`CS_LINE_ADDR_WIDTH-1:0] mreq_addr;
    wire [MSHR_ADDR_WIDTH-1:0] mreq_id;
    wire mreq_rw;
    wire [`CS_LINE_ADDR_WIDTH-1:0] evicted_addr_s1 = {evicted_tag_s1, addr_st1[`CS_LINE_SEL_BITS-1:0]};
    wire mreq_flush;
    if (WRITEBACK) begin
        assign mreq_push = ((do_read_miss_st1 || do_write_miss_st1) && ~mshr_pending_st1) || (eviction_s1); // lookup matches are only for read, not for write. There can be write match but mshr_pending_st1 is not set
        assign mreq_rw   = WRITE_ENABLE && eviction_s1;
        assign mreq_addr = eviction_s1 ? evicted_addr_s1 : addr_st1;
        assign mreq_data = evicted_data_s1; // read_data_st1 is the data evicted data when an eviction happens
        assign mreq_flush = mem_req_flush_s1;
    end else begin
        assign mreq_push = (do_read_miss_st1 && ~mshr_pending_st1) || do_creq_wr_st1;
        assign mreq_rw   = WRITE_ENABLE && rw_st1;
        assign mreq_addr = addr_st1;
        assign mreq_data = {`CS_WORDS_PER_LINE{write_data_st1}};
        `UNUSED_VAR (eviction_s1)
        `UNUSED_VAR (evicted_data_s1)
        `UNUSED_VAR (evicted_addr_s1)
    end
    assign mreq_pop = mem_req_valid && mem_req_ready;
    assign mreq_id   = mshr_id_st1;
    assign mreq_byteen = line_byteen_st1;


    `RESET_RELAY (mreq_reset, reset);

    if (WRITEBACK) begin
        VX_fifo_queue #(
            .DATAW    (1 + `CS_LINE_ADDR_WIDTH + MSHR_ADDR_WIDTH + LINE_SIZE + `CS_LINE_WIDTH + 1), 
            .DEPTH    (MREQ_SIZE),
            .ALM_FULL (MREQ_SIZE-2),
            .OUT_REG  (`TO_OUT_BUF_REG(MEM_OUT_BUF))
        ) mem_req_queue (
            .clk        (clk),
            .reset      (mreq_reset),
            .push       (mreq_push),
            .pop        (mreq_pop),
            .data_in    ({mreq_rw, mreq_addr, mreq_id, mreq_byteen, mreq_data, mreq_flush}),
            .data_out   ({mem_req_rw, mem_req_addr, mem_req_id, mem_req_byteen, mem_req_data, mem_req_flush}),
            .empty      (mreq_empty), 
            .alm_full   (mreq_alm_full),
            `UNUSED_PIN (full),
            `UNUSED_PIN (alm_empty), 
            `UNUSED_PIN (size)
        );
    end else begin
        VX_fifo_queue #(
            .DATAW    (1 + `CS_LINE_ADDR_WIDTH + MSHR_ADDR_WIDTH + LINE_SIZE + `CS_LINE_WIDTH), 
            .DEPTH    (MREQ_SIZE),
            .ALM_FULL (MREQ_SIZE-2),
            .OUT_REG  (`TO_OUT_BUF_REG(MEM_OUT_BUF))
        ) mem_req_queue (
            .clk        (clk),
            .reset      (mreq_reset),
            .push       (mreq_push),
            .pop        (mreq_pop),
            .data_in    ({mreq_rw, mreq_addr, mreq_id, mreq_byteen, mreq_data}),
            .data_out   ({mem_req_rw, mem_req_addr, mem_req_id, mem_req_byteen, mem_req_data}),
            .empty      (mreq_empty), 
            .alm_full   (mreq_alm_full),
            `UNUSED_PIN (full),
            `UNUSED_PIN (alm_empty), 
            `UNUSED_PIN (size)
        );
    end

    

    assign mem_req_valid = ~mreq_empty;

///////////////////////////////////////////////////////////////////////////////

`ifdef PERF_ENABLE
    assign perf_read_misses  = do_read_miss_st1;
    assign perf_write_misses = do_write_miss_st1;
    assign perf_mshr_stalls  = mshr_alm_full;
`endif

`ifdef DBG_TRACE_CACHE
    wire crsq_fire = crsq_valid && crsq_ready;
    wire pipeline_stall = (replay_valid || mem_rsp_valid || core_req_valid) 
                       && ~(replay_fire || mem_rsp_fire || core_req_fire);
    always @(posedge clk) begin
        if (pipeline_stall) begin
            `TRACE(3, ("%d: *** %s-bank%0d stall: crsq=%b, mreq=%b, mshr=%b\n", $time, INSTANCE_ID, BANK_ID, crsq_stall, mreq_alm_full, mshr_alm_full));
        end
        if (init_enable2) begin
            `TRACE(2, ("%d: %s-bank%0d init: addr=0x%0h\n", $time, INSTANCE_ID, BANK_ID, `CS_LINE_TO_FULL_ADDR(init_line_sel2, BANK_ID)));
        end
        if (mem_rsp_fire) begin
            `TRACE(2, ("%d: %s-bank%0d fill-rsp: addr=0x%0h, mshr_id=%0d, data=0x%0h\n", $time, INSTANCE_ID, BANK_ID, `CS_LINE_TO_FULL_ADDR(mem_rsp_addr, BANK_ID), mem_rsp_id, mem_rsp_data));
        end
        if (replay_fire) begin
            `TRACE(2, ("%d: %s-bank%0d mshr-pop: addr=0x%0h, tag=0x%0h, req_idx=%0d (#%0d)\n", $time, INSTANCE_ID, BANK_ID, `CS_LINE_TO_FULL_ADDR(replay_addr, BANK_ID), replay_tag, replay_idx, req_uuid_sel));
        end
        if (core_req_fire) begin
            if (core_req_rw)
                `TRACE(2, ("%d: %s-bank%0d core-wr-req: addr=0x%0h, tag=0x%0h, req_idx=%0d, byteen=%b, data=0x%0h (#%0d)\n", $time, INSTANCE_ID, BANK_ID, `CS_LINE_TO_FULL_ADDR(core_req_addr, BANK_ID), core_req_tag, core_req_idx, core_req_byteen, core_req_data, req_uuid_sel));
            else
                `TRACE(2, ("%d: %s-bank%0d core-rd-req: addr=0x%0h, tag=0x%0h, req_idx=%0d (#%0d)\n", $time, INSTANCE_ID, BANK_ID, `CS_LINE_TO_FULL_ADDR(core_req_addr, BANK_ID), core_req_tag, core_req_idx, req_uuid_sel));
        end
        if (crsq_fire) begin
            `TRACE(2, ("%d: %s-bank%0d core-rd-rsp: addr=0x%0h, tag=0x%0h, req_idx=%0d, data=0x%0h (#%0d)\n", $time, INSTANCE_ID, BANK_ID, `CS_LINE_TO_FULL_ADDR(addr_st1, BANK_ID), crsq_tag, crsq_idx, crsq_data, req_uuid_st1));
        end
        if (mreq_push) begin
            if (do_creq_wr_st1)
                `TRACE(2, ("%d: %s-bank%0d writethrough: addr=0x%0h, byteen=%b, data=0x%0h (#%0d)\n", $time, INSTANCE_ID, BANK_ID, `CS_LINE_TO_FULL_ADDR(mreq_addr, BANK_ID), mreq_byteen, mreq_data, req_uuid_st1));
            else
                `TRACE(2, ("%d: %s-bank%0d fill-req: addr=0x%0h, mshr_id=%0d (#%0d)\n", $time, INSTANCE_ID, BANK_ID, `CS_LINE_TO_FULL_ADDR(mreq_addr, BANK_ID), mreq_id, req_uuid_st1));
        end
        if (eviction_s1) begin
            `TRACE(3, ("%d: *** %s-bank%0d evicted_address=0x%0h evicted_data=0x%0h  evicted_byteen=%b Yi-Lin Tsai\n", $time, INSTANCE_ID, BANK_ID, evicted_addr_s1, evicted_data_s1, line_byteen_st1));
        end
    end    
`endif

endmodule
