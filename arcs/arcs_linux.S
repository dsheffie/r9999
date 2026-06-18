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
#define ARCS_RAM_SIZE   0x08000000      /* 128 MiB (Linux needs free RAM) */
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
 * PATCH SLOT @ blob offset 0x40 (kseg1 0xA0001040).  The FPGA driver writes the
 * loaded kernel's ELF e_entry here (big-endian) BEFORE starting the core, so
 * ONE firmware boots any kernel.  arcs_boot reads this (uncached via kseg1)
 * instead of a baked-in immediate.  Unpatched it defaults to ARCS_KENTRY.
 * ==================================================================== */
    .org    0x40
    .globl  arcs_kentry_slot
arcs_kentry_slot:
    .word   ARCS_KENTRY

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
 * arcs_boot @ 0xA0003000 -- the ENTRY point (self-contained pseudo-PROM).
 * Replaces the C++ harness handoff: (1) print a heartbeat out the Z8530 SCC
 * (proof-of-life on silicon), (2) stage the sash argv/envp blob at kseg0
 * 0x88fff000 (top of the 16 MiB bank, where the kernel reads it in early
 * mlsetup -- mirrors interp_mips pseudo_bios.cc), (3) set a0=argc, a1=argv,
 * a2=envp and jump to the Linux kernel entry (ARCS_KENTRY). The driver starts the
 * core here via --start-pc 0xa0003000.
 * ==================================================================== */
    .set    ARCS_BB,   0x88fff000       /* runtime base for the argv/envp blob */
    .set    ARCS_ARGC, 8
    /* Linux kernel ELF entry (kernel_entry). BUILD-SPECIFIC: henry_tb prints it
     * as "kernel entry 0x...."; update if vmlinux.32 is relinked. (Was the IRIX
     * /unix entry 0x88005960; only the jump target differs for Linux -- the
     * argv/envp handoff stub below is identical.) */
    .set    ARCS_KENTRY, 0x8832c118     /* Linux vmlinux.32 entry */

    .org    0x2000
    .globl  arcs_boot
arcs_boot:
    /* (1) SCC heartbeat: poll RR0.TxEmpty @0xbfbd9830, write DATA @0xbfbd9837 */
    lui     $t4, 0xbfbd
    ori     $t5, $t4, 0x9830
    ori     $t6, $t4, 0x9837
    la      $t1, arcs_hb_str
1:  lbu     $t2, 0($t1)
    beq     $t2, $zero, 2f
    nop
9:  lbu     $t3, 0($t5)             /* RR0 */
    andi    $t3, $t3, 0x04         /* Tx Buffer Empty */
    beq     $t3, $zero, 9b
    nop
    sb      $t2, 0($t6)
    addiu   $t1, $t1, 1
    b       1b
    nop
2:
    /* (2) copy the argv/envp blob to kseg0 0x88fff000 */
    la      $t0, arcs_argv_blob
    la      $t2, arcs_argv_blob_end
    li      $t1, ARCS_BB
3:  lbu     $t3, 0($t0)
    sb      $t3, 0($t1)
    addiu   $t0, $t0, 1
    addiu   $t1, $t1, 1
    bne     $t0, $t2, 3b
    nop
    /* (3) entry regs + jump to /unix */
    li      $a0, ARCS_ARGC
    /* NB: `li $a1, ARCS_BB+(label-label)` mis-assembles to a single sign-extended
     * addiu (0xfffffffffffff254) -- the label-diff defeats li's constant path.
     * Load the base (li of a plain constant is fine) then addiu the folded offset. */
    li      $a1, ARCS_BB
    addiu   $a2, $a1, (arcs_envp_arr - arcs_argv_blob)   /* a2 = envp array */
    addiu   $a1, $a1, (arcs_argv_arr - arcs_argv_blob)   /* a1 = argv array */
    /* clean handoff: a real PROM enters /unix with only a0/a1/a2 meaningful;
     * zero the scratch GPRs the stub dirtied so the kernel can't read stale
     * values (jump via $k0 so no general reg is left holding the entry addr). */
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
    /* patchable kernel entry: load from the slot @ 0xA0001040 (kseg1, uncached
     * so the driver's write is seen), not a baked-in immediate. */
    la      $k0, arcs_kentry_slot
    lw      $k0, 0($k0)
    jr      $k0
    nop

    .align  2
