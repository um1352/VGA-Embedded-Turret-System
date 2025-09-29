`timescale 1ns / 1ps

// top
module top_uart9_basys3 (
    input  logic clk,        // 100MHz
    input  logic fclk,
    input  logic reset,
    input  logic [8:0] data_detect, // Basys3 슬라이드 스위치 9개
    input  logic btnU,       // 중앙 버튼
    input  logic sw_chase,
    output logic uart_tx
);

    logic btn_rise;
    logic btn_fall;
    logic busy;

    uart9_tx_basys3 #(
        .CLK_HZ(100_000_000),
        .BAUD  (115200)
    ) UTX (
        .clk,
        .reset,
        .start(btn_rise),
        .sendzero(btn_fall),
        .data9(data_detect),
        .sw_chase(sw_chase),
        .tx(uart_tx),
        .busy
    );

    switch_detector U_SW_DEC (
        .fclk(fclk),
        .reset(reset),
        .sw_in(btnU),
        .rising_edge(btn_rise),
        .falling_edge(btn_fall)
    );

endmodule

// uart tx
module uart9_tx_basys3 #(
    parameter int CLK_HZ = 100_000_000,
    parameter int BAUD   = 115200
) (
    input  logic       clk,
    reset,
    input  logic       start,     // 1클럭 펄스
    input  logic       sendzero,  // 1클럭 펄스 (falling edge에서 발생)
    input  logic [8:0] data9,
    input  logic       sw_chase,
    output logic       tx,        // idle=1
    output logic       busy
);
    localparam int DIV = CLK_HZ / BAUD;  // 100e6/115200 ≈ 868
    logic [$clog2(DIV)-1:0] baud_cnt;
    logic [3:0] bit_idx;
    logic [10:0] shifter;  // {stop(1), 9 data, start(0)}

    logic [$clog2(50_000_000-1):0] counter;
    logic active;

    // falling edge 요청 래치
    logic sendzero_req;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) sendzero_req <= 1'b0;
        else if (sendzero) sendzero_req <= 1'b1;                 // 요청 들어오면 set
        else if (!busy && sendzero_req) sendzero_req <= 1'b0;   // 전송 시작하면 clear
    end

    // chase 모드용 타이머
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            counter <= 0;
            active  <= 0;
        end else if (sw_chase) begin
            if (counter == 50_000_000 - 1) begin
                counter <= 0;
                active  <= 1;
            end else begin
                counter <= counter + 1;
                active  <= 0;
            end
        end
    end

    // UART 송신 FSM
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            tx       <= 1'b1;
            busy     <= 1'b0;
            baud_cnt <= '0;
            bit_idx  <= '0;
        end else begin
            if (!busy) begin
                if (!sw_chase) begin
                    if (start || sendzero_req) begin
                        shifter <= (sendzero_req) ?
                            {1'b1, 9'b0, 1'b0} :  // stop, 000000000, start
                            {1'b1, data9, 1'b0};  // stop, data[8:0], start
                        busy     <= 1'b1;
                        baud_cnt <= '0;
                        bit_idx  <= 0;
                        tx       <= 1'b0;  // start bit
                    end
                end else if (sw_chase) begin
                    if (active) begin
                        shifter <= (sendzero_req) ?
                            {1'b1, 9'b0, 1'b0} :
                            {1'b1, data9, 1'b0};
                        busy     <= 1'b1;
                        baud_cnt <= '0;
                        bit_idx  <= 0;
                        tx       <= 1'b0;
                    end
                end
            end else begin
                if (baud_cnt == DIV - 1) begin
                    baud_cnt <= '0;
                    bit_idx  <= bit_idx + 1;
                    tx       <= shifter[bit_idx+1];
                    if (bit_idx == 10) begin
                        busy <= 1'b0;
                        tx   <= 1'b1;  // idle
                    end
                end else baud_cnt <= baud_cnt + 1;
            end
        end
    end
endmodule

// switch edge detector
module switch_detector (
    input  logic fclk,
    input  logic reset,
    input  logic sw_in,
    output logic rising_edge,
    output logic falling_edge
);

    logic sw_dly;

    always_ff @(posedge fclk or posedge reset) begin
        if (reset) sw_dly <= 1'b0;
        else       sw_dly <= sw_in;
    end

    assign rising_edge  =  sw_in & ~sw_dly;  // 0→1
    assign falling_edge = ~sw_in &  sw_dly;  // 1→0

endmodule
