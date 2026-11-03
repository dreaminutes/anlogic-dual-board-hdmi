`timescale 1ns/1ps
// Serial RGB565 canvas operations on a 32-bit memory bus. Pixel zero occupies
// bits15:0; an odd-width next row can start in the high half of the same word.
// command: 0 fill whole canvas; 1 copy whole canvas; 2 clear rectangle;
//          3 write one pixel. Inputs are latched when start && !busy.
module canvas_memory_ops(
 input clk,rst,start,input [2:0] command,
 input [20:0] src_base,dst_base,total_pixels,
 input [15:0] canvas_width,rect_left,rect_top,rect_width,rect_height,
 input [15:0] pixel_x,pixel_y,color,
 output busy,output reg done,error,
 output reg mem_req,mem_write,output reg [20:0] mem_addr,
 output reg [31:0] mem_wdata,input mem_ready,mem_rvalid,input [31:0] mem_rdata
);
 localparam IDLE=0,FILL_ISSUE=1,FILL_ACK=2,COPY_ISSUE=3,COPY_ACK=4,
 COPY_DATA=5,COPY_WRITE=6,COPY_WRITE_ACK=7,PIXEL_READ=8,PIXEL_ACK=9,
 PIXEL_DATA=10,PIXEL_WRITE=11,PIXEL_WRITE_ACK=12,RECT_NEXT=13;
 reg [3:0] state=IDLE;
 reg [20:0] source_base,destination_base,word_count,word_index;
 reg [15:0] draw_color,x,y,left,right,bottom;
 reg [15:0] row_advance;
 reg [31:0] packed_word,pixel_index;
 reg rectangle;
 // Pixel writes and rectangle starts are mutually exclusive commands.
 // Share their initial row multiply rather than mapping both to hardware.
 wire [15:0] requested_x=command==2?rect_left:pixel_x;
 wire [15:0] requested_y=command==2?rect_top:pixel_y;
 wire [31:0] requested_pixel_index=requested_y*canvas_width+requested_x;
 wire [16:0] requested_right={1'b0,rect_left}+{1'b0,rect_width};
 wire [16:0] requested_bottom={1'b0,rect_top}+{1'b0,rect_height};
 wire [32:0] requested_rect_end=(requested_bottom-1)*{1'b0,canvas_width}+requested_right;
 assign busy=(state!=IDLE);
 task finish;
  begin state<=IDLE;mem_req<=0;done<=1;end
 endtask
 task merge_pixel;
  input [31:0] previous;
  begin
   packed_word<=pixel_index[0]?{draw_color,previous[15:0]}:{previous[31:16],draw_color};
   state<=PIXEL_WRITE;
  end
 endtask
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   state<=IDLE;done<=0;error<=0;mem_req<=0;mem_write<=0;mem_addr<=0;mem_wdata<=0;
   source_base<=0;destination_base<=0;word_count<=0;word_index<=0;
   draw_color<=0;rectangle<=0;x<=0;y<=0;left<=0;right<=0;bottom<=0;
   pixel_index<=0;packed_word<=0;row_advance<=0;
  end else begin
   done<=0;
   case(state)
    IDLE:if(start)begin
     error<=0;source_base<=src_base;destination_base<=dst_base;
     word_count<=(total_pixels>>1)+total_pixels[0];word_index<=0;
     draw_color<=color;rectangle<=(command==2);
     // Last pixel of this row -> first pixel of the next rectangle row.
     // Valid nonempty rectangles guarantee this increment fits 16 bits.
     row_advance<=canvas_width-rect_width+16'd1;
     if(command>3)begin error<=1;done<=1;end
     else if(total_pixels==0)done<=1;
     else case(command)
      0:state<=FILL_ISSUE;
      1:state<=COPY_ISSUE;
      2:begin
       if(rect_width==0||rect_height==0)done<=1;
       else if(canvas_width==0 || requested_right>{1'b0,canvas_width} ||
        requested_bottom>65535 || requested_rect_end>{12'd0,total_pixels})begin error<=1;done<=1;end
       else begin
        x<=rect_left;y<=rect_top;left<=rect_left;right<=requested_right[15:0];bottom<=requested_bottom[15:0];
        pixel_index<=requested_pixel_index;state<=PIXEL_READ;
       end
      end
      3:begin
       if(canvas_width==0||pixel_x>=canvas_width||requested_pixel_index>={11'd0,total_pixels})begin error<=1;done<=1;end
       else begin pixel_index<=requested_pixel_index;state<=PIXEL_READ;end
      end
     endcase
    end
    FILL_ISSUE:begin
     mem_req<=1;mem_write<=1;mem_addr<=destination_base+word_index;
     mem_wdata<={draw_color,draw_color};state<=FILL_ACK;
    end
    FILL_ACK:if(mem_ready)begin
     mem_req<=0;
     if(word_index+1>=word_count)finish;
     else begin word_index<=word_index+1;state<=FILL_ISSUE;end
    end
    COPY_ISSUE:begin
     mem_req<=1;mem_write<=0;mem_addr<=source_base+word_index;state<=COPY_ACK;
    end
    COPY_ACK:if(mem_ready)begin
     mem_req<=0;
     if(mem_rvalid)begin packed_word<=mem_rdata;state<=COPY_WRITE;end
     else state<=COPY_DATA;
    end
    COPY_DATA:if(mem_rvalid)begin packed_word<=mem_rdata;state<=COPY_WRITE;end
    COPY_WRITE:begin
     mem_req<=1;mem_write<=1;mem_addr<=destination_base+word_index;
     mem_wdata<=packed_word;state<=COPY_WRITE_ACK;
    end
    COPY_WRITE_ACK:if(mem_ready)begin
     mem_req<=0;
     if(word_index+1>=word_count)finish;
     else begin word_index<=word_index+1;state<=COPY_ISSUE;end
    end
    PIXEL_READ:begin
     mem_req<=1;mem_write<=0;mem_addr<=destination_base+pixel_index[21:1];state<=PIXEL_ACK;
    end
    PIXEL_ACK:if(mem_ready)begin
     mem_req<=0;
     if(mem_rvalid)merge_pixel(mem_rdata);else state<=PIXEL_DATA;
    end
    PIXEL_DATA:if(mem_rvalid)merge_pixel(mem_rdata);
    PIXEL_WRITE:begin
     mem_req<=1;mem_write<=1;mem_addr<=destination_base+pixel_index[21:1];
     mem_wdata<=packed_word;state<=PIXEL_WRITE_ACK;
    end
    PIXEL_WRITE_ACK:if(mem_ready)begin
     mem_req<=0;
     if(rectangle)state<=RECT_NEXT;else finish;
    end
    RECT_NEXT:begin
     if(x+1<right)begin x<=x+1;pixel_index<=pixel_index+1;state<=PIXEL_READ;end
     else if(y+1<bottom)begin x<=left;y<=y+1;pixel_index<=pixel_index+{16'd0,row_advance};state<=PIXEL_READ;end
     else finish;
    end
    default:begin error<=1;finish;end
   endcase
  end
 end
endmodule
