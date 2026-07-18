/*
 * fp_capacity.c -- Henry-SoC bare-metal FP test for the IRIX capacity bug.
 *
 * The IRIX reconfigure crash traces to a hash-array capacity computed in FP:
 *   capacity = (int)trunc( 100.0 + f4 )   where f4 = (double)count * load_factor
 * Golden gives 216; silicon's array ends up ~108 (undersized) -> OOB -> crash.
 * This exercises add.d / mul.d / cvt.d.w / trunc.w.d directly with the real
 * operands (and a magnitude sweep) to see whether the silicon FPU diverges
 * from IEEE-754.  fp_capacity PASSED in Verilator sim, so a FAIL here = a
 * sim/synth FPU mismatch; a PASS here => the bug is the upstream integer input.
 *
 * Run: mips-axi -f fp_capacity.elf --sgi true --arcs henry_arcs.bin --start-pc 0xbfc00000
 */
#include "henry_io.h"

typedef unsigned long long u64;

static u64 dbits(double d) { u64 u; __builtin_memcpy(&u, &d, 8); return u; }

static int g_fail;

static void ckd(const char *tag, double got, double exp)
{
    if (dbits(got) != dbits(exp)) {
        g_fail++;
        puts_("FAIL "); puts_(tag);
        puts_(" got="); puthex32((unsigned)(dbits(got) >> 32)); puthex32((unsigned)dbits(got));
        puts_(" exp="); puthex32((unsigned)(dbits(exp) >> 32)); puthex32((unsigned)dbits(exp));
        putch('\n');
    }
}

static void cki(const char *tag, int got, int exp)
{
    if (got != exp) {
        g_fail++;
        puts_("FAIL "); puts_(tag);
        puts_(" got="); puthex32((unsigned)got);
        puts_(" exp="); puthex32((unsigned)exp);
        putch('\n');
    }
}

int main(int argc, char **argv, char **envp)
{
    (void)argc; (void)argv; (void)envp;
    puts_("Henry FP capacity test\n");

    /* enable CP1 (Status.CU1 bit29) + FR=1 (bit26); bare-metal crt0 leaves CU1=0 */
    __asm__ volatile(
        "mfc0 $8, $12\n"
        "lui  $9, 0x2400\n"      /* (1<<29)|(1<<26) = CU1 | FR */
        "or   $8, $8, $9\n"
        "mtc0 $8, $12\n"
        "nop\n nop\n nop\n"
        ::: "$8", "$9");

    volatile double a, b;

    /* ---- add.d (the sizer's add: 100.0 + f4) ---- */
    a = 100.0; b = 116.0; ckd("add100+116=216", a + b, 216.0);   /* THE case */
    a = 100.0; b = 115.0; ckd("add100+115=215", a + b, 215.0);
    a = 100.0; b = 117.0; ckd("add100+117=217", a + b, 217.0);
    a = 108.0; b = 108.0; ckd("add108+108=216", a + b, 216.0);
    a = 128.0; b = 128.0; ckd("add128+128=256", a + b, 256.0);
    a = 200.0; b =  16.0; ckd("add200+16=216",  a + b, 216.0);
    a =   1.0; b =   2.0; ckd("add1+2=3",        a + b, 3.0);

    /* ---- mul.d (the load-factor scale) ---- */
    a =   2.0; b =   3.0; ckd("mul2*3=6",     a * b, 6.0);
    a = 100.0; b =   2.0; ckd("mul100*2=200", a * b, 200.0);
    a = 108.0; b =   2.0; ckd("mul108*2=216", a * b, 216.0);
    a =  58.0; b =   2.0; ckd("mul58*2=116",  a * b, 116.0);

    /* ---- cvt.d.w (int -> double, produces f4's base) ---- */
    volatile int iv;
    iv = 116; ckd("cvt(double)116", (double)iv, 116.0);
    iv = 216; ckd("cvt(double)216", (double)iv, 216.0);
    iv = 58;  ckd("cvt(double)58",  (double)iv, 58.0);

    /* ---- trunc.w.d (double -> int) ---- */
    a = 216.0; cki("trunc216.0", (int)a, 216);
    a = 216.9; cki("trunc216.9", (int)a, 216);

    /* ---- the full sizer chain: (int)trunc(100.0 + (double)count) ---- */
    volatile int cnt = 116;
    double f4 = (double)cnt;              /* cvt.d.w */
    double sized = 100.0 + f4;            /* add.d   */
    cki("sizer(cnt=116)=216", (int)sized, 216);   /* trunc.w.d */

    if (g_fail == 0)
        puts_("PASS\n");
    else {
        puts_("FAILED n="); puthex32((unsigned)g_fail); putch('\n');
    }
    sim_halt();
    return 0;
}
