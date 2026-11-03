// CRC16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection/xorout.
function [15:0] db_crc16_byte;
 input [15:0] crc;
 input [7:0] data;
 reg [15:0] work;
 integer bit_index;
 begin
  work=crc^{data,8'h00};
  for(bit_index=0;bit_index<8;bit_index=bit_index+1)
   work=work[15] ? (work<<1)^16'h1021 : work<<1;
  db_crc16_byte=work;
 end
endfunction
