# 🔴 적 식별 방산 터렛 (Basys3 + OV7670 + STM32)

> **Vision + FPGA + MCU**: OV7670 카메라로 빨간색(RED)을 감지해 3×3 구역으로 표적을 표시하고, 9비트 UART로 STM32 터렛 제어까지! 🚀

<p align="center">
  <img src="https://img.shields.io/badge/Board-Basys3%20(Artix--7)-blue" />
  <img src="https://img.shields.io/badge/Camera-OV7670-green" />
  <img src="https://img.shields.io/badge/MCU-STM32%20Nucleo-orange" />
  <img src="https://img.shields.io/badge/Interface-UART%209N1%20(9--bit)-purple" />
</p>

---

## ✨ 프로젝트 한눈에 보기 (TL;DR)

* **주제**: 적(RED) 색상 자동 식별 방산 터렛
* **알고리즘**: RGB444 표시 기준의 **빨간색(R)** 우세성 검사 (내부 처리 RGB565 기반)
* **하드웨어**: **Basys3 + OV7670**로 영상처리 & 3×3 구역 LED 표시 → **STM32 Nucleo**와 **9비트 UART** 통신
* **디스플레이**: Basys3 **VGA → HDMI 어댑터**로 모니터 연결 (640×480\@60Hz)
* **목표(차기)**: Nucleo가 수신한 9비트 패턴(예: `9'b101_101_101`)을 해석해 **터렛(서보/발사 장치)** 를 순차 제어

---

## 🧭 시스템 아키텍처

```
OV7670 ──(PCLK/HREF/VSYNC/D[7:0])──▶ [Basys3]
  │                                    │
  │   (SCCB/I2C 설정)                   │  ┌─────────────────────────┐
  └──────────────▶ OV7670_Master ─────▶  │  OV7670_MemController    │
                                         │  (RGB565 캡처, 320×240)  │
                                         └──────────┬───────────────┘
                                                    ▼
                                        frame_buffer (BRAM, 320×240)
                                        ├─ VGA_MemController ──▶ VGA 포트(4:4:4)
                                        └─ 3×3 RED 감지 → led[8:0], UART 9bit TX

                               VGA(640×480) ──▶ HDMI 어댑터 ──▶ 모니터

led[8:0] (Basys3) ────────▶ LED 패널
UART TX(9N1) ─────────────▶ STM32 Nucleo USART1_RX(PA10) ──▶ 터렛 제어
```

flowchart TB
  %% ========== Camera side ==========
  subgraph CAM["OV7670 Camera"]
    OV[OV7670 Sensor\nPCLK/HREF/VSYNC/D[7:0]]
    SCCB[SCCB_Core\n(OV7670_Master)]
    SCCB -- "SCL/SDA" --> OV
  end

  %% ========== Basys3 (FPGA) ==========
  subgraph FPGA["Basys3 (Artix-7)"]
    direction TB
    MC[OV7670_MemController\nRGB565 capture @320×240]
    FB[frame_buffer (BRAM)\n320×240 RGB565\n+ 3×3 RED detector (5×5 ROI)]
    VDEC[VGA_Decoder\n640×480@60Hz sync]
    VMC[VGA_MemController\naddr gen & RGB565→RGB444]
    GRAY[GrayScaleFilter]
    GUI[GUIMaker (overlay)]
    MUX["mux_3×1\n(vga / gray / gui)"]
    TEST[test_buffer\nzone debounce]
    UART9[top_uart9_basys3\nUART 9N1 TX]
  end

  %% ========== STM32 ==========
  subgraph MCU["STM32 Nucleo"]
    STM["USART1_RX (PA10)\n수신 & 터렛 제어"]
  end

  %% --- connections: camera -> capture -> FB ---
  OV -- "PCLK/HREF/VSYNC/D[7:0]" --> MC
  MC --> FB

  %% --- display path ---
  VDEC --> VMC
  FB -->|rData| VMC
  VMC -->|rgb444| GRAY
  VMC -->|rgb444| GUI
  VMC -->|rgb444| MUX
  GRAY --> MUX
  GUI  --> MUX
  MUX  -->|r,g,b| VGA["VGA 4:4:4 → HDMI 어댑터 → 모니터"]
  VDEC -- "h_sync / v_sync / DE / x,y" --> VGA

  %% --- detection + UART path ---
  FB -->|data[8:0]| TEST
  TEST -->|led[8:0]| LED["Basys3 LED[8:0]"]
  TEST -->|data_detect[8:0]| UART9
  UART9 --> STM

  %% --- misc clocks (개념선) ---
  VDEC -. pclk/fclk .- MUX
  VDEC -. ov7670_xclk .- OV



---

## 📦 저장소 구조 & 역할

> 업로드된 주요 SystemVerilog 파일을 **모듈 단위**로 설명합니다.

