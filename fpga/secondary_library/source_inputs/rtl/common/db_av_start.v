`timescale 1ns/1ps
// Physical run switch enters reset/output-enable control through three stages.
module db_av_start(input wire clk,rst,sw0,output wire enable);
 (* async_reg="true" *)reg[2:0]sw_sync;
 always@(posedge clk or posedge rst)
  if(rst)sw_sync<=0;else sw_sync<={sw_sync[1:0],sw0};
 assign enable=sw_sync[2]&&!rst;
endmodule