arcs_hb_str:
    .asciz  "r9999 PROM: CPU alive, handing off to Linux\n"

/* sash argv/envp blob (mirrors pseudo_bios.cc); pointers are assembler-computed
 * for runtime base ARCS_BB = 0x88fff000.  Copied there by arcs_boot. */
    .align  2
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
arcs_argv_blob_end:

/* ====================================================================
 * dump_state @ 0xA0003800 -- CP0 fault-state dumper for the IRIX TLB panics.
 * /unix panic() entry (0x8815bf2c) is patched in-place to jump here; we print
 * the fault CP0 registers over the SCC, then re-run panic's 4 relocated
 * prologue insns and jr back to panic+16 (0x8815bf3c) so the normal panic
 * still proceeds.  Runs in the kernel's context at the panic; clobbers only
 * t0-t9,k0,k1 (all caller-saved/dead at panic's call boundary) and preserves
 * a0-a6/sp/ra so panic's later register saves stay valid.
 * SCC: RR0 ctrl @0xbfbd9830 (poll bit2 = Tx empty), DATA @0xbfbd9837. */

    /* Scratch discipline: /unix is n32 (a4-a7 = $8-$11), so we touch ONLY
     * registers that are caller-saved/dead in n32 at panic's call boundary:
     * $12-$15,$24,$25 (o32 t4-t9), $1 (at), $26/$27 (k0/k1).  a0-a7/sp/ra are
     * preserved so panic's prologue saves stay valid. */

    /* PUTC \reg : poll SCC Tx-empty (t8=RR0), write \reg to DATA (t9); clob t7 */
    .macro PUTC reg
.Lpc_\@:
    lbu     $t7, 0($t8)
    andi    $t7, $t7, 0x04
    beqz    $t7, .Lpc_\@
    nop
    sb      \reg, 0($t9)
    .endm

    /* PUTHEX32 \reg : print low 32 bits of \reg as 8 hex digits */
    .macro PUTHEX32 reg
    or      $t4, \reg, $zero
    li      $t5, 28
.Lh_\@:
    srlv    $t6, $t4, $t5
    andi    $t6, $t6, 0xf
    sltiu   $at, $t6, 10
    bnez    $at, .Lha_\@
    nop
    addiu   $t6, $t6, 0x57          /* 'a'-10 */
    b       .Lhb_\@
    nop
.Lha_\@:
    addiu   $t6, $t6, 0x30          /* '0' */
.Lhb_\@:
    PUTC    $t6
    addiu   $t5, $t5, -4
    bgez    $t5, .Lh_\@
    nop
    .endm

    /* PUTHEX64 \reg : print full 64 bits of \reg as 16 hex digits */
    .macro PUTHEX64 reg
    or      $t4, \reg, $zero
    li      $t5, 60
.Lq_\@:
    dsrlv   $t6, $t4, $t5
    andi    $t6, $t6, 0xf
    sltiu   $at, $t6, 10
    bnez    $at, .Lqa_\@
    nop
    addiu   $t6, $t6, 0x57
    b       .Lqb_\@
    nop
.Lqa_\@:
    addiu   $t6, $t6, 0x30
