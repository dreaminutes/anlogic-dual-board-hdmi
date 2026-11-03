`ifndef DB_MEDIA_METADATA_VH
`define DB_MEDIA_METADATA_VH
// V1 packet envelope, versioned media business record. Legacy 0x80 records
// remain separate and cannot be silently interpreted as this 0x81 extension.
`define DB_MEDIA_BEGIN_TYPE 8'h13
`define DB_MEDIA_FLAGS 8'h81
`define DB_MEDIA_BEGIN_BYTES 16'd32
// {kind2,epoch32,wire_frame32,asset32,content_frame32,pts90k32,duration90k32}
`define DB_MEDIA_METADATA_WIDTH 194
`define DB_MEDIA_KIND 193:192
`define DB_MEDIA_EPOCH 191:160
`define DB_MEDIA_WIRE_FRAME 159:128
`define DB_MEDIA_ASSET 127:96
`define DB_MEDIA_CONTENT_FRAME 95:64
`define DB_MEDIA_PTS 63:32
`define DB_MEDIA_DURATION 31:0
`endif
