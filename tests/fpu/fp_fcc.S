/* TDD test: FCC (FP condition code) coherence between the two places it lives.
 *
 * BC1T/BC1F read the RENAMED FCR physreg (exec.sv r_fcr_prf), whose only writer
 * is an FP compare (exec.sv:1821).  CTC1/CFC1 read and write the ARCHITECTURAL
 * FCSR (exec.sv:3862) and never touch r_fcr_prf -- CTC1 carries no
 * fcr_dst_valid, so it allocates no FCR physreg.  Nor does a compare's result
 * ever get merged into FCSR: the retire-time update only writes Cause[17:12]
 * and Flags[6:2], never the Condition bit 23.
 *
 * So the two directions below must both work and are both believed BROKEN:
 *   A/B: CTC1 then BC1T -- the branch must see the value CTC1 wrote, not the
 *        stale compare result.  IRIX's FP context restore does exactly this
 *        (ctc1 restores FCSR including FCC), so a context switch landing
 *        between a compare and its branch takes the WRONG DIRECTION.
 *   C:   a compare then CFC1 -- FCSR bit 23 must reflect the compare.
 *
 * fp_cfc1.S already covers the ctc1->cfc1 round trip; that passes because both
 * ends go to r_fcsr.  This test is specifically the CROSS paths.
 * Values are exact in single precision; this tests plumbing, not rounding.
 */
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type main,@function
main:
    /* enable CU1 in Status so the FP ops are legal */
    mfc0  $2, $12
    lui   $3, 0x2000          /* CU1 = bit 29 */
    or    $2, $2, $3
    mtc0  $2, $12
    nop
    nop

    /* f0 = f2 = 1.0 */
    lui   $8, 0x3f80
    mtc1  $8, $f0
    mtc1  $8, $f2
    nop

    /* ---- A: compare sets FCC=1, then CTC1 CLEARS it; BC1T must NOT take ---- */
    c.eq.s $f0, $f2           /* 1.0 == 1.0 -> FCC0 = 1 */
    nop
    move  $9, $0              /* FCSR = 0 -> FCC0 clear, RN, no enables */
    ctc1  $9, $31
    nop
    nop
    bc1t  fail_a              /* stale renamed FCC=1 would wrongly take this */
    nop

    /* ---- B: compare clears FCC=0, then CTC1 SETS it; BC1T MUST take ---- */
    c.lt.s $f0, $f2           /* 1.0 < 1.0 -> FCC0 = 0 */
    nop
    lui   $9, 0x0080          /* FCSR bit 23 = FCC0 = 1 */
    ctc1  $9, $31
    nop
    nop
    bc1t  b_ok                /* stale renamed FCC=0 would wrongly fall through */
    nop
    b     fail_b
    nop
b_ok:

    /* ---- C: compare then CFC1 -- FCSR bit 23 must reflect the compare ---- */
    c.eq.s $f0, $f2           /* FCC0 = 1 */
    nop
    nop
    cfc1  $10, $31
    nop
    lui   $11, 0x0080
    and   $12, $10, $11
    beq   $12, $0, fail_c     /* bit 23 clear -> the compare never reached FCSR */
    nop

    ori   $25, $0, 0x50       /* 'P' */
    mtc0  $25, $7
    break
fail_a:
    ori   $25, $0, 0x41       /* 'A' -- ctc1 did not clear the FCC a branch reads */
    mtc0  $25, $7
    break
fail_b:
    ori   $25, $0, 0x42       /* 'B' -- ctc1 did not set the FCC a branch reads */
    mtc0  $25, $7
    break
fail_c:
    ori   $25, $0, 0x43       /* 'C' -- a compare never reached FCSR bit 23 */
    mtc0  $25, $7
    break
    .size main,.-main