.Lqb_\@:
    PUTC    $t6
    addiu   $t5, $t5, -4
    bgez    $t5, .Lq_\@
    nop
    .endm

    /* PUTSP : print a space */
    .macro PUTSP
    li      $k1, 0x20
    PUTC    $k1
    .endm

    .org    0x2800
    .globl  dump_state
    /* Hooked from cmn_err() entry (0x8815ae58, patched to jr here).  cmn_err is
     * the common emitter for ALL the TLB-panic flavors (it prepends "PANIC: ");
     * panic() is NOT on that path.  But cmn_err also prints benign boot warnings,
     * so we GATE on the fault address: only dump+halt when BadVAddr >= 0xff800000
     * (the KPTEBASE / kptbl self-mapped page-table region); otherwise re-run
     * cmn_err's 4 relocated prologue insns and return to cmn_err+16 so the benign
     * message prints normally.  cmn_err's prologue is byte-identical to panic's. */
    /* Hooked from enter_panic_mode() entry (0x881698ec, patched to jr here).
     * That is reached ONLY on a real panic (every flavor funnels through the
     * cmn_err panic path), never on benign warnings -- so no gate/return is
     * needed: dump the fault CP0 state + the full TLB, then halt.  The original
     * "PANIC: ..." line has already printed by this point. */
dump_state:
    lui     $t8, 0xbfbd
    ori     $t9, $t8, 0x9837        /* SCC DATA */
    ori     $t8, $t8, 0x9830        /* SCC RR0  */

    li $k1, 0x0a ; PUTC $k1
    li $k1, 0x4b ; PUTC $k1         /* K */
    li $k1, 0x46 ; PUTC $k1         /* F  (kptbl-region fault) */
    li $k1, 0x20 ; PUTC $k1
    li $k1, 0x56 ; PUTC $k1 ; dmfc0 $k0,$8  ; PUTHEX64 $k0 ; PUTSP   /* V BadVAddr */
    li $k1, 0x43 ; PUTC $k1 ; dmfc0 $k0,$4  ; PUTHEX64 $k0 ; PUTSP   /* C Context  */
    li $k1, 0x58 ; PUTC $k1 ; dmfc0 $k0,$20 ; PUTHEX64 $k0 ; PUTSP   /* X XContext */
    li $k1, 0x53 ; PUTC $k1 ; mfc0  $k0,$12 ; PUTHEX32 $k0 ; PUTSP   /* S Status   */
    li $k1, 0x45 ; PUTC $k1 ; mfc0  $k0,$13 ; PUTHEX32 $k0           /* E Cause    */
    li $k1, 0x0a ; PUTC $k1

    /* TLB walk: dump all 48 entries as "T <i> <EntryHi> <Lo0> <Lo1>".  tlbr
     * clobbers EntryHi/EntryLo/PageMask -- fine, we halt after.  Loop counter
     * lives in dump_i (RAM) since PUTHEX/PUTC consume every scratch reg. */
    lui $t5,0xa000 ; ori $t5,$t5,0x4f00 ; sw $zero,0($t5)   /* i = 0 */
.Lwalk:
    lui $t5,0xa000 ; ori $t5,$t5,0x4f00 ; lw $t4,0($t5)
    mtc0 $t4, $0                    /* Index = i */
    nop ; nop
    tlbr
    nop ; nop
    li $k1,0x54 ; PUTC $k1          /* T */
    lui $t5,0xa000 ; ori $t5,$t5,0x4f00 ; lw $k0,0($t5) ; PUTHEX32 $k0 ; PUTSP   /* i */
    dmfc0 $k0,$10 ; PUTHEX64 $k0 ; PUTSP        /* EntryHi  */
    mfc0  $k0,$2  ; PUTHEX32 $k0 ; PUTSP        /* EntryLo0 */
    mfc0  $k0,$3  ; PUTHEX32 $k0                /* EntryLo1 */
    li $k1,0x0a ; PUTC $k1
    lui $t5,0xa000 ; ori $t5,$t5,0x4f00 ; lw $t4,0($t5) ; addiu $t4,$t4,1 ; sw $t4,0($t5)
    slti $at,$t4,48
    bne  $at,$zero,.Lwalk
    nop

    /* magic halt (0xbfd00000 <- 1) so the run ends cleanly (no spin/timeout) */
    lui $k0, 0xbfd0
    li  $k1, 1
    sw  $k1, 0($k0)
.Lhalt:
    b   .Lhalt
    nop

    .org    0x3f00
dump_i:
    .word   0
