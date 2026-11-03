// Ordered read ownership queue permits pipelined video reads beside serial jobs.
module animated_memory_arbiter(input clk,rst,
 input v_req,input [20:0] v_addr,output v_ready,output v_rvalid,
 input e_req,e_write,input [20:0] e_addr,input [31:0] e_wdata,
 output e_ready,e_rvalid,
 output m_req,m_write,output [20:0] m_addr,output [31:0] m_wdata,
 input m_ready,m_rvalid);
reg owner[0:15];reg [3:0] wp,rp;reg [4:0] pending;
wire video_selected=v_req&&pending<15;
wire engine_selected=!video_selected&&e_req&&pending<15&&(!e_write||pending==0);
assign m_req=video_selected||engine_selected;
assign m_write=engine_selected&&e_write;
assign m_addr=video_selected?v_addr:e_addr;assign m_wdata=e_wdata;
assign v_ready=m_ready&&video_selected;
assign e_ready=m_ready&&engine_selected;
wire issue=m_req&&m_ready&&!m_write;
assign v_rvalid=m_rvalid&&pending!=0&&owner[rp];
assign e_rvalid=m_rvalid&&pending!=0&&!owner[rp];
always @(posedge clk)begin
 if(rst)begin wp<=0;rp<=0;pending<=0;end
 else begin
  if(issue)begin owner[wp]<=video_selected;wp<=wp+1'b1;end
  if(m_rvalid&&pending!=0)rp<=rp+1'b1;
  case({issue,m_rvalid&&pending!=0})
   2'b10:pending<=pending+1'b1;2'b01:pending<=pending-1'b1;
   default:pending<=pending;
  endcase
 end
end
endmodule
