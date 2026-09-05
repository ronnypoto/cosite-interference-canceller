# Firmware Walkthrough — Co-Site Interference Canceller

Firmware documentation for the co-site interference canceller.
This explains what each file does and *why* it is written that way.
Read alongside the source; SETUP.md covers the CubeIDE configuration.

**This document describes the FINAL firmware as submitted**, including the
in-situ calibrations and the workaround for the damaged DAC channel found
during laboratory testing (see report sections 10.2.5 and 9.5).

---

## The one-paragraph version

An interferer arrives on two paths. One path goes to the antenna/receiver
("main"), the other is tapped as a "reference". The board multiplies the
reference by two numbers, **I** and **Q**, to build a *replica* of the
interferer with adjustable amplitude and phase, then subtracts that replica
from the main path in a 180° combiner. What survives is measured by a log
detector. The MCU's only job is to keep hunting for the (I, Q) pair that makes
the surviving signal as small as possible.

```
        I                       Q
        |                       |
  ref --+--> AD835 #1 --> AD835 #2 --> replica --,
                                                  (-) 180° combiner --> residual
  main -------------------------------------(+)--'                        |
                                                                          v
                                                                   AD8307 detector
                                                                          |
                                                                     ADC (PA0)
                                                                          |
                                                              [ algorithm picks I,Q ]
                                                                          |
                                                            DAC (PA5 = I, PA4 = Q)
```

The maths the analog board implements is
`replica = I·ref + Q·(ref shifted 90°)`.
Any amplitude and phase can be produced from those two numbers — that is why
two multipliers are enough, and why the search space is only 2-dimensional.

---

## Files

| File | Role |
|---|---|
| `canceller.h` | State struct, tunables, API |
| `canceller.c` | The search algorithm (LP-V17b) |
| `console.h/.c` | Serial command interface, 115200 8N1 |
| `main.c` | HAL init + the two interrupt callbacks that glue it together |

---

## How the pieces connect at run time

Two things run concurrently:

**1. The 30 kHz control loop** — `HAL_TIM_PeriodElapsedCallback()` in `main.c`,
fired by TIM2 every 33.3 µs (PSC = 83, ARR = 32). Each tick it:
  - reads the ADC conversion started on the *previous* tick
  - starts the next conversion (never blocks waiting — 480-cycle sampling
    takes ~23 µs, which would eat a quarter of the tick if we waited)
  - if in AUTO, calls `canc_step()` to update I and Q
  - writes I and Q to the two DACs

**2. The main loop** — `console_poll()`, running as fast as it can. It handles
serial input/echo and telemetry. Nothing time-critical lives here.

The split matters: anything slow (UART transmit, `snprintf`) stays out of the
interrupt so the 33.3 µs control tick is never missed.

---

## `canceller.h` — the numbers worth understanding

```c
#define DWELL_LEN        1        /* ticks to wait after moving I/Q  */
#define DAC_LSB          0.0005f  /* smallest usable weight step     */
#define MARGIN_DB_BASE   0.15f    /* "is this actually better?" gate */
#define STARTUP_TICKS    30       /* settle before searching         */
#define AVG_MAX          16       /* cap on adaptive averaging       */
#define LOCK_AVG_MIN     2        /* averaging required before lock  */
#define TICK_MS          0.0333f  /* 30 kHz tick, for the g command  */
#define DB_PER_COUNT     0.029940f /* MEASURED, not theoretical      */
```

**`DWELL_LEN`** — after changing I or Q, the analog detector needs time to
settle before its reading means anything. The AD8307's output sees ~12.5 kΩ
into C1 = 1 nF, so τ ≈ 12.5 µs. At the 33.3 µs tick, one skipped tick is
already ~2.7τ, and the averaging that follows adds further settling time.
Judging a move on an unsettled reading turns the search into a random walk —
this was the actual bug in an earlier version (LP-V14), which dwelled in only
one of its two phases.

