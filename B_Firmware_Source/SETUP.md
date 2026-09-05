# STM32CubeIDE Setup — Co-Site Canceller (NUCLEO-F446RE)

## 0. Pin map

| Signal | Pin | Peripheral |
|---|---|---|
| AD8307 OUT (detector) | **PA0** | ADC1_IN0 |
| I control → AD835 #1 Y1 | **PA4** | DAC_OUT1 |
| Q control → AD835 #2 Y1 | **PA5** | DAC_OUT2 |
| Console TX/RX | PA2 / PA3 | USART2 (ST-Link VCP) |
| +3V3 / GND | 3V3 / GND | to your board header |

---

## 1. Create the project

1. **File → New → STM32 Project**
2. **Board Selector** tab → search `NUCLEO-F446RE` → select it → **Next**
3. Name it `canceller` → **Finish**
4. When asked *"Initialize all peripherals with their default Mode?"* → **Yes**
   (this wires up USART2 to the ST-Link VCP for you)

---

## 2. Clock configuration

**Clock Configuration** tab:
- Set **HCLK = 84 MHz** (type 84 into the HCLK box and press Enter; let it auto-solve)
- This gives APB1 = 42 MHz, and **APB1 Timer clocks = 84 MHz**

> If you use a different HCLK, you must recompute the TIM2 prescaler in step 3.

---

## 3. Peripheral configuration (Pinout & Configuration tab)

### ADC1 — detector input
- **Analog → ADC1** → tick **IN0**
- Parameter Settings:
  - Resolution: **12 bits**
  - Continuous Conversion Mode: **Disabled**
  - External Trigger Conversion Source: **Regular Conversion launched by software**
  - **Rank → Sampling Time: `480 Cycles`**  ← **important**

> The AD8307 output has ~12.5 kΩ source impedance. Short sampling times will
> not let the ADC sample-and-hold settle and the readings will be wrong.
> 480 cycles is the safe choice.

### DAC — I and Q outputs
- **Analog → DAC** → tick **OUT1** and **OUT2**
- For both channels:
  - Output Buffer: **Enable**
  - Trigger: **None**

### TIM2 — 10 kHz control loop
- **Timers → TIM2** → Clock Source: **Internal Clock**
- Parameter Settings:
  - Prescaler: **83**
  - Counter Period (ARR): **99**
  - → 84 MHz / 84 / 100 = **10 kHz**
- **NVIC Settings** tab → tick **TIM2 global interrupt**

### USART2 — console
- Already enabled by the board defaults. Confirm:
  - Mode: **Asynchronous**
  - Baud: **115200**, 8 bits, no parity, 1 stop bit
- **NVIC Settings** → tick **USART2 global interrupt**

Then **Ctrl+S** to save and generate code.

---

## 4. Add the source files

1. Copy `canceller.h` and `console.h` into `Core/Inc/`
2. Copy `canceller.c` and `console.c` into `Core/Src/`
3. Right-click the project → **Refresh** (F5)

---

## 5. Edit `main.c`

Paste each block into the matching `USER CODE` section.

### `/* USER CODE BEGIN Includes */`
```c
#include "canceller.h"
#include "console.h"
```

### `/* USER CODE BEGIN PV */`
```c
canc_state_t  g_canc;
canc_mode_t   g_mode = MODE_MANUAL;
static uint8_t g_rx_byte;
volatile uint16_t g_adc_latest = 0;
```

### `/* USER CODE BEGIN 2 */`  (after all the MX_*_Init calls)
```c
  canc_init(&g_canc);
  g_mode = MODE_MANUAL;              /* boot safe: nothing moves until 'a' */

  HAL_DAC_Start(&hdac, DAC_CHANNEL_1);
  HAL_DAC_Start(&hdac, DAC_CHANNEL_2);
  HAL_DAC_SetValue(&hdac, DAC_CHANNEL_1, DAC_ALIGN_12B_R, 2048);
  HAL_DAC_SetValue(&hdac, DAC_CHANNEL_2, DAC_ALIGN_12B_R, 2048);

  HAL_UART_Receive_IT(&huart2, &g_rx_byte, 1);
  console_init();

  HAL_ADC_Start(&hadc1);             /* first conversion; ISR reads it */
  HAL_TIM_Base_Start_IT(&htim2);
```

### `/* USER CODE BEGIN WHILE */` (inside the `while (1)` loop)
```c
    console_poll(&g_canc, &g_mode);
```

