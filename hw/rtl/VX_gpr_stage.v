`include "VX_define.vh"

module VX_gpr_stage (
    input wire              clk,
    input wire              reset,
    input wire              schedule_delay,

    input  wire             memory_delay,
    input  wire             exec_delay,
    input  wire             stall_gpr_csr,
    output wire             delay,

    // decodee inputs
    VX_backend_req_if       bckE_req_if,

    // WriteBack inputs
    VX_wb_if                writeback_if,

    // Outputs
    VX_exec_unit_req_if     exec_unit_req_if,
    VX_lsu_req_if           lsu_req_if,
    VX_gpu_inst_req_if      gpu_inst_req_if,
    VX_csr_req_if           csr_req_if
);
`DEBUG_BEGIN
    wire[31:0] curr_PC   = bckE_req_if.curr_PC;
    wire[2:0] branchType = bckE_req_if.branch_type;
    wire is_store        = (bckE_req_if.mem_write != `BYTE_EN_NO);
    wire is_load         = (bckE_req_if.mem_read  != `BYTE_EN_NO);
    wire is_jal          = bckE_req_if.is_jal;
`DEBUG_END

    assign csr_req_if.is_io = 1'b0; // GPR only issues csr requests coming from core

    VX_gpr_read_if gpr_read_if();
    assign gpr_read_if.rs1      = bckE_req_if.rs1;
    assign gpr_read_if.rs2      = bckE_req_if.rs2;
    assign gpr_read_if.warp_num = bckE_req_if.warp_num;

`ifndef ASIC
    assign gpr_read_if.is_jal  = bckE_req_if.is_jal;
    assign gpr_read_if.curr_PC = bckE_req_if.curr_PC;
`else 
    assign gpr_read_if.is_jal  = exec_unit_req_if.is_jal;
    assign gpr_read_if.curr_PC = exec_unit_req_if.curr_PC;
`endif

    VX_gpr_wrapper grp_wrapper (
        .clk            (clk),
        .reset          (reset),
        .writeback_if   (writeback_if),
        .gpr_read_if    (gpr_read_if)
    );

    // Outputs
    VX_exec_unit_req_if   exec_unit_req_temp_if();
    VX_lsu_req_if         lsu_req_temp_if();
    VX_gpu_inst_req_if    gpu_inst_req_temp_if();
    VX_csr_req_if         csr_req_temp_if();

    VX_inst_multiplex inst_mult(
        .bckE_req_if       (bckE_req_if),
        .gpr_read_if       (gpr_read_if),
        .exec_unit_req_if  (exec_unit_req_temp_if),
        .lsu_req_if        (lsu_req_temp_if),
        .gpu_inst_req_if   (gpu_inst_req_temp_if),
        .csr_req_if        (csr_req_temp_if)
    );

`DEBUG_BEGIN
    wire is_lsu = (| lsu_req_temp_if.valid);
`DEBUG_END
    wire stall_rest = 0;
    wire flush_rest = schedule_delay;

    wire stall_lsu  = memory_delay;
    wire flush_lsu  = schedule_delay && !stall_lsu;

    wire stall_exec  = exec_delay;
    wire flush_exec  = schedule_delay && !stall_exec;

    wire stall_csr = stall_gpr_csr && bckE_req_if.is_csr && (| bckE_req_if.valid);

    assign delay = stall_lsu || stall_exec || stall_csr;

