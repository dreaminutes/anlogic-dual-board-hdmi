// Authorized <=15data sectors plus caller-validated adjacent guard sector.
// Whole run is immutable and unpublished until every512byte CRC AND final
// CMD12/auto-stop succeeded. Caller receives128 little-endian32bit words for its requested512byte sector.
// Raw byte counts, per-block CRC and whole-run stop barrier are unchanged.
module db_fast24_sector_backend #(
 parameter INIT_TIMEOUT=250000000,READ_TIMEOUT=30000000
)(input wire clk,fast_clk,sample_clk,rst,input wire[3:0]sd_dat,inout wire sd_cmd,output wire sd_dclk,
 input wire sd_audio,
 input wire sd_req,input wire[31:0]sd_lba,input wire[3:0]sd_count,
 output wire initialized,failed,output wire[7:0]error_code,
 output reg[31:0]sd_data,output reg sd_valid,sd_end);
 localparam IDLE=0,CAPTURE=1,PRIME=2,STREAM=3,TAIL=4,WAIT_LOW=5,FAULT=6;
 reg[2:0]state;reg request;reg[31:0]lba,cache_lba;reg[3:0]count,cache_count;
 reg audio_owner;reg cache_valid;reg[12:0]received;reg[9:0]block_bytes;reg[3:0]blocks;
 reg[6:0]sent;reg[10:0]read_address;reg[31:0]buffer_read;reg[23:0]pack_low;
 reg[31:0]sector[0:2047] /* fehdl force_ram=1, ram_style="bram" */;
 reg local_failed;reg[7:0]local_error;
 wire core_initialized,hs_selected;
 assign initialized=core_initialized&&hs_selected&&!failed;
 wire cmd_oe,cmd_out,core_failed,core_valid,core_done,core_ready,block_done,block_failed;wire[7:0]core_data,core_error;
 wire cache_hit=cache_valid&&sd_lba>=cache_lba&&(sd_lba-cache_lba)<cache_count;
 wire[31:0]cache_offset=sd_lba-cache_lba;
 db_fast24_sd_controller #(.INIT_TIMEOUT(INIT_TIMEOUT),.READ_TIMEOUT(READ_TIMEOUT)) controller(
  .clk(clk),.fast_clk(fast_clk),.sample_clk(sample_clk),.rst(rst),.cmd_in(sd_cmd),.dat_in(sd_dat),.sd_clk(sd_dclk),.cmd_out(cmd_out),.cmd_oe(cmd_oe),
  .read_request(request),.read_lba(lba),.read_count({1'b0,count}),.initialized(core_initialized),.failed(core_failed),.error_code(core_error),
  .byte_data(core_data),.byte_valid(core_valid),.read_done(core_done),.read_ready(core_ready),.block_done(block_done),.block_failed(block_failed),
  .hs_request(core_initialized&&!hs_selected),.hs_selected(hs_selected),.query_checked(),.first_failure(),.count_known(),.count_supported(),.multi_active(),.stage(),.rca(),.ocr());
 assign sd_cmd=cmd_oe?cmd_out:1'bz;
 assign failed=core_failed||local_failed;
 assign error_code=local_failed?local_error:core_error;
 always@(posedge clk)begin
  if(state==CAPTURE&&core_valid&&received<7680&&!rst)begin
   case(received[1:0])
    0:pack_low[7:0]<=core_data;1:pack_low[15:8]<=core_data;2:pack_low[23:16]<=core_data;
    3:sector[audio_owner?{4'd15,received[8:2]}:received[12:2]]<={core_data,pack_low};
   endcase
  end
  if((state==PRIME||(state==STREAM&&sent<127))&&!rst)buffer_read<=sector[read_address];
 end
 always@(posedge clk or posedge rst)begin
  if(rst)begin audio_owner<=0;state<=IDLE;request<=0;lba<=0;count<=1;cache_lba<=0;cache_count<=0;cache_valid<=0;received<=0;block_bytes<=0;blocks<=0;sent<=0;read_address<=0;local_failed<=0;local_error<=0;sd_data<=0;sd_valid<=0;sd_end<=0;end
  else begin
   request<=0;sd_valid<=0;sd_end<=0;
   if(core_failed&&state!=FAULT)begin
    cache_valid<=0;if(state==CAPTURE||state==PRIME||state==STREAM||state==TAIL)sd_end<=1;state<=FAULT;
   end else case(state)
    IDLE:if(sd_req&&core_ready&&initialized)begin
     if(sd_count==0)begin local_failed<=1;local_error<=8'h44;sd_end<=1;state<=FAULT;cache_valid<=0;end
     else if(!sd_audio&&cache_hit)begin read_address<={cache_offset[3:0],7'd0};sent<=0;state<=PRIME;end
     else begin audio_owner<=sd_audio;lba<=sd_lba;count<=sd_audio?4'd1:sd_count;request<=1;received<=0;block_bytes<=0;blocks<=0;if(!sd_audio)cache_valid<=0;state<=CAPTURE;end
    end
    CAPTURE:begin
     if(core_valid)begin
      if(received>=7680||block_bytes>=512)begin local_failed<=1;local_error<=8'h40;sd_end<=1;state<=FAULT;end
      else begin received<=received+1'b1;block_bytes<=block_bytes+1'b1;end
     end
     if(block_done)begin
      if(block_failed||block_bytes!=512||blocks>=count)begin local_failed<=1;local_error<=8'h41;sd_end<=1;state<=FAULT;end
      else begin blocks<=blocks+1'b1;block_bytes<=0;end
     end
     if(core_done)begin
      if(received!={count,9'd0}||blocks!=count||block_bytes!=0||local_failed)begin local_failed<=1;local_error<=8'h42;sd_end<=1;state<=FAULT;end
      else begin if(!audio_owner)begin cache_valid<=1;cache_lba<=lba;cache_count<=count;end read_address<=audio_owner?11'd1920:11'd0;sent<=0;state<=PRIME;end
     end
    end
    PRIME:begin read_address<=read_address+1'b1;sent<=0;state<=STREAM;end
    STREAM:begin sd_data<=buffer_read;sd_valid<=1;
     if(sent==127)state<=TAIL;else begin sent<=sent+1'b1;read_address<=read_address+1'b1;end
    end
    TAIL:begin sd_end<=1;state<=WAIT_LOW;end
    WAIT_LOW:if(!sd_req)state<=IDLE;
    FAULT:begin cache_valid<=0;end
    default:begin local_failed<=1;local_error<=8'h43;cache_valid<=0;state<=FAULT;end
   endcase
  end
 end
endmodule
