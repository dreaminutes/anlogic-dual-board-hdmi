`timescale 1ns/1ps
// Bounded two-row lookahead. The source API and lease/control addresses are
// unchanged. Only a complete row is published across the toggle mailbox; its
// bank remains immutable until the sequential consumer advances to the next row.
// Shared reset and 1MHz reset-release/drain assumptions match db_word_read_cdc.
module db_burstrow_prefetch_cdc(
 input wire src_clk,dst_clk,arst,
 input wire src_req,output wire src_ready,input wire[20:0]src_address,
 output reg src_done,output reg[31:0]src_data,
 output wire mem_req,output wire[20:0]mem_address,input wire mem_ready,mem_rvalid,input wire[31:0]mem_data
);
 (* async_reg="true" *)reg[2:0]sr,dr;
 always @(posedge src_clk or posedge arst)if(arst)sr<=7;else sr<={sr[1:0],1'b0};
 always @(posedge dst_clk or posedge arst)if(arst)dr<=7;else dr<={dr[1:0],1'b0};
 // 2 x 512 locations; only 320 per bank used. No reset on RAM contents:
 // source-domain bank-valid bits gate all reads, including after reacquisition.
 reg[31:0]rows[0:1023];reg[31:0]row_data;
 reg[20:0]pending_address;reg[1:0]pending;
 reg[1:0]valid;reg[8:0]tag0,tag1,active_row;reg active_valid,warm_initial;
 wire pixel=pending_address[20:18]==0&&pending_address[17:9]<480&&pending_address[8:0]<320;
 wire[8:0]wanted=pending_address[17:9];
 wire hit=valid[wanted[0]]&&(wanted[0]?tag1:tag0)==wanted;
 wire[8:0]next_row=active_row+1'b1;
 wire next_hit=valid[next_row[0]]&&(next_row[0]?tag1:tag0)==next_row;
 reg job_busy,job_row;reg[8:0]job_index;
 wire c_ready,c_done;wire[31:0]c_data;
 wire control_needed=pending==1&&!pixel;
 wire demand_needed=pending==1&&pixel&&!hit;
 wire ahead_needed=active_valid&&active_row<479&&!next_hit;
 wire start=!sr[2]&&!job_busy&&c_ready&&(control_needed||demand_needed||warm_initial||ahead_needed);
 wire start_row=!control_needed;
 wire[8:0]start_index=demand_needed?wanted:warm_initial?9'd0:next_row;
 wire[20:0]command_address=start_row?{12'hc00,start_index}:pending_address;
 wire b_req,b_ready,b_valid;wire[20:0]b_address;wire[31:0]b_data;
 db_word_read_cdc control(.src_clk(src_clk),.dst_clk(dst_clk),.arst(arst),
  .src_req(start),.src_ready(c_ready),.src_address(command_address),.src_done(c_done),.src_data(c_data),
  .mem_req(b_req),.mem_address(b_address),.mem_ready(b_ready),.mem_rvalid(b_valid),.mem_data(b_data));
 assign src_ready=!sr[2]&&pending==0;
 always @(posedge src_clk)row_data<=rows[{pending_address[9],pending_address[8:0]}];
 always @(posedge src_clk or posedge sr[2])begin
  if(sr[2])begin pending<=0;pending_address<=0;src_done<=0;src_data<=0;valid<=0;tag0<=0;tag1<=0;active_row<=0;active_valid<=0;warm_initial<=0;job_busy<=0;job_row<=0;job_index<=0;end
  else begin
   src_done<=0;
   if(start)begin job_busy<=1;job_row<=start_row;job_index<=start_index;if(start_row)valid[start_index[0]]<=0;end
   if(c_done)begin
    job_busy<=0;
    if(job_row)begin
     valid[job_index[0]]<=1;if(job_index[0])tag1<=job_index;else tag0<=job_index;
     if(warm_initial&&job_index==0)begin warm_initial<=0;active_valid<=1;active_row<=0;end
    end
    else begin
     src_done<=1;src_data<=c_data;pending<=0;
     if(pending_address==21'h100000||pending_address==21'h080000)begin
      valid<=0;active_valid<=0;warm_initial<=pending_address==21'h100000;
      // Do not acknowledge acquisition until row zero is fully resident. This
      // keeps bulk-read latency OUTSIDE a packet, respecting the unchanged
      // receiver's inter-byte timeout even under slow memory arbitration.
      if(pending_address==21'h100000)begin pending<=3;src_done<=0;end
     end
    end
   end
   if(pending==1&&pixel&&hit)pending<=2;
   if(pending==2)begin src_done<=1;src_data<=row_data;pending<=0;end
   if(pending==3&&valid[0]&&tag0==0&&!warm_initial)begin src_done<=1;pending<=0;end
   if(src_req&&src_ready)begin
    pending<=1;pending_address<=src_address;
    if(src_address[20:18]==0&&src_address[17:9]<480&&src_address[8:0]<320)begin active_valid<=1;active_row<=src_address[17:9];end
    else if(src_address==21'h100000||src_address==21'h080000)begin valid<=0;active_valid<=0;warm_initial<=0;end
   end
  end
 end
 // Eight bounded in-order reads may be outstanding. Only a completed 320-word
 // row is acknowledged through the unchanged held toggle mailbox. A bank is
 // never published or reused while any of its writes remain in flight.
 localparam IDLE=0,ISSUE=1,REPLY=3;
 reg[1:0]state;reg filling;reg[8:0]fill_row,issued,returned;reg[20:0]direct_address;
 reg reply_valid;reg[31:0]reply_data;
 wire[8:0]limit=filling?9'd320:9'd1;
 wire[8:0]pending_words=issued-returned;
 assign b_ready=!dr[2]&&state==IDLE;
 assign b_valid=reply_valid;assign b_data=reply_data;
 assign mem_req=!dr[2]&&state==ISSUE&&issued<limit&&pending_words<8;
 assign mem_address=filling?{3'd0,fill_row,issued}:direct_address;
 wire issue_word=mem_req&&mem_ready;
 wire got_word=!dr[2]&&state==ISSUE&&mem_rvalid&&(pending_words!=0||issue_word);
 always @(posedge dst_clk)if(got_word&&filling)rows[{fill_row[0],returned}]<=mem_data;
 always @(posedge dst_clk or posedge dr[2])begin
  if(dr[2])begin state<=IDLE;filling<=0;fill_row<=0;issued<=0;returned<=0;direct_address<=0;reply_valid<=0;reply_data<=0;end
  else begin
   reply_valid<=0;
   case(state)
    IDLE:if(b_req&&b_ready)begin
     filling<=b_address[20:9]==12'hc00;fill_row<=b_address[8:0];issued<=0;returned<=0;direct_address<=b_address;state<=ISSUE;
    end
    ISSUE:begin
     if(issue_word)issued<=issued+1'b1;
     if(got_word)begin
      returned<=returned+1'b1;
      if(returned==limit-1'b1)begin reply_data<=filling?32'hdbf20003:mem_data;state<=REPLY;end
     end
    end
    REPLY:begin reply_valid<=1;state<=IDLE;end
   endcase
  end
 end
endmodule
