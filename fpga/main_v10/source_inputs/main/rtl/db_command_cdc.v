`timescale 1ns/1ps
// One immutable command and one return result. Shared asynchronous flush is
// mandatory; release occurs independently in both clock domains.
module db_command_cdc #(parameter WIDTH=136)(
 input wire src_clk,dst_clk,arst,
 input wire src_valid,output wire src_ready,input wire [WIDTH-1:0] src_data,
 output reg src_done,src_ok,
 output reg dst_valid,input wire dst_take,input wire dst_ok,
 output reg [WIDTH-1:0] dst_data
);
 (* async_reg="true" *)reg [2:0] sr,dr;
 always @(posedge src_clk or posedge arst)if(arst)sr<=7;else sr<={sr[1:0],1'b0};
 always @(posedge dst_clk or posedge arst)if(arst)dr<=7;else dr<={dr[1:0],1'b0};
 wire sreset=sr[2],dreset=dr[2];
 reg request,ack,busy,reply;
 reg [WIDTH-1:0] held;
 (* async_reg="true" *)reg [2:0] ack_sync,req_sync;
 always @(posedge src_clk or posedge sreset)
  if(sreset)ack_sync<=0;else ack_sync<={ack_sync[1:0],ack};
 always @(posedge dst_clk or posedge dreset)
  if(dreset)req_sync<=0;else req_sync<={req_sync[1:0],request};
 assign src_ready=!sreset&&!busy;
 always @(posedge src_clk or posedge sreset)begin
  if(sreset)begin request<=0;busy<=0;held<=0;src_done<=0;src_ok<=0;end
  else begin
   src_done<=0;
   if(src_valid&&src_ready)begin held<=src_data;request<=~request;busy<=1;end
   else if(busy&&ack_sync[2]==request)begin busy<=0;src_done<=1;src_ok<=reply;end
  end
 end
 always @(posedge dst_clk or posedge dreset)begin
  if(dreset)begin ack<=0;reply<=0;dst_valid<=0;dst_data<=0;end
  else if(dst_valid)begin
   if(dst_take)begin ack<=req_sync[2];reply<=dst_ok;dst_valid<=0;end
  end else if(req_sync[2]!=ack)begin dst_data<=held;dst_valid<=1;end
 end
endmodule