**`DB_PER_COUNT`** — the AD8307 is *logarithmic*, so the ADC reading is
already a dB measure of residual power. The whole algorithm therefore works
in dB and never needs a `log()`.

This constant was **calibrated in situ against the spectrum analyser** rather
than taken from the datasheet: stepping the generator down by exactly 10.0 dB
moved the ADC by 334 counts, giving 10.0/334 = **0.02994 dB per count**. That
corresponds to an AD8307 slope of ~26.9 mV/dB against the 25 mV/dB nominal —
within normal part-to-part variation. The theoretical value (0.032227) would
have over-reported every depth figure by 7.6%.

**`MARGIN_DB_BASE`** — a move only counts as an improvement if the power drops
by more than this. It has to exceed the measurement noise or every comparison
is a coin flip. 0.15 dB ≈ 5 ADC counts.

---

## `canceller.c` — the algorithm, step by step

### Weight → voltage mapping

```c
uint16_t canc_weight_to_dac(float w)   /* w in [-1,+1] -> 0..4095 */
```

I and Q live in [−1, +1]. The DAC outputs 0–3.3 V, which passes through a
10k/10k divider (so Y1 = DAC/2) and is compared against VREF on the AD835's
Y2 pin. The multiplier acts on `(Y1 − Y2)`.

**VREF was measured at 0.682 V, not the 0.825 V the divider predicts.** The
30k/10k divider has a 7.5 kΩ Thevenin impedance and the two AD835 Y-inputs
draw bias current, dropping ~143 mV. `canc_weight_to_dac()` is calibrated
around the *measured* value, so w = 0 is a true zero weight:

| w | DAC | Y1 | Y1−Y2 | meaning |
|---|---|---|---|---|
| −1 | 0 V | 0 V | −0.682 V | full negative (180° flip) |
| 0 | 1.364 V | 0.682 V | **0 V** | zero output |
| +1 | 2.728 V | 1.364 V | +0.682 V | full positive |

**This is why Y2 must go to VREF and never to ground.** With Y2 grounded,
`Y1 − Y2` can never go negative, the multiplier loses its sign, and half the
I/Q plane becomes unreachable — so most nulls simply cannot be formed.

### The tick, in order

**1. Startup (`WaitTimer < 30`)**
Do nothing but watch. Records `InitP_dB` = the *uncancelled* power level.
Everything afterwards is measured relative to this, which makes the algorithm
scale-invariant: it behaves the same whether the interferer is at −20 dBm or
+10 dBm.

**2. Locked** — if the search has converged, hold the best point and return.

**3. Dwell** — if we just moved, skip this tick. (See `DWELL_LEN` above.)

**4. Adaptive integration** — the clever part:

```c
depth_dB = P - InitP_dB;          /* how far down we are */
if      (depth_dB > -13) AvgTarget = 1;
else if (depth_dB > -20) AvgTarget = 2;
...
else                     AvgTarget = 16;
```

Far from the null, one reading is enough — move fast. Near the null the
residual approaches the noise floor and single readings become unreliable, so
we average up to 16. Averaging N samples improves SNR by √N, so 16 readings
buy ~12 dB of extra usable measurement range — which converts directly into a
deeper reachable null. Speed where speed is free, precision where it matters.

**5. Step-size law**

```c
TargetStep = 0.20f * powf(10.0f, depth_dB / 20.0f);
```

Step size shrinks with the square root of the remaining power. Big strides at
first, fine steps near the bottom — and because it is relative to `InitP_dB`,
it needs no retuning when signal levels change.

**6. Adaptive margin**

```c
margin_dB = MARGIN_DB_BASE / sqrtf(AvgTarget);
```

More averaging → quieter measurement → smaller improvements can be trusted.

**7. The 8-way pattern search** — the core:

```c
if (P < LastP_dB - margin_dB) {   /* better! */
```
- **Improvement** → keep the position, save it as best, and *grow* the step
  (doubling on a 2-win streak — "momentum", so long runs downhill take
  log(distance) decisions instead of linear).
