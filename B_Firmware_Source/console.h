/* console.h - 115200 8N1 serial console over USART2 (ST-Link VCP)
 *
 * COMMANDS
 *   m         manual mode (default at boot - nothing moves until 'a')
 *   a         auto mode: reset the algorithm and close the loop
 *   i<val>    manual I weight, -1 .. +1     e.g.  i0.5   i-0.3   i0
 *   q<val>    manual Q weight, -1 .. +1
 *   v         print raw ADC (detector calibration)
 *   t         toggle telemetry streaming
 *   s         status
 *   h         help
 */

#ifndef CONSOLE_H
#define CONSOLE_H

#include "canceller.h"

void console_init(void);
void console_on_rx_byte(uint8_t c);   /* call from the UART RX callback */
void console_poll(canc_state_t *s, canc_mode_t *mode);  /* call from main loop */
void console_print(const char *msg);

#endif /* CONSOLE_H */
