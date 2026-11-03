`timescale 1ns/1ps
`include "db_frame_descriptor.vh"
// Encoded word-read CDC port for the existing diagnostic wire format.
// 0x100000 acquires one complete frame; 0x080000 releases it AFTER END+CRC.
// Other addresses encode row[17:9], pixel_pair[8:0]. No snapshot advances a
// mutable playback pointer: every word uses the same held ownership lease.
module db_av_lease_port(
 input wire clk,rst,cancel,
 input wire req,input wire[20:0]address,output wire ready,output reg rvalid,output reg[31:0]data,
 input wire frame_valid,output wire frame_take,input wire[216:0]frame_descriptor,
 output wire finish_valid,input wire finish_ready,
 output wire ram_req,output wire[20:0]ram_address,input wire ram_ready,ram_rvalid,input wire[31:0]ram_data,input wire reads_idle,
 output reg failed,output wire transport_drained
);
 localparam IDLE=0,ACQUIRE=1,ISSUE=2,WAIT_READ=3,RELEASE=4,DRAIN=5;
 reg[216:0]held_descriptor;
 wire[255:0]metadata_bytes={32'd614400,held_descriptor[`DB_FRAME_DESCRIPTOR_DURATION],held_descriptor[`DB_FRAME_DESCRIPTOR_PTS],held_descriptor[`DB_FRAME_DESCRIPTOR_ID],held_descriptor[`DB_FRAME_DESCRIPTOR_ASSET],8'd0,8'd0,{6'd0,held_descriptor[`DB_FRAME_DESCRIPTOR_KIND]},8'd1,16'd480,16'd640,held_descriptor[`DB_FRAME_DESCRIPTOR_EPOCH]};

 reg[2:0]state;reg have_lease;reg[20:0]base,physical;reg[3:0]outstanding;
 wire[21:0]offset=({13'd0,address[17:9]}<<8)+({13'd0,address[17:9]}<<6)+address[8:0];
 wire[21:0]wide={1'b0,base}+offset;
 wire pixel=address[20:18]==0&&address[17:9]<480&&address[8:0]<320&&!wide[21];
 // Reserve at acceptance, retire only actual RAM requests. The one-entry
 // elastic stage removes coded address arithmetic from physical RAM ready.
 reg queued_valid;reg[20:0]queued_address;
 wire[4:0]reserved_words={1'b0,outstanding}+{4'd0,queued_valid};
 wire pixel_accept=req&&ready&&have_lease&&pixel;
 wire pixel_issue=ram_req&&ram_ready;
 wire pixel_return=ram_rvalid&&(outstanding!=0||pixel_issue);
 // Ordered RAM responses remain bound to this one immutable held lease.
 // Control/metadata commands cannot pass any outstanding raster read.
 assign ready=!rst&&!cancel&&state==IDLE&&((have_lease&&pixel)?(reserved_words<8&&(!queued_valid||ram_ready)):(outstanding==0&&!queued_valid));
 assign frame_take=!rst&&!cancel&&state==ACQUIRE&&frame_valid;
 assign finish_valid=!rst&&!cancel&&state==RELEASE&&!queued_valid&&outstanding==0&&reads_idle;
 assign ram_req=!rst&&!cancel&&state==IDLE&&have_lease&&queued_valid;assign ram_address=queued_address;
 assign transport_drained=!have_lease&&state==IDLE&&!queued_valid&&outstanding==0&&reads_idle;
 always @(posedge clk or posedge rst)begin
  if(rst)begin queued_valid<=0;queued_address<=0;outstanding<=0;held_descriptor<=0;state<=IDLE;have_lease<=0;base<=0;physical<=0;rvalid<=0;data<=0;failed<=0;end
  else begin
   rvalid<=0;
   if(pixel_issue)queued_valid<=0;
   if(pixel_accept)begin queued_valid<=1;queued_address<=wide[20:0];end
   case({pixel_issue,pixel_return})
    2'b10:outstanding<=outstanding+1'b1;
    2'b01:outstanding<=outstanding-1'b1;
   endcase
   if(ram_rvalid&&!pixel_return)failed<=1;
   if(pixel_return&&!cancel&&state!=DRAIN)begin data<=ram_data;rvalid<=1;end
   if(cancel)begin queued_valid<=0;state<=DRAIN;have_lease<=0;failed<=0;end
   else case(state)
    IDLE:if(req&&ready&&!(have_lease&&pixel))begin
     if(address==21'h100000&&!have_lease)state<=ACQUIRE;
     else if(address==21'h080000&&have_lease)state<=RELEASE;
     else if(have_lease&&address[20:4]==17'h04000&&address[3:0]<8)begin data<=metadata_bytes[address[3:0]*32+:32];rvalid<=1;end
     else if(!have_lease||address[20:18]!=0||address[17:9]>=480||address[8:0]>=320||wide[21])begin failed<=1;data<=0;rvalid<=1;end
     else begin failed<=1;data<=0;rvalid<=1;end
    end
    ACQUIRE:if(frame_valid&&frame_take)begin
     held_descriptor<=frame_descriptor;base<=frame_descriptor[`DB_FRAME_DESCRIPTOR_BASE];have_lease<=1;data<=32'hdbf20001;rvalid<=1;state<=IDLE;
    end
    RELEASE:if(finish_valid&&finish_ready)begin have_lease<=0;data<=32'hdbf20002;rvalid<=1;state<=IDLE;end
    DRAIN:if(outstanding==0&&reads_idle)state<=IDLE;
    default:begin queued_valid<=0;state<=DRAIN;have_lease<=0;failed<=1;end
   endcase
  end
 end
endmodule