`ifdef ASIC
        wire delayed_lsu_last_cycle;

        VX_generic_register #(
            .N(1)
        ) delayed_reg (
            .clk   (clk),
            .reset (reset),
            .stall (stall_rest),
            .flush (stall_rest),
            .in    (stall_lsu),
            .out   (delayed_lsu_last_cycle),
            `UNUSED_PIN (size)
        );

        wire [`NUM_THREADS-1:0][31:0] temp_store_data;
        wire [`NUM_THREADS-1:0][31:0] temp_base_addr; // A reg data

        wire [`NUM_THREADS-1:0][31:0] real_store_data;
        wire [`NUM_THREADS-1:0][31:0] real_base_addr; // A reg data

        wire store_curr_real = !delayed_lsu_last_cycle && stall_lsu;

        VX_generic_register #(
            .N(`NUM_THREADS*32*2)
        ) lsu_data (
            .clk   (clk),
            .reset (reset),
            .stall (!store_curr_real),
            .flush (stall_rest),
            .in    ({real_store_data, real_base_addr}),
            .out   ({temp_store_data, temp_base_addr})
        );

        assign real_store_data = lsu_req_temp_if.store_data;
        assign real_base_addr  = lsu_req_temp_if.base_addr;

        assign lsu_req_if.store_data = (delayed_lsu_last_cycle) ? temp_store_data   : real_store_data;
        assign lsu_req_if.base_addr  = (delayed_lsu_last_cycle) ? temp_base_addr : real_base_addr;

        VX_generic_register #(
            .N(77 + `NW_BITS-1 + 1 + (`NUM_THREADS))
        ) lsu_reg (
            .clk   (clk),
            .reset (reset),
            .stall (stall_lsu),
            .flush (flush_lsu),
            .in    ({lsu_req_temp_if.valid, lsu_req_temp_if.curr_PC, lsu_req_temp_if.warp_num, lsu_req_temp_if.offset, lsu_req_temp_if.mem_read, lsu_req_temp_if.mem_write, lsu_req_temp_if.rd, lsu_req_temp_if.wb}),
            .out   ({lsu_req_if.valid     , lsu_req_if.curr_PC     ,lsu_req_if.warp_num     , lsu_req_if.offset     , lsu_req_if.mem_read     , lsu_req_if.mem_write     , lsu_req_if.rd     , lsu_req_if.wb     })
        );

        VX_generic_register #(
            .N(224 + `NW_BITS-1 + 1 + (`NUM_THREADS))
        ) exec_unit_reg (
            .clk   (clk),
            .reset (reset),
            .stall (stall_exec),
            .flush (flush_exec),
            .in    ({exec_unit_req_temp_if.valid, exec_unit_req_temp_if.warp_num, exec_unit_req_temp_if.curr_PC, exec_unit_req_temp_if.next_PC, exec_unit_req_temp_if.rd, exec_unit_req_temp_if.wb, exec_unit_req_temp_if.alu_op, exec_unit_req_temp_if.rs1, exec_unit_req_temp_if.rs2, exec_unit_req_temp_if.rs2_src, exec_unit_req_temp_if.itype_immed, exec_unit_req_temp_if.upper_immed, exec_unit_req_temp_if.branch_type, exec_unit_req_temp_if.is_jal, exec_unit_req_temp_if.jal, exec_unit_req_temp_if.jal_offset, exec_unit_req_temp_if.is_etype, exec_unit_req_temp_if.wspawn, exec_unit_req_temp_if.is_csr, exec_unit_req_temp_if.csr_addr, exec_unit_req_temp_if.csr_immed, exec_unit_req_temp_if.csr_mask}),
            .out   ({exec_unit_req_if.valid     , exec_unit_req_if.warp_num     , exec_unit_req_if.curr_PC     , exec_unit_req_if.next_PC     , exec_unit_req_if.rd     , exec_unit_req_if.wb     , exec_unit_req_if.alu_op     , exec_unit_req_if.rs1     , exec_unit_req_if.rs2     , exec_unit_req_if.rs2_src     , exec_unit_req_if.itype_immed     , exec_unit_req_if.upper_immed     , exec_unit_req_if.branch_type     , exec_unit_req_if.is_jal     , exec_unit_req_if.jal     , exec_unit_req_if.jal_offset     , exec_unit_req_if.is_etype     , exec_unit_req_if.wspawn     , exec_unit_req_if.is_csr     , exec_unit_req_if.csr_addr     , exec_unit_req_if.csr_immed     , exec_unit_req_if.csr_mask     })
        );

        assign exec_unit_req_if.a_reg_data = real_base_addr;
        assign exec_unit_req_if.b_reg_data = real_store_data;

        VX_generic_register #(
            .N(36 + `NW_BITS-1 + 1 + (`NUM_THREADS))
        ) gpu_inst_reg (
            .clk   (clk),
            .reset (reset),
            .stall (stall_rest),
            .flush (flush_rest),
            .in    ({gpu_inst_req_temp_if.valid, gpu_inst_req_temp_if.warp_num, gpu_inst_req_temp_if.is_wspawn, gpu_inst_req_temp_if.is_tmc, gpu_inst_req_temp_if.is_split, gpu_inst_req_temp_if.is_barrier, gpu_inst_req_temp_if.next_PC}),
            .out   ({gpu_inst_req_if.valid     , gpu_inst_req_if.warp_num     , gpu_inst_req_if.is_wspawn     , gpu_inst_req_if.is_tmc     , gpu_inst_req_if.is_split     , gpu_inst_req_if.is_barrier     , gpu_inst_req_if.next_PC     })
        );

        assign gpu_inst_req_if.a_reg_data = real_base_addr;
        assign gpu_inst_req_if.rd2        = real_store_data;

        VX_generic_register #(
            .N(`NW_BITS-1  + 1 + `NUM_THREADS + 58)
        ) csr_reg (
            .clk   (clk),
            .reset (reset),
            .stall (stall_gpr_csr),
            .flush (flush_rest),
            .in    ({csr_req_temp_if.valid, csr_req_temp_if.warp_num, csr_req_temp_if.rd, csr_req_temp_if.wb, csr_req_temp_if.alu_op, csr_req_temp_if.is_csr, csr_req_temp_if.csr_addr, csr_req_temp_if.csr_immed, csr_req_temp_if.csr_mask}),
            .out   ({csr_req_if.valid     , csr_req_if.warp_num     , csr_req_if.rd     , csr_req_if.wb     , csr_req_if.alu_op     , csr_req_if.is_csr     , csr_req_if.csr_addr     , csr_req_if.csr_immed     , csr_req_if.csr_mask     })
        );


`else 

    // 341 
    VX_generic_register #(
        .N(77 + `NW_BITS-1 + 1 + 65*(`NUM_THREADS))
    ) lsu_reg (
        .clk   (clk),
        .reset (reset),
        .stall (stall_lsu),
        .flush (flush_lsu),
        .in    ({lsu_req_temp_if.valid, lsu_req_temp_if.curr_PC, lsu_req_temp_if.warp_num, lsu_req_temp_if.store_data, lsu_req_temp_if.base_addr, lsu_req_temp_if.offset, lsu_req_temp_if.mem_read, lsu_req_temp_if.mem_write, lsu_req_temp_if.rd, lsu_req_temp_if.wb}),
        .out   ({lsu_req_if.valid     , lsu_req_if.curr_PC     , lsu_req_if.warp_num     , lsu_req_if.store_data     , lsu_req_if.base_addr     , lsu_req_if.offset     , lsu_req_if.mem_read     , lsu_req_if.mem_write     , lsu_req_if.rd     , lsu_req_if.wb     })
    );

    VX_generic_register #(
        .N(224 + `NW_BITS-1 + 1 + 65*(`NUM_THREADS))
    ) exec_unit_reg (
        .clk   (clk),
        .reset (reset),
        .stall (stall_exec),
        .flush (flush_exec),
        .in    ({exec_unit_req_temp_if.valid, exec_unit_req_temp_if.warp_num, exec_unit_req_temp_if.curr_PC, exec_unit_req_temp_if.next_PC, exec_unit_req_temp_if.rd, exec_unit_req_temp_if.wb, exec_unit_req_temp_if.a_reg_data, exec_unit_req_temp_if.b_reg_data, exec_unit_req_temp_if.alu_op, exec_unit_req_temp_if.rs1, exec_unit_req_temp_if.rs2, exec_unit_req_temp_if.rs2_src, exec_unit_req_temp_if.itype_immed, exec_unit_req_temp_if.upper_immed, exec_unit_req_temp_if.branch_type, exec_unit_req_temp_if.is_jal, exec_unit_req_temp_if.jal, exec_unit_req_temp_if.jal_offset, exec_unit_req_temp_if.is_etype, exec_unit_req_temp_if.wspawn, exec_unit_req_temp_if.is_csr, exec_unit_req_temp_if.csr_addr, exec_unit_req_temp_if.csr_immed, exec_unit_req_temp_if.csr_mask}),
        .out   ({exec_unit_req_if.valid     , exec_unit_req_if.warp_num     , exec_unit_req_if.curr_PC     , exec_unit_req_if.next_PC     , exec_unit_req_if.rd     , exec_unit_req_if.wb     , exec_unit_req_if.a_reg_data     , exec_unit_req_if.b_reg_data     , exec_unit_req_if.alu_op     , exec_unit_req_if.rs1     , exec_unit_req_if.rs2     , exec_unit_req_if.rs2_src     , exec_unit_req_if.itype_immed     , exec_unit_req_if.upper_immed     , exec_unit_req_if.branch_type     , exec_unit_req_if.is_jal     , exec_unit_req_if.jal     , exec_unit_req_if.jal_offset     , exec_unit_req_if.is_etype     , exec_unit_req_if.wspawn     , exec_unit_req_if.is_csr     , exec_unit_req_if.csr_addr     , exec_unit_req_if.csr_immed     , exec_unit_req_if.csr_mask     })
    );

    VX_generic_register #(
        .N(68 + `NW_BITS-1 + 1 + 33*(`NUM_THREADS))
    ) gpu_inst_reg (
        .clk   (clk),
        .reset (reset),
        .stall (stall_rest),
        .flush (flush_rest),
        .in    ({gpu_inst_req_temp_if.valid, gpu_inst_req_temp_if.warp_num, gpu_inst_req_temp_if.is_wspawn, gpu_inst_req_temp_if.is_tmc, gpu_inst_req_temp_if.is_split, gpu_inst_req_temp_if.is_barrier, gpu_inst_req_temp_if.next_PC, gpu_inst_req_temp_if.a_reg_data, gpu_inst_req_temp_if.rd2}),
        .out   ({gpu_inst_req_if.valid     , gpu_inst_req_if.warp_num     , gpu_inst_req_if.is_wspawn     , gpu_inst_req_if.is_tmc     , gpu_inst_req_if.is_split     , gpu_inst_req_if.is_barrier     , gpu_inst_req_if.next_PC     , gpu_inst_req_if.a_reg_data     , gpu_inst_req_if.rd2     })
    );

    VX_generic_register #(
        .N(`NW_BITS-1  + 1 + `NUM_THREADS + 58)
    ) csr_reg (
        .clk   (clk),
        .reset (reset),
        .stall (stall_gpr_csr),
        .flush (flush_rest),
        .in    ({csr_req_temp_if.valid, csr_req_temp_if.warp_num, csr_req_temp_if.rd, csr_req_temp_if.wb, csr_req_temp_if.alu_op, csr_req_temp_if.is_csr, csr_req_temp_if.csr_addr, csr_req_temp_if.csr_immed, csr_req_temp_if.csr_mask}),
        .out   ({csr_req_if.valid     , csr_req_if.warp_num     , csr_req_if.rd     , csr_req_if.wb     , csr_req_if.alu_op     , csr_req_if.is_csr     , csr_req_if.csr_addr     , csr_req_if.csr_immed     , csr_req_if.csr_mask     })
    );

`endif

endmodule : VX_gpr_stage