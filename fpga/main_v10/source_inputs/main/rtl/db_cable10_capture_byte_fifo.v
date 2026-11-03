`timescale 1ns/1ps
// 64-byte two-clock FIFO: registered Gray full/empty, two-stage pointer CDC,
// synchronous show-ahead RAM. No data RAM reset; validity follows pointers.
module db_cable10_capture_byte_fifo(
 input wire rst,wr_clk,rd_clk,wr_en,rd_en,input wire[7:0]wr_data,
 output reg[7:0]rd_data,output wire full,empty,output reg overflow
);
 reg[7:0]memory[0:63] /* fehdl force_ram=1, ram_style="bram" */;
 reg[6:0]wp,wp_ahead,rp,wgray,rgray;
 (* async_reg="true" *)reg[6:0]rg0,rg1,wg0,wg1;
 (* async_reg="true" *)reg[1:0]ws,rs;
 reg wfull,rempty;
 assign full=wfull||ws[1];assign empty=rempty||rs[1];
 wire push=wr_en&&!full,pop=rd_en&&!empty;
 wire[6:0]rn=rp+pop;
 wire[6:0]wgn_ahead=(wp_ahead>>1)^wp_ahead;
 wire[6:0]full_target={~rg1[6:5],rg1[4:0]};
 wire[6:0]rgn=(rn>>1)^rn;
 always @(posedge wr_clk)if(push)memory[wp[5:0]]<=wr_data;
 always @(posedge rd_clk)rd_data<=memory[rn[5:0]];
 always @(posedge wr_clk or posedge rst)
  if(rst)begin wp<=0;wp_ahead<=1;wgray<=0;rg0<=0;rg1<=0;ws<=3;wfull<=0;overflow<=0;end
  else begin
   ws<={ws[0],1'b0};rg0<=rgray;rg1<=rg0;
   // Invariant wp_ahead=wp+1. The selected full comparison contains
   // no binary increment; both comparisons reflect the same oldrg1.
   if(push)begin wp<=wp_ahead;wp_ahead<=wp_ahead+1'b1;wgray<=wgn_ahead;end
   wfull<=push?(wgn_ahead==full_target):(wgray==full_target);
   if(wr_en&&full&&!ws[1])overflow<=1;
  end
 always @(posedge rd_clk or posedge rst)
  if(rst)begin rp<=0;rgray<=0;wg0<=0;wg1<=0;rs<=3;rempty<=1;end
  else begin
   rs<={rs[0],1'b0};wg0<=wgray;wg1<=wg0;
   rp<=rn;rgray<=rgn;rempty<=rgn==wg1;
  end
endmodule
