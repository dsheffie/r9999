/*
 * test_devregs.c -- directed read/write test of the IRIX-boot-critical SoC
 * device registers (MC @0x1fa00000, IOC2/HPC3 @0x1fbd9800/0x1fb80000), checked
 * against MAME's golden kernel-visible values (MAME_QUESTIONS.md Q4/round-4/6).
 *
 * All reads are uncached kseg1 (0xbf...) -> the SoC device models.  Values are
 * what the kernel's `lw` actually sees (the BE-lw byte order the kernel masks
 * on, e.g. SYSID 0x26 lands in bits[7:0]).  This is the regression check that
 * would have caught the IOC2 SYSID offset bug (0x58000 vs 0x59858).
 *
 * Run (RTL device models): henry_tb --kernel test_devregs.elf   (no --arcs)
 * Run (C++ models):        ooo_core --file test_devregs.elf --arcs <blob> -c0
 */
#include "sim.h"

#define RD(a)  (*(volatile unsigned int *)(unsigned long)(a))
#define WR(a,v) (*(volatile unsigned int *)(unsigned long)(a) = (v))

static int fails;

static void check(const char *name, unsigned int got, unsigned int want)
{
    simcon_puts(name);
    simcon_puts(" = ");
    simcon_puthex32(got);
    if (got == want) {
        simcon_puts("  PASS\n");
    } else {
        simcon_puts("  want ");
        simcon_puthex32(want);
        simcon_puts("  FAIL\n");
        fails++;
    }
}

int main(void)
{
    fails = 0;
    simcon_puts("== IRIX-boot device-register check (vs MAME golden) ==\n");

    /* ---- reads the kernel makes during mlreset / getsysid / machine config ---- */
    check("MC.sysid   1fa0001c", RD(0xbfa0001cu), 0x00000013u); /* MC rev/config */
    check("MC.mconfig0 1fa000c4", RD(0xbfa000c4u), 0x23200000u); /* 16 MB @0x08000000 */
    check("MC.mconfig1 1fa000cc", RD(0xbfa000ccu), 0x00000000u);
    check("IOC2.sysid 1fbd9858", RD(0xbfbd9858u), 0x00000026u); /* guinness/Indy board id */
    check("HPC 1fb91004",        RD(0xbfb91004u), 0x00000010u);
    check("HPC 1fbd8010",        RD(0xbfbd8010u), 0x00000018u);
    check("HPC 1fbd8020",        RD(0xbfbd8020u), 0x00004010u);

    /* ---- write/read-back on R/W MC registers (validates the store path) ----
     * Full 32-bit R/W regs round-trip: the store BE-encodes and the load
     * BE-decodes, so the byte swaps cancel and RD == the value written. */
    WR(0xbfa00000u, 0xdeadbeefu);            /* MC cpu_control[0] */
    check("MC.cpuctrl0 wr/rd",   RD(0xbfa00000u), 0xdeadbeefu);
    WR(0xbfa000dcu, 0x0000a5a5u);            /* MC gio_mem_access_config */
    check("MC.gioacc   wr/rd",   RD(0xbfa000dcu), 0x0000a5a5u);

    simcon_puts(fails ? "== DEVREGS FAIL ==\n" : "== DEVREGS OK ==\n");
    return 0;
}
