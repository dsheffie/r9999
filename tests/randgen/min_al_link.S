    /* Regression: MIPS *al branches link ra=pc+8 UNCONDITIONALLY, even when the
     * branch is NOT taken.  r9999 used to gate the link on takeBranch (exec.sv
     * t_result = t_take_br ? pc+8 : old_r31), which broke the glibc PIC bootstrap
     * `bltzal t0,.+8` (t0>=0, not taken) -> ra=0 -> ld.so SIGSEGV.
     * Each case forces NOT-taken, then checks ra == &(label after delay slot).
     * Prints 1234 if all four link; 'F' + break on the first failure. */
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type main,@function
main:
    /* --- bltzal, NOT taken (t0 = 0, not < 0) --- */
    li     $8, 0
    bltzal $8, La1
    nop
La1:
    la     $11, La1
    bne    $31, $11, fail
    nop
    li     $9, 0x31        /* '1' */
    mtc0   $9, $7

    /* --- bgezal, NOT taken (t0 = -1, not >= 0) --- */
    li     $8, -1
    bgezal $8, La2
    nop
La2:
    la     $11, La2
    bne    $31, $11, fail
    nop
    li     $9, 0x32        /* '2' */
    mtc0   $9, $7

    /* --- bltzall (likely), NOT taken (t0 = 0); delay slot nullified --- */
    li     $8, 0
    bltzall $8, La3
    nop
La3:
    la     $11, La3
    bne    $31, $11, fail
    nop
    li     $9, 0x33        /* '3' */
    mtc0   $9, $7

    /* --- bgezall (likely), NOT taken (t0 = -1); delay slot nullified --- */
    li     $8, -1
    bgezall $8, La4
    nop
La4:
    la     $11, La4
    bne    $31, $11, fail
    nop
    li     $9, 0x34        /* '4' */
    mtc0   $9, $7

    li     $9, 0x0a        /* '\n' */
    mtc0   $9, $7
    break

fail:
    li     $9, 0x46        /* 'F' */
    mtc0   $9, $7
    break
    .size main,.-main