- **Failure** → undo the step, rotate to the next of 8 directions
  (±I, ±Q, and the four diagonals). After all 8 fail, return to the best known
  point and halve the step.

Why "better or worse?" instead of computing a gradient: it only needs a
*comparison*, so it tolerates noise well. A gradient method divides small
differences of noisy readings and amplifies that noise — we tried it (V16,
V18) and it lost every time. V18 in particular diverged on hardware.

**Two phases:** phase 1 is coarse (large steps, capped at 0.25); once 6 dB of
cancellation is achieved it switches to phase 2, fine (capped at 0.04). The
"anti-stagnation kick" in phase 2 re-expands the step once if the search
stalls, to escape a shallow local minimum.

**Lock** happens only after a long stall, at the DAC quantisation floor, with
averaging active — three conditions, so it cannot latch early by luck.

One bug worth recording: the lock gate originally required
`AvgTarget >= AVG_MAX` (16), which the adaptive-averaging ladder only reaches
past 33 dB of depth. Real achievable depth on this detector is ~20 dB, so the
condition was **mathematically unreachable** and every run ended "never locked
within the window" no matter how well it had converged. `LOCK_AVG_MIN = 2` is
the reachable gate.

### The hop detector (in `main.c`'s AUTO path via `canc_init`)

An earlier version reset the search whenever `Error_Power > 100` — an
*absolute* threshold. Change the signal level and it latches on forever,
resetting every tick, output stuck at zero. The current version compares
against `InitP_dB` (scale-invariant) and requires the jump to be *sustained*,
so a single noise spike cannot trigger it.

---

## The damaged DAC channel — `dac1_fix()`

```c
static uint16_t dac1_fix(float w)
{
    float v = 1.21f - w * 1.35f;      /* inverted, over-driven */
    ...
}
```

Measured behaviour of PA4 after the fault: w = −1 → 2.06 V, w = 0 → 1.21 V,
w = +1 → 0.36 V. Two defects at once — the output runs **backwards**, and its
span is **1.7 V instead of 2.7 V**.

`dac1_fix()` corrects both: the negative coefficient undoes the inversion, and
the 1.35 magnitude over-drives the request to recover most of the lost span.
After compensation the axis reaches roughly ±0.59 in weight instead of ±1.0.

This is the reason the ISR looks asymmetric:

```c
HAL_DAC_SetValue(&hdac, DAC_CHANNEL_2, DAC_ALIGN_12B_R,
                 canc_weight_to_dac(g_canc.I));   /* PA5 - healthy   */
HAL_DAC_SetValue(&hdac, DAC_CHANNEL_1, DAC_ALIGN_12B_R,
                 dac1_fix(g_canc.Q));             /* PA4 - damaged   */
```

## `console.c` — the interface

| Command | Effect |
|---|---|
| `m` | manual mode |
| `a` | auto mode — resets the search, closes the loop, arms the logger |
| `i0.5` | set I = 0.5 |
| `q-0.3` | set Q = −0.3 |
| `z` | zero both weights (the baseline state) |
| `b` | capture baseline ADC at I = Q = 0 |
| `k` | automatic grid scan — coarse, fine, ultra-fine |
| `g` | dump convergence log with time-to-threshold analysis |
| `v` | raw ADC + depth vs baseline |
| `t` | toggle telemetry streaming |
| `s` | status |

**`k` — the grid scan.** Three passes over the I/Q plane: coarse 9×9, then
fine ±0.25 in 0.05 steps, then ultra-fine in 0.01 steps. Each point is
measured with `MEAS_AVG = 16` averaged readings because the raw ADC wanders
1.3–2.3 dB at a *fixed* I/Q — with only 4 averages the scan was ranking
points on noise rather than signal.

