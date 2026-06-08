/*
 * arcs_fw.S  --  minimal synthetic SGI ARCS firmware for the r9999 simulator.
 *
 * A 64-bit MIPS Linux IP22 kernel's PROMLIB (arch/mips/fw/arc) expects an ARCS
 * "System Parameter Block" (SPB) at physical 0x1000 (kseg1 0xA0001000) with a
 * magic cookie and a pointer to a "romvec" table of firmware callbacks.  This
 * file provides a just-enough SPB + romvec + callback stubs so the kernel gets
 * past prom_init, can print (Write -> CP0 putchar), and can size memory
 * (GetMemoryDescriptor).
 *
 * The kernel is built CONFIG_FW_ARC32, so this is the 32-bit ARC ABI: romvec
 * entries are 32-bit pointers (stride 4) and calls use the O32 convention
 * (args a0..a3, return v0).  Everything is linked at kseg1 0xA0001000 (see
 * arcs.ld) so the absolute pointers below resolve correctly; objcopy -O binary
 * then yields a flat image loaded at PA 0x1000 (vaddr & 0x1fffffff).
 *
 * Memory layout (section offsets from 0xA0001000):
 *   0x000  SPB         (magic @ +0x00, romvec ptr @ +0x20)
 *   0x100  romvec      (37 x u32; live slots get_mdesc@0x48, write@0x6c, get_evar@0x78)
 *   0x200  stubs + data
 */

#include "sim.h"     /* SIMCON_PUTCHAR / magic-halt address conventions */

/* Physical RAM the kernel may use, advertised via GetMemoryDescriptor.
 * IP22 main RAM is based at physical 0x08000000; describe a block there. */
#ifndef ARCS_RAM_BASE
#define ARCS_RAM_BASE   0x08000000
#endif
#ifndef ARCS_RAM_SIZE
#define ARCS_RAM_SIZE   0x08000000      /* 128 MiB */
#endif
#define ARCS_RAM_BASE_PG (ARCS_RAM_BASE >> 12)
#define ARCS_RAM_PAGES   (ARCS_RAM_SIZE >> 12)

    .set    mips3
    .set    noreorder
    .set    noat

    .section .arcs, "ax"

/* ====================================================================
 * System Parameter Block @ 0xA0001000  (32-bit ARC layout)
 * ==================================================================== */
    .globl  arcs_spb
arcs_spb:
    .word   0x53435241          /* +0x00 magic ("ARCS") */
    .word   0x00000094          /* +0x04 len (informational) */
    .short  64                  /* +0x08 ver */
    .short  0                   /* +0x0a rev */
    .word   0                   /* +0x0c rs_block  (restart block) */
    .word   0                   /* +0x10 dbg_block */
    .word   0                   /* +0x14 gevect */
    .word   0                   /* +0x18 utlbvect */
    .word   0x00000094          /* +0x1c rveclen (37 * 4) */
    .word   arcs_romvec         /* +0x20 romvec  -> 0xA0001100 */
    .word   0                   /* +0x24 pveclen */
    .word   0                   /* +0x28 pvector */
    .word   0                   /* +0x2c adap_cnt */

/* ====================================================================
 * romvec @ 0xA0001100  (struct linux_romvec, 37 x u32)
 * Live slots: get_mdesc(18,@0x48), write(27,@0x6c), get_evar(30,@0x78).
 * halt/pdown/restart/reboot -> clean sim halt; everything else -> return 0.
 * ==================================================================== */
    .org    0x100
    .globl  arcs_romvec
arcs_romvec:
    .word   stub_default        /*  0 load                */
    .word   stub_default        /*  1 invoke              */
    .word   stub_default        /*  2 exec                */
    .word   stub_halt           /*  3 halt                */
    .word   stub_halt           /*  4 pdown               */
    .word   stub_halt           /*  5 restart             */
    .word   stub_halt           /*  6 reboot              */
    .word   stub_default        /*  7 imode               */
    .word   stub_default        /*  8 _unused1            */
    .word   stub_default        /*  9 next_component      */
    .word   stub_child          /* 10 child_component     */
    .word   stub_default        /* 11 parent_component    */
    .word   stub_default        /* 12 component_data      */
    .word   stub_default        /* 13 child_add           */
    .word   stub_default        /* 14 comp_del            */
    .word   stub_default        /* 15 component_by_path   */
    .word   stub_default        /* 16 cfg_save            */
    .word   stub_default        /* 17 get_sysid           */
    .word   stub_mdesc          /* 18 get_mdesc      @0x48 */
    .word   stub_default        /* 19 _unused2            */
    .word   stub_default        /* 20 get_tinfo           */
    .word   stub_default        /* 21 get_rtime           */
    .word   stub_default        /* 22 get_vdirent         */
    .word   stub_default        /* 23 open                */
    .word   stub_default        /* 24 close               */
    .word   stub_default        /* 25 read                */
    .word   stub_default        /* 26 get_rstatus         */
    .word   stub_write          /* 27 write          @0x6c */
    .word   stub_default        /* 28 seek                */
    .word   stub_default        /* 29 mount               */
    .word   stub_getenv         /* 30 get_evar       @0x78 */
    .word   stub_default        /* 31 set_evar            */
    .word   stub_default        /* 32 get_finfo           */
    .word   stub_default        /* 33 set_finfo           */
    .word   stub_default        /* 34 cache_flush         */
    .word   stub_default        /* 35 TestUnicodeCharacter */
    .word   stub_default        /* 36 GetDisplayStatus    */

