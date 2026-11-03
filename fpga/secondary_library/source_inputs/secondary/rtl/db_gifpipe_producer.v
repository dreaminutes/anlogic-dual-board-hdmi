`timescale 1ns/1ps
// User accepts only640x480 logical GIF canvas. Preserve LZW/transparency/
// local rectangles/disposal; direct RGB565 canvas copy has no scaler. Only three OUTPUT slots are leased;
// native canvas 0 and disposal-3 restore canvas 614400 persist separately.
// Input bytes must support ready backpressure (FAT reader has sector buffers).
module db_gifpipe_producer(
 input wire clk,rst,cancel,start,input wire[31:0]epoch,asset,
 input wire byte_valid,input wire[7:0]byte_data,output wire byte_ready,
 output wire alloc_valid,alloc_static,output wire[1:0]alloc_kind,
 output wire[31:0]alloc_epoch,alloc_asset,alloc_frame,alloc_pts,alloc_duration,
 input wire alloc_ready,input wire[1:0]alloc_slot,input wire[31:0]alloc_token,input wire[20:0]alloc_base,
 output wire commit_valid,commit_static,output wire[1:0]commit_slot,output wire[31:0]commit_token,input wire commit_ready,
 output wire mem_req,mem_write,output wire[20:0]mem_address,output wire[31:0]mem_data,
 input wire mem_ready,mem_rvalid,input wire[31:0]mem_rdata,input wire writes_idle,reads_idle,
 output wire busy,output reg done,failed,output reg[7:0]error_code,output reg[31:0]frames_committed
);
 localparam IDLE=0,DECODE=1,CLEAR=2,OP_WAIT=3,AFTER_DISPOSE=4,ALLOC=5,COMMIT=8,FINISHED=9,FAULT=10;
 reg[3:0]state,after_op;reg gif_start,op_start;
 wire local_rst=rst||cancel;
 reg[31:0]held_epoch,held_asset,pts;reg[15:0]delay_cs,bg_color;
 reg[1:0]slot;reg[31:0]token;
 reg[2:0]disposal,prev_disposal;reg[15:0]prev_left,prev_top,prev_width,prev_height;
 reg frame_pending,trailer_pending;
 wire gh,gb,gf,gd,ge,gpv,gpt,gbr;wire[7:0]gerr;
 wire[15:0]gw,ght,gx,gy,gdelay,gl,gt,gfw,gfh;wire[2:0]gdisp;
 wire[23:0]grgb,gbg;wire gtransparent;
 wire pixel_sink_ready,op_busy;
 wire decoding=state==DECODE&&!frame_pending&&!trailer_pending;
 db_opt_gif_decoder #(.MAX_WIDTH(640),.MAX_HEIGHT(480)) gif(
  .clk(clk),.rst(local_rst),.start(gif_start),.byte_valid(byte_valid&&decoding),.byte_data(byte_data),.byte_ready(gbr),
  .header_valid(gh),.canvas_width(gw),.canvas_height(ght),.background_rgb(gbg),
  .frame_begin(gb),.frame_done(gf),.frame_delay_cs(gdelay),.frame_disposal(gdisp),.frame_left(gl),.frame_top(gt),.frame_width(gfw),.frame_height(gfh),.frame_transparent(gtransparent),
  .pixel_valid(gpv),.pixel_ready(pixel_sink_ready),.pixel_x(gx),.pixel_y(gy),.pixel_rgb(grgb),.pixel_transparent(gpt),.done(gd),.error(ge),.error_code(gerr));
 // Two-entry skid queue; palette/LZW work continues while a canvas pixel
 // command executes. Frame/disposal/copy boundaries wait for complete drain.
 reg[34:0]pixel_queue[0:1] /* fehdl force_ram=0 */;
 reg pixel_rd,pixel_wr;reg[1:0]pixel_count;
 wire queue_push=gpv&&pixel_sink_ready&&!gpt;
 wire stream_pixel_ready;
 wire stream_pixel_valid=state==DECODE&&pixel_count!=0&&!op_start&&!gh&&!gb;
 wire queue_pop=stream_pixel_valid&&stream_pixel_ready;
 assign pixel_sink_ready=decoding&&(gpt||pixel_count<2);
 always@(posedge clk or posedge local_rst)
 if(local_rst)begin pixel_rd<=0;pixel_wr<=0;pixel_count<=0;end
 else if(start)begin pixel_rd<=0;pixel_wr<=0;pixel_count<=0;end
 else begin
  if(queue_push)begin pixel_queue[pixel_wr]<={gx[9:0],gy[8:0],grgb[23:19],grgb[15:10],grgb[7:3]};pixel_wr<=~pixel_wr;end
  if(queue_pop)pixel_rd<=~pixel_rd;
  case({queue_push,queue_pop})2'b10:pixel_count<=pixel_count+1'b1;2'b01:pixel_count<=pixel_count-1'b1;endcase
 end
 wire pixels_drained=pixel_count==0&&!op_busy&&!op_start;
 assign byte_ready=state==FINISHED?1'b1:decoding&&gbr;
 reg[2:0]op_command;reg[20:0]op_src,op_dst;reg[15:0]op_left,op_top,op_width,op_height,op_x,op_y,op_color;
 wire op_done,op_error,op_req,op_write;wire[20:0]op_addr;wire[31:0]op_data;
 db_gifpipe_canvas_ops ops(.stream_valid(stream_pixel_valid),.stream_ready(stream_pixel_ready),.clk(clk),.rst(local_rst),.start(op_start),.command(op_command),.src_base(op_src),.dst_base(op_dst),.total_pixels(21'd307200),.canvas_width(16'd640),
  .rect_left(op_left),.rect_top(op_top),.rect_width(op_width),.rect_height(op_height),.pixel_x({6'd0,pixel_queue[pixel_rd][34:25]}),.pixel_y({7'd0,pixel_queue[pixel_rd][24:16]}),.color(state==DECODE?pixel_queue[pixel_rd][15:0]:op_color),
  .busy(op_busy),.done(op_done),.error(op_error),.mem_req(op_req),.mem_write(op_write),.mem_addr(op_addr),.mem_wdata(op_data),
  .mem_ready(mem_ready),.mem_rvalid(mem_rvalid),.mem_rdata(mem_rdata));
 assign mem_req=!local_rst&&op_req;
 assign mem_write=op_write;assign mem_address=op_addr;assign mem_data=op_data;
 assign alloc_valid=!local_rst&&state==ALLOC;assign alloc_static=0;assign alloc_kind=1;
 assign alloc_epoch=held_epoch;assign alloc_asset=held_asset;assign alloc_frame=frames_committed;assign alloc_pts=pts;
 assign alloc_duration=delay_cs*32'd900;
 assign commit_valid=!local_rst&&state==COMMIT&&writes_idle&&reads_idle;
 assign commit_static=0;assign commit_slot=slot;assign commit_token=token;
 assign busy=state!=IDLE&&state!=FINISHED&&state!=FAULT;
 task begin_op(input[2:0]command,input[20:0]src,dst,input[3:0]afterwards);begin
  op_command<=command;op_src<=src;op_dst<=dst;after_op<=afterwards;op_start<=1;state<=OP_WAIT;
 end endtask
 task fail(input[7:0]why);begin failed<=1;error_code<=why;state<=FAULT;end endtask
 always @(posedge clk or posedge local_rst)begin
  if(local_rst)begin
   state<=IDLE;after_op<=DECODE;gif_start<=0;op_start<=0;held_epoch<=0;held_asset<=0;pts<=0;slot<=0;token<=0;
   delay_cs<=10;bg_color<=0;disposal<=0;prev_disposal<=0;prev_left<=0;prev_top<=0;prev_width<=0;prev_height<=0;
   frame_pending<=0;trailer_pending<=0;done<=0;failed<=0;error_code<=0;frames_committed<=0;
   op_command<=0;op_src<=0;op_dst<=0;op_left<=0;op_top<=0;op_width<=0;op_height<=0;op_x<=0;op_y<=0;op_color<=0;
  end else begin
   gif_start<=0;op_start<=0;done<=0;
   if(gf)frame_pending<=1;if(gd)trailer_pending<=1;
   if(op_error)fail(8'h82);
   else if(ge&&state!=IDLE&&state!=FAULT)fail(8'h40|gerr);
   else case(state)
    IDLE,FINISHED:if(start)begin
     held_epoch<=epoch;held_asset<=asset;pts<=0;frames_committed<=0;failed<=0;error_code<=0;
     prev_disposal<=0;bg_color<=0;delay_cs<=10;disposal<=0;frame_pending<=0;trailer_pending<=0;gif_start<=1;state<=DECODE;
    end
    DECODE:begin
     if(gh)begin
      if(gw!=640||ght!=480)fail(8'h86);
      else begin bg_color<={gbg[23:19],gbg[15:10],gbg[7:3]};state<=CLEAR;end
     end
     else if(gb)begin
      delay_cs<=gdelay<2?16'd2:gdelay;disposal<=gdisp;
      op_left<=prev_left;op_top<=prev_top;op_width<=prev_width;op_height<=prev_height;op_color<=bg_color;
      if(prev_disposal==2)begin_op(2,0,0,AFTER_DISPOSE);
      else if(prev_disposal==3)begin_op(1,21'd614400,0,AFTER_DISPOSE);
      else state<=AFTER_DISPOSE;
      prev_left<=gl;prev_top<=gt;prev_width<=gfw;prev_height<=gfh;prev_disposal<=gdisp;
     end else if(frame_pending&&pixels_drained)begin frame_pending<=0;state<=ALLOC;end
     else if(trailer_pending&&pixels_drained)begin
      if(frames_committed==0)fail(8'h85);else begin done<=1;state<=FINISHED;end
     end
    end
    CLEAR:begin op_color<=bg_color;begin_op(0,0,0,DECODE);end
    AFTER_DISPOSE:if(disposal==3)begin_op(1,0,21'd614400,DECODE);else state<=DECODE;
    OP_WAIT:if(op_error)fail(8'h82);else if(op_done)state<=after_op;
    ALLOC:if(alloc_valid&&alloc_ready)begin
     slot<=alloc_slot;token<=alloc_token;
     begin_op(1,0,alloc_base,COMMIT);
    end
    COMMIT:if(commit_valid&&commit_ready)begin frames_committed<=frames_committed+1'b1;pts<=pts+alloc_duration;state<=DECODE;end
    FAULT:state<=FAULT;
    default:fail(8'hff);
   endcase
  end
 end
endmodule