| 파일                        | 핵심 역할                                                                                                             | 비고                         |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------- | -------------------------- |
| `VGA_Camera_Display.sv`   | **Top (FPGA)**. 카메라 캡처 → 프레임버퍼 → VGA 출력 파이프라인을 연결하고, 표시 모드(원본/그레이/GUI)를 선택.                                       | XCLK 생성, 서브모듈 인스턴스 연결 허브   |
| `OV7670_MemController.sv` | OV7670 8bit 버스에서 **RGB565 픽셀 조립** 및 **다운샘플(640×480 → 320×240)** 후 BRAM 주소/데이터/WE 생성.                              | HREF/VSYNC 카운터로 `wAddr` 증가 |
| `frame_buffer.sv`         | 듀얼 포트 **프레임버퍼(BRAM)**. 카메라 도메인(wclk)에서 쓰기, VGA 도메인에서 읽기. 동시에 **3×3 구역 RED 감지**(5×5 윈도우 평균 기반) 수행, `data[8:0]` 출력. | RED 판정 파라미터 제공(아래 참조)      |
| `VGA_MemController.sv`    | VGA 타이밍 `DE/x/y`로부터 **320×240 메모리 주소 생성** 후 픽셀을 **4:4:4로 변환**해 Basys3 VGA 포트에 출력.                                 | 픽셀 복제(×2)로 640×480 화면 채움   |
| `VGA_Decoder.sv`          | **640×480\@60Hz 타이밍** 생성. `h_sync/v_sync/DE`와 `x_pixel/y_pixel` 카운터, `pclk/fclk` 제공.                              | 표준 VGA 파라미터                |
| `SCCB_Core.sv`            | `OV7670_Master`: SCCB(I²C 유사) **400kHz** 상태기계. **레지스터 ROM**에 정의된 시퀀스로 OV7670 초기화(RGB565, 클럭/감마 등).                | `startSig`로 시퀀스 시작         |
| `GrayScaleFilter.sv`      | RGB444 입력을 그레이스케일로 변환(`gray = 77R + 154G + 25B`, 12bit → 상위 4bit 복제).                                             | 표시 모드 2에서 사용               |
| `GUIMaker.sv`             | VGA 좌표로 **3×3 그리드/표적(원)** 오버레이. 빨간색 타겟/초록색 그리드 등 시각화.                                                             | 필요 시 코멘트 해제하여 사용           |
| `top_uart9_basys3.sv`     | **9비트 UART 송신 Top**. 버튼 트리거/디바운스 + `uart9_tx`로 `data_detect[8:0]` 패턴을 전송.                                         | Nucleo 연동용                 |
| `test_buffer.sv`          | 9개 구역의 감지 카운터/임계 기반 **안정화(디바운스)** 후 `led[8:0]` 점등.                                                                | 실험용 필터                     |

> **참고**: `button_detector`, `uart9_tx` 등 보조 모듈은 별도 파일/프로젝트에 있을 수 있습니다.

---

## 🔎 RED 식별 알고리즘 (5×5 윈도우 평균)

* 프레임버퍼는 RGB565(5-6-5) 포맷으로 저장합니다.
* 각 구역(zone)마다 5×5 픽셀의 합을 누적한 뒤, **나눗셈 없이** 임계값과 비교(25배 스케일)로 평균 조건을 검사합니다.

**파라미터(예시, `frame_buffer.sv`)**

* `R_MIN = 10` (0..31) : 빨강 평균 하한
* `G_MAX = 32` (0..63) : 초록 평균 상한
* `B_MAX = 16` (0..31) : 파랑 평균 상한
* `R_MINUS_G = 4` : `R - (G/2) ≥ 4`
* `R_MINUS_B = 4` : `R - B ≥ 4`
* `SCALE = 25` : 5×5 샘플 개수

**판정식(스케일 비교)**

```
(sumR ≥ 25·R_MIN) ∧ (sumG ≤ 25·G_MAX) ∧ (sumB ≤ 25·B_MAX)
∧ ((sumR − sumG/2) ≥ 25·R_MINUS_G) ∧ ((sumR − sumB) ≥ 25·R_MINUS_B)
```

* 조건을 만족하면 해당 구역의 `data[k] = 1` → **LED/ UART 비트 셋**

> 구역은 화면 3×3 분할(9분할)이며, 각 구역 내부에 **5×5 픽셀 ROI**를 지정해 빠르고 가벼운 연산으로 실시간 판단합니다.

---

## 🖥️ 디스플레이 파이프라인

1. **카메라 캡처**: `OV7670_MemController`가 HREF/VSYNC에 따라 RGB565 픽셀을 순차 저장 (320×240)
2. **프레임버퍼 읽기**: `VGA_MemController`가 VGA 타이밍(`DE/x/y`)을 1/2 스케일 주소로 변환해 픽셀을 읽고, **RGB444**로 매핑
3. **필터/GUI**: 선택에 따라 원본/그레이/GUI 오버레이 표시 (`VGA_Camera_Display`)
4. **출력**: Basys3 VGA 포트 → (VGA→HDMI 어댑터) → 모니터

