`timescale 1ns/1ps
// One engine read in flight, with explicit audio/compositor response owner.
// Video retains its separate pipelined path in the existing memory arbiter.
module db_library_engine_mux(input clk,rst,
 input a_req,input[20:0]a_addr,output a_ready,a_rvalid,
 input e_req,e_write,input[20:0]e_addr,input[31:0]e_data,output e_ready,e_rvalid,
 output m_req,m_write,output[20:0]m_addr,output[31:0]m_data,input m_ready,m_rvalid);
 reg pending,owner_audio;
 wire choose_audio=a_req&&!pending;
 // Writes can overlap an outstanding read; its response owner is unchanged.
 assign m_req=pending?(e_req&&e_write):(a_req||e_req);assign m_write=!choose_audio&&e_write;
 assign m_addr=choose_audio?a_addr:e_addr;assign m_data=e_data;
 assign a_ready=m_ready&&m_req&&choose_audio;assign e_ready=m_ready&&m_req&&!choose_audio;
 assign a_rvalid=m_rvalid&&pending&&owner_audio;assign e_rvalid=m_rvalid&&pending&&!owner_audio;
 always@(posedge clk or posedge rst)
 if(rst)begin pending<=0;owner_audio<=0;end
 else begin
  if(m_rvalid&&pending)pending<=0;
  if(m_req&&m_ready&&!m_write)begin pending<=1;owner_audio<=choose_audio;end
 end
endmodule
