/* canceller.h - LP-V17b adaptive pattern search, dB domain
 * Co-Site Interference Canceller, 30-88 MHz
 * Ronny Pustilnik / Adir Lemaer - Afeka
 *
 * NUCLEO-F446RE:
 *   PA0 = ADC1_IN0  <- AD8307 OUT (log detector, ~25 mV/dB)
 *   PA4 = DAC_OUT1  -> I control  (via 10k/10k divider -> AD835 #1 Y1)
 *   PA5 = DAC_OUT2  -> Q control  (via 10k/10k divider -> AD835 #2 Y1)
 *
 * I and Q are held in [-1, +1].  DAC code = 2048 + w*2048.
 *   w = -1 -> 0 V    -> Y1 = 0      -> Y1-Y2 = -0.825 V
 *   w =  0 -> 1.65 V -> Y1 = 0.825  -> Y1-Y2 =  0
 *   w = +1 -> 3.3 V  -> Y1 = 1.65   -> Y1-Y2 = +0.825 V
 */

#ifndef CANCELLER_H
#define CANCELLER_H

#include <stdint.h>
#include <stdbool.h>

/* ---- tunables ------------------------------------------------------- */
/* Convergence budget, at a 10 kHz tick (100 us):
 *   decision cost = (DWELL_LEN + AvgTarget) ticks
 *   AD8307 out is 12.5k into C1 = 1nF -> tau = 12.5 us, so 1 tick = 8 tau.
 *   DWELL_LEN = 1 is therefore already fully settled; 2 was conservative.
 * Tactical VHF hops every ~10 ms, so the whole search must fit inside that. */
#define DWELL_LEN        1       /* ticks held after each move (filter settle) */
#define DAC_LSB          0.0005f /* 12-bit step in I/Q units (1/2048)         */
#define MARGIN_DB_BASE   0.60f   /* improvement threshold at AvgTarget = 1;
                                     raised from 0.15 because the raw ADC was
                                     measured to wander 1.3-2.3 dB at a fixed
                                     I/Q - the margin must clear that noise  */
#define STARTUP_TICKS    10      /* ticks before the search begins             */
#define AVG_MAX          16      /* hop-time cap on the adaptive averaging     */
#define LOCK_AVG_MIN     2       /* min AvgTarget required before locking.
                                     Was tied to AVG_MAX (16, i.e. needs >33 dB
                                     depth) which real hardware never reaches -
                                     see canc_step()'s lock condition. 2 is
                                     reachable at realistic (~18-20 dB) depths
                                     while still requiring some averaging. */
#define TICK_MS          0.0333f /* 30 kHz (ARR=32). 0.1f was 10 kHz (ARR=99) */
/* AD8307: 25 mV/dB.  ADC LSB = 3.3/4096 V.  -> dB per ADC count.
 * MEASURED on this board: -10.0 dB generator step -> 334 ADC counts.
 * 10.0 / 334 = 0.029940 dB per count  (AD8307 slope ~26.9 mV/dB,
 * vs 25 mV/dB nominal - within normal part variation).
 * Previously used the theoretical 0.032227, which over-reported depth by 7.6%. */
#define DB_PER_COUNT     0.029940f

typedef enum { MODE_MANUAL = 0, MODE_AUTO = 1 } canc_mode_t;

typedef struct {
    float   I, Q;          /* current weights, [-1,+1]      */
    float   BestI, BestQ;  /* best point found              */
    float   Step;
    float   InitP_dB;      /* baseline (uncancelled) level  */
    float   LastP_dB;
    uint8_t phase;         /* 1 = coarse, 2 = fine          */
    uint8_t DirState;      /* 1..8 pattern-search direction */
    uint8_t StallCycles;
    uint8_t WinStreak;
    uint8_t AvgTarget;
    uint8_t AvgCnt;
    uint16_t WaitTimer;
    uint16_t Dwell;
    float   AvgAcc;
    bool    locked;
    bool    Kicked;
    bool    initialised;
    uint16_t last_adc;     /* most recent raw ADC reading   */
} canc_state_t;

/* Reset all algorithm state (called on boot and on 'a'). */
void canc_init(canc_state_t *s);

/* One control-loop tick. Feed the raw ADC count from the AD8307.
 * Updates s->I and s->Q. Call at a fixed rate (10 kHz). */
void canc_step(canc_state_t *s, uint16_t adc_counts);

/* Convert a weight in [-1,+1] to a 12-bit DAC code. */
uint16_t canc_weight_to_dac(float w);

/* ---- convergence logger --------------------------------------------
 * Captures the raw ADC reading on EVERY tick (100 us) into RAM, so a
 * convergence event lasting a few ms can actually be resolved. 400
 * samples = 40 ms at 10 kHz, which covers the whole search plus margin.
 * Telemetry at 100 ms intervals is far too coarse for this.            */
#define LOG_LEN 1200

void     canc_log_start(void);          /* arm the logger, clears it    */
uint16_t canc_log_count(void);          /* samples captured so far      */
uint16_t canc_log_get(uint16_t idx);    /* raw ADC at tick idx          */
uint16_t canc_log_lock_tick(void);      /* tick where locked, or 0xFFFF */

#endif /* CANCELLER_H */
