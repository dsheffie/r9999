/* TDD test: cfc1/ctc1 — FP control register read/write.
 *  - ctc1 writes FCR31 (FCSR); cfc1 reads it back (round-trip).
 *  - cfc1 reads FCR0 (FIR) -> the read-only R4000 FPU id (0x00000500).
 * Runs under the co-sim checker, so RTL and the interpreter must agree
 * instruction-by-instruction in addition to the PASS/FAIL self-check.
 */
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type main,@function
main:
    /* enable CU1 in Status so the FP control ops are legal */
    mfc0  $2, $12             /* read Status */
    lui   $3, 0x2000          /* CU1 = bit 29 */
    or    $2, $2, $3
    mtc0  $2, $12
    nop
    nop

    /* ctc1 FCR31 = 0x0140000c, then cfc1 read it back */
    lui   $8, 0x0140
    ori   $8, $8, 0x000c      /* $8 = 0x0140000c */
    ctc1  $8, $31             /* FCSR <- $8 */
    nop
    cfc1  $9, $31             /* $9 <- FCSR */
    nop
    bne   $8, $9, fail
    nop

    /* cfc1 FCR0 (FIR) -> must read the R4000 FPU id 0x00000500 */
    cfc1  $10, $0
    nop
    lui   $11, 0x0000
    ori   $11, $11, 0x0500
    bne   $10, $11, fail
    nop

    ori   $25, $0, 0x50       /* 'P' */
    mtc0  $25, $7
    break
fail:
    ori   $25, $0, 0x46       /* 'F' */
    mtc0  $25, $7
    break
    .size main,.-main
