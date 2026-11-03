`timescale 1ns/1ps
// Media and PCM share one packet transmitter. PCM consumes at most one packet
// per256 samples after a short initial prefill; media rows are never interrupted.
module db_start24_link_mux(
 input wire clk,rst,hello_retry,session_confirmed,credit_in,media_descriptor_valid,
 output wire media_descriptor_ready,input wire[7:0]media_type,input wire[31:0]media_frame,
 input wire[15:0]media_sequence,media_length,input wire media_payload_valid,
 output wire media_payload_ready,input wire[7:0]media_payload,output wire media_done,
 input wire pcm_valid,input wire[15:0]pcm_data,input wire[11:0]pcm_used,output wire pcm_take,
 output wire forward_clk,link_valid,output wire[7:0]link_data,output wire audio_active
);
 reg busy,audio,session_sent;reg[9:0]index;reg[31:0]sample_cursor;
 reg[14:0]rate_acc;reg[7:0]sample_phase;reg[2:0]due;
 wire sample_tick=rate_acc>=15'd24952;
 wire next_due=sample_tick&&sample_phase==255;
 wire choose_audio=session_sent&&session_confirmed&&due!=0&&pcm_used>=256;
 wire descriptor_ready,payload_ready,packet_done;
 wire descriptor_valid=!busy&&(choose_audio||media_descriptor_valid);
 wire packet_audio=busy?audio:choose_audio;
 wire accepted=descriptor_valid&&descriptor_ready;
 assign media_descriptor_ready=!busy&&!choose_audio&&descriptor_ready;
 assign media_payload_ready=busy&&!audio&&payload_ready;
 assign media_done=packet_done&&busy&&!audio;
 assign pcm_take=busy&&audio&&index>=8&&index[0]&&payload_ready&&pcm_valid;
 assign audio_active=busy&&audio;
 reg[7:0]audio_byte;
 always@*begin
  case(index)
   0:audio_byte=1;1,2,3:audio_byte=0;
   4:audio_byte=8'h80;5:audio_byte=8'hbb; // 48000Hz
   6:audio_byte=0;7:audio_byte=1; // 256 samples
   default:audio_byte=index[0]?pcm_data[15:8]:pcm_data[7:0];
  endcase
 end
 wire payload_valid=busy&&(audio?(index<8||pcm_valid):media_payload_valid);
 db_source_sync_tx #(.MAX_PAYLOAD(1284)) link(.link_clk(clk),.rst(rst||hello_retry),.credit_in(credit_in),
  .descriptor_valid(descriptor_valid),.descriptor_ready(descriptor_ready),
  .packet_type(packet_audio?8'h20:media_type),.flags(8'h81),
  .frame_id(packet_audio?sample_cursor:media_frame),.sequence_number(packet_audio?16'd0:media_sequence),
  .payload_length(packet_audio?16'd520:media_length),.payload_valid(payload_valid),.payload_ready(payload_ready),
  .payload_data(audio?audio_byte:media_payload),.forward_clk(forward_clk),.link_valid(link_valid),.link_data(link_data),.packet_done(packet_done),.waiting_for_credit());
 always@(posedge clk or posedge rst)
  if(rst)begin busy<=0;audio<=0;session_sent<=0;index<=0;sample_cursor<=0;rate_acc<=0;sample_phase<=0;due<=4;end
  else begin
   rate_acc<=sample_tick?rate_acc-15'd24952:rate_acc+15'd48;
   if(sample_tick)sample_phase<=sample_phase+1'b1;
   case({next_due,accepted&&choose_audio})
    2'b10:if(due<4)due<=due+1'b1;
    2'b01:due<=due-1'b1;
   endcase
   if(accepted)begin busy<=1;audio<=choose_audio;index<=0;end
   if(payload_valid&&payload_ready)index<=index+1'b1;
   if(packet_done)begin busy<=0;if(audio)sample_cursor<=sample_cursor+256;else if(media_type==8'h03)session_sent<=1;end
  end
endmodule
