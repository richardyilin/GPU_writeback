`include "VX_define.vh"

module VX_encoder_onehot #(
    parameter N = 6
) (
    input wire [N-1:0] onehot,    
    output reg [`LOG2UP(N)-1:0] binary,
    output reg valid
);
    integer i;

    always @(*) begin
        valid = 1'b0;    
        binary = `LOG2UP(N)'(0);                
        for (i = 0; i < N; i++) begin
            if (onehot[i]) begin
                valid = 1'b1;
                binary = `LOG2UP(N)'(i);
            end
        end
    end
    
endmodule
