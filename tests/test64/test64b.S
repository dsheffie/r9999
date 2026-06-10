/* test64b.S -- kernel-exact Status setup (clears EXL/ERL, KSU=0, sets KX via or/xori)
 * then one daddiu. Isolates whether clearing EXL/ERL exposes a mode hazard. */
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type  main, @function
main:
    li    $t9, 0x41          /* 'A' */
    mtc0  $t9, $7
    mfc0  $t0, $12
    lui   $at, 0x1000
    ori   $at, $at, 0x9f
    or    $t0, $t0, $at      /* set CU0,KX,KSU=11,IE/EXL/ERL  */
    xori  $t0, $t0, 0x1f     /* clear IE/EXL/ERL, KSU->00 (kernel) ; KX stays 1 */
    mtc0  $t0, $12
    .word 0x000000c0         /* ehb */
    li    $t9, 0x42          /* 'B' */
    mtc0  $t9, $7
    daddiu $t1, $zero, 0x1234 /* 64-bit op */
    li    $t9, 0x43          /* 'C' : daddiu did NOT trap */
    mtc0  $t9, $7
    break
    .size main, .-main
