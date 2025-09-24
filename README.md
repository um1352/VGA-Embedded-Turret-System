# 🔴 적 식별 방산 터렛 (Basys3 + OV7670 + STM32)

> **Vision + FPGA + MCU + PC HUD**: OV7670 카메라로 빨간색(RED)을 감지해 3×3 구역 타겟을 만들고, Basys3가 9비트 패턴을 송신 → STM32가 서보·모터로 터렛 시퀀스를 수행 → PC(PyQt HUD)가 상황을 시각화합니다.

<p align="center">
  <img src="https://img.shields.io/badge/Board-Basys3%20(Artix--7)-blue" />
  <img src="https://img.shields.io/badge/Camera-OV7670-green" />
  <img src="https://img.shields.io/badge/MCU-STM32%20Nucleo-orange" />
  <img src="https://img.shields.io/badge/Interface-UART%209N1%20(9--bit)-purple" />
  <img src="https://img.shields.io/badge/PC-PyQt5%20HUD-lightgrey" />
</p>

---

## ✨ TL;DR

* **주제**: RED 색상 자동 식별 및 3×3 구역 기반 터렛 제어
* **영상처리**: RGB565 프레임버퍼에서 9구역 ROI별 RED 우세성(5×5 윈도 평균) 판단
* **표시**: Basys3 VGA 640×480(×2 스케일) + GUI 오버레이 옵션
* **통신**: Basys3 → STM32 **9N1(9-bit) UART**, PC HUD는 시리얼 패킷(저/고/\n) 수신 표시
* **제어**: STM32가 **최소 이동 경로 기반**으로 목표 구역을 순차 방문·발사, **부드러운 서보 이동**

---

## 🧭 시스템 아키텍처

```
OV7670 ──(PCLK/HREF/VSYNC/D[7:0])──▶ Basys3 (Artix-7)
  │                                     │
  │  (SCCB 설정)                         │   ┌──────────────────────────────┐
  └────────▶ SCCB_Core ────────────────▶   │  OV7670_MemController         │
                                            │  (RGB565 capture @ 320×240)   │
                                            └───────────┬───────────────────┘
                                                        ▼
                                            frame_buffer (BRAM, 320×240 RGB565)
                                             ├─▶ VGA_MemController ─▶ VGA(640×480)
                                             └─▶ 3×3 RED Detect ─▶ led[8:0]
                                                                └─▶ UART(9N1)
                                                                     └─▶ STM32(USART1_RX)
                                                                             └─▶ Pan/Tilt Servo, Fire 모터

PC(PyQt HUD) ◀─────(USB-Serial, LED 패턴 패킷 수신·표시)─────── Basys3/STM32
```

---

## 📦 저장소 구조 (16개)

| 경로/파일                     | 역할 요약                                                |
| ------------------------- | ---------------------------------------------------- |
| `VGA_Camera_Display.sv`   | Top(표시 파이프라인 허브): 모드 선택(원본/그레이/GUI), XCLK/서브모듈 연결    |
| `OV7670_MemController.sv` | OV7670 8bit 스트림을 RGB565로 조립, 320×240 쓰기 주소/WE 생성     |
| `frame_buffer.sv`         | 듀얼포트 BRAM 프레임버퍼. VGA에서 읽고, 내부에서 **9구역 RED 감지** 비트 생성 |
| `VGA_MemController.sv`    | VGA 좌표→메모리 주소 변환(×2 스케일), RGB444 출력                  |
| `VGA_Decoder.sv`          | 640×480\@60Hz 타이밍(hsync/vsync/DE, x/y 카운터)           |
| `SCCB_Core.sv`            | OV7670 초기설정 I²C(SCCB) 400kHz 상태기계                    |
| `GrayScaleFilter.sv`      | RGB→그레이 변환 모듈(옵션 표시 모드)                              |
| `GUIMaker.sv`             | 3×3 그리드·표적 오버레이 렌더                                   |
| `VGA_Camera_Display.sv`   | (상동) 최상위 표시 및 모듈 연결 허브                               |
| `top_uart9_basys3.sv`     | Basys3 9비트 UART 송신 Top(버튼/디바운스 포함)                   |
| `usb_uart.sv`             | FPGA UART 보조(테스트/브릿지에 사용)                            |
| `button_detector.sv`      | 버튼 디바운스·에지 검출                                        |
| `test_buffer.sv`          | 9구역 디텍션 안정화(카운터/임계) 및 LED 매핑 실험                      |
| `Basys-3-Master.xdc`      | 핀 매핑·보드 제약 XDC                                       |
| `STM32/main.c, main.h`    | 터렛 제어(서보/모터), 9비트 수신, **최적 경로 실행/실시간 추적** 모드         |
| `PC/main.py`              | PyQt HUD(카메라 보기+3×3 오버레이), 시리얼 패킷 수신 로그              |

