`timescale 1ns/1ps
// Eleven Q2 spectrum states in one true dual-port BRAM9K. Port A is used
// only for reset sweep / blanking updates; port B is a one-edge display read.
module db_neon_spectrum_cache(
 input clk,rst,enable,input[9:0]x,y,
 input[5:0]spectrum_level,input spectrum_ready,
 output[5:0]spectrum_index,input[3:0]read_band,
 output[5:0]read_level,read_level_next,output cache_ready,output reg[5:0]audio_energy);
 reg[7:0]memory[0:15] /* fehdl force_ram=1, ram_style="bram" */;
 reg[7:0]old_value,display_value;
 reg clearing,was_enabled,pending,display_valid;
 reg[3:0]clear_slot,pending_slot;
 wire scan_window=(y==10'd480)&&(x<10'd128);
 wire[5:0]scan_slot=x[6:1];
 assign spectrum_index=scan_window?scan_slot:6'd0;
 wire request=enable&&!clearing&&scan_window&&!x[0]&&scan_slot<6'd11&&spectrum_ready;
 // Both the recorded request and current coordinates qualify the return:
 // switching modes, a not-ready FFT or arbitrary raster jumps cannot write.
 wire response=pending&&enable&&!clearing&&spectrum_ready&&scan_window&&x[0]&&
               (scan_slot=={2'd0,pending_slot});
 wire[3:0]next_read_band=read_band==4'd10 ? 4'd0 : read_band+1'b1;
 wire[3:0]address_a=clearing?clear_slot:(response?pending_slot:(scan_window?scan_slot[3:0]:next_read_band));
 reg next_display_valid;
 always@(posedge clk or posedge rst)if(rst)next_display_valid<=0;
 else next_display_valid<=enable&&!clearing&&!scan_window&&(read_band<11);
 wire[3:0]address_b=(read_band<4'd11)?read_band:4'd0;
 wire[7:0]next_value=old_value-{2'd0,old_value[7:2]}+{2'd0,spectrum_level};
 wire write_a=!rst&&(clearing||response);
 wire[7:0]data_a=clearing?8'd0:next_value;
 // Publish one complete low-frequency envelope per blanking scan. These
 // registers observe the existing writes; they do not change the RAM ports.
 reg[5:0]scan_peak;
 reg[3:0]peak_next_slot;
 reg peak_active;
 wire[5:0]updated_level=next_value[7:2];
 wire[5:0]peak_with_return=(updated_level>scan_peak)?updated_level:scan_peak;
 always@(posedge clk or posedge rst)
  if(rst)begin
   audio_energy<=0;scan_peak<=0;peak_next_slot<=0;peak_active<=0;
  end else if(!enable||clearing)begin
   audio_energy<=0;scan_peak<=0;peak_next_slot<=0;peak_active<=0;
  end else if(!spectrum_ready||!scan_window)begin
   // Incomplete/not-ready scans keep the previous published energy. The
   // next complete slot0..10 scan replaces it; disabled scenes publish zero.
   peak_active<=0;
  end else if(response)begin
   if(pending_slot==0)begin
    scan_peak<=updated_level;peak_next_slot<=1;peak_active<=1;
   end else if(peak_active&&pending_slot==peak_next_slot)begin
    if(pending_slot==10)begin audio_energy<=peak_with_return;peak_active<=0;end
    else begin scan_peak<=peak_with_return;peak_next_slot<=peak_next_slot+1'b1;end
   end else peak_active<=0;
  end
 // No reset on the RAM or its read registers: clearing is eleven clocked
 // writes, so synthesis can retain a physical RAM instead of 88 FF + muxes.
 always@(posedge clk)begin
  if(write_a)memory[address_a]<=data_a;
  old_value<=memory[address_a];
 end
 always@(posedge clk)display_value<=memory[address_b];
 always@(posedge clk or posedge rst)
  if(rst)begin
   clearing<=1'b1;clear_slot<=4'd0;was_enabled<=1'b0;
   pending<=1'b0;pending_slot<=4'd0;display_valid<=1'b0;
  end else begin
   was_enabled<=enable;
   pending<=request;
   if(request)pending_slot<=scan_slot[3:0];
   // Cross-port same-address read/write data is not relied on. Suppress that
   // one blanking read; visible rows never write the cache.
   display_valid<=enable&&!clearing&&(read_band<4'd11)&&
                  !(write_a&&(address_a==address_b));
   if(was_enabled&&!enable)begin
    clearing<=1'b1;clear_slot<=4'd0;pending<=1'b0;display_valid<=1'b0;
   end else if(clearing)begin
    pending<=1'b0;display_valid<=1'b0;
    if(clear_slot==4'd10)begin clearing<=1'b0;clear_slot<=4'd0;end
    else clear_slot<=clear_slot+1'b1;
   end
  end
 assign read_level_next=(cache_ready&&next_display_valid)?old_value[7:2]:6'd0;
 assign cache_ready=enable&&!clearing&&!rst;
 assign read_level=(cache_ready&&display_valid)?display_value[7:2]:6'd0;
endmodule
