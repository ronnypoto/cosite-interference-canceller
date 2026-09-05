/* console.c - serial console for the co-site canceller
 * USART2 @ 115200 8N1, routed to the ST-Link virtual COM port.
 *
 * v2: adds LOCAL ECHO. Without it the terminal shows nothing while you
 * type, which is indistinguishable from a dead RX path. Characters are
 * queued in the RX interrupt and echoed from console_poll() in the main
 * loop, so no blocking UART transmit ever happens inside an ISR.
 */

#include "console.h"
#include "main.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

extern UART_HandleTypeDef huart2;

#define RXBUF_LEN   32
#define ECHO_LEN    64      /* must be a power of two */

static volatile char     rxbuf[RXBUF_LEN];
static volatile uint8_t  rxlen  = 0;
static volatile bool     rxdone = false;

/* echo ring buffer, filled in the ISR, drained in the main loop */
static volatile uint8_t  echo_buf[ECHO_LEN];
static volatile uint16_t echo_head = 0;   /* write index (ISR)  */
static volatile uint16_t echo_tail = 0;   /* read index  (main) */

static bool              telemetry = false;
static uint32_t          telem_last = 0;

void console_print(const char *msg)
{
    HAL_UART_Transmit(&huart2, (uint8_t *)msg, strlen(msg), 100);
}

static void echo_push(uint8_t c)
{
    uint16_t next = (uint16_t)((echo_head + 1u) & (ECHO_LEN - 1u));
    if (next != echo_tail) {          /* drop if full, never block */
        echo_buf[echo_head] = c;
        echo_head = next;
    }
}

static void echo_drain(void)
{
    while (echo_tail != echo_head) {
        uint8_t c = echo_buf[echo_tail];
        echo_tail = (uint16_t)((echo_tail + 1u) & (ECHO_LEN - 1u));
        HAL_UART_Transmit(&huart2, &c, 1, 10);
    }
}

/* ---------------------------------------------------------------------
 * Baseline + automatic grid scan
 *
 * The TIM2 ISR keeps writing s->I / s->Q to the DACs and refreshing
 * s->last_adc every 100 us, so a scan can simply set a weight, wait, and
 * read back. Blocking with HAL_Delay here is safe: the control loop lives
 * in the interrupt, not in this loop.
 * ------------------------------------------------------------------- */

static uint16_t base_adc  = 0;      /* uncancelled reference reading */
static bool     base_valid = false;

/* Settle, then average MANY readings.
 *
 * The raw ADC was measured to wander 1.3-2.3 dB (40-70 counts) at a FIXED
 * I/Q. Averaging only 4 readings left ~0.6-1.1 dB of uncertainty - larger
 * than many of the differences the scan needs to resolve between candidate
 * points, so comparisons were partly noise-driven. 16 readings cut that by
 * sqrt(16)=4x, to ~0.15-0.3 dB. Cost: ~18 ms/point instead of 6 ms - the
 * full 3-stage scan takes ~15 s instead of ~2 s. Worth it for a reliable
 * result. */
#define MEAS_AVG   16

static uint16_t measure_point(canc_state_t *s)
{
    uint32_t acc = 0;
    HAL_Delay(2);                    /* settle */
    for (int k = 0; k < MEAS_AVG; k++) {
        acc += s->last_adc;
        HAL_Delay(1);
    }
    return (uint16_t)(acc / (uint32_t)MEAS_AVG);
}

static void do_baseline(canc_state_t *s)
{
    char out[80];
    float keepI = s->I, keepQ = s->Q;
    s->I = 0.0f; s->Q = 0.0f;        /* zero weight = no cancellation */
    base_adc = measure_point(s);
    base_valid = true;
    s->I = keepI; s->Q = keepQ;
    snprintf(out, sizeof(out), "baseline adc=%u (%.1f mV)\r\n",
             base_adc, (float)base_adc * 3300.0f / 4095.0f);
    console_print(out);
}

