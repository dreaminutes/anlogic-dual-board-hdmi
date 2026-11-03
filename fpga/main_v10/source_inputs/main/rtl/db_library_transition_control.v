`timescale 1ns/1ps
// Compose off screen. Only completed buffers are published at vertical blank.
// Engine hold freezes the incoming GIF, never the independent PCM stream.
module db_library_transition_control #(parameter CLK_HZ=50000000)(
 input clk,rst,frame_tick,running,input [2:0] mode,input [1:0] duration,
 input source_valid,input [20:0] source_base,
 input source_portrait,source_native,input [31:0] source_index,
 input [20:0] render_base,cache_base,input cache_available,history_available,
 output[20:0]hold_old,hold_new,output busy,output reg reader_valid,output reg [20:0] reader_base,
 output reg reader_portrait,reader_native,
 output mem_req,mem_write,output [20:0] mem_addr,output [31:0] mem_wdata,
 input mem_ready,mem_rvalid,input [31:0] mem_rdata);
 localparam IDLE=0,LAUNCH=1,RENDER=2,SWAP=3,LATCH=4,FINISH=5,ENDWAIT=6;
 reg [2:0] state,kind;reg [31:0] accepted_index;reg[1:0]seconds;
 reg [20:0] job_origin;reg [20:0] old_base,new_base;reg old_native,old_portrait,new_native,new_portrait;
 localparam STEP_BITS=$clog2(CLK_HZ/16+1);
 reg [6:0] progress;reg [STEP_BITS-1:0] step_clock;reg front,job_buffer;
 reg use_history,history_valid,final_job;reg [6:0] job_phase,previous_phase;reg job_start;wire job_busy,job_done;
 wire changed=reader_valid&&source_valid&&source_index!=accepted_index;
 wire [STEP_BITS-1:0] step_limit=(seconds==0)?CLK_HZ/64:
  ((seconds==1)?CLK_HZ/32:((seconds==2)?CLK_HZ*3/64:CLK_HZ/16));
 wire [20:0] job_target=job_origin+(job_buffer?21'd153600:21'd0);
 assign hold_old=state==IDLE?reader_base:old_base;assign hold_new=state==IDLE?reader_base:new_base;
 assign busy=running&&(state!=IDLE||(changed&&mode!=0&&cache_available));
 photo_frame_compositor compositor(.clk(clk),.rst(rst),.start(job_start),.busy(job_busy),.done(job_done),
  .mode(kind),.progress(job_phase),.phase_delta(job_phase-previous_phase),
  .history_enable(use_history&&kind==1),.history_valid(history_valid),
  .history_base(job_origin+21'd307200+(front?21'd153600:21'd0)),
  .history_target(job_origin+21'd307200+(job_buffer?21'd153600:21'd0)),.old_base(old_base),.new_base(new_base),.target_base(job_target),
  .old_native(old_native),.old_portrait(old_portrait),.new_native(new_native),.new_portrait(new_portrait),
  .mem_req(mem_req),.mem_write(mem_write),.mem_addr(mem_addr),.mem_wdata(mem_wdata),
  .mem_ready(mem_ready),.mem_rvalid(mem_rvalid),.mem_rdata(mem_rdata));
 task commit_source;begin reader_valid<=source_valid;reader_base<=source_base;
  reader_native<=source_native;reader_portrait<=source_portrait;accepted_index<=source_index;end endtask
 always @(posedge clk or posedge rst)
 if(rst)begin
  state<=IDLE;accepted_index<=0;kind<=0;seconds<=1;progress<=0;step_clock<=0;
  job_origin<=0;old_base<=0;new_base<=0;old_native<=0;new_native<=0;old_portrait<=0;new_portrait<=0;
  use_history<=0;history_valid<=0;final_job<=0;job_phase<=0;previous_phase<=0;front<=1;job_buffer<=0;job_start<=0;reader_valid<=0;reader_base<=0;reader_native<=0;reader_portrait<=0;
 end else begin
  job_start<=0;
  if(state==IDLE)begin progress<=0;step_clock<=0;end
  else if(progress<64)begin
   if(step_clock==step_limit-1)begin step_clock<=0;progress<=progress+1'b1;end
   else step_clock<=step_clock+1'b1;
  end
  case(state)
   IDLE:if(frame_tick)begin
    if(running&&changed&&mode!=0&&cache_available)begin
     old_base<=reader_base;old_native<=reader_native;old_portrait<=reader_portrait;
     new_base<=source_base;new_native<=source_native;new_portrait<=source_portrait;
     job_origin<=cache_base;kind<=mode;seconds<=duration;use_history<=history_available;history_valid<=0;final_job<=0;previous_phase<=0;job_buffer<=0;front<=1;state<=LAUNCH;
    end else commit_source;
   end
   LAUNCH:if(!job_busy)begin
    if(!running||final_job)state<=FINISH;
    else begin job_phase<=progress;final_job<=progress==64;job_buffer<=~front;job_start<=1;state<=RENDER;end
   end
   RENDER:if(job_done)begin
    history_valid<=1;previous_phase<=job_phase;state<=!running?FINISH:SWAP;
   end
   SWAP:if(frame_tick)begin
    reader_valid<=1;reader_base<=job_target;reader_native<=1;reader_portrait<=0;state<=LATCH;
   end
   // Reader has latched this completed buffer; only the other buffer may now
   // be overwritten. Its outstanding old reads drain before our first write.
   LATCH:if(render_base==job_target)begin front<=job_buffer;state<=LAUNCH;end
   FINISH:if(frame_tick)begin commit_source;state<=ENDWAIT;end
   ENDWAIT:if(render_base==reader_base)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
endmodule
