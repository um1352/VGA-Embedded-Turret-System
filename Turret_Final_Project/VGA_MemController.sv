`timescale 1ns / 1ps

// =======================
// VGA_MemController (No pipeline in MemController)
// - x_pixel, y_pixel, DE, rData를 즉시 사용
// - 왼쪽 가장자리 픽셀 미스얼라인은 GUI로 가린다는 전제
// =======================
module VGA_MemController (
    input  logic        pclk,
    input  logic        reset,
    input  logic btn_rise,
    input  logic        DE,          // 640x480 visible
    input  logic        sw,          // 1: Sobel, 0: original
    input  logic [9:0]  x_pixel,     // 0..639
    input  logic [9:0]  y_pixel,     // 0..479
    // frame buffer side (320x240 RGB565)
    output logic        den,
    output logic [16:0] rAddr,
    input  logic [15:0] rData,
    // VGA ports (Basys3 4:4:4)
    output logic [3:0]  r_port,
    output logic [3:0]  g_port,
    output logic [3:0]  b_port
);



//logic btn_rise;
logic [$clog2(12_500_000-1):0] counter;
logic [$clog2(6-1):0] counter2;
logic active;
logic screen;

//assign led1 = active; assign led2 = screen;
/*
button_detector #(
    .DIV(1000)
    )
    U_BTN_Detector(
    .fclk(pclk),
    .reset(reset),
    .in_button(~btn),
    .rising_edge(btn_rise)
);
*/
always_ff @(posedge pclk or posedge reset) begin
    if (reset) begin
        counter <= 0;
        screen <= 0;
        active <= 0;
        counter2 <= 0;
    end else if (!sw) begin
        if (btn_rise&&!active) begin
            counter <= 0;
            counter2 <= 0;
            active<=1;
        end 
        if (active) begin
            if (counter == 12_500_000-1) begin
                counter <= 0;
                if (counter2 == 6-1) begin
                    active   <= 0;
                    counter2 <= 0;
                    screen   <= 0;
                end else begin
                    screen   <= ~screen;
                    counter2 <= counter2 + 1;
                end
            end else begin
                counter <= counter + 1;
            end
        end
    end else if (sw) begin
        active   <= 0;
        counter2 <= 0;
        if (counter == 12_500_000-1) begin
            screen <= ~screen;
            counter <= 0;
        end else begin
            counter <= counter + 1;
        end
    end
end


    // ------------------------------
    // Params
    // ------------------------------
    localparam int SRC_W = 320;
    localparam int SRC_H = 240;

    // ------------------------------
    // Frame buffer read: no delay
    // ------------------------------
    assign den = 1'b1;           // continuous read
    wire de_vis = DE;

    // 2x 업스케일 좌표를 즉시 계산해 주소 생성
    wire [9:0] src_x = x_pixel >> 1;  // 0..319
    wire [9:0] src_y = y_pixel >> 1;  // 0..239
    assign rAddr = src_y * SRC_W + src_x;

    // ------------------------------
    // Sobel (기존 모듈 그대로 사용)
    // ------------------------------
    logic        de_sobel;
    logic [15:0] sobel_rgb16;

/*    SobelRedFilter #(
        .W(SRC_W),
        .H(SRC_H),
        .R_MIN(10),
        .G_MAX(25),
        .B_MAX(12),
        .RG_DELTA(64),
        .RB_DELTA(48),
        .THICK_H(1'b1),
        .THICK_V(1'b1),
        .SOBEL_TH(120)
        
        //.USE_MAJORITY(1'b0),
        //.K_RED(5)
    ) u_sobel (
        .pclk      (pclk),
        .rstn      (1'b1),        // 필요시 ~reset으로 교체 가능
        .de_in     (de_vis),      // ★ 지연 없이 바로 전달
        .rgb565_in (rData),       // ★ 지연 없이 바로 전달
        .x_in      (src_x),       // ★ 즉시 계산 좌표
        .y_in      (src_y),       // ★ 즉시 계산 좌표
        .de_out    (de_sobel),
        .rgb565_out(sobel_rgb16)
    );*/

    SobelRedFilter #(
        .W(SRC_W),
        .H(SRC_H),
        .S_MIN(150),
        .V_MIN(18),
        .V_MAX(255),
        .RG_DELTA(68),
        .RB_DELTA(48),
        .CR_MIN(150),
        .CB_MAX(120),
        .R_FRAC_NUM(100),
        .R_FRAC_DEN(46),
        .RG_NUM(5),
        .RG_DEN(8),
        .RB_NUM(2),
        .RB_DEN(1),
        .THICK_H(1'b1),
        .THICK_V(1'b1),
        .SOBEL_TH(120)
        
        //.USE_MAJORITY(1'b0),
        //.K_RED(5)
    ) u_sobel (
        .pclk      (pclk),
        .rstn      (1'b1),        // 필요시 ~reset으로 교체 가능
        .de_in     (de_vis),      // ★ 지연 없이 바로 전달
        .rgb565_in (rData),       // ★ 지연 없이 바로 전달
        .x_in      (src_x),       // ★ 즉시 계산 좌표
        .y_in      (src_y),       // ★ 즉시 계산 좌표
        .de_out    (de_sobel),
        .rgb565_out(sobel_rgb16)
    );

    localparam int SOBEL_LAT = 4;  // 실제 측정해서 조정

    // 원본 경로 파이프
    logic [SOBEL_LAT-1:0] de_orig_pipe;
    logic [         15:0] rgb_orig_pipe[0:SOBEL_LAT-1];

    always_ff @(posedge pclk or posedge reset) begin
        if (reset) begin
            de_orig_pipe <= '0;
            for (int i = 0; i < SOBEL_LAT; i++) rgb_orig_pipe[i] <= 16'h0000;
        end else begin
            de_orig_pipe     <= {de_orig_pipe[SOBEL_LAT-2:0], DE};
            rgb_orig_pipe[0] <= DE ? rData : 16'h0000;
            for (int i = 1; i < SOBEL_LAT; i++)
            rgb_orig_pipe[i] <= rgb_orig_pipe[i-1];
        end
    end

    wire         de_orig_lat = de_orig_pipe[SOBEL_LAT-1];
    wire  [15:0] pix_orig_lat = rgb_orig_pipe[SOBEL_LAT-1];

    // ------------------------------
    // Output select (Sobel / Original)
    // ------------------------------
    logic [15:0] pix_out;
    logic        de_out;

    always_comb begin
        if (screen) begin
            pix_out = sobel_rgb16;
            de_out  = de_sobel;  // Sobel 내부 파이프라인에 정렬됨
        end else begin
            pix_out = pix_orig_lat;  // 원본은 지연 없음
            de_out  = de_orig_lat;
        end
    end

    // RGB 4:4:4 출력
    assign r_port = de_out ? pix_out[15:12] : 4'h0;
    assign g_port = de_out ? pix_out[10:7] : 4'h0;
    assign b_port = de_out ? pix_out[4:1] : 4'h0;

endmodule



// =======================
// SobelRedFilter (강화된 빨강 마스크 + 엣지 두껍게)
// - 모듈 인터페이스 동일
// - 항상 pclk 동기, rstn=1 동작/0 클리어
// =======================
module SobelRedFilter #(
    parameter int W = 320,
    parameter int H = 240,
    // === HSV 기반 파라미터 (조명 강인성) ===
    parameter int S_MIN   = 60,   // 채도 하한(0..255)
    parameter int V_MIN   = 30,   // 명도 하한(0..255)
    parameter int V_MAX   = 255,  // 명도 상한(0..255)
    // Hue 근사: R 최대 + 지배도
    parameter int RG_DELTA = 64,  // R8 >= G8 + 64
    parameter int RB_DELTA = 48,  // R8 >= B8 + 48

    // === 추가 분리 파라미터(주황 억제) ===
    // YCbCr 게이트(빨강일수록 Cr↑, Cb↓)
    parameter int CR_MIN = 150,   // 권장 시작 150~170
    parameter int CB_MAX = 120,   // 권장 시작 100~130
    // 비율식 임계(정수 비교용)
    // R/Σ ≥ 0.46  <=> 100*R ≥ 46*(R+G+B)
    parameter int R_FRAC_NUM = 100,
    parameter int R_FRAC_DEN = 46,
    // R/G ≥ 1.6  <=> 5*R ≥ 8*G
    parameter int RG_NUM = 5,     // 분자
    parameter int RG_DEN = 8,     // 분모
    // R/B ≥ 2.0  <=> R ≥ 2*B
    parameter int RB_NUM = 1,
    parameter int RB_DEN = 2,

    // 엣지 두께 옵션 / 소벨 임계
    parameter bit THICK_H = 1'b1,
    parameter bit THICK_V = 1'b1,
    parameter int SOBEL_TH = 120
) (
    input  logic        pclk,
    input  logic        rstn,
    input  logic        de_in,
    input  logic [15:0] rgb565_in,
    input  logic [ 9:0] x_in,
    input  logic [ 9:0] y_in,
    output logic        de_out,
    output logic [15:0] rgb565_out
);
    // --- RGB565 → 8b ---
    logic [4:0] R5;  logic [5:0] G6;  logic [4:0] B5;
    assign R5 = rgb565_in[15:11];
    assign G6 = rgb565_in[10:5];
    assign B5 = rgb565_in[4:0];

    logic [7:0] R8, G8, B8;
    assign R8 = {R5, R5[4:2]};
    assign G8 = {G6, G6[5:4]};
    assign B8 = {B5, B5[4:2]};

    // =========================
    // HSV 근사 마스크 계산부
    // =========================
    // Cmax/Cmin/Δ (0..255)
    logic [7:0] cmax, cmin, delta;
    always_comb begin
        cmax  = (R8 >= G8) ? ((R8 >= B8) ? R8 : B8) : ((G8 >= B8) ? G8 : B8);
        cmin  = (R8 <= G8) ? ((R8 <= B8) ? R8 : B8) : ((G8 <= B8) ? G8 : B8);
        delta = cmax - cmin;
    end

    // S ≥ S_MIN  <=>  255*Δ ≥ S_MIN*Cmax  (Cmax=0이면 S=0)
    // V 범위 체크: V=cmax
    localparam [8:0] RG_DEL9 = RG_DELTA[8:0];
    localparam [8:0] RB_DEL9 = RB_DELTA[8:0];

    logic s_ok, v_ok, hue_like_red;
    always_comb begin
        // s_ok (255≈256 근사)
        if (cmax == 8'd0) s_ok = 1'b0;
        else s_ok = ( {delta,8'd0} >= ( cmax * S_MIN[7:0] ) );

        // v_ok
        v_ok = (cmax >= V_MIN[7:0]) && (cmax <= V_MAX[7:0]);

        // hue_like_red (나눗셈 없이)
        hue_like_red = (R8 >= G8) && (R8 >= B8)
                     && ( {1'b0,R8} >= {1'b0,G8} + RG_DEL9 )
                     && ( {1'b0,R8} >= {1'b0,B8} + RB_DEL9 );
    end

    // --- Y(그레이) 즉시값: Y_now ≈ (2R + 5G + B) >> 3 ---
    wire [10:0] sum_now = (R8<<1) + (G8*5) + B8;
    wire [7:0]  Y_now   = sum_now[10:3];

    // =========================
    // (추가) YCbCr 게이트 + 비율식
    // =========================
    // 간단 정수 근사: Cr ≈ 128 + 2*(R - Y), Cb ≈ 128 + 2*(B - Y)
    function automatic [7:0] clamp8(input signed [9:0] v);
        if      (v <  10'sd0)   clamp8 = 8'd0;
        else if (v > 10'sd255)  clamp8 = 8'd255;
        else                    clamp8 = v[7:0];
    endfunction

    logic signed [9:0] cr_tmp = ( $signed({1'b0,R8}) - $signed({2'b00,Y_now}) ) <<< 1;
    logic signed [9:0] cb_tmp = ( $signed({1'b0,B8}) - $signed({2'b00,Y_now}) ) <<< 1;
    logic [7:0] Cr = clamp8(cr_tmp + 10'sd128);
    logic [7:0] Cb = clamp8(cb_tmp + 10'sd128);

    wire ycbcr_red = (Cr >= CR_MIN[7:0]) && (Cb <= CB_MAX[7:0]);

    // 비율식(정수 교차곱으로 비교)
    logic [9:0] sumRGB = R8 + G8 + B8; // 0..765
    wire ratio_rfrac_ok = ( (R_FRAC_NUM * R8) >= (R_FRAC_DEN * sumRGB) );
    wire ratio_rg_ok    = ( (RG_NUM * R8)    >= (RG_DEN    * G8)     );
    wire ratio_rb_ok    = ( (RB_NUM * R8)    >= (RB_DEN    * B8)     );
    wire ratio_red      = ratio_rfrac_ok && ratio_rg_ok && ratio_rb_ok;

    // 최종 빨강 마스크(색상)
    logic red_mask_in;
    always_ff @(posedge pclk) begin
        if (!rstn) red_mask_in <= 1'b0;
        else       red_mask_in <= de_in
                                 && s_ok && v_ok && hue_like_red
                                 && ycbcr_red && ratio_red;
    end

    // --- Y 레지스터 (소벨 입력용) ---
    logic [7:0] Y_in;
    always_ff @(posedge pclk) begin
        if (!rstn)          Y_in <= '0;
        else if (de_in)     Y_in <= Y_now;
        else                Y_in <= '0;
    end

    // --- 3x3 윈도우 (라인버퍼 2 + 시프트) ---
    (* ram_style = "block" *) logic [7:0] LB0 [0:W-1];  // y-1
    (* ram_style = "block" *) logic [7:0] LB1 [0:W-1];  // y-2
    (* ram_style = "block" *) logic       LB0m[0:W-1]; // mask y-1
    (* ram_style = "block" *) logic       LB1m[0:W-1]; // mask y-2

    logic [7:0] y0_in, y1_in;
    logic m0_in, m1_in;

    logic [7:0] w00, w01, w02, w10, w11, w12, w20, w21, w22;
    logic       m00, m01, m02, m10, m11, m12, m20, m21, m22;

    always_ff @(posedge pclk) begin
        if (!rstn) begin
            {w00, w01, w02, w10, w11, w12, w20, w21, w22} <= '{default:8'd0};
            {m00, m01, m02, m10, m11, m12, m20, m21, m22} <= '{default:1'b0};
            y0_in <= 0; y1_in <= 0; m0_in <= 0; m1_in <= 0;
        end else if (de_in) begin
            // 과거 두 줄 읽기
            y1_in <= LB1[x_in];
            y0_in <= LB0[x_in];
            m1_in <= LB1m[x_in];
            m0_in <= LB0m[x_in];

            // 시프트
            {w00, w01} <= {w01, w02};  w02 <= y1_in;
            {w10, w11} <= {w11, w12};  w12 <= y0_in;
            {w20, w21} <= {w21, w22};  w22 <= Y_in;

            {m00, m01} <= {m01, m02};  m02 <= m1_in;
            {m10, m11} <= {m11, m12};  m12 <= m0_in;
            {m20, m21} <= {m21, m22};  m22 <= red_mask_in;

            // 라인버퍼 갱신
            LB1[x_in]  <= LB0[x_in];
            LB0[x_in]  <= Y_in;
            LB1m[x_in] <= LB0m[x_in];
            LB0m[x_in] <= red_mask_in;
        end
    end

    // --- Sobel |Gx|+|Gy| ---
    logic signed [11:0] gx, gy;
    logic [11:0] mag, ax, ay;
    always_comb begin
        gx = ($signed({1'b0, w02}) + ($signed({1'b0, w12}) <<< 1) + $signed({1'b0, w22}))
           - ($signed({1'b0, w00}) + ($signed({1'b0, w10}) <<< 1) + $signed({1'b0, w20}));
        gy = ($signed({1'b0, w00}) + ($signed({1'b0, w01}) <<< 1) + $signed({1'b0, w02}))
           - ($signed({1'b0, w20}) + ($signed({1'b0, w21}) <<< 1) + $signed({1'b0, w22}));
        ax = (gx[11] ? -gx : gx);
        ay = (gy[11] ? -gy : gy);
        mag = ax + ay;
    end

    // --- 색 경계: 모폴로지 경계(0<합<9) ---
    logic [3:0] sum3x3;
    always_comb begin
        sum3x3 = m00+m01+m02+m10+m11+m12+m20+m21+m22; // 0..9
    end
    wire red_boundary = (sum3x3 != 4'd0) && (sum3x3 != 4'd9);

    // --- 엣지/두께/파이프/출력 ---
    logic edge_bin;
    always_ff @(posedge pclk) begin
        if (!rstn) edge_bin <= 1'b0;
        else edge_bin <= (mag >= SOBEL_TH) && red_boundary && (x_in > 1) && (y_in > 1);
    end

    logic edge_prev1, edge_prev2, edge_prev3;
    logic thick_edge;

    // 이전 라인 엣지 ping-pong 메모리
    logic bank_wr, bank_rd;
    (* ram_style = "distributed" *) logic E0[0:W-1];
    (* ram_style = "distributed" *) logic E1[0:W-1];

    // 라인 시작에서 bank 스왑
    always_ff @(posedge pclk) begin
        if (!rstn) begin
            bank_wr <= 1'b0; bank_rd <= 1'b0;
        end else if (de_in && (x_in == 0)) begin
            bank_wr <= ~bank_wr;  // 이번 라인 기록
            bank_rd <= bank_wr;   // 이전 라인 읽기
        end
    end

    // 이전 라인 주변 읽기(경계 보호)
    wire e_up_c  = THICK_V ? (bank_rd ? E1[x_in]   : E0[x_in])   : 1'b0;
    wire e_up_l  = (THICK_V && (x_in > 0))   ? (bank_rd ? E1[x_in-1] : E0[x_in-1]) : 1'b0;
    wire e_up_r  = (THICK_V && (x_in < W-1)) ? (bank_rd ? E1[x_in+1] : E0[x_in+1]) : 1'b0;
    wire e_up_l2 = (THICK_V && (x_in > 1))   ? (bank_rd ? E1[x_in-2] : E0[x_in-2]) : 1'b0;
    wire e_up_r2 = (THICK_V && (x_in < W-2)) ? (bank_rd ? E1[x_in+2] : E0[x_in+2]) : 1'b0;

    always_ff @(posedge pclk) begin
        if (!rstn) begin
            edge_prev1 <= 1'b0;
            edge_prev2 <= 1'b0;
            edge_prev3 <= 1'b0;
            thick_edge <= 1'b0;
        end else if (de_in) begin
            // 윗줄 기록
            if (bank_wr) E1[x_in] <= edge_bin;
            else         E0[x_in] <= edge_bin;

            // 가로 확장
            if (x_in == 0) begin
                edge_prev1 <= 1'b0;
                edge_prev2 <= 1'b0;
                edge_prev3 <= 1'b0;
            end else begin
                edge_prev3 <= edge_prev2;   // x-3
                edge_prev2 <= edge_prev1;   // x-2
                edge_prev1 <= edge_bin;     // x-1
            end

            // 합성
            thick_edge <= edge_bin
                        | (THICK_H ? (edge_prev1 | edge_prev2 | edge_prev3) : 1'b0)
                        | e_up_c | e_up_l | e_up_r | e_up_l2 | e_up_r2;
        end else begin
            edge_prev1 <= 1'b0;
            edge_prev2 <= 1'b0;
            edge_prev3 <= 1'b0;
            thick_edge <= 1'b0;
        end
    end

    // ===== 정렬 파이프 =====
    localparam int LAT = 4;

    // DE 파이프
    logic [LAT-1:0] de_pipe;
    always_ff @(posedge pclk) begin
        if (!rstn) de_pipe <= '0;
        else       de_pipe <= {de_pipe[LAT-2:0], de_in};
    end
    assign de_out = de_pipe[LAT-1];

    // 원본 RGB 파이프
    logic [15:0] rgb_pipe [0:LAT-1];
    always_ff @(posedge pclk) begin
        if (!rstn) begin
            for (int i=0;i<LAT;i++) rgb_pipe[i] <= 16'h0000;
        end else begin
            rgb_pipe[0] <= de_in ? rgb565_in : 16'h0000;
            for (int i=1;i<LAT;i++) rgb_pipe[i] <= rgb_pipe[i-1];
        end
    end

    // 최종 출력: 엣지와 동일 시점의 원본색과 합성(노란선)
    logic [15:0] edge_rgb;
    always_comb begin
        edge_rgb = thick_edge ? 16'hFFE0 : rgb_pipe[LAT-1];
    end
    assign rgb565_out = edge_rgb;

endmodule








