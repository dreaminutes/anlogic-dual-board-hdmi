`timescale 1ns/1ps
// PCM-only dual-clock FIFO. Synchronous show-ahead RAM, Gray-pointer crossing.
module db_av_pcm_fifo #(parameter AW=11)(
 input wire rst,wr_clk,rd_clk,wr_valid,rd_take,input wire[15:0]wr_data,
 output wire wr_ready,rd_valid,output reg[15:0]rd_data,
 output wire[AW:0]wr_free,rd_used
);
 reg[15:0]ram[0:(1<<AW)-1];
 reg[AW:0]wp,rp,wgray,rgray,wg0,wg1,rg0,rg1;
 (* async_reg="true" *)reg[1:0]ws,rs;
 function[AW:0]binary(input[AW:0]g);integer i;begin
  binary[AW]=g[AW];for(i=AW-1;i>=0;i=i-1)binary[i]=binary[i+1]^g[i];
 end endfunction
 wire[AW:0]used_w=wp-binary(rg1);
 assign wr_free=(1<<AW)-used_w;assign rd_used=binary(wg1)-rp;
 assign wr_ready=!ws[1]&&used_w<(1<<AW)-1;
 assign rd_valid=!rs[1]&&rgray!=wg1;
 wire push=wr_valid&&wr_ready,pop=rd_take&&rd_valid;
 wire[AW-1:0]read_address=rp[AW-1:0]+pop;
 always@(posedge wr_clk)if(push)ram[wp[AW-1:0]]<=wr_data;
 always@(posedge rd_clk)rd_data<=ram[read_address];
 always@(posedge wr_clk or posedge rst)
  if(rst)begin wp<=0;wgray<=0;rg0<=0;rg1<=0;ws<=3;end
  else begin ws<={ws[0],1'b0};rg0<=rgray;rg1<=rg0;
   if(push)begin wp<=wp+1'b1;wgray<=((wp+1'b1)>>1)^(wp+1'b1);end
  end
 always@(posedge rd_clk or posedge rst)
  if(rst)begin rp<=0;rgray<=0;wg0<=0;wg1<=0;rs<=3;end
  else begin rs<={rs[0],1'b0};wg0<=wgray;wg1<=wg0;
   if(pop)begin rp<=rp+1'b1;rgray<=((rp+1'b1)>>1)^(rp+1'b1);end
  end
endmodule
