`timescale 1ns/1ps
// Startup/reset request lasts at least 50 ms. Sample both assertion and release
// in each destination domain, avoiding raw 50 MHz reset recovery paths at 125 MHz.
// Only the FIRST sampling D pin is a CDC exception; second-stage timing is checked.
module reset_sync(input clk,arst,output rst);
(* syn_preserve = 1, syn_keep = 1, ASYNC_REG = "TRUE" *) reg sync0=1'b1;
(* syn_preserve = 1, syn_keep = 1, ASYNC_REG = "TRUE" *) reg sync1=1'b1;
always @(posedge clk)begin sync0<=arst;sync1<=sync0;end
assign rst=sync1;
endmodule