> 세부 파라미터/레지스터 시퀀스는 소스 주석 참고.

---

## 🔎 RED 감지 로직(개요)

* 포맷: RGB565(5-6-5)
* 각 구역에 5×5 ROI 샘플 합을 누적 → **나눗셈 없이** 임계 비교(×25 스케일)
* 예시 조건: `R ≥ R_MIN`, `G ≤ G_MAX`, `B ≤ B_MAX`, `R−G/2 ≥ a`, `R−B ≥ b`
* 충족 시 해당 구역 비트 셋 → `led[8:0]` / UART 9비트 전송

---

## 🧾 9비트 UART 프로토콜

* 프레임: **9N1** (9 data, no parity, 1 stop)
* 비트 맵(MSB→LSB): `[TL, TM, TR, ML, MM, MR, BL, BM, BR]`
* 예: `9'b101_101_101` (1,3,4,6,7,9 구역)

> STM32는 USART1 **RX 전용(9-bit)** 로 수신, PC HUD는 (저/고/\n) 3바이트 패킷을 읽어 9비트로 재조합(테스트/모니터링용).

---

## 🖥️ 디스플레이 & HUD

* **FPGA VGA**: 320×240 프레임버퍼를 640×480으로 스케일 출력, 그레이/GUI 오버레이 옵션
* **PC(PyQt HUD)**: 웹캠/캡처 영상 위에 3×3 그리드를 오버레이, 시리얼 패킷을 수신해 로그 창에 구역 번호를 실시간 표시
* HUD 단축키: `H` → 화질 개선 토글(블러+감마+샤프닝)

---

## 🔩 하드웨어 결선 요약

### OV7670 ↔ Basys3

* XCLK, PCLK, VSYNC/HREF, D\[7:0], SIOC/SIOD(SCCB)
* 3.3V 로직, GND 공통

### Basys3 VGA → 모니터

* 4:4:4 VGA → (VGA→HDMI 어댑터) → 640×480\@60Hz

### Basys3 ↔ STM32

* `uart_tx` → `PA10 (USART1_RX)` (Nucleo)
* **GND 공통**, 9N1 설정 일치

---

## 🛠️ 빌드 & 실행

### 1) FPGA (Vivado)

1. 보드: Digilent **Basys3 (Artix‑7)**
2. 소스 추가: `.sv` + `Basys-3-Master.xdc`
3. 합성/구현/비트스트림 → 프로그래밍

### 2) STM32 (STM32CubeIDE)

1. 보드: Nucleo‑F401RE/F411RE 등
2. `USART1`: **9-bit, Parity None, Stop 1**, **RX only**, Baud **115200** 권장
3. PWM 타이머: Pan/Tilt/Fire 서보, 모터 채널 설정

### 3) PC HUD (Python 3.9+)

```bash
pip install pyqt5 opencv-python pyserial numpy
python main.py
```

* `SerialThread`의 포트(`COM7`)와 Baud를 실제 환경에 맞게 수정

---

## 🧪 운용/디버깅 팁

* **모드 스위치**: `PC0=HIGH` → UART 패턴 기반 **최적 경로+발사**, `PC0=LOW` → **실시간 추적(발사 없음)**
* **서보 튜닝**: 이동 스텝 딜레이(기본 50ms)로 부드러움/속도 조절
* **RED 파라미터**: 조도에 따라 `R_MIN`, `R−G/2`, `R−B` 등 임계 재튜닝
* **UART**: 9N1 매칭, 라인 GND, 오버런/프레이밍 에러 확인
* **VGA 타이밍**: 싱크 어긋나면 타이밍 상수 재확인

---

## ⚠️ 설정 주의 (Baud/포맷 일치)

* STM32 USART1: **115200 / 9N1 / RX only**
* PC HUD 기본값: `COM7`, **9600 / 8N1 (패킷 3바이트)** → 테스트/모니터링 용도
* 실제 동작 시 **Baud/포맷을 통일**하거나, HUD를 115200/9-bit 환경에 맞게 조정 필요

---

## 🚀 Roadmap

* [ ] 터렛 시퀀스 고급화(연속 표적, 우선순위/재인식)
* [ ] 색상·형태 감지 다중화(RED 외)
* [ ] 간단 추적기(Kalman/EMA) 적용
* [ ] AXI-Stream/DMA 캡처·기록

---

## 📝 License

MIT (또는 프로젝트 정책)

> *Identify → Decide → Engage* — 저지연 하드웨어 가속으로 실시간 표적 인지·제어를 구현합니다.
