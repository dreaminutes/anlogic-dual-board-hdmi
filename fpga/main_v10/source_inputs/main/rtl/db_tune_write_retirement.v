`timescale 1ns/1ps
// One completion for EVERY accepted write, eight later logic edges at50MHz. The
// opposite-edge SDRAM sample and original seven-cycle write recovery fit in
// this interval. Transport cancellation must not reset this physical drain.
module db_tune_write_retirement(input wire clk,rst,accepted,output reg done);
 reg[7:0]pending;
 always @(posedge clk or posedge rst)
  if(rst)begin pending<=0;done<=0;end
  else begin pending<={pending[6:0],accepted};done<=pending[7];end
endmodule
