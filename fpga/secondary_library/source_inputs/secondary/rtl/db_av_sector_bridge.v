// Request/address remain stable until completion reaches the loader. An end
// token immediately blocks SD-side requests, preventing duplicate commands.
module db_av_sector_bridge(
 input mem_clk,mem_rst,sd_clk,sd_rst,
 input visual_audio,output wire sd_audio,
 input visual_req,input [31:0] visual_lba,input[3:0]visual_count,
 output sd_req,output [31:0] sd_lba,output[3:0]sd_count,
 input [31:0] sd_data,input sd_valid,sd_end,
 output [31:0] visual_data,output visual_valid,visual_end,
 output reg overflow);
(* async_reg="true" *) reg req0,req1,req2;
reg audio0,audio1;assign sd_audio=audio1;
reg [31:0] address0,address1;reg[3:0]count0,count1;reg complete;
wire reset_request=mem_rst||sd_rst;
(* async_reg="true",syn_preserve=1 *) reg [1:0] fifo_reset_sd;
// Assert immediately; release in the 50 MHz write domain. The FIFO's read
// pointer already waits for its own two-clock reset-release guard.
always @(posedge sd_clk or posedge reset_request)
 if(reset_request)fifo_reset_sd<=3;
 else fifo_reset_sd<={fifo_reset_sd[0],1'b0};
wire fifo_empty,fifo_full;wire [33:0] fifo_data;
wire push=sd_valid||sd_end;
// Request gets one extra settle edge beyond the two-stage immutable bundle.
assign sd_req=req2&&!complete;assign sd_lba=address1;assign sd_count=count1;
assign visual_data=fifo_data[31:0];
assign visual_valid=!fifo_empty&&fifo_data[33];
assign visual_end=!fifo_empty&&fifo_data[32];
db_opt_word_fifo fifo(.rst(fifo_reset_sd[1]),.clkw(sd_clk),.clkr(mem_clk),
 .we(push),.re(!fifo_empty),.di({sd_valid,sd_end,sd_data}),
 .dout(fifo_data),.empty_flag(fifo_empty),.full_flag(fifo_full),.wrusedw());
always @(posedge sd_clk or posedge sd_rst)begin
 if(sd_rst)begin audio0<=0;audio1<=0;count0<=1;count1<=1;req0<=0;req1<=0;req2<=0;address0<=0;address1<=0;complete<=0;overflow<=0;end
 else begin
  audio0<=visual_audio;audio1<=audio0;count0<=visual_count;count1<=count0;req0<=visual_req;req1<=req0;req2<=req1;address0<=visual_lba;address1<=address0;
  if(sd_end)complete<=1;else if(!req2)complete<=0;
  if(push&&fifo_full)overflow<=1;
 end
end
endmodule
