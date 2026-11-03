`timescale 1ns/1ps
// Private GIF640 canvas port. The producer holds command inputs until done.
// Pixel stores may remain in a one-word combining buffer. Every non-pixel
// command flushes it before reading/copying/clearing the canvas. The producer
// publishes a frame only after the barrier COPY has completed.
module db_gifpipe_canvas_ops(
 input clk,rst,start,stream_valid,output wire stream_ready,input[2:0]command,
 input[20:0]src_base,dst_base,total_pixels,
 input[15:0]canvas_width,rect_left,rect_top,rect_width,rect_height,
 input[15:0]pixel_x,pixel_y,color,
 output busy,output reg done,error,
 output wire mem_req,mem_write,output wire[20:0]mem_addr,
 output wire[31:0]mem_wdata,input mem_ready,mem_rvalid,input[31:0]mem_rdata
);
 localparam IDLE=0,DISPATCH=1,FLUSH_START=2,FLUSH_WAIT=3,LEGACY_START=4,LEGACY_WAIT=5,PAIR_WRITE=6,COPY_READ=7,COPY_WAIT=8,COPY_WRITE=9;
 reg[3:0]state;reg legacy_start,stream_flush;
 reg[1:0]pending_mask;reg[20:0]pending_addr;reg[31:0]pending_data;
 wire[18:0]pixel_index=({1'b0,pixel_y[8:0],9'b0})+({3'b0,pixel_y[8:0],7'b0})+{9'b0,pixel_x[9:0]};
 // The direct GIF stream always updates native canvas0. Bulk operations
 // retain their independent source/destination bases; no GIF scaling exists.
 wire[20:0]pixel_addr={3'd0,pixel_index[18:1]};
 wire[1:0]pixel_mask=pixel_index[0]?2'b10:2'b01;
 wire[31:0]merged=pixel_index[0]?{color,pending_data[15:0]}:{pending_data[31:16],color};
 wire stream_geometry_ok=canvas_width==640&&total_pixels==307200&&pixel_x<640&&pixel_y<480;
 assign stream_ready=state==IDLE&&!start&&stream_geometry_ok&&(pending_mask==0||pending_addr==pixel_addr);
 // Eight reads then eight writes amortize SDRAM read/write turnaround.
 // The existing producer/sender arbiter retains response ownership/limits.
 reg[31:0]copy_words[0:7];reg[31:0]copy_word_q;
 reg[17:0]copy_offset;reg[3:0]copy_issued,copy_received;reg[2:0]copy_write_index;
 wire copying=state==COPY_READ||state==COPY_WAIT||state==COPY_WRITE;
 wire copy_pop=state==COPY_WRITE&&mem_ready;
 wire[2:0]copy_buffer_address=copy_write_index+copy_pop;
 // All fast-path GIF copies have one base0, and are disjoint. Other calls
 // retain scalar behavior, including overlapping/self copies.
 wire copy_disjoint=(src_base==0&&dst_base>=153600)||(dst_base==0&&src_base>=153600);
 always@(posedge clk)begin
  if((state==COPY_READ||state==COPY_WAIT)&&mem_rvalid&&copy_received<8)copy_words[copy_received[2:0]]<=mem_rdata;
  copy_word_q<=copy_words[copy_buffer_address];
 end
 wire flushing=state==FLUSH_START||state==FLUSH_WAIT;
 wire legacy_req,legacy_write,legacy_done,legacy_error,legacy_busy;
 wire[20:0]legacy_addr;wire[31:0]legacy_data;
 db_gif_fast_scalar scalar(
  .clk(clk),.rst(rst),.start(legacy_start),.command(flushing?3'd3:command),
  .src_base(flushing?21'd0:src_base),.dst_base(flushing?pending_addr:dst_base),
  .total_pixels(total_pixels),.canvas_width(canvas_width),
  .rect_left(rect_left),.rect_top(rect_top),.rect_width(rect_width),.rect_height(rect_height),
  .pixel_x(flushing?(pending_mask[0]?16'd0:16'd1):pixel_x),.pixel_y(flushing?16'd0:pixel_y),
  .color(flushing?(pending_mask[0]?pending_data[15:0]:pending_data[31:16]):color),
  .busy(legacy_busy),.done(legacy_done),.error(legacy_error),
  .mem_req(legacy_req),.mem_write(legacy_write),.mem_addr(legacy_addr),.mem_wdata(legacy_data),
  .mem_ready(mem_ready&&state!=PAIR_WRITE&&!copying),.mem_rvalid(mem_rvalid&&!copying),.mem_rdata(mem_rdata));
 assign busy=state!=IDLE;
 assign mem_req=state==PAIR_WRITE?1'b1:copying?((state==COPY_READ&&copy_issued<8)||state==COPY_WRITE):legacy_req;
 assign mem_write=state==PAIR_WRITE?1'b1:copying?(state==COPY_WRITE):legacy_write;
 assign mem_addr=state==PAIR_WRITE?pending_addr:copying?(state==COPY_WRITE?dst_base+copy_offset+copy_write_index:src_base+copy_offset+copy_issued[2:0]):legacy_addr;
 assign mem_wdata=state==PAIR_WRITE?pending_data:copying?copy_word_q:legacy_data;
 always@(posedge clk or posedge rst)begin
  if(rst)begin stream_flush<=0;state<=IDLE;legacy_start<=0;done<=0;error<=0;pending_mask<=0;pending_addr<=0;pending_data<=0;copy_offset<=0;copy_issued<=0;copy_received<=0;copy_write_index<=0;end
  else begin
   done<=0;legacy_start<=0;
   if((state==COPY_READ||state==COPY_WAIT)&&mem_rvalid)copy_received<=copy_received+1'b1;
   case(state)
    IDLE:if(start)begin error<=0;stream_flush<=0;state<=DISPATCH;end
     else if(stream_valid)begin
      if(!stream_geometry_ok)begin error<=1;done<=1;end
      else if(pending_mask!=0&&pending_addr!=pixel_addr)begin stream_flush<=1;state<=FLUSH_START;end
      else if(stream_ready)begin
       pending_addr<=pixel_addr;pending_data<=merged;
       if(pending_mask!=0&&(pending_mask|pixel_mask)==3)begin pending_mask<=3;state<=PAIR_WRITE;end
       else pending_mask<=pending_mask|pixel_mask;
      end
     end
    DISPATCH:begin
     if(command>2)begin error<=1;done<=1;state<=IDLE;end
     else if(pending_mask!=0)state<=FLUSH_START;
     else if(command==1&&total_pixels==307200&&copy_disjoint)begin
      copy_offset<=0;copy_issued<=0;copy_received<=0;copy_write_index<=0;state<=COPY_READ;
     end else state<=LEGACY_START;
    end
    FLUSH_START:begin legacy_start<=1;state<=FLUSH_WAIT;end
    FLUSH_WAIT:if(legacy_error)begin error<=1;done<=1;state<=IDLE;end
      else if(legacy_done)begin pending_mask<=0;state<=stream_flush?IDLE:DISPATCH;end
    LEGACY_START:begin legacy_start<=1;state<=LEGACY_WAIT;end
    LEGACY_WAIT:if(legacy_error)begin error<=1;done<=1;state<=IDLE;end
      else if(legacy_done)begin done<=1;state<=IDLE;end
    PAIR_WRITE:if(mem_ready)begin pending_mask<=0;done<=1;state<=IDLE;end
    COPY_READ:if(copy_issued<8&&mem_ready)begin
     copy_issued<=copy_issued+1'b1;if(copy_issued==7)state<=COPY_WAIT;
    end
    COPY_WAIT:if(copy_received==8)state<=COPY_WRITE;
    COPY_WRITE:if(mem_ready)begin
     if(copy_write_index==7)begin
      if(copy_offset==153592)begin done<=1;state<=IDLE;end
      else begin copy_offset<=copy_offset+8;copy_issued<=0;copy_received<=0;copy_write_index<=0;state<=COPY_READ;end
     end else copy_write_index<=copy_write_index+1'b1;
    end
    default:begin error<=1;done<=1;state<=IDLE;end
   endcase
  end
 end
endmodule
