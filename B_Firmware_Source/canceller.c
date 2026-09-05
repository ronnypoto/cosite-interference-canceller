/* canceller.c - LP-V17b adaptive-integration pattern search, dB domain
 *
 * WHY dB DOMAIN
 *   The AD8307 is logarithmic (~25 mV/dB), so the ADC reading IS a dB
 *   measure of residual power. Working directly in dB avoids an exp() on
 *   every tick and keeps every comparison scale-invariant.
 *
 *   MATLAB (linear)                 ->  here (dB)
 *   P / InitPower                   ->  P_dB - InitP_dB
 *   P < LastPower * margin          ->  P_dB < LastP_dB - margin_dB
 *   LastPower < 0.25 * InitPower    ->  LastP_dB < InitP_dB - 6.02
 *   0.20 * sqrt(P/InitPower)        ->  0.20 * 10^((P_dB-InitP_dB)/20)
 *
 * NOTE ON MARGIN: the ADC LSB is ~0.032 dB, so the MATLAB margin of
 * 0.004 (=0.017 dB) is below the noise floor of a single reading. The
 * margin here starts at 0.15 dB and tightens as averaging deepens.
 */

#include "canceller.h"
#include <math.h>

/* ---- convergence logger (see canceller.h) ---- */
static uint16_t log_adc[LOG_LEN];
static uint16_t log_n        = 0;
static bool     log_active   = false;
static uint16_t log_lock_idx = 0xFFFF;

void canc_log_start(void)
{
    log_n = 0;
    log_lock_idx = 0xFFFF;
    log_active = true;
}
uint16_t canc_log_count(void)          { return log_n; }
uint16_t canc_log_get(uint16_t idx)    { return (idx < log_n) ? log_adc[idx] : 0; }
uint16_t canc_log_lock_tick(void)      { return log_lock_idx; }

/* 8-way pattern search direction table */
static const int8_t DIR_I[8] = { 1, -1,  0,  0,  1,  1, -1, -1 };
static const int8_t DIR_Q[8] = { 0,  0,  1, -1,  1, -1,  1, -1 };

void canc_init(canc_state_t *s)
{
    /* Start at TRUE ZERO WEIGHT, matching the 'z'/'b' baseline convention. */
    s->I = 0.0f;  s->Q = 0.0f;
    s->BestI = 0.0f; s->BestQ = 0.0f;
    s->Step = 0.20f;
    s->InitP_dB = -999.0f;
    s->LastP_dB =  999.0f;
    s->phase = 1;
    s->DirState = 0;          /* index 0..7 */
    s->StallCycles = 0;
    s->WinStreak = 0;
    s->AvgTarget = 1;
    s->AvgCnt = 0;
    s->AvgAcc = 0.0f;
    s->WaitTimer = 0;
    s->Dwell = 0;
    s->locked = false;
    s->Kicked = false;
    s->initialised = true;
    s->last_adc = 0;
}

#define VREF_MEAS  0.682f   /* MEASURED Y2 - update if it changes */

uint16_t canc_weight_to_dac(float w)
{
    if (w >  1.0f) w =  1.0f;
    if (w < -1.0f) w = -1.0f;
    float y1   = VREF_MEAS + w * VREF_MEAS;   /* symmetric +/- VREF */
    float vdac = y1 * 2.0f;                   /* undo the 10k/10k divider */
    int32_t code = (int32_t)(vdac / 3.3f * 4095.0f + 0.5f);
    if (code < 0)    code = 0;
    if (code > 4095) code = 4095;
    return (uint16_t)code;
}

static void clamp_iq(canc_state_t *s)
{
    if (s->I >  1.0f) s->I =  1.0f;
    if (s->I < -1.0f) s->I = -1.0f;
    if (s->Q >  1.0f) s->Q =  1.0f;
    if (s->Q < -1.0f) s->Q = -1.0f;
}

