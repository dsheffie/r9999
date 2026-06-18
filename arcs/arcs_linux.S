/*
 * arcs_linux.S  --  IP22-faithful synthetic ARCS firmware for booting IP22 Linux.
 *
 * Structured like a real IP22: a first-stage boot loader (FSBL) lives in the
 * Boot PROM at kseg1 0xBFC00000 (phys 0x1fc00000, the CPU reset vector). At
 * reset the FSBL COPIES the small SPB/romvec block from the PROM into RAM at
 * kseg1 0xA0001000 (phys 0x1000), then stages the sash argv/envp and jumps to
 * the kernel.  The ARCS callback stubs stay in the PROM; the romvec entries
 * (copied to 0xA0001000) point back at them.
 *
 * Why FSBL+copy instead of loading the whole blob at 0x1000: with the IP22
 * "System Memory Alias" (mc.pdf 4) phys 0x0..0x7ffff maps into the bottom of
 * main DRAM @ 0x08000000, where the kernel _text loads at phys 0x08004000.
 * The full 16 KB blob at 0x1000 (->0x08001000) would overlap _text; copying
 * only the ~3 KB SPB there (below _text) does not, and the stub code stays in
 * the PROM shadow far from the kernel.  See arcs_linux.ld.
 *
 * Loaded as one flat blob into the PROM region (the address map shadows it into
 * DRAM); core resets to 0xBFC00000.  Build: see the Makefile arcs_linux target.
 */

#include "sim.h"

/* Free-RAM descriptor base: reserve the low 16 KiB of main memory (phys
 * 0x08000000..0x08003fff) -- with the System Memory Alias that region backs the
 * CPU exception vectors (phys 0/0x80, aliased here) and the SPB the FSBL copies
 * to phys 0x1000.  It sits below the kernel _text @ 0x08004000, so reporting
 * free RAM from 0x08004000 keeps the kernel mm from freeing/allocating over the
 * vectors (which on real IP22 the firmware likewise reserves). */
#ifndef ARCS_RAM_BASE
#define ARCS_RAM_BASE   0x08004000
#endif
#ifndef ARCS_RAM_SIZE
#define ARCS_RAM_SIZE   0x07ffc000      /* 128 MiB - 16 KiB low-reserved */
#endif
#define ARCS_RAM_BASE_PG (ARCS_RAM_BASE >> 12)
#define ARCS_RAM_PAGES   (ARCS_RAM_SIZE >> 12)

    .set    ARCS_BB,   0x88fff000       /* runtime base for the argv/envp blob */
    .set    ARCS_ARGC, 8
    .set    ARCS_KENTRY, 0x8832c118     /* default Linux entry (driver patches the slot) */

    .set    mips3
    .set    noreorder
    .set    noat

/* ====================================================================
 * PROM: first-stage boot loader @ 0xBFC00000 (the CPU reset vector).
 * ==================================================================== */
    .section .arcs_boot, "ax"
    .globl  arcs_boot
arcs_boot:
    b       fsbl                    /* 0xBFC00000: skip the patch slot */
    nop
    .globl  arcs_kentry_slot
arcs_kentry_slot:                   /* 0xBFC00008: driver patches kernel e_entry (BE) */
    .word   ARCS_KENTRY
fsbl:
    /* (0) FSBL: copy the SPB/romvec block PROM(_spb_lma) -> RAM 0xA0001000.
     * 0xA0001000 is kseg1 (uncached, so the kernel's later reads see it) and the
     * System Memory Alias lands it in real DRAM @ 0x08001000. */
    la      $t0, _spb_lma           /* src in PROM */
    li      $t1, 0xA0001000         /* dst in RAM */
    la      $t2, _spb_size
    addu    $t2, $t0, $t2           /* src end */
1:  lw      $t3, 0($t0)
    sw      $t3, 0($t1)
    addiu   $t0, $t0, 4
    addiu   $t1, $t1, 4
    bne     $t0, $t2, 1b
    nop

    /* (1) SCC heartbeat: poll RR0.TxEmpty @0xbfbd9830, write DATA @0xbfbd9837 */
    lui     $t4, 0xbfbd
    ori     $t5, $t4, 0x9830
    ori     $t6, $t4, 0x9837
    la      $t1, arcs_hb_str
