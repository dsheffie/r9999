/*
 * henry_arcs.S  --  asm shim for the Henry synthetic ARCS/FSBL firmware.
 *
 * Only the parts that MUST be assembly live here; the firmware body (SPB relocation,
 * console, MAC, Newport bring-up, argv staging, ARCS callbacks) is C in henry_fw.c
 * and henry_newport.c.  What stays asm, and why:
 *   - the reset vector @0xBFC00000 and the driver-patched kentry slot @0xBFC00008;
 *   - the MC early init (MEMCFG, GIO abort-enable) -- runs before the stack's RAM is
 *     configured, so it cannot call into C;
 *   - the stack setup and the final jump into the kernel (exact register control);
 *   - the SPB/romvec/pvec and argv/envp DATA, whose byte layout the kernel reads.
 *
 * One blob boots BOTH IP22 Linux (-> /init) and IRIX 6.5 (-> banner); the driver/TB
 * patches the kentry slot per kernel.  Loaded flat into the PROM region; the core
 * resets to 0xBFC00000.  Build: see the Makefile.  See also henry_arcs.ld.
 */

#include "sim.h"

/* Free-RAM descriptor base: reserve the low 16 KiB of main memory (phys
 * 0x08000000..0x08003fff) -- the CPU exception vectors (aliased) and the SPB the FSBL
 * copies to phys 0x1000 live there, below the kernel _text @ 0x08004000. */
#ifndef ARCS_RAM_BASE
#define ARCS_RAM_BASE   0x08004000
#endif
#ifndef ARCS_RAM_SIZE
#define ARCS_RAM_SIZE   0x07ffc000      /* 128 MiB - 16 KiB low-reserved */
#endif
#define ARCS_RAM_BASE_PG (ARCS_RAM_BASE >> 12)
#define ARCS_RAM_PAGES   (ARCS_RAM_SIZE >> 12)

    .set    ARCS_BB,   0x88fff000       /* runtime base for the argv/envp blob */
    .set    ARCS_KENTRY, 0x88005960     /* default kernel entry; the driver/TB patches @0xBFC00008 */

    .set    mips3
    .set    noreorder
    .set    noat

/* ====================================================================
 * PROM: reset vector + minimal early init @ 0xBFC00000.
 * ==================================================================== */
    .section .arcs_boot, "ax"
    .globl  arcs_boot
arcs_boot:
    b       _start                  /* 0xBFC00000: skip the patch slot */
    nop
    .globl  arcs_kentry_slot
arcs_kentry_slot:                   /* 0xBFC00008: driver patches kernel e_entry (BE) */
    .word   ARCS_KENTRY

_start:
    /* (-1) MC MEMCFG0 = 256 MB (2x128MB banks) so IRIX hinv sees full RAM.
     * MC base 0x1fa00000 + MEMCFG0 offset 0xc4 = kseg1 0xbfa000c4.  Must run before
     * the C stack, which lives in RAM this enables. */
    lui     $t0, 0x3f20
    ori     $t0, $t0, 0x3f40        /* MEMCFG0 = 0x3f203f40 (2 banks x 128MB) */
    lui     $t1, 0xbfa0
    sw      $t0, 0xc4($t1)
    nop

    /* (-1b) MC CPUCTRL1.ABORT_EN (bit 4): a GIO access no slave answers then completes
     * with a bus error instead of hanging -- IRIX's and Linux's GIO probes need it. */
    lw      $t0, 0xc($t1)           /* MC CPUCTRL1 (kseg1 0xbfa0000c) */
    ori     $t0, $t0, 0x0010
    sw      $t0, 0xc($t1)
    nop

    /* set up a stack just below the argv blob (0x88ffe000, scratch RAM above the
     * kernel image) and hand off to the C firmware body, which does not return. */
    lui     $sp, 0x88ff
    ori     $sp, $sp, 0xe000
    move    $fp, $sp
    jal     fsbl_main
    nop
1:  b       1b                      /* fsbl_main jumps to the kernel; never returns */
    nop

/* jump_kernel(argc, argv, envp, entry): a0=argc a1=argv a2=envp a3=entry already
 * (O32), so Linux/IRIX see the ARCS convention; just transfer to the kernel. */
    .globl  jump_kernel
jump_kernel:
    jr      $a3
    nop

/* ====================================================================
 * PROM: data the ARCS callbacks (henry_fw.c) return.
 * ==================================================================== */
    .section .arcs_code, "a"

    .align  2
    .globl  eaddr_str
eaddr_str:
    .asciz  "08:00:69:12:34:56"     /* getenv("eaddr") -> SGI MAC (etoh parses this) */
    .globl  monitor_str
monitor_str:
    .asciz  "h"                     /* getenv("monitor") -> the 1280x1024 monitor */
#ifdef SINGLE_USER
    .globl  single_str
single_str:
    .asciz  "SINGLE"                /* getenv("initstate") -> single-user boot */
#endif

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

/* sash argv/envp blob (mirrors pseudo_bios.cc); pointers computed for runtime base
 * ARCS_BB = 0x88fff000.  fsbl_main copies it there and derives argv/envp. */
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
s_e18: .asciz "monitor=h"
#ifdef SINGLE_USER
s_e17: .asciz "initstate=SINGLE"
#endif
    .align  2
    .globl  arcs_argv_arr
arcs_argv_arr:
    .word   ARCS_BB+(s_a0-arcs_argv_blob), ARCS_BB+(s_a1-arcs_argv_blob)
    .word   ARCS_BB+(s_a2-arcs_argv_blob), ARCS_BB+(s_a3-arcs_argv_blob)
    .word   ARCS_BB+(s_a4-arcs_argv_blob), ARCS_BB+(s_a5-arcs_argv_blob)
    .word   ARCS_BB+(s_a6-arcs_argv_blob), ARCS_BB+(s_a7-arcs_argv_blob)
    .word   0
    .globl  arcs_envp_arr
arcs_envp_arr:
    .word   ARCS_BB+(s_e0-arcs_argv_blob),  ARCS_BB+(s_e1-arcs_argv_blob)
    .word   ARCS_BB+(s_e2-arcs_argv_blob),  ARCS_BB+(s_e3-arcs_argv_blob)
    .word   ARCS_BB+(s_e4-arcs_argv_blob),  ARCS_BB+(s_e5-arcs_argv_blob)
    .word   ARCS_BB+(s_e6-arcs_argv_blob),  ARCS_BB+(s_e7-arcs_argv_blob)
    .word   ARCS_BB+(s_e8-arcs_argv_blob),  ARCS_BB+(s_e9-arcs_argv_blob)
    .word   ARCS_BB+(s_e10-arcs_argv_blob), ARCS_BB+(s_e11-arcs_argv_blob)
    .word   ARCS_BB+(s_e12-arcs_argv_blob), ARCS_BB+(s_e13-arcs_argv_blob)
    .word   ARCS_BB+(s_e14-arcs_argv_blob), ARCS_BB+(s_e15-arcs_argv_blob)
    .word   ARCS_BB+(s_e16-arcs_argv_blob), ARCS_BB+(s_e18-arcs_argv_blob)
#ifdef SINGLE_USER
    .word   ARCS_BB+(s_e17-arcs_argv_blob)
#endif
    .word   0
    .globl  arcs_argv_blob_end
arcs_argv_blob_end:

/* ====================================================================
 * RAM image: ARCS SPB + romvec + pvec, linked at kseg1 0xA0001000 but STORED in the
 * PROM (LMA); fsbl_relocate_spb() copies it to VMA at reset.  romvec entries point at
 * the C callbacks in henry_fw.c.
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
