/*
 * fp_fr0.S -- FR=0 (o32) FP-compute register rules.
 *
 * In FR=0 the FPRs are 16 even/odd 32-bit pairs and ARITHMETIC is even-register
 * only (R10000 UM p.307).  An odd register on a compute op is UNPREDICTABLE in
 * the MIPS ISA (no mandated exception; Sail doesn't even model FR) -- r9999
 * CHOOSES a loud Reserved Instruction (ExcCode 10) rather than the R10000's
 * silent force-to-even.  This checks:
 *   T1: FR=0, EVEN-reg add.s  -> runs, 1.0+2.0=3.0, no fault.
 *   T2: FR=0, ODD-reg  add.s  -> Reserved Instruction (cause 10).  (.word: gas
 *       refuses odd FP regs under .set mips3.)
 *   T3: FR=1, ODD-reg  add.s  -> runs, no fault (FR=1 has no even/odd rule).
 * Prints 'P'/'F'.  Self-contained (own vectors, no crt0).  Run under -c 0.
 *   1.0=0x3f800000  2.0=0x40000000  3.0=0x40400000
 *   add.s $f5,$f0,$f2 (fd=$f5 odd) = 0x46020140
 *   Status: CU1=1 (bit29); FR = bit26.
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

/* handler @0x80000180: record ExcCode, skip the faulting insn, return. */
    .section .except_vec, "ax"
    .org    0x180