/* ====================================================================
 * Callback stubs @ 0xA0001200  (O32: args a0..a3, return v0)
 * ==================================================================== */
    .org    0x200

/* LONG Write(handle a0, void *buf a1, ULONG len a2, ULONG *cnt a3)
 * Write len bytes from buf to the console (CP0 reg 7 putchar); *cnt = len;
 * return 0 (ESUCCESS). */
    .globl  stub_write
stub_write:
    move    $t0, $a2            /* remaining = len */
    move    $t1, $a1            /* p = buf */
1:
    blez    $t0, 2f
    nop
    lb      $t2, 0($t1)
    mtc0    $t2, $7             /* putchar */
    addiu   $t1, $t1, 1
    b       1b
    addiu   $t0, $t0, -1        /* (delay slot) */
2:
    beq     $a3, $zero, 3f
    nop
    sw      $a2, 0($a3)         /* *cnt = len */
3:
    jr      $ra
    move    $v0, $zero          /* return ESUCCESS (delay slot) */

/* struct linux_mdesc *GetMemoryDescriptor(struct linux_mdesc *cur a0)
 * First call (cur==NULL) returns our single RAM descriptor; then NULL. */
    .globl  stub_mdesc
stub_mdesc:
    bne     $a0, $zero, 1f
    nop
    la      $v0, mdesc_ram      /* first call -> our descriptor */
    jr      $ra
    nop
1:
    jr      $ra
    move    $v0, $zero          /* end of list (delay slot) */

/* char *GetEnvironmentVariable(char *name a0) -> NULL (use CONFIG_CMDLINE) */
    .globl  stub_getenv
stub_getenv:
    jr      $ra
    move    $v0, $zero

/* pcomponent *GetChild(pcomponent *cur a0)
 * prom_identify_arch() calls GetChild(NULL) to get the root component and reads
 * its ->iname to identify the machine.  Return our root for the NULL query
 * (the system/root component named "SGI-IP22"); NULL otherwise. */
    .globl  stub_child
stub_child:
    bne     $a0, $zero, 1f
    nop
    la      $v0, root_component
    jr      $ra
    nop
1:
    jr      $ra
    move    $v0, $zero

/* Default callback: return 0 cleanly (no wild jumps for unimplemented calls) */
    .globl  stub_default
stub_default:
    jr      $ra
    move    $v0, $zero

/* halt/restart/reboot: stop the simulator via the magic-halt register */
    .globl  stub_halt
stub_halt:
    li      $k0, 0xBFD00000
    li      $k1, 1
    sw      $k1, 0($k0)
1:
    b       1b
    nop

/* ====================================================================
 * Data: memory descriptor (struct linux_mdesc { type; base_pg; pages; })
 * type = 2 (arcs_fcontig = free; IP22 sets PROM_FLAG_ARCS).
 * ==================================================================== */
    .align  3
    .globl  mdesc_ram
mdesc_ram:
    .word   2                   /* type: arcs_fcontig (free RAM) */
    .word   ARCS_RAM_BASE_PG    /* base page (0x08000000 >> 12) */
    .word   ARCS_RAM_PAGES      /* page count */

/* Root ARC component (struct linux_component, 32-bit ARC).  Only ->iname is
 * read by prom_identify_arch; the rest is benign.  iname -> "SGI-IP22". */
    .align  3
    .globl  root_component
root_component:
    .word   1                   /* +0x00 class (SystemClass) */
    .word   1                   /* +0x04 type  */
    .word   0                   /* +0x08 iflags */
    .short  0                   /* +0x0c vers */
    .short  0                   /* +0x0e rev */
    .word   0                   /* +0x10 key */
    .word   0                   /* +0x14 amask */
    .word   0                   /* +0x18 cdsize */
    .word   8                   /* +0x1c ilen (strlen "SGI-IP22") */
    .word   arch_name           /* +0x20 iname -> identifier string */

arch_name:
    .asciz  "SGI-IP22"