2:  lbu     $t2, 0($t1)
    beq     $t2, $zero, 3f
    nop
9:  lbu     $t3, 0($t5)
    andi    $t3, $t3, 0x04
    beq     $t3, $zero, 9b
    nop
    sb      $t2, 0($t6)
    addiu   $t1, $t1, 1
    b       2b
    nop
3:
    /* (2) copy the argv/envp blob to kseg0 0x88fff000 */
    la      $t0, arcs_argv_blob
    la      $t2, arcs_argv_blob_end
    li      $t1, ARCS_BB
4:  lbu     $t3, 0($t0)
    sb      $t3, 0($t1)
    addiu   $t0, $t0, 1
    addiu   $t1, $t1, 1
    bne     $t0, $t2, 4b
    nop

    /* (3) entry regs + jump to the kernel */
    li      $a0, ARCS_ARGC
    li      $a1, ARCS_BB
    addiu   $a2, $a1, (arcs_envp_arr - arcs_argv_blob)   /* a2 = envp array */
    addiu   $a1, $a1, (arcs_argv_arr - arcs_argv_blob)   /* a1 = argv array */
    move    $a3, $zero
    move    $v0, $zero
    move    $v1, $zero
    move    $t0, $zero
    move    $t1, $zero
    move    $t2, $zero
    move    $t3, $zero
    move    $t4, $zero
    move    $t5, $zero
    move    $t6, $zero
    move    $t7, $zero
    move    $t8, $zero
    move    $t9, $zero
    la      $k0, arcs_kentry_slot   /* 0xBFC00008, kseg1 uncached -> sees driver patch */
    lw      $k0, 0($k0)
    jr      $k0
    nop

    .align  2
arcs_hb_str:
    .asciz  "r9999 PROM: CPU alive, handing off to Linux\n"

/* sash argv/envp blob (mirrors pseudo_bios.cc); pointers computed for runtime
 * base ARCS_BB = 0x88fff000.  Copied there by the FSBL above. */
    .align  2
    .globl  arcs_argv_blob
arcs_argv_blob:
s_a0:  .asciz "scsi(0)disk(1)rdisk(0)partition(0)/unix"
s_a1:  .asciz "OSLoadOptions=auto"
s_a2:  .asciz "ConsoleIn=serial(0)"
s_a3:  .asciz "ConsoleOut=serial(0)"
s_a4:  .asciz "SystemPartition=scsi(0)disk(1)rdisk(0)partition(8)"
s_a5:  .asciz "OSLoader=sash"
s_a6:  .asciz "OSLoadPartition=scsi(0)disk(1)rdisk(0)partition(0)"
s_a7:  .asciz "OSLoadFilename=/unix"
s_e0:  .asciz "AutoLoad=Yes"
s_e1:  .asciz "TimeZone=PST8PDT"
s_e2:  .asciz "console=d"
s_e3:  .asciz "diskless=0"
s_e4:  .asciz "dbaud=9600"
s_e5:  .asciz "volume=80"
s_e6:  .asciz "sgilogo=y"
s_e7:  .asciz "autopower=y"
s_e8:  .asciz "eaddr=08:01:02:03:04:05"
s_e9:  .asciz "ConsoleOut=serial(0)"
s_e10: .asciz "ConsoleIn=serial(0)"
s_e11: .asciz "cpufreq=100"
s_e12: .asciz "SystemPartition=scsi(0)disk(1)rdisk(0)partition(8)"
s_e13: .asciz "OSLoadPartition=scsi(0)disk(1)rdisk(0)partition(0)"
s_e14: .asciz "OSLoadFilename=/unix"
s_e15: .asciz "OSLoader=sash"
s_e16: .asciz "kernname=scsi(0)disk(1)rdisk(0)partition(0)/unix"
    .align  2
arcs_argv_arr:
    .word   ARCS_BB+(s_a0-arcs_argv_blob), ARCS_BB+(s_a1-arcs_argv_blob)
    .word   ARCS_BB+(s_a2-arcs_argv_blob), ARCS_BB+(s_a3-arcs_argv_blob)
    .word   ARCS_BB+(s_a4-arcs_argv_blob), ARCS_BB+(s_a5-arcs_argv_blob)
    .word   ARCS_BB+(s_a6-arcs_argv_blob), ARCS_BB+(s_a7-arcs_argv_blob)
    .word   0