_exc_handler:
    la      $k0, fpe_flag
    li      $k1, 1
    sw      $k1, 0($k0)
    mfc0    $k0, $13
    srl     $k0, $k0, 2
    andi    $k0, $k0, 0x1f
    la      $k1, fpe_code
    sw      $k0, 0($k1)
    mfc0    $k0, $14
    addiu   $k0, $k0, 4
    mtc0    $k0, $14
    eret
    nop

    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    li      $t0, 0x20000000     /* Status: CU1=1, FR=0 (bit26 clear), BEV=0, kernel */
    mtc0    $t0, $12
    nop
    nop
    nop
    la      $19, fpe_flag

    /* ---- T1: FR=0 even-reg add.s -> runs, 3.0 ---- */
    sw      $0, 0($19)
    lui     $8, 0x3f80          /* 1.0 */
    mtc1    $8, $f0
    lui     $8, 0x4000          /* 2.0 */
    mtc1    $8, $f2
    add.s   $f4, $f0, $f2       /* even regs -> legal in FR=0 */
    nop
    nop
    nop
    nop
    lw      $2, 0($19)
    bne     $2, $0, fail        /* must NOT fault */
    nop
    mfc1    $9, $f4
    lui     $3, 0x4040          /* 3.0 */
    bne     $9, $3, fail
    nop

    /* ---- T2: FR=0 odd-reg add.s -> Reserved Instruction (cause 10) ---- */
    sw      $0, 0($19)
    .word   0x46020140          /* add.s $f5,$f0,$f2 (fd=$f5 odd) */
    nop
    nop
    nop
    nop
    lw      $2, 0($19)
    beq     $2, $0, fail        /* must fault */
    nop
    la      $4, fpe_code
    lw      $2, 0($4)
    li      $3, 10              /* Reserved Instruction */
    bne     $2, $3, fail
    nop

    /* ---- T2b: FR=0 even-reg ldc1/sdc1 -> valid full-64 (no fault, roundtrip) ---- */
    la      $14, dbl
    sw      $0, 0($19)
    ldc1    $f0, 0($14)         /* even reg: legal in FR=0, full 64 */
    nop
    nop
    sdc1    $f0, 8($14)
    nop
    nop
    lw      $2, 0($19)
    bne     $2, $0, fail        /* must NOT fault */
    nop
    lw      $9, 8($14)          /* hi(roundtripped) */
    lw      $3, 0($14)
    bne     $9, $3, fail        /* roundtrip hi word matches */
    nop

    /* ---- T2c: FR=0 odd-reg ldc1 -> invalid -> RI (.word: ldc1 $f1,0($14)) ---- */
    sw      $0, 0($19)
    .word   0xd5c10000          /* ldc1 $f1, 0($14)  (ft=$f1 odd) */
    nop
    nop
    nop
    nop
    lw      $2, 0($19)
    beq     $2, $0, fail        /* must fault */
    nop
    la      $4, fpe_code
    lw      $2, 0($4)
    li      $3, 10
    bne     $2, $3, fail
    nop

    /* ---- T2d: FR=0 mfc1 extract -- even reg = low half, odd reg = high half ----
     * dbl[0] = 0x400921fb54442d18 -> low=0x54442d18, high=0x400921fb */
    ldc1    $f0, 0($14)
    nop
    nop
    sw      $0, 0($19)
    mfc1    $9, $f0             /* even -> low half */
    nop
    nop
    nop
    .word   0x440a0800          /* mfc1 $10, $f1 -> high half */
    nop
    nop
    nop
    lw      $2, 0($19)
    bne     $2, $0, fail        /* must NOT fault */
    nop
    lui     $3, 0x5444
    ori     $3, $3, 0x2d18      /* 0x54442d18 (low) */
    bne     $9, $3, fail
    nop
    lui     $3, 0x4009
    ori     $3, $3, 0x21fb      /* 0x400921fb (high) */
    bne     $10, $3, fail
    nop

    /* ---- T2e: FR=0 mtc1 merge -- overwrite one half, preserve the other ----
     * ldc1 $f0=0x400921fb54442d18; mtc1 $f0 low<-0x11112222; mtc1 $f1 high<-0x33334444 */
    ldc1    $f0, 0($14)
    nop
    nop
    sw      $0, 0($19)
    lui     $8, 0x1111
    ori     $8, $8, 0x2222
    mtc1    $8, $f0             /* even -> overwrite LOW half */
    nop
    nop
    nop
    nop
    mfc1    $9, $f0             /* low = 0x11112222 */
    bne     $9, $8, fail
    nop
    .word   0x440a0800          /* mfc1 $10,$f1 -> high (unchanged) = 0x400921fb */
    nop
    nop
    nop
    lui     $3, 0x4009
    ori     $3, $3, 0x21fb
    bne     $10, $3, fail       /* high half preserved by the low-half merge */
    nop
    lui     $8, 0x3333
    ori     $8, $8, 0x4444
    .word   0x44880800          /* mtc1 $8,$f1 -> overwrite HIGH half */
    nop
    nop
    nop
    nop
    .word   0x440a0800          /* mfc1 $10,$f1 -> high = 0x33334444 */
    nop
    nop
    nop
    bne     $10, $8, fail
    nop
    mfc1    $9, $f0             /* low still = 0x11112222 (preserved) */
    lui     $3, 0x1111
    ori     $3, $3, 0x2222
    bne     $9, $3, fail
    nop
    lw      $2, 0($19)
    bne     $2, $0, fail        /* none of the above faulted */
    nop

    /* ---- T2f: FR=0 swc1 extract -- even stores low half, odd stores high half ---- */
    sw      $0, 0($19)
    swc1    $f0, 24($14)        /* even -> store low half (0x11112222) */
    nop
    nop
    .word   0xe5c1001c          /* swc1 $f1, 28($14) -> store high half (0x33334444) */
    nop
    nop
    lw      $2, 0($19)
    bne     $2, $0, fail        /* must NOT fault */
    nop
    lw      $9, 24($14)
    lui     $3, 0x1111
    ori     $3, $3, 0x2222
    bne     $9, $3, fail        /* low half stored */
    nop
    lw      $9, 28($14)
    lui     $3, 0x3333
    ori     $3, $3, 0x4444
    bne     $9, $3, fail        /* high half stored */
    nop

    /* ---- T2g: FR=0 lwc1 merge -- odd writes HIGH half (preserve low), even writes
     * LOW half (preserve high).  ldc1 $f0=0x400921fb54442d18; lwc1 $f1<-0xDEADBEEF
     * (high); lwc1 $f0<-0xCAFEBABE (low); sdc1 -> 0xDEADBEEFCAFEBABE ---- */
    lui     $8, 0xDEAD
    ori     $8, $8, 0xBEEF
    sw      $8, 16($14)         /* mem word for the odd lwc1 */
    lui     $8, 0xCAFE
    ori     $8, $8, 0xBABE
    sw      $8, 20($14)         /* mem word for the even lwc1 */
    ldc1    $f0, 0($14)         /* $f0 = 0x400921fb54442d18 */
    nop
    nop
    sw      $0, 0($19)
    .word   0xc5c10010          /* lwc1 $f1, 16($14) -> HIGH half (preserve low) */
    nop
    nop
    nop
    nop
    lwc1    $f0, 20($14)        /* even -> LOW half (preserve high) */
    nop
    nop
    nop
    nop
    lw      $2, 0($19)
    bne     $2, $0, fail        /* must NOT fault */
    nop
    sdc1    $f0, 24($14)        /* store the merged double */
    nop
    nop
    lw      $9, 24($14)         /* hi = 0xDEADBEEF (from the odd lwc1) */
    lui     $3, 0xDEAD
    ori     $3, $3, 0xBEEF
    bne     $9, $3, fail
    nop
    lw      $9, 28($14)         /* lo = 0xCAFEBABE (from the even lwc1) */
    lui     $3, 0xCAFE
    ori     $3, $3, 0xBABE
    bne     $9, $3, fail
    nop

    /* ---- T3: FR=1 odd-reg add.s -> runs, no fault ---- */
    li      $t0, 0x24000000     /* Status: CU1=1, FR=1 (bit26 set) */
    mtc0    $t0, $12
    nop
    nop
    nop
    sw      $0, 0($19)
    .word   0x46020140          /* add.s $f5,$f0,$f2 -- legal when FR=1 */
    nop
    nop
    nop
    nop
    lw      $2, 0($19)
    bne     $2, $0, fail        /* must NOT fault in FR=1 */
    nop

    li      $25, 0x50           /* 'P' */
    mtc0    $25, $7
    HALT
fail:
    li      $25, 0x46           /* 'F' */
    mtc0    $25, $7
    HALT

    .data
    .align  3
dbl:        .dword 0x400921fb54442d18  /* [0]  pi-ish double for ldc1/sdc1/mfc1 */
            .dword 0                    /* [8]  ldc1/sdc1 roundtrip dest */
            .dword 0                    /* [16] scratch */
            .dword 0                    /* [24] swc1 low/high store dest (24,28) */
fpe_flag:   .word 0
fpe_code:   .word 0
