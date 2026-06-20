/*
 * test_ifetch_adel.S -- i-side (instruction fetch) Address Error test.
 *
 * The d-side counterpart (test_va_range.S) proves a DATA access to an
 * out-of-range mapped VA raises AdEL.  This proves the same for an INSTRUCTION
 * FETCH: jumping to a mapped, out-of-range VA must raise AdEL (ExcCode 4) with
 * BadVAddr = the fetch target -- NOT silently fetch garbage from a wrapped PA.
 *
 * Mechanism under test: l1i's mipsseg already computes bad_perms for the fetch
 * VA; we harvest it into insn_fetch_t.bad_va, and decode turns it into a
 * FETCH_ADDR_ERROR uop (priority ABOVE tlb_miss, since an OOR mapped VA also
 * misses the ITLB and Address Error outranks TLB refill).  Also exercises the
 * fetch-fault BadVAddr capture (r_addrs at alloc).
 *
 * 64-bit kernel (KX=1, BEV=0).  Jump to 0x0001_0000_0000_0000 (R=00 xkuseg,
 * bit 48 > SEGBITS=40).  Because the fault PC == the bad target, the handler
 * CANNOT eret back to EPC (it would re-fault forever) -- it redirects EPC to a
 * recovery label.  Verifies ExcCode==4 and BadVAddr==the target.
 * Self-contained (own reset entry + handler at the BEV=0 0x80000180 vector).
 */

#include "sim.h"

    .set    mips3
    .set    noreorder
    .set    noat

    .macro  HALT
    li      $k0, 0xBFD00000
    li      $k1, 1
    sw      $k1, 0($k0)
1:  b       1b
    nop
    .endm

/* ---- general exception handler at 0x80000180 (BEV=0) ---- */
    .section .except_vec, "ax"
    .org    0x180
    .globl  _exc_handler
_exc_handler:
    la      $k0, exc_flag
    li      $k1, 1
    sw      $k1, 0($k0)         /* exc_flag = 1 */

    mfc0    $k0, $13            /* Cause */
    srl     $k0, $k0, 2
    andi    $k0, $k0, 0x1f      /* ExcCode */
    la      $k1, saved_cause
    sw      $k0, 0($k1)         /* saved_cause = ExcCode */

    dmfc0   $k0, $8             /* BadVAddr (full 64b -- target low 32b are 0) */
    la      $k1, saved_badvaddr
    sd      $k0, 0($k1)         /* saved_badvaddr = BadVAddr */

    /* the faulting PC == the bad target, so steer EPC at a good recovery point
     * instead of re-fetching the out-of-range address. */
    la      $k0, recover
    mtc0    $k0, $14            /* EPC = recover */
    eret
    nop

/* ---- reset entry ---- */
    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    li      $t0, 0x80           /* Status: KX=1 (64-bit kernel), BEV=0, EXL=0, ERL=0 */
    mtc0    $t0, $12
    nop
    nop
    nop

    la      $t0, exc_flag
    sw      $zero, 0($t0)
    la      $t0, saved_cause
    sw      $zero, 0($t0)
    la      $t0, saved_badvaddr
    sd      $zero, 0($t0)

    la      $a0, msg_start
    jal     sim_puts
    nop

    /* out-of-range mapped fetch target: 0x0001_0000_0000_0000 (bit 48 > SEGBITS) */
    lui     $t1, 0x0001
    dsll32  $t1, $t1, 0
    .globl  test_oor_target
test_oor_target:
    jr      $t1                 /* fetch of target -> AdEL (ExcCode 4) */
    nop                         /* delay slot (good addr, executes) */

    /* execution resumes here via the handler's EPC redirect */
    .globl  recover
recover:
    /* verify the handler was reached */
    la      $t0, exc_flag
    lw      $t1, 0($t0)
    beq     $t1, $zero, fail_not_taken
    nop
    /* ExcCode == 4 (AdEL) */
    la      $t0, saved_cause
    lw      $t1, 0($t0)
    li      $t2, 4
    bne     $t1, $t2, fail_wrong_cause
    nop
    /* BadVAddr == 0x0001_0000_0000_0000 (the fetch target) */
    la      $t0, saved_badvaddr
    ld      $t1, 0($t0)
    lui     $t2, 0x0001
    dsll32  $t2, $t2, 0
    bne     $t1, $t2, fail_wrong_badvaddr
    nop

    la      $a0, msg_pass
    jal     sim_puts
    nop
    HALT

fail_not_taken:
    la      $a0, msg_fail_taken
    jal     sim_puts
    nop
    HALT

fail_wrong_cause:
    la      $a0, msg_fail_cause
    jal     sim_puts
    nop
    HALT

fail_wrong_badvaddr:
    la      $a0, msg_fail_badvaddr
    jal     sim_puts
    nop
    HALT

/* ---- sim_puts: print NUL-terminated string at $a0 ---- */
    .globl  sim_puts
sim_puts:
1:  lb      $t9, 0($a0)
    beq     $t9, $zero, 2f
    nop
    mtc0    $t9, $7
    addiu   $a0, $a0, 1
    b       1b
    nop
2:  jr      $ra
    nop

    .section .rodata
msg_start:           .asciz "i-fetch AdEL test\n"
msg_pass:            .asciz "PASS\n"
msg_fail_taken:      .asciz "FAIL: no Address Error raised\n"
msg_fail_cause:      .asciz "FAIL: wrong ExcCode (expected 4=AdEL)\n"
msg_fail_badvaddr:   .asciz "FAIL: wrong BadVAddr (expected fetch target)\n"

    .data
    .globl exc_flag
exc_flag:        .word 0
    .globl saved_cause
saved_cause:     .word 0
    .globl saved_badvaddr
    .align 3
saved_badvaddr:  .dword 0