### `/* USER CODE BEGIN 4 */`
```c
/* 10 kHz control loop */
void HAL_TIM_PeriodElapsedCallback(TIM_HandleTypeDef *htim)
{
  if (htim->Instance != TIM2) return;

  /* read the conversion started last tick, then start the next one.
     480-cycle sampling ~ 23 us, well inside the 100 us tick. */
  if (HAL_ADC_PollForConversion(&hadc1, 0) == HAL_OK) {
      g_adc_latest = (uint16_t)HAL_ADC_GetValue(&hadc1);
  }
  HAL_ADC_Start(&hadc1);

  if (g_mode == MODE_AUTO) {
      canc_step(&g_canc, g_adc_latest);
  } else {
      g_canc.last_adc = g_adc_latest;   /* keep 'v' live in manual mode */
  }

  HAL_DAC_SetValue(&hdac, DAC_CHANNEL_1, DAC_ALIGN_12B_R,
                   canc_weight_to_dac(g_canc.I));
  HAL_DAC_SetValue(&hdac, DAC_CHANNEL_2, DAC_ALIGN_12B_R,
                   canc_weight_to_dac(g_canc.Q));
}

/* console RX */
void HAL_UART_RxCpltCallback(UART_HandleTypeDef *huart)
{
  if (huart->Instance == USART2) {
      console_on_rx_byte(g_rx_byte);
      HAL_UART_Receive_IT(&huart2, &g_rx_byte, 1);
  }
}
```

---

## 6. Enable float printf

`snprintf("%f")` returns nothing useful unless you enable it:

**Project → Properties → C/C++ Build → Settings → MCU/MPU Settings**
→ tick **Use float with printf from newlib-nano**

Then **Project → Clean**, then **Build**.

---

## 7. Flash and open the console

1. USB cable to the Nucleo's ST-Link port
2. **Run → Debug** (or the hammer, then the green Run arrow)
3. Open a terminal (PuTTY / TeraTerm) on the **STMicroelectronics STLink Virtual COM Port**
   - 115200, 8N1, no flow control
4. Press Enter — you should see the `>` prompt. Type `h` for help.

---

## 8. Bench bring-up (no RF yet)

Do these **in order**. Each is a gate.

### 8.1 Rails, sockets EMPTY
- Ch1 **+**→+5V, Ch1 **−**→GND
- Ch2 **+**→**GND**, Ch2 **−**→−5V ← reversed kills both AD835s
- Current limit **100 mA**
- Nucleo on USB (gives +3V3)
- Meter: **+5.00 / −5.00 / +3.3 / VREF ≈ 0.825 V**

### 8.2 Insert chips
Pin 1 to the notch. Re-check the rails.

### 8.3 Control interface test
At the console, in MANUAL mode, measure **Y1−Y2** at each AD835:

| Command | Expected Y1−Y2 |
|---|---|
| `i0` | 0.000 V |
| `i1` | +0.825 V |
| `i-1` | −0.825 V |
| `q0` / `q1` / `q-1` | same on AD835 #2 |

This proves DAC → divider → chip. **If this fails, stop and fix it before RF.**

### 8.4 Detector path
- `v` with no RF → some low baseline count
- Inject a known level into SMA4 (through the attenuator!) → `v` should rise
- Two known levels give you the slope: should be ~**25 mV/dB** (≈0.78 counts/dB… i.e. ~31 counts per dB is wrong — expect **~0.032 dB per count**, so ~31 counts per dB)

### 8.5 Manual null (the milestone)
- Jammer on, wanted generator **off**
- Hand-tune with `i` / `q` while watching the analyser
- **≥15 dB by hand = hardware proven.** Photograph it.
- If it will not null by hand → **STOP**, debug RF. Do not close the loop.

### 8.6 Close the loop
- Type `a`. Watch the analyser and use `t` to stream telemetry.
- Record depth and time-to-lock.
- `s` shows phase, step size, and whether it has LOCKED.

---

## 9. Two gotchas specific to this board

**PA5 is also the user LED (LD2).** On a NUCLEO-64 the green LED sits on PA5,
which is your Q DAC output. The LED plus its series resistor load the DAC and
will clamp/distort the top of the Q range (above the LED's forward voltage).
Check it: set `q1` and see whether LD2 lights. If it does and your Q range
looks compressed at the top, remove the LD2 solder bridge / series resistor,
or keep Q operation in the lower part of the range. The I channel (PA4) is
unaffected.

**VDDA must be the same 3V3 that feeds your VREF divider.** The DAC reference
is VDDA. If your divider is fed from a different 3.3 V source, the null point
drifts. Take pin 4 of your header from the Nucleo's own 3V3 pin.

---

## 10. Command reference

| Cmd | Action |
|---|---|
| `m` | manual mode |
| `a` | auto mode — resets the search and closes the loop |
| `i0.5` | set I = 0.5 |
| `q-0.3` | set Q = −0.3 |
| `v` | raw ADC (detector calibration) |
| `t` | toggle telemetry streaming |
| `s` | status |
| `h` | help |