**`g` — the convergence logger.** `canc_step()` records the raw ADC on every
tick into a 1200-sample RAM buffer (40 ms at 30 kHz), before any early return,
so the time axis is exact. `g` then reports the time to reach −3, −6, −10,
−15, −20, −25 and −30 dB, the lock time, and a CSV decimated to one line per
millisecond. This is what produced the convergence figures in the report —
the analyser's sweep time is irrelevant because the measurement happens
inside the MCU.

Two implementation details worth noting:

**Echo is queued, not transmitted in the ISR.** `console_on_rx_byte()` runs in
the UART interrupt and only pushes characters into a ring buffer;
`console_poll()` drains it from the main loop. A blocking UART transmit inside
an interrupt would be ~87 µs per byte at 115200 — nearly a whole control tick.

**It boots in MANUAL.** Nothing moves until someone types `a`. Deliberate: you
never want an adaptive loop driving RF hardware the instant power is applied.

---

## Things that will bite you

1. **Y2 to ground instead of VREF** — kills the phase flip. Has been
   reintroduced repeatedly by well-meaning edits.
2. **Y1 without its 10 k series resistor** — puts 0–3.3 V on a ±1 V input.
3. **W1 → Z2 must be a direct wire** — Z is a unity-gain summing input; any
   divider there leaves I weaker than Q and the plane becomes skewed.
4. **Keep `clamp_iq()` and the `k` scan bounds in agreement.** The search in
   `canc_step()` and the grid scan in `console.c` must explore the *same*
   reachable box. At one point the clamp restricted Q to ±0.59 while the scan
   still swept ±1.0, so `k` kept finding nulls that `a` could never reach —
   which looked like an algorithm failure but was purely a bounds mismatch.
5. **The detector is wideband.** It measures *total* power and cannot tell the
   wanted signal from the interferer residual. So cancellation stalls at
   roughly the interferer-to-wanted power ratio: a wanted tone 10 dB below the
   interferer floors you at ~10 dB, no matter how good the hardware is. This
   is a measured, reproduced result — not a bug — and it is what motivates
   selective (frequency-aware) detection as future work.
6. **ADC sampling time must be 480 cycles.** The AD8307's ~12.5 kΩ output
   cannot charge the sample-and-hold in a short window; shorter settings give
   readings that look plausible and are wrong.
7. **DAC1 (PA4) is physically damaged** on this board — output inverted, span
   reduced to ~1.7 V. A short on the Nucleo header during assembly caused it.
   The channels were swapped in firmware: I drives PA5 (healthy DAC2), Q drives
   PA4 through `dac1_fix()`. On an undamaged board, delete `dac1_fix()` and use
   `canc_weight_to_dac()` for both channels — then Q regains its full ±1.0
   range and `clamp_iq()` should be widened to match.
8. **PA5 is also wired to the Nucleo's LD2 LED**, which loads the output very
   slightly. It mattered more when PA5 carried Q; on the final build it carries
   I and the effect is negligible.

---

## Suggested reading order

1. This document
2. `canceller.h` — the state struct tells you what the algorithm remembers
3. `canceller.c` §7, the pattern search — the heart of it
4. `main.c`, `HAL_TIM_PeriodElapsedCallback` — how a tick actually flows
5. `main.c`, `dac1_fix()` — why the two channels are handled differently
6. `console.c` — the scan and the convergence logger

---

## Measured performance (final build)

| Metric | Result |
|---|---|
| Cancellation depth | 22.1 dB mean, 28.6 dB best, 13.6 dB worst across 30–88 MHz |
| Convergence, t(−15 dB) | 1.9 ms mean, 3.7 ms worst — target was 10 ms |
| Wanted-signal loss | ≤0.5 dB down to 50 kHz separation |
| Detector calibration | 0.02994 dB/count, verified against the analyser |

The detector-measured depth reads a few dB lower than the analyser because the
AD8307 is wideband and saturates on the wanted tone once the interferer
residual falls below it. That gap is a measured result, not an error — see
report section 10.2.6.
