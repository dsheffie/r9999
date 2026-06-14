/*
 * arcs_irix.S  --  synthetic SGI ARCS firmware for booting the IRIX /unix
 * kernel on the r9999 simulator (sash-less / PROM-less direct boot).
 *
 * Ground truth from the MAME session (IRIX 6.5.22 on indy_4610) --
 * see IRIX_CPU_REQUIREMENTS.md:
 *   - IRIX `start` (0x88005960) is entered with a0=8, a1=0, a2=0 (NOT
 *     argc/argv/envp).  The entry register state is set by the harness, not here.
 *   - The kernel finds everything through the SPB at phys 0x1000 (kseg1
 *     0xA0001000): sig "ARCS", a 35-entry FirmwareVector (romvec), a 13-entry
 *     PrivateVector.
 *   - The *running* kernel calls the romvec exactly ONCE
 *     (GetEnvironmentVariable, a0=NULL); RAM sizing is via the MC, not ARCS.
 *
 * So this shim is mostly correct in-memory state: a valid SPB + a romvec whose
 * live entries return sane values.  Linked at kseg1 0xA0001000 (arcs.ld),
 * objcopy'd to a flat blob loaded at phys 0x1000.
 *
 * Layout (offsets from 0xA0001000):
 *   0x000  SPB
 *   0x800  FirmwareVector (35 x u32)  -> 0xA0001800
 *   0xc00  PrivateVector  (13 x u32)  -> 0xA0001C00
 *   0xe00  stubs + data
 */

#include "sim.h"

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
 * ARCS System Parameter Block @ 0xA0001000  (IRIX layout, see reqs doc)
 * ==================================================================== */
    .globl  arcs_spb
arcs_spb:
    .word   0x53435241          /* +0x00 signature "ARCS" */
    .word   0x00000048          /* +0x04 SPBLength = 72 */
    .word   0x0001000a          /* +0x08 ARCS version 1, revision 10 */
    .word   0                   /* +0x0c RestartBlock (none) */
    .word   0                   /* +0x10 DebugBlock (none) */
    .word   0                   /* +0x14 GeneralException vector (IRIX installs its own) */
    .word   0                   /* +0x18 UTLB-miss vector */
    .word   0x0000008c          /* +0x1c FirmwareVectorLength = 140 (35 entries) */
    .word   arcs_romvec         /* +0x20 FirmwareVector -> 0xA0001800 */
    .word   0x00000034          /* +0x24 PrivateVectorLength = 52 (13 entries) */
    .word   arcs_pvec           /* +0x28 PrivateVector -> 0xA0001C00 */
    .word   0                   /* +0x2c AdapterCount = 0 */

/* ====================================================================
 * FirmwareVector (romvec) @ 0xA0001800  -- 35 entries, standard ARCS order.
 * Live: Halt/PowerDown/Restart/Reboot -> clean sim halt; GetMemoryDescriptor
 * (18); GetChild/GetPeer (9/10) -> component tree; Write (27) -> CP0 putchar
 * (unused by the kernel but harmless); GetEnvironmentVariable (30).  All
 * others -> stub_default (return 0).
 * ==================================================================== */
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

/* ====================================================================
 * PrivateVector @ 0xA0001C00 -- 13 SGI-private entries (semantics TBD) -> 0.
 * ==================================================================== */
    .org    0xc00
    .globl  arcs_pvec
arcs_pvec:
    .word   stub_default, stub_default, stub_default, stub_default
    .word   stub_default, stub_default, stub_default, stub_default
    .word   stub_default, stub_default, stub_default, stub_default
    .word   stub_default

/* ====================================================================
 * Callback stubs @ 0xA0001E00  (O32: args a0..a3, return v0)
 * ==================================================================== */
    .org    0xe00

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

/* char *GetEnvironmentVariable(char *name): return a fixed eaddr (MAC) string.
 * IRIX init_sysid does etoh(getenv("eaddr")); a NULL return -> etoh(NULL) ->
 * lbu 0(0) -> fault.  Real PROM returns the EEPROM eaddr; we hand back an SGI
 * MAC (08:00:69 = SGI OUI).  The kernel pulls little else from the romvec. */
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
 * Type 1 = FreeMemory (FreeContiguous). */
    .align  3
    .globl  mdesc_ram
mdesc_ram:
    .word   1
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
