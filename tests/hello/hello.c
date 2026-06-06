#include "sim.h"

int main(void) {
    simcon_puts("Hello from R4000!\n");

    /* Exercise SIMCON_PUTCHAR directly */
    SIMCON_PUTCHAR('O');
    SIMCON_PUTCHAR('K');
    SIMCON_PUTCHAR('\n');

    SIM_PASS();
    while(1) {};
    return 0;
}
