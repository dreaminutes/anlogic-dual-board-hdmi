// 24-bit uncompressed BMP pixel stream. The FAT scanner has already validated
// the BMP header; metadata is latched at start and the stream starts at byte 0.
// Rows are normalized to top-left coordinates. Every byte and pixel supports
// backpressure; done is issued only after the final pixel was accepted.
module bmp_stream_decoder(
    input wire clk, input wire rst, input wire start,
    input wire [15:0] width, input wire [15:0] height, input wire top_down,
    input wire [31:0] pixel_offset, input wire [31:0] row_stride,
    input wire [31:0] file_size,
    input wire byte_valid, input wire [7:0] byte_data, output wire byte_ready,
    output wire pixel_valid, input wire pixel_ready,
    output reg [15:0] pixel_x, output reg [15:0] pixel_y,
    output reg [23:0] pixel_rgb,
    output reg done, output reg error, output reg [7:0] error_code
);
    localparam IDLE=0, HEADER=1, BLUE=2, GREEN=3, RED=4,
               HOLD=5, PADDING=6, ENDED=7, FAILED=8;
    reg [3:0] state;
    reg [15:0] image_w, image_h, col, row;
    reg orientation;
    reg [31:0] offset, stride, size, position, padding_left;
    reg [7:0] blue, green;
    wire [47:0] expected_size={16'b0,pixel_offset}+row_stride*{32'b0,height};
    // Explicit shift/add avoids spending DSP blocks on multiplication by 3.
    // 16-bit dimensions need 18 bits for their RGB888 byte count.
    wire [17:0] requested_row_payload={2'b0,width}+{1'b0,width,1'b0};
    wire [17:0] row_payload={2'b0,image_w}+{1'b0,image_w,1'b0};
    wire take=byte_valid && byte_ready;
    assign byte_ready=state==HEADER || state==BLUE || state==GREEN ||
                      state==RED || state==PADDING;
    assign pixel_valid=(state==HOLD);
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE; done<=0; error<=0; error_code<=0;
            image_w<=0; image_h<=0; orientation<=0; col<=0; row<=0;
            offset<=0; stride<=0; size<=0; position<=0; padding_left<=0;
            blue<=0; green<=0; pixel_x<=0; pixel_y<=0; pixel_rgb<=0;
        end else begin
            done<=0;
            if(start) begin
                image_w<=width; image_h<=height; orientation<=top_down;
                offset<=pixel_offset; stride<=row_stride; size<=file_size;
                position<=0; col<=0; row<=0; error<=0; error_code<=0;
                if(width==0 || height==0 || pixel_offset<54 ||
                    row_stride<{14'd0,requested_row_payload} || row_stride[1:0]!=0) begin
                    error<=1; error_code<=8'h01; state<=FAILED;
                end else if(expected_size>{16'b0,file_size}) begin
                    error<=1; error_code<=8'h02; state<=FAILED;
                end else state<=HEADER;
            end else begin
                if(take) begin
                    if(position>=size) begin
                        error<=1; error_code<=8'h02; state<=FAILED;
                    end else begin
                        position<=position+1;
                        case(state)
                            HEADER: if(position+1==offset) state<=BLUE;
                            BLUE: begin blue<=byte_data; state<=GREEN; end
                            GREEN: begin green<=byte_data; state<=RED; end
                            RED: begin
                                pixel_rgb<={byte_data,green,blue};
                                pixel_x<=col;
                                pixel_y<=orientation ? row : image_h-1-row;
                                state<=HOLD;
                            end
                            PADDING: begin
                                if(padding_left==1) begin
                                    if(row+1==image_h) begin done<=1; state<=ENDED; end
                                    else begin row<=row+1; col<=0; state<=BLUE; end
                                end else padding_left<=padding_left-1;
                            end
                        endcase
                    end
                end
                if(state==HOLD && pixel_ready) begin
                    if(col+1<image_w) begin col<=col+1; state<=BLUE; end
                    else if(stride>row_payload) begin
                        padding_left<=stride-row_payload; state<=PADDING;
                    end else if(row+1==image_h) begin done<=1; state<=ENDED; end
                    else begin row<=row+1; col<=0; state<=BLUE; end
                end
            end
        end
    end
endmodule
