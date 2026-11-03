`timescale 1ns/1ps
// Eight prefetched words and up to eight ordered, unretired writes. Abort
// stops new commands immediately but retains ownership until accepted writes
// retire. A row is published only after every physical write is retired.
module db_pipelined_row_pixel_writer #(parameter WIDTH=640,HEIGHT=480,parameter MEM_WORDS=2097152)(
 input wire clk,rst,abort_request,
 input wire row_valid,output reg row_take,
 input wire[31:0]row_epoch,row_frame_id,input wire[15:0]row_index,row_length,
 output reg[8:0]row_read_address,input wire[31:0]row_read_data,
 input wire lease_active,input wire[31:0]lease_epoch,lease_frame_id,
 input wire[15:0]lease_expected_row,input wire[20:0]lease_base,
 output wire mem_req,output wire[20:0]mem_address,output wire[31:0]mem_data,
 input wire mem_ready,mem_done,
 output wire writes_idle,output reg row_committed,row_failed,
 output reg[31:0]committed_epoch,committed_frame_id,
 output reg[15:0]committed_row,committed_length,output reg[31:0]rejected_rows
);
 localparam WORDS_PER_ROW=WIDTH/2,ROW_BYTES=WIDTH*2;
 localparam IDLE=0,RUN=1,DRAIN=2,RELEASE=3;
 reg[1:0]state,fetch_valid;reg[31:0]fifo[0:7];reg[2:0]rd,wr;
 reg[3:0]count,outstanding;reg[8:0]fetch_index,issued_words,retired_words;
 reg[20:0]address,saved_base;reg[31:0]saved_epoch,saved_frame;reg[15:0]saved_row;
 wire[32:0]row_offset;
 generate if(WIDTH==640)begin:fixed_640
  assign row_offset=({17'd0,row_index}<<8)+({17'd0,row_index}<<6);
 end else begin:other_width
  assign row_offset=row_index*WORDS_PER_ROW;
 end endgenerate
 wire[32:0]row_start={12'd0,lease_base}+row_offset;
 wire[32:0]row_end=row_start+WORDS_PER_ROW;
 wire admissible=lease_active&&row_epoch==lease_epoch&&row_frame_id==lease_frame_id&&row_index==lease_expected_row&&row_index<HEIGHT&&row_length==ROW_BYTES&&row_end<=MEM_WORDS;
 wire lease_intact=lease_active&&lease_epoch==saved_epoch&&lease_frame_id==saved_frame&&lease_base==saved_base&&lease_expected_row==saved_row;
 wire unexpected_retirement=mem_done&&outstanding==0&&(state==RUN||state==DRAIN);
 wire cancel_now=abort_request||!row_valid||!lease_intact||unexpected_retirement;
 wire fetch_fire=state==RUN&&!cancel_now&&fetch_index<WORDS_PER_ROW&&(count+fetch_valid[0]+fetch_valid[1])<8;
 wire push=state==RUN&&!cancel_now&&fetch_valid[1];
 assign mem_req=state==RUN&&!cancel_now&&count!=0&&outstanding<8;
 assign mem_address=address;assign mem_data=fifo[rd];
 wire accepted=mem_req&&mem_ready;
 wire retired=mem_done&&outstanding!=0;
 assign writes_idle=state==IDLE||state==RELEASE;
 // The mailbox registers its RAM output one edge after observing this
 // registered address. Capture two edges after each fetch issue, in order.
 always @(posedge clk)if(push)fifo[wr]<=row_read_data;
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   state<=IDLE;fetch_valid<=0;rd<=0;wr<=0;count<=0;outstanding<=0;
   fetch_index<=0;issued_words<=0;retired_words<=0;address<=0;saved_base<=0;saved_epoch<=0;saved_frame<=0;saved_row<=0;
   row_read_address<=0;row_take<=0;row_committed<=0;row_failed<=0;committed_epoch<=0;committed_frame_id<=0;committed_row<=0;committed_length<=0;rejected_rows<=0;
  end else begin
   row_take<=0;row_committed<=0;row_failed<=0;
   case({accepted,retired})
    2'b10:outstanding<=outstanding+1'b1;
    2'b01:outstanding<=outstanding-1'b1;
   endcase
   if(retired)retired_words<=retired_words+1'b1;
   case(state)
    IDLE:if(row_valid&&!abort_request)begin
     if(!admissible)begin row_failed<=1;row_take<=1;rejected_rows<=rejected_rows+1'b1;state<=RELEASE;end
     else begin
      saved_epoch<=row_epoch;saved_frame<=row_frame_id;saved_base<=lease_base;saved_row<=row_index;
      address<=row_start[20:0];fetch_index<=0;issued_words<=0;retired_words<=0;fetch_valid<=0;count<=0;rd<=0;wr<=0;state<=RUN;
     end
    end
    RUN:if(cancel_now)begin
     fetch_valid<=0;count<=0;rd<=0;wr<=0;state<=DRAIN;
    end else begin
     fetch_valid<={fetch_valid[0],fetch_fire};
     if(fetch_fire)begin row_read_address<=fetch_index;fetch_index<=fetch_index+1'b1;end
     if(push)wr<=wr+1'b1;
     if(accepted)begin rd<=rd+1'b1;issued_words<=issued_words+1'b1;address<=address+1'b1;end
     case({push,accepted})
      2'b10:count<=count+1'b1;
      2'b01:count<=count-1'b1;
     endcase
     if(issued_words==WORDS_PER_ROW&&retired_words==WORDS_PER_ROW&&outstanding==0&&count==0&&fetch_valid==0)begin
      row_committed<=1;row_take<=1;committed_epoch<=saved_epoch;committed_frame_id<=saved_frame;committed_row<=saved_row;committed_length<=ROW_BYTES;state<=RELEASE;
     end
    end
    DRAIN:if(outstanding==0)begin row_failed<=1;row_take<=1;rejected_rows<=rejected_rows+1'b1;state<=RELEASE;end
    RELEASE:if(!row_valid)state<=IDLE;
   endcase
  end
 end
endmodule
