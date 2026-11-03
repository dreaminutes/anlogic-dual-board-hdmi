`timescale 1ns/1ps
// 25MHz20/20ns link,250MHz sampler. Two synchronizer stages precede a
// three-sample majority. The aligned median data tap preserves source setup
// and hold; a4ns positive/negative clock glitch affects at most one sample.
module db_link25_input_filter(
 input wire clk,rst,forward_clk,link_valid,input wire[7:0]link_data,
 output reg sample_pulse,output wire sample_valid,output wire[7:0]sample_data
);
 (* async_reg="true" *)reg[4:0]clock_sync;
 (* async_reg="true" *)reg[3:0]valid_sync;
 (* async_reg="true" *)reg[7:0]data0,data1,data2,data3;
 reg clean_previous;reg[2:0]rise_guard;
 reg[7:0]accepted_data;reg accepted_valid;
 wire clean_clock=(clock_sync[4]&&clock_sync[3])||
                  (clock_sync[4]&&clock_sync[2])||
                  (clock_sync[3]&&clock_sync[2]);
 always@(posedge clk or posedge rst)begin
  if(rst)begin
   clock_sync<=0;valid_sync<=0;data0<=0;data1<=0;data2<=0;data3<=0;
   clean_previous<=0;rise_guard<=0;accepted_data<=0;accepted_valid<=0;sample_pulse<=0;
  end else begin
   clock_sync<={clock_sync[3:0],forward_clk};valid_sync<={valid_sync[2:0],link_valid};
   data0<=link_data;data1<=data0;data2<=data1;data3<=data2;
   clean_previous<=clean_clock;sample_pulse<=0;
   if(rise_guard!=0)rise_guard<=rise_guard-1'b1;
   if(clean_clock&&!clean_previous&&rise_guard==0)begin
    sample_pulse<=1;accepted_data<=data3;accepted_valid<=valid_sync[3];rise_guard<=6;
   end
  end
 end
 assign sample_valid=sample_pulse&&accepted_valid;assign sample_data=accepted_data;
endmodule
