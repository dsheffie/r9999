/* test64.S -- isolate the 64-bit-op (daddiu) Reserved-Instruction bug.
 * Mirrors kernel_entry: set Status.KX, ehb, then a single daddiu.
 * Markers via mtc0 $7 (console): expect "ABC" if daddiu executes,
 * "AB" (+ trap to exc vector in the PC trace) if it RIs.
 */
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type  main, @function
main:
    li    $t9, 0x41          /* 'A' : reached main            */
    mtc0  $t9, $7
    mfc0  $t0, $12           /* read Status (SR)              */
    ori   $t0, $t0, 0x0080   /* set KX (bit 7)                */
    mtc0  $t0, $12           /* write Status -> KX=1          */
    .word 0x000000c0         /* ehb  (exact kernel_entry hazard barrier) */
    li    $t9, 0x42          /* 'B' : KX set, about to daddiu */
    mtc0  $t9, $7
    daddiu $t1, $zero, 0x1234 /* <-- 64-bit op under test       */
    li    $t9, 0x43          /* 'C' : daddiu did NOT trap     */
    mtc0  $t9, $7
    break
    .size main, .-main
