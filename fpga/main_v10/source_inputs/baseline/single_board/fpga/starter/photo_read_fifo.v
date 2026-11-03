`timescale 1ns/1ps
// Canonical two-clock RAM template; pointers/reset logic are separate from RAM.
// Show-ahead output: consuming a word preloads the next word on the same edge.
module photo_read_fifo(input rst,clkw,clkr,we,re,input [31:0] di,
 output reg [31:0] dout,output empty_flag,full_flag,output [8:0] wrusedw);
reg [31:0] memory[0:511];
reg [9:0] wp,rp,wgray,rgray;
reg [9:0] wg0,wg1,rg0,rg1;reg [1:0] ws,rs;
function [9:0] gray_bin;input [9:0] g;integer j;begin
 gray_bin[9]=g[9];for(j=8;j>=0;j=j-1)gray_bin[j]=gray_bin[j+1]^g[j];end endfunction
wire [9:0] wcount=wp-gray_bin(rg1);
wire [9:0] rcount=gray_bin(wg1)-rp;
assign wrusedw=wcount[8:0];
assign full_flag=wcount>=511;
assign empty_flag=rcount==0||rs[1];
wire push=we&&!full_flag&&!ws[1];wire pop=re&&!empty_flag;
wire [8:0] read_address=rp[8:0]+pop;
always @(posedge clkw)if(push)memory[wp[8:0]]<=di;
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
