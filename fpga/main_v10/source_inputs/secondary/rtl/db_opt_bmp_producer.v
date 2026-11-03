`timescale 1ns/1ps
// Lease one STATIC slot, retain the original BMP decoder and addressed scaler.
// In particular, bottom-up file rows and the scaler's initial whole-frame
// clear/repeated target writes are not misinterpreted as a linear word stream.
module db_opt_bmp_producer(
 input wire clk,rst,cancel,start,input wire[31:0]epoch,asset,
 input wire[15:0]width,height,input wire top_down,input wire[31:0]file_size,pixel_offset,row_stride,
 input wire byte_valid,input wire[7:0]byte_data,output wire byte_ready,
 output wire alloc_valid,alloc_static,output wire[1:0]alloc_kind,
 output wire[31:0]alloc_epoch,alloc_asset,alloc_frame,alloc_pts,alloc_duration,
 input wire alloc_ready,input wire[1:0]alloc_slot,input wire[31:0]alloc_token,input wire[20:0]alloc_base,
 output wire commit_valid,commit_static,output wire[1:0]commit_slot,output wire[31:0]commit_token,input wire commit_ready,
 output wire mem_req,mem_write,output wire[20:0]mem_address,output wire[31:0]mem_data,input wire mem_ready,writes_idle,
 output wire busy,output reg done,failed,output reg[7:0]error_code
);
 localparam IDLE=0,ALLOC=1,DECODE=2,COMMIT=3,FINISHED=4,FAULT=5;
 reg[2:0]state;wire local_rst=rst||cancel;
 reg[31:0]held_epoch,held_asset,held_size,held_offset,held_stride;reg[15:0]held_width,held_height;reg held_top;
 reg[20:0]target;reg[1:0]slot;reg[31:0]token;reg decode_start,decode_done_seen,scale_done_seen;
 wire dp_valid,dp_ready,decoder_byte_ready,decode_done,decode_error,sc_busy,sc_done,sc_error,sc_req,sc_write;
 wire[7:0]decoder_error,sc_error_code;wire[15:0]px,py;wire[23:0]rgb;wire[20:0]sc_address;wire[31:0]sc_data;
 wire in_range=sc_address>=target&&{1'b0,sc_address}<{1'b0,target}+22'd153600;
 bmp_stream_decoder decoder(.clk(clk),.rst(local_rst),.start(decode_start),.width(held_width),.height(held_height),.top_down(held_top),.pixel_offset(held_offset),.row_stride(held_stride),.file_size(held_size),
  .byte_valid(byte_valid&&state==DECODE),.byte_data(byte_data),.byte_ready(decoder_byte_ready),.pixel_valid(dp_valid),.pixel_ready(dp_ready&&state==DECODE),.pixel_x(px),.pixel_y(py),.pixel_rgb(rgb),.done(decode_done),.error(decode_error),.error_code(decoder_error));
 db_opt_bmp_scaler scaler(.clk(clk),.rst(local_rst),.start(decode_start),.src_width(held_width),.src_height(held_height),.top_down(held_top),.target_base(target),
  .pixel_valid(dp_valid&&state==DECODE),.pixel_ready(dp_ready),.pixel_x(px),.pixel_y(py),.pixel_rgb(rgb),.busy(sc_busy),.done(sc_done),.error(sc_error),.error_code(sc_error_code),
  .mem_req(sc_req),.mem_write(sc_write),.mem_addr(sc_address),.mem_wdata(sc_data),.mem_ready(mem_ready&&in_range));
 assign byte_ready=!local_rst&&(state==DECODE?decoder_byte_ready:state==FINISHED);
 assign mem_req=!local_rst&&sc_req&&in_range;assign mem_write=sc_write;assign mem_address=sc_address;assign mem_data=sc_data;
 assign alloc_valid=!local_rst&&state==ALLOC;assign alloc_static=1;assign alloc_kind=0;
 assign alloc_epoch=held_epoch;assign alloc_asset=held_asset;assign alloc_frame=0;assign alloc_pts=0;assign alloc_duration=270000;
 assign commit_valid=!local_rst&&state==COMMIT&&writes_idle;assign commit_static=1;assign commit_slot=slot;assign commit_token=token;
 assign busy=state!=IDLE&&state!=FINISHED&&state!=FAULT;
 task fail(input[7:0]code);begin failed<=1;error_code<=code;state<=FAULT;end endtask
 always @(posedge clk or posedge local_rst)begin
  if(local_rst)begin
   state<=IDLE;held_epoch<=0;held_asset<=0;held_size<=0;held_offset<=0;held_stride<=0;held_width<=0;held_height<=0;held_top<=0;
   target<=0;slot<=0;token<=0;decode_start<=0;decode_done_seen<=0;scale_done_seen<=0;done<=0;failed<=0;error_code<=0;
  end else begin
   decode_start<=0;done<=0;if(decode_done)decode_done_seen<=1;if(sc_done)scale_done_seen<=1;
   if(decode_error&&state==DECODE)fail(8'h60|decoder_error);
   else if(sc_error&&state==DECODE)fail(8'h90|sc_error_code);
   else if(sc_req&&!in_range)fail(8'ha1);
   else case(state)
    IDLE,FINISHED:if(start)begin held_epoch<=epoch;held_asset<=asset;held_size<=file_size;held_offset<=pixel_offset;held_stride<=row_stride;held_width<=width;held_height<=height;held_top<=top_down;decode_done_seen<=0;scale_done_seen<=0;failed<=0;error_code<=0;state<=ALLOC;end
    ALLOC:if(alloc_valid&&alloc_ready)begin target<=alloc_base;slot<=alloc_slot;token<=alloc_token;decode_start<=1;state<=DECODE;end
    DECODE:if(decode_done_seen&&scale_done_seen)state<=COMMIT;
    COMMIT:if(commit_valid&&commit_ready)begin done<=1;state<=FINISHED;end
    FAULT:state<=FAULT;
    default:fail(8'hff);
   endcase
  end
 end
endmodule
