`timescale 1ns / 1ps
module top_uart9_USB (
    input  logic         clk,
    input  logic         fclk,
    input  logic         reset,
    input  logic [8:0]   data_detect,
    output logic         uart_tx,
    output logic         busy
);
    // ===== fclk 동기화 & 라이징 엣지 검출 (clk 도메인) =====
    logic [1:0] fclk_sync;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) fclk_sync <= 2'b00;
        else       fclk_sync <= {fclk_sync[0], fclk};
    end
    wire fclk_rise =  fclk_sync[1] & ~fclk_sync[0];

    logic start_tx;

    // 2바이트(LE) 전송기
    uart9_tx #(
        .CLK_HZ(100_000_000),
        .BAUD  (9600)
    ) UTX (
        .clk     (clk),
        .reset   (reset),
        .start   (start_tx),
        .data9   (data_detect),
        .tx      (uart_tx),
        .busy    (busy)
    );

    // fclk 한 펄스마다 1클럭 start (busy일 땐 무시)
    always_ff @(posedge clk or posedge reset) begin
        if (reset)          start_tx <= 1'b0;
        else if (fclk_rise && !busy) start_tx <= 1'b1;
        else                start_tx <= 1'b0;
    end
endmodule


// ===== 8N1 두 바이트 연속 전송 (LE) =====
module uart9_tx #(
    parameter int CLK_HZ = 100_000_000,
    parameter int BAUD   = 9600
)(
    input  logic         clk,
    input  logic         reset,
    input  logic         start,       // 1-clock pulse
    input  logic [8:0]   data9,
    output logic         tx,          // idle=1
    output logic         busy
);
    localparam int DIV = CLK_HZ / BAUD;     // 정수분주(오차 ~0.64% @ 100MHz/9600)
    // 보드레이트 tick
    logic [$clog2(DIV)-1:0] baud_cnt;
    logic                    tick;

    // 1바이트 8N1 시프터
    logic [9:0] shifter;  // {stop(1), data[7:0], start(0)}
    logic [3:0] bit_idx;  // 0..9

    // 두 번째 바이트 관리
    logic        second_pending;
    logic [7:0]  byte0, byte1;

    // tick 생성
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            baud_cnt <= '0; tick <= 1'b0;
        end else if (busy) begin
            if (baud_cnt == DIV-1) begin baud_cnt <= '0; tick <= 1'b1; end
            else begin baud_cnt <= baud_cnt + 1; tick <= 1'b0; end
        end else begin
            baud_cnt <= '0; tick <= 1'b0;
        end
    end

    // 본체
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            tx <= 1'b1; busy <= 1'b0;
            shifter <= 10'h3FF; bit_idx <= '0;
            second_pending <= 1'b0; byte0 <= 8'h00; byte1 <= 8'h00;
        end else begin
            if (!busy) begin
                if (start) begin
                    byte0 <= data9[7:0];
                    byte1 <= {7'b0, data9[8]};
                    shifter <= {1'b1, data9[7:0], 1'b0}; // 첫 바이트
                    tx <= 1'b0;          // start
                    bit_idx <= 4'd0;
                    second_pending <= 1'b1;
                    busy <= 1'b1;
                end
            end else begin
                if (tick) begin
                    bit_idx <= bit_idx + 1;
                    tx <= shifter[bit_idx+1];    // 다음 비트 출력
                    if (bit_idx == 4'd9) begin   // 10비트 끝
                        if (second_pending) begin
                            shifter <= {1'b1, byte1, 1'b0}; // hi 바이트
                            tx <= 1'b0;
                            bit_idx <= 4'd0;
                            second_pending <= 1'b0;
                        end else begin
                            busy <= 1'b0; tx <= 1'b1;      // idle
                        end
                    end
                end
            end
        end
    end
endmodule