void canc_step(canc_state_t *s, uint16_t adc_counts)
{
    s->last_adc = adc_counts;

    /* log EVERY tick, before any early return, so the time axis is exact */
    if (log_active) {
        if (log_n < LOG_LEN) {
            log_adc[log_n++] = adc_counts;
            if (s->locked && log_lock_idx == 0xFFFF) log_lock_idx = log_n - 1;
        } else {
            log_active = false;
        }
    }

    float P_dB = (float)adc_counts * DB_PER_COUNT;

    /* ---- 1. startup: let everything settle, capture the baseline ---- */
    if (s->WaitTimer < STARTUP_TICKS) {
        s->WaitTimer++;
        s->LastP_dB = P_dB;
        if (s->WaitTimer >= (STARTUP_TICKS * 2 / 3) && P_dB > s->InitP_dB)
            s->InitP_dB = P_dB;     /* max of the settled tail */
        return;
    }

    /* ---- 2. locked: hold the best point ---- */
    if (s->locked) {
        s->I = s->BestI;
        s->Q = s->BestQ;
        return;
    }

    /* ---- 3. dwell: wait for the detector filter after a move ---- */
    if (s->Dwell > 0) { s->Dwell--; return; }

    /* ---- 4. adaptive integration ------------------------------------- */
    s->AvgAcc += P_dB;
    s->AvgCnt++;
    if (s->AvgCnt < s->AvgTarget) return;

    float P = s->AvgAcc / (float)s->AvgCnt;
    s->AvgAcc = 0.0f;
    s->AvgCnt = 0;

    float depth_dB = P - s->InitP_dB;      /* negative as we null */
    if      (depth_dB > -13.0f) s->AvgTarget = 1;
    else if (depth_dB > -20.0f) s->AvgTarget = 2;
    else if (depth_dB > -27.0f) s->AvgTarget = 4;
    else if (depth_dB > -33.0f) s->AvgTarget = 8;
    else                        s->AvgTarget = 16;
    if (s->AvgTarget > AVG_MAX) s->AvgTarget = AVG_MAX;   /* hop-time cap */

    /* ---- 5. scale-invariant step law (phase 1) ---- */
    float TargetStep = DAC_LSB;
    if (s->phase == 1) {
        TargetStep = 0.20f * powf(10.0f, depth_dB / 20.0f);
        if (TargetStep < DAC_LSB) TargetStep = DAC_LSB;
        if (TargetStep > 0.25f)   TargetStep = 0.25f;
    }

    /* ---- 6. adaptive margin: more averaging -> trust smaller wins ---- */
    float margin_dB = MARGIN_DB_BASE / sqrtf((float)s->AvgTarget);

    /* ---- 7. 8-way pattern search with momentum ---- */
    if (P < s->LastP_dB - margin_dB) {
        /* improvement: keep the position, remember it */
        s->LastP_dB = P;
        s->StallCycles = 0;
        s->Kicked = false;
        s->BestI = s->I;
        s->BestQ = s->Q;
        s->WinStreak++;

        if (s->phase == 1) {
            s->Step = TargetStep;
            if (s->WinStreak >= 2) s->Step *= 2.0f;
            if (s->Step > 0.25f)   s->Step = 0.25f;
        } else {
            s->Step *= (s->WinStreak >= 2) ? 2.0f : 1.6f;
            if (s->Step > 0.10f) s->Step = 0.10f;
        }
    } else {
        /* failure: undo the trial step, rotate to the next direction */
        s->WinStreak = 0;
        s->I -= s->Step * (float)DIR_I[s->DirState];
        s->Q -= s->Step * (float)DIR_Q[s->DirState];
        s->DirState++;

        if (s->DirState > 7) {
            s->DirState = 0;
            s->StallCycles++;
            s->I = s->BestI;          /* re-anchor at the best point */
            s->Q = s->BestQ;

            if (s->phase == 1) {
                s->Step *= 0.5f;
                if (s->Step < TargetStep) s->Step = TargetStep;
                if (s->StallCycles >= 2) {                  /* FASTER TRANSITION: was 3 */
                    if (s->LastP_dB < s->InitP_dB - 10.0f) { /* WAS 12.0f */
                        s->phase = 2;          /* 10 dB achieved -> fine */
                        s->StallCycles = 0;
                        s->Kicked = false;
                    } else {
                        s->Step = 0.25f;       /* kick out harder */
                        s->StallCycles = 0;
                    }
                }
            } else {
                /* ---- PHASE 2 (Fine Search) ---- */
                s->Step *= 0.5f;
                if (s->Step < DAC_LSB) s->Step = DAC_LSB;

                /* TACTICAL SPEED RUN: No anti-stagnation kicks.
                 * Lock immediately after 2 failed rotations when step size is small. */
                if (s->StallCycles >= 2 &&
                    s->Step <= 16.0f * DAC_LSB &&
                    s->AvgTarget >= LOCK_AVG_MIN) {
                    s->locked = true;
                    s->I = s->BestI;
                    s->Q = s->BestQ;
                    return;
                }
            }
        }
    }

    /* ---- 8. apply the next trial step ---- */
    s->I += s->Step * (float)DIR_I[s->DirState];
    s->Q += s->Step * (float)DIR_Q[s->DirState];
    clamp_iq(s);

    s->Dwell = DWELL_LEN;
}
