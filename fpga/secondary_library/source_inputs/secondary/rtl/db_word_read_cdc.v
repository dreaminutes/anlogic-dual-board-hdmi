`timescale 1ns/1ps
// One read at a time, held address/data with three-stage request/reply toggles.
// Shared async reset; source is 1MHz and controller pipeline drains <1us, before
// source's 3us reset release permits another request. This is a low-speed adapter.
module db_word_read_cdc(
 input wire src_clk,dst_clk,arst,
 input wire src_req,output wire src_ready,input wire[20:0]src_address,
 output reg src_done,output reg[31:0]src_data,
 output wire mem_req,output wire[20:0]mem_address,input wire mem_ready,mem_rvalid,input wire[31:0]mem_data
);
 (* async_reg="true" *)reg[2:0]sr,dr,ack_sync,req_sync;
 reg request,ack,busy;reg[20:0]held_address,address;reg[31:0]held_data;
 reg[1:0]state;
 always @(posedge src_clk or posedge arst)if(arst)sr<=7;else sr<={sr[1:0],1'b0};
 always @(posedge dst_clk or posedge arst)if(arst)dr<=7;else dr<={dr[1:0],1'b0};
 assign src_ready=!sr[2]&&!busy;
 assign mem_req=!dr[2]&&state==1;assign mem_address=address;
 always @(posedge src_clk or posedge sr[2])begin
  if(sr[2])begin request<=0;busy<=0;ack_sync<=0;src_done<=0;src_data<=0;held_address<=0;end
  else begin
   ack_sync<={ack_sync[1:0],ack};src_done<=0;
   if(src_req&&src_ready)begin held_address<=src_address;request<=~request;busy<=1;end
   else if(busy&&ack_sync[2]==request)begin busy<=0;src_done<=1;src_data<=held_data;end
  end
 end
 always @(posedge dst_clk or posedge dr[2])begin
  if(dr[2])begin req_sync<=0;ack<=0;held_data<=0;state<=0;address<=0;end
  else begin
   req_sync<={req_sync[1:0],request};
   case(state)
    0:if(req_sync[2]!=ack)begin address<=held_address;state<=1;end
    1:if(mem_ready)state<=2;
    2:if(mem_rvalid)begin held_data<=mem_data;ack<=req_sync[2];state<=0;end
   endcase
  end
 end
endmodule