---

## 🔩 하드웨어 결선 (요약)

> 보드는 **3.3V 로직**입니다. GND는 **공통**!

### OV7670 ↔ Basys3

| OV7670     | Basys3 | 설명                  |
| ---------- | ------ | ------------------- |
| XCLK       | FPGA 핀 | 카메라 구동 클럭(25MHz 내외) |
| PCLK       | FPGA 핀 | 픽셀 클럭               |
| VSYNC/HREF | FPGA 핀 | 프레임/라인 동기           |
| D\[7:0]    | FPGA 핀 | 픽셀 데이터              |
| SIOC/SIOD  | FPGA 핀 | SCCB(I²C 유사) 설정     |

> 정확한 핀네임은 보드 XDC에 맞춰 조정하세요.

### Basys3 VGA → 모니터

* Basys3 VGA 4:4:4 → **VGA to HDMI 어댑터** → 모니터 입력 (해상도 640×480\@60)

### Basys3 ↔ STM32 (UART 9-bit)

| Basys3    | STM32 Nucleo       | 비고                             |
| --------- | ------------------ | ------------------------------ |
| `uart_tx` | `PA10 (USART1_RX)` | **9N1**, 115200 (초기엔 38400 권장) |
| GND       | GND                | 공통 그라운드                        |

> Nucleo에서 **USART2(PA2/PA3)** 는 기본적으로 **ST-LINK VCP**에 연결되어 충돌 위험이 있으니 **USART1**(PA10/PA9) 사용을 권장합니다.

---

## 🧾 9비트 UART 프로토콜 (Basys3 → STM32)

* 프레임: **9N1 (9 data, No parity, 1 stop)**
* 비트 맵(상위→하위): `[TL, TM, TR, ML, MM, MR, BL, BM, BR]`
  (T/M/B: Top/Middle/Bottom, L/M/R: Left/Middle/Right)
* 예시

  * `9'b111_000_000` → 상단 3구역 모두 RED
  * `9'b101_101_101` → **1,3,4,6,7,9** 구역 RED (목표 시나리오)
  * `9'b100_000_001` → 좌상, 우하 RED

STM32 측 비교 예시(수신값 `rx`는 9비트 마스크 필요):

```c
if ((rx & 0x01FF) == 0x101) { /* TL & BR */ }
```

---

## 🛠️ 빌드 & 실행

### FPGA (Vivado)

1. 보드: **Digilent Basys3 (Artix-7)** 선택
2. 소스 추가: 본 저장소의 `.sv` 파일들 + 보조 모듈(`uart9_tx`, `button_detector` 등)
3. 제약(XDC): OV7670, VGA, UART 핀 매핑 반영
4. 합성/구현/비트스트림 생성 → **프로그램**

### MCU (STM32CubeIDE)

1. 보드: **Nucleo-F401RE/F411RE** 등
2. `USART1` 활성화, **WordLength: 9B**, **Parity: None**, **Mode: RX**
3. 핀: `PA10=USART1_RX(AF7)`
4. 수신 루프: `HAL_UART_Receive(&huart1, (uint8_t*)&rx, 1, timeout)` → `rx &= 0x01FF` 후 매핑 처리

---

## 🧪 디버깅 팁

* **VGA 동기**: 패턴/그리드가 어긋나면 `VGA_Decoder` 타이밍 상수 확인
* **카메라**: SCCB 시퀀스가 모두 쓰였는지(`0xFFFF` 종료)와 XCLK 주파수 확인
* **RED 감지**: `R_MIN/G_MAX/B_MAX`/`R_MINUS_G/B` 값 튜닝 (조명/노이즈 환경에 맞춤)
* **UART**: 라인 공통 GND, 9N1 설정 일치, 오버런(ORE) 클리어

---

## 🚀 Roadmap

* [ ] 터렛(서보 2축 + 발사기) **시퀀스 제어** (예: `101_101_101` → 1→3→4→6→7→9 순차 발사)
* [ ] RED 외 색상/형태 감지로 확장
* [ ] 스트리밍/기록(AXI-Stream, DMA) 추가
* [ ] 간단한 Kalman/Tracker로 표적 추적

---

## 📚 주석/참고

* GUI/그레이 모듈은 필요 시 표시 파이프라인에 인서트하여 시각화에 활용
* XDC/핀맵은 보드 리비전에 따라 상이할 수 있으므로 실물 실크/매뉴얼 기준으로 업데이트 권장

---

## 📝 라이선스

MIT 혹은 프로젝트 정책에 맞게 지정하세요.

> *“Identify ➜ Decide ➜ Engage” — 가벼운 하드웨어 가속 영상처리로 실시간 표적 인지/제어를 구현했습니다.*