arcs_envp_arr:
    .word   ARCS_BB+(s_e0-arcs_argv_blob),  ARCS_BB+(s_e1-arcs_argv_blob)
    .word   ARCS_BB+(s_e2-arcs_argv_blob),  ARCS_BB+(s_e3-arcs_argv_blob)
    .word   ARCS_BB+(s_e4-arcs_argv_blob),  ARCS_BB+(s_e5-arcs_argv_blob)
    .word   ARCS_BB+(s_e6-arcs_argv_blob),  ARCS_BB+(s_e7-arcs_argv_blob)
    .word   ARCS_BB+(s_e8-arcs_argv_blob),  ARCS_BB+(s_e9-arcs_argv_blob)
    .word   ARCS_BB+(s_e10-arcs_argv_blob), ARCS_BB+(s_e11-arcs_argv_blob)
    .word   ARCS_BB+(s_e12-arcs_argv_blob), ARCS_BB+(s_e13-arcs_argv_blob)
    .word   ARCS_BB+(s_e14-arcs_argv_blob), ARCS_BB+(s_e15-arcs_argv_blob)
    .word   ARCS_BB+(s_e16-arcs_argv_blob)
    .word   0
    .globl  arcs_argv_blob_end
arcs_argv_blob_end:

/* ====================================================================
 * PROM: ARCS callback stubs + the data they return (O32: args a0..a3, ret v0).
 * The romvec (in the SPB block @ 0xA0001000) points here (PROM addresses).
 * ==================================================================== */
    .section .arcs_code, "ax"

/* LONG Write(handle, void *buf, ULONG len, ULONG *cnt): write to CP0 putchar. */
    .globl  stub_write
stub_write:
    move    $t0, $a2
    move    $t1, $a1
1:  blez    $t0, 2f
    nop
    lb      $t2, 0($t1)
9:  mfc0    $t3, $7
    andi    $t3, $t3, 1
    bne     $t3, $zero, 9b
    nop
    mtc0    $t2, $7
    addiu   $t1, $t1, 1
    b       1b
    addiu   $t0, $t0, -1
2:  beq     $a3, $zero, 3f
    nop
    sw      $a2, 0($a3)
3:  jr      $ra
    move    $v0, $zero

/* MEMORYDESCRIPTOR *GetMemoryDescriptor(MEMORYDESCRIPTOR *cur):
 * first call (cur==NULL) returns our one free-RAM descriptor; then NULL. */
    .globl  stub_mdesc
stub_mdesc:
    bne     $a0, $zero, 1f
    nop
    la      $v0, mdesc_ram
    jr      $ra
    nop
1:  jr      $ra
    move    $v0, $zero

/* char *GetEnvironmentVariable(char *name): return a fixed eaddr (MAC) string. */
    .globl  stub_getenv
stub_getenv:
    la      $v0, eaddr_str
    jr      $ra
    nop

/* COMPONENT *GetChild(COMPONENT *cur): root for NULL query, else NULL. */
    .globl  stub_child
stub_child:
    bne     $a0, $zero, 1f
    nop
    la      $v0, root_component
    jr      $ra
    nop
1:  jr      $ra
    move    $v0, $zero

/* COMPONENT *GetPeer(COMPONENT *cur): no peers -> NULL. */
    .globl  stub_peer
stub_peer:
    jr      $ra
    move    $v0, $zero

/* Default: return 0 cleanly. */
    .globl  stub_default
stub_default:
    jr      $ra
    move    $v0, $zero

/* Halt/PowerDown/Restart/Reboot: stop the simulator (magic-halt register). */
    .globl  stub_halt
stub_halt:
    li      $k0, 0xBFD00000
    li      $k1, 1
    sw      $k1, 0($k0)
1:  b       1b
    nop

/* ARCS memory descriptor { ULONG Type; ULONG BasePage; ULONG PageCount; }
 * Type 2 = FreeContiguous (Linux arc memory.c: type 2 = free RAM). */
    .align  3
    .globl  mdesc_ram
mdesc_ram:
    .word   2
    .word   ARCS_RAM_BASE_PG
    .word   ARCS_RAM_PAGES

/* Root ARCS component; only ->iname ("SGI-IP22") is typically read. */
    .align  3
    .globl  root_component
