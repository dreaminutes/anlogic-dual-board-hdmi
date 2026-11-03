// GIF LZW decompressor. Bytes and codes are packed least significant bit first.
// The dictionary uses a prefix/suffix chain and a reverse stack; no CPU or IP
// core is needed. The sink may stall on every output pixel.
module db_opt_gif_lzw(
    input wire clk, input wire rst, input wire start,
    input wire [3:0] min_code_size,
    input wire byte_valid, input wire [7:0] byte_data,
    output wire byte_ready,
    output wire index_valid, output wire [7:0] index_data,
    input wire index_ready,
    output reg done, output reg error
);
    localparam IDLE=0, CODE=1, CHECK=2, WALK=3, ADD=4, POP=5,
               OUTPUT=6, ENDED=7, FAILED=8, WALK_PUSH=9;
    reg [3:0] state;
    reg [11:0] prefixes [0:4095];
    reg [7:0] suffixes [0:4095];
    reg [7:0] stack [0:4095];
    reg [12:0] stack_count;
    reg [31:0] bits;
    reg [5:0] bit_count;
    reg [3:0] code_width, initial_width;
    reg [12:0] next_code;
    reg [11:0] clear_code, end_code, code, walk_code, old_code;
    reg old_valid;
    reg [7:0] old_first, first_char, out_index;
    reg [11:0] dictionary_prefix;
    reg [7:0] dictionary_suffix;
    reg [12:0] walk_steps;
    reg [7:0] stack_q;
    wire pop_stack=state==POP||(state==OUTPUT&&index_ready&&stack_count!=0);
    wire [11:0] stack_read_address=stack_count[11:0]-12'd1-(pop_stack?12'd1:12'd0);
    wire special_push=state==CHECK&&old_valid&&{1'b0,code}==next_code;
    wire literal_push=state==WALK&&stack_count<4096&&walk_steps<4096&&walk_code<clear_code;
    wire stack_write=special_push||literal_push||state==WALK_PUSH;
    wire [11:0] stack_write_address=special_push?12'd0:stack_count[11:0];
    wire [7:0] stack_write_data=special_push?old_first:(literal_push?walk_code[7:0]:dictionary_suffix);
    // Dedicated no-reset RAM processes are required by TD's BRAM inference.
    always @(posedge clk) begin
        dictionary_prefix<=prefixes[walk_code];
        dictionary_suffix<=suffixes[walk_code];
        stack_q<=stack[stack_read_address];
        if(!rst&&!start&&state==ADD&&next_code<4096)begin
            prefixes[next_code[11:0]]<=old_code;
            suffixes[next_code[11:0]]<=first_char;
        end
        if(!rst&&!start&&stack_write)stack[stack_write_address]<=stack_write_data;
    end
    wire [31:0] code_mask=(32'h1 << code_width)-1;
    assign byte_ready=(state==CODE && bit_count<code_width);
    assign index_valid=(state==OUTPUT);
    assign index_data=out_index;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE; done<=0; error<=0; bits<=0; bit_count<=0;
            code_width<=0; initial_width<=0; next_code<=0;
            clear_code<=0; end_code<=0; old_valid<=0; old_code<=0;
            code<=0; walk_code<=0; old_first<=0; first_char<=0;
            stack_count<=0; walk_steps<=0; out_index<=0;
        end else begin
            done<=0;
            if(start) begin
                bits<=0; bit_count<=0; stack_count<=0; old_valid<=0;
                clear_code<=12'h001 << min_code_size;
                end_code<=(12'h001 << min_code_size)+1;
                next_code<=(13'h001 << min_code_size)+2;
                code_width<=min_code_size+1'b1;
                initial_width<=min_code_size+1'b1;
                error<=0;
                if(min_code_size<2 || min_code_size>8) begin
                    state<=FAILED; error<=1;
                end else state<=CODE;
            end else case(state)
                CODE: begin
                    if(bit_count>=code_width) begin
                        code<=bits & code_mask;
                        bits<=bits >> code_width;
                        bit_count<=bit_count-code_width;
                        state<=CHECK;
                    end else if(byte_valid) begin
                        bits<=bits | ({24'b0,byte_data} << bit_count);
                        bit_count<=bit_count+8;
                    end
                end
                CHECK: begin
                    if(code==clear_code) begin
                        next_code<=clear_code+2; code_width<=initial_width;
                        old_valid<=0; state<=CODE;
                    end else if(code==end_code) begin
                        done<=1; state<=ENDED;
                    end else if(!old_valid) begin
                        if(code>=clear_code) begin error<=1; state<=FAILED; end
                        else begin
                            old_code<=code; old_first<=code[7:0]; old_valid<=1;
                            out_index<=code[7:0]; state<=OUTPUT;
                        end
                    end else if({1'b0,code}>next_code) begin
                        error<=1; state<=FAILED;
                    end else begin
                        walk_steps<=0;
                        if({1'b0,code}==next_code) begin
                            // KwKwK: expand old string and append its first byte.
                            stack_count<=1; walk_code<=old_code;
                        end else begin stack_count<=0; walk_code<=code; end
                        state<=WALK;
                    end
                end
                WALK: begin
                    if(stack_count>=4096 || walk_steps>=4096) begin
                        error<=1; state<=FAILED;
                    end else if(walk_code<clear_code) begin
                        stack_count<=stack_count+1;
                        first_char<=walk_code[7:0]; state<=ADD;
                    end else if(walk_code>=next_code || walk_code==end_code || walk_code==clear_code) begin
                        error<=1; state<=FAILED;
                    end else begin
                        // Explicit registered reads allow block-RAM inference.
                        state<=WALK_PUSH;
                    end
                end
                WALK_PUSH: begin
                    stack_count<=stack_count+1;
                    walk_code<=dictionary_prefix; walk_steps<=walk_steps+1;
                    state<=WALK;
                end
                ADD: begin
                    if(next_code<4096) begin
                        next_code<=next_code+1;
                        if(next_code+1==(13'h1 << code_width) && code_width<12)
                            code_width<=code_width+1;
                    end
                    old_code<=code; old_first<=first_char; state<=POP;
                end
                POP: begin
                    out_index<=stack_q;
                    stack_count<=stack_count-1; state<=OUTPUT;
                end
                OUTPUT: if(index_ready) begin
                    if(stack_count!=0)begin out_index<=stack_q;stack_count<=stack_count-1;state<=OUTPUT;end else state<=CODE;
                end
                default: begin end
            endcase
        end
    end
endmodule
