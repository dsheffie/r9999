/* FP compare predicates beyond EQ/LT/LE: OLT, ULT, UEQ, UN, OLE -- with ordered
 * and NaN operands.  Each c.cond.s writes cc0; CKT/CKF branch-to-continue on the
 * expected outcome (bc1t/bc1f), else fall to fail.  Co-sim (--checker) validates
 * the branch outcomes; -c0 self-check prints 'P'.
 *   1.0=0x3f800000  2.0=0x40000000  qNaN=0x7fc00000
 */
    .set noreorder
    .set noat

    .macro  HALT
    li      $k0, 0xBFD00000
    li      $k1, 1
    sw      $k1, 0($k0)
1:  b       1b
    nop
    .endm

    /* expect cc0 == TRUE: continue, else fail (\@ = unique label per use) */
    .macro  CKT
    nop
    nop
    bc1t    ck_ok\@
    nop
    b       fail
    nop
ck_ok\@:
    .endm
    /* expect cc0 == FALSE */
    .macro  CKF
    nop
    nop
    bc1f    ck_ok\@
    nop
    b       fail
    nop
ck_ok\@:
    .endm

    .text
    .globl main
    .type main,@function
main:
    lui   $4, 0x3f80          /* 1.0 */
    lui   $5, 0x4000          /* 2.0 */
    lui   $6, 0x7fc0          /* qNaN */

    /* OLT(1,2) = true */
    mtc1  $4, $f0
    mtc1  $5, $f2
    c.olt.s $f0, $f2
    CKT

    /* OLT(2,1) = false */
    mtc1  $5, $f0
    mtc1  $4, $f2
    c.olt.s $f0, $f2
    CKF

    /* UEQ(1,1) = true */
    mtc1  $4, $f0
    mtc1  $4, $f2
    c.ueq.s $f0, $f2
    CKT

    /* OLE(2,2) = true */
    mtc1  $5, $f0
    mtc1  $5, $f2
    c.ole.s $f0, $f2
    CKT

    /* UN(1,NaN) = true */
    mtc1  $4, $f0
    mtc1  $6, $f2
    c.un.s $f0, $f2
    CKT

    /* OLT(1,NaN) = false (ordered, NaN) */
    mtc1  $4, $f0
    mtc1  $6, $f2
    c.olt.s $f0, $f2
    CKF

    /* ULT(1,NaN) = true (unordered) */
    mtc1  $4, $f0
    mtc1  $6, $f2
    c.ult.s $f0, $f2
    CKT

    li    $25, 0x50           /* 'P' */
    mtc0  $25, $7
    HALT
fail:
    li    $25, 0x46           /* 'F' */
    mtc0  $25, $7
    HALT