root_component:
    .word   1                   /* class  */
    .word   1                   /* type   */
    .word   0                   /* flags  */
    .short  0                   /* version */
    .short  0                   /* revision */
    .word   0                   /* key    */
    .word   0                   /* affinity mask */
    .word   0                   /* config data size */
    .word   8                   /* identifier length */
    .word   arch_name           /* identifier -> "SGI-IP22" */

arch_name:
    .asciz  "SGI-IP22"

    .align  2
eaddr_str:
    .asciz  "08:00:69:12:34:56"     /* getenv("eaddr") -> SGI MAC (etoh parses this) */

/* ====================================================================
 * RAM image: ARCS System Parameter Block + romvec + pvec, linked at kseg1
 * 0xA0001000 but STORED in the PROM (LMA); the FSBL copies it here at reset.
 * The kernel reads PROMBLOCK == 0xA0001000.
 * ==================================================================== */
    .section .arcs_spb, "a"
    .globl  arcs_spb
arcs_spb:
    .word   0x53435241          /* +0x00 signature "ARCS" */
    .word   0x00000048          /* +0x04 SPBLength = 72 */
    .word   0x0001000a          /* +0x08 ARCS version 1, revision 10 */
    .word   0                   /* +0x0c RestartBlock */
    .word   0                   /* +0x10 DebugBlock */
    .word   0                   /* +0x14 GeneralException vector */
    .word   0                   /* +0x18 UTLB-miss vector */
    .word   0x0000008c          /* +0x1c FirmwareVectorLength = 140 (35 entries) */
    .word   arcs_romvec         /* +0x20 FirmwareVector -> 0xA0001800 */
    .word   0x00000034          /* +0x24 PrivateVectorLength = 52 (13 entries) */
    .word   arcs_pvec           /* +0x28 PrivateVector -> 0xA0001C00 */
    .word   0                   /* +0x2c AdapterCount = 0 */

    .org    0x800
    .globl  arcs_romvec
arcs_romvec:
    .word   stub_default        /*  0 Load                 */
    .word   stub_default        /*  1 Invoke               */
    .word   stub_default        /*  2 Execute              */
    .word   stub_halt           /*  3 Halt                 */
    .word   stub_halt           /*  4 PowerDown            */
    .word   stub_halt           /*  5 Restart              */
    .word   stub_halt           /*  6 Reboot               */
    .word   stub_default        /*  7 EnterInteractiveMode */
    .word   stub_default        /*  8 (reserved)           */
    .word   stub_peer           /*  9 GetPeer              */
    .word   stub_child          /* 10 GetChild             */
    .word   stub_default        /* 11 GetParent            */
    .word   stub_default        /* 12 GetConfigurationData */
    .word   stub_default        /* 13 AddChild             */
    .word   stub_default        /* 14 DeleteComponent      */
    .word   stub_default        /* 15 GetComponent         */
    .word   stub_default        /* 16 SaveConfiguration    */
    .word   stub_default        /* 17 GetSystemId          */
    .word   stub_mdesc          /* 18 GetMemoryDescriptor  */
    .word   stub_default        /* 19 (reserved)           */
    .word   stub_default        /* 20 GetTime              */
    .word   stub_default        /* 21 GetRelativeTime      */
    .word   stub_default        /* 22 GetDirectoryEntry    */
    .word   stub_default        /* 23 Open                 */
    .word   stub_default        /* 24 Close                */
    .word   stub_default        /* 25 Read                 */
    .word   stub_default        /* 26 GetReadStatus        */
    .word   stub_write          /* 27 Write                */
    .word   stub_default        /* 28 Seek                 */
    .word   stub_default        /* 29 Mount                */
    .word   stub_getenv         /* 30 GetEnvironmentVariable */
    .word   stub_default        /* 31 SetEnvironmentVariable */
    .word   stub_default        /* 32 GetFileInformation   */
    .word   stub_default        /* 33 SetFileInformation   */
    .word   stub_default        /* 34 FlushAllCaches       */

    .org    0xc00
    .globl  arcs_pvec
arcs_pvec:
    .word   stub_default, stub_default, stub_default, stub_default
    .word   stub_default, stub_default, stub_default, stub_default
    .word   stub_default, stub_default, stub_default, stub_default
    .word   stub_default
