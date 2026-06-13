# IRIX CPU / ARCS requirements — ground truth from MAME

Findings from the **MAME session** (dedicated session driving headless MAME, which boots the
*same* IRIX 6.5.22 Indy image our `unix` kernel came from). MAME is the ground-truth oracle.
See `~/code/chd-dumper/MAME_SESSION_BRIEF.md` for the mission. Captured 2026-06-12.

**How this was captured:** headless MAME `indy_4610` (= mips3 `r4600be` core), interpreter
(`-nodrc`), driven by a Lua `-autoboot_script` that uses the debugger core
(`cpu.debug:bpset(addr,"1","")` + poll `manager.machine.debugger.execution_state=="stop"` →
read state/memory → set `="running"`). IRIX boots cleanly to multiuser in MAME (needed a
one-time PROM `setenv -f eaddr <mac>` or the early kernel panics — see the MAME-session memory).
Reads use `cpu.spaces["program"]:readv_u32/u8` (the `v` = MMU-translated; plain `read_*` does
NOT translate kseg and returns junk).

---

## P0-A: the PROM→kernel handoff at `start` (0x88005960)

### Register state on entry to `start`
```
a0 = 0x00000008   a1 = 0   a2 = 0   a3 = 0
sp = 0  gp = 0  ra = 0  fp = 0   (kernel sets up its own gp/sp immediately)
t0=0x11 t1=7 t2=0x10 t3=0x11 t4=0x12   s6=4  s7=0x01000000  t8=8   (sash leftovers)
SR = 0x30004801
```
**Key correction to prior assumption:** IRIX `start` is **NOT** `start(argc, argv, envp)` with
argv/envp pointer arrays. `a1=a2=0` — there is no argv/envp array to walk. Only **`a0 = 8`**
carries info (a small integer/flag, not a pointer; meaning TBD — likely a boot-type/argc-ish
code). `start` immediately does `sw $a0/$a1/$a2` to globals (saves all three boot args) then
calls its first C routine `0x880255e8(a0,a1,a2,a3=0x880059b0)`. So the shim should enter `start`
with **a0=8, a1=0, a2=0** and a clean register file; everything else IRIX needs it pulls from the
**SPB + ARCS romvec**, not registers.

`start` prologue (verified disassembly):
```
88005960 3c1c8833 lui  gp,0x8833
88005964 3c1d8833 lui  sp,0x8833
88005968 279c2bf0 addiu gp,gp,0x2bf0     ; gp = 0x88332bf0
8800596c 27bdbfa0 addiu sp,sp,-0x4060
88005970 8fbd0000 lw   sp,0(sp)          ; sp = *(0x8832bfa0)
88005974 2781abc0 addiu at,gp,-0x5440
88005978 ac240000 sw   a0,0(at)          ; save boot arg a0
... (saves a1,a2 similarly) ...
880059a8 0e00957a jal  0x880255e8        ; first C call with the saved args
```

### The ARCS System Parameter Block (SPB) @ phys 0x1000 (kseg1 0xA0001000, kseg0 0x80001000)
The kernel finds *everything* through this. The shim must plant it verbatim:
```
+0x00  0x53435241  signature "ARCS"            (LE bytes 41 52 43 53)
+0x04  0x00000048  SPBLength = 72
+0x08  0x0001000a  ARCS version 1, revision 10
+0x0c  0xa87484ec  RestartBlock ptr
+0x10  0x00000000  DebugBlock (none)
+0x14  0x9fc30590  GeneralException vector (PROM)
+0x18  0x9fc306e4  UTLB-miss vector (PROM)
+0x1c  0x0000008c  FirmwareVectorLength = 140  (35 entries)
+0x20  0xa0001800  FirmwareVector  -> the ARCS romvec (below)
+0x24  0x00000034  PrivateVectorLength = 52    (13 entries)
+0x28  0xa0001c00  PrivateVector   -> SGI-private extensions
+0x2c  0x00000000  AdapterCount = 0
```