static void report_depth(canc_state_t *s, uint16_t a)
{
    char out[80];
    (void)s;
    if (base_valid) {
        float d = (float)((int32_t)base_adc - (int32_t)a) * DB_PER_COUNT;
        snprintf(out, sizeof(out), "adc=%u  depth=%.1f dB\r\n", a, d);
    } else {
        snprintf(out, sizeof(out), "adc=%u  (no baseline - press b)\r\n", a);
    }
    console_print(out);
}

/* Two-stage grid scan: coarse over the whole plane, then fine around the
 * best point. Finds the true achievable null independently of the search
 * algorithm - so if 'k' nulls deeply but 'a' does not, the problem is the
 * algorithm; if neither nulls, the problem is the RF. */
static void do_scan(canc_state_t *s, canc_mode_t *mode)
{
    char out[96];
    *mode = MODE_MANUAL;             /* algorithm must not fight the scan */

    if (!base_valid) do_baseline(s);

    float bestI = 0.0f, bestQ = 0.0f;
    uint16_t bestA = 0xFFFF;

    console_print("coarse scan (9x9)...\r\n");
    for (int qi = -4; qi <= 4; qi++) {
        for (int ii = -4; ii <= 4; ii++) {
            s->I = (float)ii * 0.25f;
            s->Q = (float)qi * 0.25f;
            uint16_t a = measure_point(s);
            if (a < bestA) { bestA = a; bestI = s->I; bestQ = s->Q; }
        }
    }
    snprintf(out, sizeof(out), "  coarse best I=%.3f Q=%.3f adc=%u\r\n",
             bestI, bestQ, bestA);
    console_print(out);

    console_print("fine scan (11x11)...\r\n");
    float cI = bestI, cQ = bestQ;
    for (int qi = -5; qi <= 5; qi++) {
        for (int ii = -5; ii <= 5; ii++) {
            s->I = cI + (float)ii * 0.05f;
            s->Q = cQ + (float)qi * 0.05f;
            if (s->I >  1.0f || s->I < -1.0f) continue;
            if (s->Q >  1.0f || s->Q < -1.0f) continue;
            uint16_t a = measure_point(s);
            if (a < bestA) { bestA = a; bestI = s->I; bestQ = s->Q; }
        }
    }

    console_print("ultra-fine scan (11x11)...\r\n");
    cI = bestI; cQ = bestQ;
    for (int qi = -5; qi <= 5; qi++) {
        for (int ii = -5; ii <= 5; ii++) {
            s->I = cI + (float)ii * 0.01f;
            s->Q = cQ + (float)qi * 0.01f;
            if (s->I >  1.0f || s->I < -1.0f) continue;
            if (s->Q >  1.0f || s->Q < -1.0f) continue;
            uint16_t a = measure_point(s);
            if (a < bestA) { bestA = a; bestI = s->I; bestQ = s->Q; }
        }
    }

    s->I = bestI; s->Q = bestQ;       /* park at the best point */
    snprintf(out, sizeof(out), "BEST I=%.3f Q=%.3f  ", bestI, bestQ);
    console_print(out);
    report_depth(s, bestA);
}

static void print_help(void)
{
    console_print("\r\n--- Co-Site Canceller ---\r\n");
    console_print("  m       manual mode\r\n");
    console_print("  a       auto mode (close the loop)\r\n");
    console_print("  i<val>  set I, -1..+1   e.g. i0.5\r\n");
    console_print("  q<val>  set Q, -1..+1\r\n");
    console_print("  v       raw ADC + depth\r\n");
    console_print("  z       zero I and Q\r\n");
    console_print("  b       capture baseline (I=Q=0)\r\n");
    console_print("  k       AUTO GRID SCAN -> finds the null\r\n");
    console_print("  g       dump convergence log + timing\r\n");
    console_print("  t       toggle telemetry\r\n");
    console_print("  s       status\r\n");
    console_print("> ");
}

void console_init(void)
{
    rxlen = 0; rxdone = false;
    telemetry = true;        // <-- FORCE TELEMETRY ON AT BOOT
    echo_head = 0; echo_tail = 0;
    console_print("\r\n[BOOT] Canceller ready. Telemetry streaming active.\r\n");
    print_help();
}

