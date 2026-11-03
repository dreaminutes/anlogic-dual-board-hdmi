`timescale 1ns/1ps
// Canonical two-clock RAM template; pointers/reset logic are separate from RAM.
// Show-ahead output: consuming a word preloads the next word on the same edge.
module db_full_word_fifo #(parameter AW=11)(input rst,clkw,clkr,we,re,input [33:0] di,
 output reg [33:0] dout,output empty_flag,full_flag,output [AW:0] wrusedw);
reg [33:0] memory[0:(1<<AW)-1];
reg [AW:0] wp,rp,wgray,rgray;
reg [AW:0] wg0,wg1,rg0,rg1;reg [1:0] ws,rs;
function [AW:0] gray_bin;input [AW:0] g;integer j;begin
 gray_bin[AW]=g[AW];for(j=AW-1;j>=0;j=j-1)gray_bin[j]=gray_bin[j+1]^g[j];end endfunction
wire [AW:0] wcount=wp-gray_bin(rg1);
assign wrusedw=wcount;
assign full_flag=wcount>=(1<<AW)-1;
assign empty_flag=wg1==rgray||rs[1];
wire push=we&&!full_flag&&!ws[1];wire pop=re&&!empty_flag;
wire [AW-1:0] read_address=rp[AW-1:0]+pop;
always @(posedge clkw)if(push)memory[wp[AW-1:0]]<=di;
always @(posedge clkr)dout<=memory[read_address];
always @(posedge clkw or posedge rst)
if(rst)begin wp<=0;wgray<=0;rg0<=0;rg1<=0;ws<=3;end
else begin
 ws<={ws[0],1'b0};rg0<=rgray;rg1<=rg0;
 if(push)begin wp<=wp+1'b1;wgray<=((wp+1'b1)>>1)^(wp+1'b1);end
end
always @(posedge clkr or posedge rst)
if(rst)begin rp<=0;rgray<=0;wg0<=0;wg1<=0;rs<=3;end
else begin
 rs<={rs[0],1'b0};wg0<=wgray;wg1<=wg0;
 if(pop)begin rp<=rp+1'b1;rgray<=((rp+1'b1)>>1)^(rp+1'b1);end
end
endmodule