### The ARCS romvec (FirmwareVector @0xA0001800, 35 fn-pointers into PROM)
Labeled by the standard ARCS vector order; the two reserved NULL slots (idx 8, 19) match the
dump exactly, confirming the layout. The shim must implement each entry IRIX actually calls
(see P0-B, TODO). Addresses are this PROM's (`indy_4610`); for the shim only the *semantics*
and *which are called* matter.
```
 0 Load                 9fc31a8c      18 GetMemoryDescriptor  9fc10b90
 1 Invoke               9fc31bd8      19 (reserved)           00000000
 2 Execute              9fc31ee4      20 GetTime              9fc106d0
 3 Halt                 9fc005ec      21 GetRelativeTime      9fc39fb0
 4 PowerDown            9fc005f4      22 GetDirectoryEntry    9fc10608
 5 Restart              9fc00614      23 Open                 9fc0fc34
 6 Reboot               9fc0061c      24 Close                9fc1046c
 7 EnterInteractiveMode 9fc00624      25 Read                 9fc1004c
 8 (reserved)           00000000      26 GetReadStatus        9fc107b4
 9 GetPeer              9fc2c1f8      27 Write                9fc1030c
10 GetChild             9fc2c204      28 Seek                 9fc1053c
11 GetParent            9fc2c228      29 Mount                9fc10878
12 GetConfigurationData 9fc2c234      30 GetEnvironmentVariable 9fc10944
13 AddChild             9fc2c284      31 SetEnvironmentVariable 9fc10924
14 DeleteComponent      9fc2c548      32 GetFileInformation   9fc10964
15 GetComponent         9fc34680      33 SetFileInformation   9fc10a04
16 SaveConfiguration    9fc2c674      34 FlushAllCaches       9fc0e278
17 GetSystemId          9fc107a8
```
PrivateVector (@0xA0001C00, 13 entries, SGI extensions — semantics TBD):
```
9fc0cbc8 9fc0fac4 9fc31b64 9fc31ec0 9fc32008 9fc337d0 9fc33870
9fc15aa0 9fc2fbc0 9fc31920 9fc0bcf8 9fc3a110 9fc3115c
```

### What the r9999 ARCS shim must provide (minimum, from the above)
1. Enter `/unix` `start` (0x88005960) with **a0=8, a1=0, a2=0**, clean GPRs.
2. An **SPB at phys 0x1000** with signature "ARCS" and the field layout above, pointing at:
3. A **35-entry FirmwareVector** (romvec) implementing at least the functions IRIX calls during
   boot. Strong candidates the kernel needs (vs sash-only I/O): **GetMemoryDescriptor (18)**
   (memory map — almost certainly required), **GetEnvironmentVariable (30)** (console/root/
   OSLoadOptions/...), **GetTime (20)**, **FlushAllCaches (34)**, and the config-tree walkers
   **GetChild/GetPeer (9/10)** / **GetConfigurationData (12)**. EXACT set pending P0-B.
4. The PROM exception vectors (GeneralException 0x9fc30590, UTLB-miss 0x9fc306e4) — IRIX
   installs its own vectors early, but the SPB advertises the PROM's.

---

## P0-B: who calls the ARCS romvec, and when (DONE)

Method: breakpoint every romvec entry, tag the caller as **sash/PROM `[s]`** (before kernel
`start`) vs **kernel `[K]`** (after). Pass that matters: arm the romvec bps *only at kernel start*
to skip the PROM idle-loop GetTime flood. 100 emulated sec = full boot to multiuser.

**Result — the running kernel barely touches ARCS:**
- **Kernel-phase `[K]` calls over the entire boot: exactly ONE** — `GetEnvironmentVariable(NULL)`
  (a0=0). Zero GetTime, zero Read/Write, zero GetMemoryDescriptor, zero config-tree from the kernel.
- **Everything else is sash/PROM `[s]`, BEFORE the kernel runs:** `GetMemoryDescriptor` ×14
  (enumerate RAM), the component/config tree build+walk `GetChild`×57 `GetPeer`×50 `GetParent`×47
  `AddChild`×23 (≈177), `FlushAllCaches` ×1. Plus the PROM idle loop polls `GetTime` ~10^4× while
  it waits (that is the PROM, not the kernel).
- **Steady-state timekeeping = CP0, not ARCS.** Sampled CP0 across boot: `Count` climbs
  monotonically (wraps 0xffffffff), and every tick the handler re-arms `Compare = Count + ~0x25000`
  → the on-chip R4000 timer interrupt drives the scheduler. The kernel never calls ARCS GetTime
  after the one-shot wall-clock seed (which sash does pre-kernel). Answers "is hardware access
  always via ARCS?" — NO: firmware is bringup-only, and mostly *pre-kernel* (sash).