void console_on_rx_byte(uint8_t c)
{
    if (c == '\r' || c == '\n') {
        rxbuf[rxlen] = '\0';
        rxdone = true;
        echo_push('\r');
        echo_push('\n');
    } else if (c == 8 || c == 127) {              /* backspace */
        if (rxlen > 0) {
            rxlen--;
            echo_push(8); echo_push(' '); echo_push(8);
        }
    } else if (rxlen < RXBUF_LEN - 1) {
        rxbuf[rxlen++] = (char)c;
        echo_push(c);                             /* <-- the fix */
    }
}

void console_poll(canc_state_t *s, canc_mode_t *mode)
{
    char out[96];

    echo_drain();          /* show what the user typed */

    /* ---- telemetry stream (every ~100 ms) ---- */
    if (telemetry && (HAL_GetTick() - telem_last >= 100)) {
        telem_last = HAL_GetTick();
        snprintf(out, sizeof(out),
                 "T %lu adc=%u I=%.4f Q=%.4f ph=%u avg=%u %s\r\n",
                 (unsigned long)HAL_GetTick(), s->last_adc,
                 s->I, s->Q, s->phase, s->AvgTarget,
                 s->locked ? "LOCKED" : "");
        console_print(out);
    }

    if (!rxdone) return;

    char cmd = rxbuf[0];
    float val = 0.0f;
    if (rxlen > 1) val = strtof((const char *)&rxbuf[1], NULL);

    switch (cmd) {

    case 'm':
        *mode = MODE_MANUAL;
        console_print("MANUAL\r\n");
        break;

    case 'a':
        canc_init(s);                 /* fresh search every time */
        canc_log_start();             /* capture the convergence */
        *mode = MODE_AUTO;
        console_print("AUTO - loop closed, logging 40 ms. Press g to dump.\r\n");
        break;

    case 'i':
        if (val >  1.0f) val =  1.0f;
        if (val < -1.0f) val = -1.0f;
        s->I = val;
        snprintf(out, sizeof(out), "I = %.4f (dac %u)\r\n",
                 s->I, canc_weight_to_dac(s->I));
        console_print(out);
        break;

    case 'q':
        if (val >  1.0f) val =  1.0f;
        if (val < -1.0f) val = -1.0f;
        s->Q = val;
        snprintf(out, sizeof(out), "Q = %.4f (dac %u)\r\n",
                 s->Q, canc_weight_to_dac(s->Q));
        console_print(out);
        break;

    case 'v':
        snprintf(out, sizeof(out), "adc = %u  (%.1f mV)  ",
                 s->last_adc,
                 (float)s->last_adc * 3300.0f / 4095.0f);
        console_print(out);
        report_depth(s, s->last_adc);
        break;

    case 'z':
        s->I = 0.0f; s->Q = 0.0f;
        console_print("I = Q = 0\r\n");
        break;

    case 'b':
        do_baseline(s);
        break;

    case 'k':
        do_scan(s, mode);
        break;

    case 'g': {
        uint16_t n = canc_log_count();
        if (n < 20) { console_print("no log - press a first\r\n"); break; }

        /* baseline = mean of the first 8 ticks (still uncancelled) */
        uint32_t acc = 0;
        for (uint16_t k = 0; k < 8; k++) acc += canc_log_get(k);
        float base = (float)acc / 8.0f;

        /* time to reach each depth, sustained for 5 ticks */
        const float TH[7] = { 3.0f, 6.0f, 10.0f, 15.0f, 20.0f, 25.0f, 30.0f };
        float t_th[7];
        for (int j = 0; j < 7; j++) t_th[j] = -1.0f;

        for (uint16_t k = 0; k + 5 < n; k++) {
            for (int j = 0; j < 7; j++) {
                if (t_th[j] >= 0.0f) continue;
                bool ok = true;
                for (uint16_t m = k; m < k + 5; m++) {
                    float d = (base - (float)canc_log_get(m)) * DB_PER_COUNT;
                    if (d < TH[j]) { ok = false; break; }
                }
                if (ok) t_th[j] = (float)k * TICK_MS;   /* ticks -> ms */
            }
        }

        /* deepest point reached */
        uint16_t mn = 0xFFFF;
        for (uint16_t k = 0; k < n; k++)
            if (canc_log_get(k) < mn) mn = canc_log_get(k);
        float dmax = (base - (float)mn) * DB_PER_COUNT;

        snprintf(out, sizeof(out),
                 "\r\n--- CONVERGENCE (%u ticks = %.1f ms) ---\r\n",
                 n, (float)n * TICK_MS);
        console_print(out);
        snprintf(out, sizeof(out), "baseline adc=%.0f  best adc=%u  max depth=%.1f dB\r\n",
                 base, mn, dmax);
        console_print(out);
        for (int j = 0; j < 7; j++) {
            if (t_th[j] >= 0.0f)
                snprintf(out, sizeof(out), "  t(-%2.0f dB) = %5.1f ms %s\r\n",
                         TH[j], t_th[j], (t_th[j] <= 10.0f) ? "OK" : "SLOW");
            else
                snprintf(out, sizeof(out), "  t(-%2.0f dB) = not reached\r\n", TH[j]);
            console_print(out);
        }
        uint16_t lt = canc_log_lock_tick();
        if (lt != 0xFFFF) {
            snprintf(out, sizeof(out), "  LOCKED at %.1f ms\r\n", (float)lt * TICK_MS);
            console_print(out);
        } else {
            console_print("  never locked within the window\r\n");
        }

        /* Decimate to roughly one line per millisecond. At 30 kHz that is
         * every 30th tick, so 40 ms becomes ~40 lines instead of 1200 -
         * short enough to read in the console and to paste into Excel.
         * Each printed sample is the MEAN of its 1 ms block, so nothing is
         * hidden between printed points. */
        {
            uint16_t dec = (uint16_t)(1.0f / TICK_MS + 0.5f);
            if (dec < 1) dec = 1;
            /* Detector-visible depth saturates around ~18-20 dB once the
             * wanted tone/broadband noise dominates (see the "why 30 dB
             * isn't reached" note in the README). Turn the wanted generator
             * OFF before this run if you want the higher thresholds above
             * to have a chance of firing; otherwise treat "not reached"
             * above ~20 dB as expected, not a fault. */
            const float TARGET_DB = 15.0f;

            snprintf(out, sizeof(out),
                     "\r\nms,adc,depth_dB,reached_%.0fdB\r\n", TARGET_DB);
            console_print(out);

            for (uint16_t k = 0; k + dec <= n; k += dec) {
                uint32_t acc = 0;
                for (uint16_t m = k; m < k + dec; m++) acc += canc_log_get(m);
                float avg = (float)acc / (float)dec;
                float d = (base - avg) * DB_PER_COUNT;
                snprintf(out, sizeof(out), "%.1f,%.0f,%.2f,%s\r\n",
                         (float)k * TICK_MS, avg, d,
                         (d >= TARGET_DB) ? "YES" : "no");
                console_print(out);
            }
        }
        break;
    }

    case 't':
        telemetry = !telemetry;
        console_print(telemetry ? "telemetry ON\r\n" : "telemetry OFF\r\n");
        break;

    case 's':
        snprintf(out, sizeof(out),
                 "mode=%s I=%.4f Q=%.4f step=%.5f ph=%u avg=%u %s\r\n",
                 (*mode == MODE_AUTO) ? "AUTO" : "MANUAL",
                 s->I, s->Q, s->Step, s->phase, s->AvgTarget,
                 s->locked ? "LOCKED" : "searching");
        console_print(out);
        snprintf(out, sizeof(out), "  adc=%u init=%.2f dB last=%.2f dB\r\n",
                 s->last_adc, s->InitP_dB, s->LastP_dB);
        console_print(out);
        break;

    case 'h':
    case '?':
        print_help();
        break;

    default:
        if (rxlen > 0) console_print("? (h for help)\r\n");
        break;
    }

    rxlen = 0;
    rxdone = false;
    console_print("> ");
}