**Architectural implication for the r9999 shim (important):** r9999 loads `/unix` **directly**,
bypassing sash — so the kernel will find an environment that sash normally prepares. Since the
*running* kernel pulls almost nothing from the romvec (1 getenv in 100 s), the shim's real job is
to leave correct **in-memory state** at `start`, not to implement many live firmware functions:
1. The **SPB** at phys 0x1000 (above) — the kernel finds everything through it.
2. Whatever conveys the **memory map**. The kernel does NOT call GetMemoryDescriptor itself (sash
   does, ×14) — so either sash stashes the map where the kernel reads it, or the kernel reads
   PROM-built tables. **OPEN: how does the kernel learn RAM size/layout for a sash-less boot?**
   (trace 0x880255e8 / early mlsetup; or it reads the component tree / a fixed structure.)
3. A romvec with at least a **working GetEnvironmentVariable** (kernel calls it once, a0=NULL —
   likely getenv-of-NULL to fetch the env block base, or an init probe).

---

## P0-C: how the kernel sizes/maps RAM (RESOLVED — it reads the MC directly, NOT ARCS)

Traced from the symbolized kernel (`/home/dsheffie/code/chd-dumper/extracted/unix`, ELF32 with
symbols). `szmem` (@`0x8800790c`, "size memory") loops 3 banks and calls a helper that reads the
**SGI MC (memory controller) registers directly** — confirmed at `0x880077c0`:
```
lui  a5,0xbfa0        ; 0xbfa00000 = kseg1 uncached -> phys 0x1fa00000 = the MC
lw   a3,196(a5)       ; MEMCFG0 @ 0xbfa000c4
lw   a3,204(a5)       ; MEMCFG1 @ 0xbfa000cc
srlv v0,a3,a4         ; select the bank's 16-bit half (two banks packed per 32-bit reg)
andi v0,v0,0xffff
```
So **IRIX learns RAM size/layout by reading MEMCFG0/MEMCFG1, not via ARCS GetMemoryDescriptor and
not by probing** — consistent with P0-B (the kernel makes zero GetMemoryDescriptor calls; sash's 14
calls are pre-kernel and irrelevant to a sash-less r9999 boot).

**Register layout** (MAME `src/mame/sgi/mc.cpp` confirms): each MEMCFG reg packs two banks —
`hiBank = bits[31:16]`, `loBank = bits[15:0]`; per bank: `base = bits[..:16]/[..:0] (8b)`,
`simmSize = bits[28:24]/[12:8] (5b)`, `valid = bit29/bit13`, `subbanks = bit30/bit14 (+1)`.
Range mapping: `bankBase = base << 22` (4 MB units), `bankSize = (simmSize+1) << 22` (MAME memcfg_w).

**Live values captured at kernel start (this working boot — r9999 can replicate verbatim):**
```
0xbfa000c4 MEMCFG0 = 0x23200000  -> hiBank{base=0x20 sz=3 valid=1}  loBank{valid=0}
0xbfa000cc MEMCFG1 = 0x00000000  -> no banks
0xbfa000d0 CPUmemAccessCfg = 0x11453433
```
=> one bank, base `0x20<<22 = 0x08000000` (matches `_physmem_start = 0x08000000`), modest size
(boot prints "Low free memory"). **For r9999's direct boot: implement MEMCFG0/MEMCFG1 at phys
`0x1fa000c4`/`0x1fa000cc` returning values that describe r9999's DRAM** (for 128 MB at 0x08000000
you'll need bank config(s) whose decoded base/size cover 0x08000000-0x0fffffff; start from the
0x23200000 example and widen the size field / add a bank). Also return something sane for
`0x1fa000d0` (=0x11453433 here). Cross-check the decoded total against `physmem`/`maxmem`
(`0x8832d1f0`/`0x8832d1f8`) after `szmem` runs.

---

## TODO (next MAME-session steps)
- (optional) Decode the single kernel `GetEnvironmentVariable(NULL)` — what it returns / how used.
- (optional) what `a0=8` means to `start` (minor; `start` saves it but boot succeeds regardless).
- **Next major: the FPU mission** (COP1 histogram, E-traps, fp_intr) — harness + breakpoint proven.
```
