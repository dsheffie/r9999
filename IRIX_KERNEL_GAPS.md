# IRIX 6.5.22 kernel — instruction working set & r9999 implementation gaps

**Source:** `/home/dsheffie/code/chd-dumper/extracted/unix` (and `unix.install`, identical footprint) —
the **IRIX 6.5.22 kernel**, ELF32 MSB, **N32 MIPS-III**, statically linked, **with symbols**, arch
`mips:4000`, entry `0x88005960`. Disassembled with `mips-linux-gnu-objdump -d` (→ /tmp/irix_unix.dis,
756k lines). Goal: find what r9999 must implement to boot this kernel.

## Headline
**The integer / 64-bit / system / atomic ISA r9999 already implements is COMPLETE for this kernel.**
The only gaps are: **(1) the floating-point subsystem** and **(2) the `wait` instruction**. And the FP
gap is much smaller than it looks — see below.

## Complete instruction working set (125 distinct mnemonics)
- **Integer/branch (MIPS I/II):** move lw addiu sw li b/beq/bne/beqz/bnez/blez/bgtz/bltz/bgez + the
  **branch-likely** forms (beqzl bnezl beql bnel bltzl blezl bgtzl bgezl), j jal jr jalr, lui addu subu
  and or xor nor andi ori xori sll srl sra sllv srlv srav slt sltu slti sltiu lb/lbu/lh/lhu/sb/sh,
  unaligned lwl lwr swl swr, mult multu div divu mfhi mflo mthi mtlo, add addi sub negu, teq, break syscall.
- **64-bit (MIPS III):** ld sd lwu ldl ldr sdl sdr, daddu daddiu daddi dsubu dnegu, dsll dsrl dsra
  dsll32 dsrl32 dsra32 dsllv dsrlv dsrav, dmult dmultu ddiv ddivu.
- **System / CP0:** mtc0 mfc0 dmtc0 dmfc0, tlbr tlbwi tlbwr tlbp, eret, cache, sync, **wait**.
- **Atomics:** ll sc lld scd.
- **FP (cop1):** swc1 sdc1 lwc1 ldc1, mtc1 mfc1 dmtc1 dmfc1, cfc1 ctc1, **cvt.s.l cvt.d.l** — *that's all.*

## KEY FINDING — the kernel does almost no FP, and **no FP arithmetic at all**
FP static counts: swc1 96, sdc1 81, dmtc1/dmfc1 65, mtc1/mfc1 64, lwc1 64, ldc1 49, cfc1 5, ctc1 4,
cvt.s.l 1, cvt.d.l 1. **There is NO add.*/sub.*/mul.*/div.*/sqrt/abs/neg/c.* (compare) anywhere in the
kernel.** All FP activity is **context save/restore** (the moves + loads/stores — the kernel saving/
restoring the 32 FP regs + FCSR across context switches / signal delivery) plus **two long→float converts**.

**Implication:** *booting the IRIX kernel does not require an FP ALU.* It requires the FP register file,
the FP move/load/store path, FCSR access, two converts, and the FP-related exception plumbing. The FP
adder/multiplier/divider are only exercised by **user** programs — and even those can be punted to
software via the Unimplemented (E) trap (see `FPU_ROUNDING_EXCEPTIONS.md`).

## How IRIX manages/uses the FPU (from kernel symbols)
- **FPU management:** `fp_init`, `fp_reinit`, `fp_intr` (the FP-exception handler, CP0 cause 15),
  `fp_find`, `fp_poweroff`, `get_fpc_csr`, `get_fpc_irr`, `fpcsr_fs_bit` (reads FCR31, incl. the FS bit).
- **Context save/restore:** `fpunit_fpload_{s,d}`, `fpunit_fpstore_{s,d}` — the lwc1/swc1/ldc1/sdc1/mtc1/
  mfc1 traffic. Lazy-FP per process implied (CU1 enable/disable + save/restore).
- **Branch-delay-slot fixup (per user, key):** `emulate_branch`, `emulate_lwc1`, `emulate_ldc1`,
  `emulate_swc1`, `emulate_sdc1` — when an **FP load/store in a branch delay slot faults** (BD set, EPC→
  branch; likely the **unaligned-FP-access** and/or precise-exception case), the kernel decodes the branch,
  emulates the FP memory op, and resumes. **This is NOT an FP-arithmetic emulator** — it's a precise-
  exception / BD-slot fixup. **Directly ties to the `WAIT_FOR_SERIALIZE_IN_FAULTED_DELAY_SLOT` HW corner**
  we studied: r9999 must deliver *precise* exceptions for delay-slot FP memory ops (correct EPC + Cause.BD)
  so this kernel fixup works.
- **Software FP convert/emulation:** `_cvtd_s _cvts_d _cvtl_sd _cvtsd_l _cvtsd_w _cvtw_sd` — softfloat
  convert routines (the E-trap / unimplemented-op path for user FP). `arg_r5000_cvt_war` = an R5000 convert
  errata workaround (gated by CPU type; not relevant when we present as R4000/R4400).

## Gap analysis vs r9999 (today: FPU fully removed)
r9999 state: `fp_prf/fp_uq/is_fp` = 0 in exec.sv (FPU ripped out); decode has only **vestigial** MTC1/MFC1
(MERGE) with **no execution** (exec.sv MFC1/MTC1 handling = 0); DMTC1/DMFC1/CFC1/CTC1/LWC1/SWC1/LDC1/SDC1/
CVT/WAIT not decoded.

| Need (to boot IRIX kernel) | r9999 today | Gap |
|---|---|---|
| Integer / branch-likely / unaligned / traps | implemented | — |
| 64-bit MIPS-III (d*, ld/sd, ldl..sdr) | implemented | — |
| System CP0 (mtc0/mfc0/dmtc0/dmfc0/tlb*/eret/cache/sync/syscall/break) | implemented (cache→NOP) | — |
| Atomics (ll/sc/lld/scd) | implemented | — |
| `wait` (R4600+/MIPS32 idle; NOT an R4000/R4400 insn) | not decoded | **likely NOT a real gap** — IRIX patches the idle loop (`wait_for_interrupt_fix_loc`) by CPU type, so a PRId=R4400 r9999 never executes it. Decode as NOP for insurance |
| **FP register file (32×64b) + Status.CU1/FR** | absent | **add** |
| **FP moves** mtc1/mfc1/dmtc1/dmfc1, cfc1/ctc1 (FCSR/FIR) | vestigial mtc1/mfc1 decode, no exec; rest absent | **add full** |
| **FP load/store** lwc1/swc1/ldc1/sdc1 (incl. precise BD-slot faults) | absent | **add** |
| **cvt.s.l / cvt.d.l** (only FP "math" the kernel runs) | absent | **add (2 converts)** |
| **FP exception (cause 15) + CU1→CpU (cause 11)** | CpU/cause-11 mechanism exists (for CP0); FP cause 15 absent | **extend CpU to ~CU1; add cause-15 FPE** |

## Staged implementation plan (boot-first)
1. **Minimal FP-to-boot** (no FP ALU): FP regfile + `Status.CU1/FR`; decode+exec for mtc1/mfc1/dmtc1/dmfc1,
   cfc1/ctc1 (FCR31/FCR0), lwc1/swc1/ldc1/sdc1, and cvt.s.l/cvt.d.l; CU1→CpU (cause 11, reuse the `CPU`
   uop); FPE (cause 15) delivery; **precise exceptions on delay-slot FP loads/stores** (so `emulate_*`
   works). (`wait` is CPU-type-patched-out on R4400, so optional — NOP it for insurance.) This should boot the kernel.
2. **FP ALU later** (for user FP): add correctly-rounded add/sub/mul/div/sqrt/compare + the rest of the
   converts, validated vs softfloat; punt denormals/hard cases via E to IRIX's emulator. Reuse the
   `mipscore@superscalar` plumbing (4 renamed domains, mem-pipe int↔FP mover) from `FPU_PORT_STUDY.md`.

## IRIX runtime CPU patching / errata workarounds (important context)
**`wait` is implementation-specific, not MIPS III or IV.** It is absent from both the R4400 manual (MIPS
III) and the R10000 manual (MIPS IV) — the R10000 CP0 chapter lists only CACHE/DMFC0/DMTC0/MFC0/MTC0/
TLBP/TLBR/TLBWI/TLBWR/ERET and explicitly "does not define a reduced power mode" (RP bit reserved). WAIT
originated on the embedded/low-power parts — R4600/R4700/R5000/RM (PRId imp `0x20/0x21/0x23/0x28`) — and
was only formalized into the architecture in MIPS32/MIPS64 (~1999). r9999 presents PRId=R4400, so it's
outside that set.
`wait` confirmed NOT a gap, and it's a pure **hint** (correctness never depends on it):
`wait_for_interrupt` is **PRId-gated** — it checks the imp field against the WAIT-capable parts
(`0x20/0x21/0x23/0x28` = R4600/R4700/R5000/RM) and on an R4000/R4400 (**imp 0x04, r9999's PRId**) hits
`bnez t2, jr ra` and **returns without ever reaching WAIT**. Even on WAIT-capable CPUs a runtime byte
flag further gates it, and it's a *single* WAIT in a leaf — the re-check loop lives in the idle scheduler
caller (`idle`/`idler`/`idlerunq`/`ksvc_global_idle`), so a NOP WAIT would be correct anyway. More broadly, IRIX
**runtime-patches the kernel by CPU type/revision (PRId)** — the symbol table is full of workaround/patch
markers: `R4000_jump_war_{always,correct,kill,warn}`, `R4000_badva_war`, `r4000_clock_war`,
`init_mfhi_war` (mult/div→mfhi/mflo hazard), `need_utlbmiss_patch`, `r4k_div_patch`, `mtext_fixup_inst`,
`clr_jump_war_wired`, plus R5000 ones (`R5000_cvt_war`, `_r5000_badvaddr_war`).
**Implication for r9999:** (1) r9999 already presents **PRId = R4000**, so IRIX applies the *R4000*
workaround set — generally conservative/harmless on a correct implementation (extra nops, safe TLB/jump
sequences). (2) But **verify any workaround that assumes specific buggy R4000 behavior** doesn't break on a
clean core — esp. `R4000_jump_war` (the branch/jump-at-page-end errata) and `init_mfhi_war` (the
hi/lo-read hazard). r9999's OOO already enforces correct hi/lo and precise control flow, so these should be
no-ops, but it's worth a targeted check during boot. (3) The R5000 workarounds are gated out for us.

## Per-processor (PRId) support map — which CPUs this kernel handles (MAME-session 2026-06-12)
Static analysis of `extracted/unix` (symbols + disasm). The kernel identifies the CPU by the **CP0
PRId imp field** (bits 15:8) and dispatches three ways.

**Processors recognized** (imp value → CPU; CPU-type strings all present in .data):

| imp | CPU | notes |
|----|----|----|
| `0x04` | **R4000 / R4400** | baseline/default path — **r9999 presents this (imp 0x04)** |
| `0x20` | **R4600** (+ R4600SC secondary-cache variant) | |
| `0x21` | **R4700** | |
| `0x22` | R4650 | string present, minimally handled |
| `0x23` | **R5000** | |
| `0x28` | **RM5271** (RM52xx) | |
| — | R8000("tfp")/R10000 | strings present, other platforms (not IP22/IP24 paths) |

The canonical inline check is in `start` (0x88005a0c): `mfc0 a3,c0_prid; andi a3,0xff00`, then a chain
of `addiu/beqz` matching imp `0x20,0x21,0x23,0x28` (R4600/R4700/R5000/RM52xx). **The Watch-register
clear (below) is the fall-through path → executed on R4000/R4400, skipped on that family.**

**Three guarding mechanisms:**
1. **Inline PRId-imp branches** (as above) for small divergences.
2. **Per-CPU function variants**, wired in at init: exception/UTLB handlers `utlbmiss_r4600`,
   `utlbmiss_r5000`, `eutlbmiss_{r4600,r5000}`, `utlbmiss_sharedseg*_r5000` (vs the R4000 default,
   patched into the refill vector — `need_utlbmiss_patch`/`utlbmiss_patched`/`utlbmiss_prolog_patch`);
   cache ops `_r4600sc_*`, `_r4600_2_0_cacheop_eret`; clocks `*_r4000` (`ackkgclock_r4000`,
   `startrtclock_r4000`, `r4kcount_intr_r4000`, …).
3. **Per-CPU workaround flags → runtime code patches:** R4000 — `R4000_jump_war_{always,correct,kill,
   warn}`, `R4000_badva_war`, `r4000_clock_war`, `R4000_div_eop_correct`, `init_mfhi_war`,
   `r4k_div_patch`, `sw_cachesynch_patch_insts_R4000`; R5000 — `R5000_cvt_war`, `_r5000_badvaddr_war`;
   RM52xx — `arg_rm5271_badvaddr_war`; R4600 — `is_r4600_flag`; R10000 — `r10k_gfx_write_war`.

**For r9999 (imp 0x04 = R4000):** baseline path only — R4000 workaround set applied, **R4000 default**
UTLB/exception handlers (not the r4600/r5000 variants), `*_r4000` clocks, **Watch regs cleared**. All
r4600/r5000/RM/r10k code is dead for us. Verify only that the R4000 workarounds assuming *buggy* R4000
behavior — `R4000_jump_war` (page-boundary branch errata), `init_mfhi_war` (hi/lo hazard) — are harmless
no-ops on r9999's clean OOO core.

### CP0 Watch registers (WatchLo/WatchHi, r18/r19): NOT used — r9999 can RAZ/WI them
The **only** references to `c0_watchlo`/`c0_watchhi` in the entire kernel are the two `mtc0 zero` clears
in `start` (0x88005a58/5c) — defensive init on R4000/R4400 (which have the regs). **Nothing ever
programs a watch address**, so the Watch exception (ExcCode 23) never fires. The kernel's
`addwatch`/`deletewatch`/`handle_watch`/`kdebug` watchpoint facility is **software** (a managed
watchpoint list + the debugger exception hook loaded from `0x80001010`; `handle_watch` is part of the
`exception` dispatch and does NOT read the CP0 Watch regs; `addwatch` doesn't touch them either).
**Implication:** r9999 needs WatchLo/WatchHi only as a functional register (accept `mtc0`/`mfc0` r18/r19
without faulting); no Watch-match hardware or ExcCode-23 delivery is required to boot/run IRIX.
**DONE (272360d):** functional WatchLo/WatchHi register interface added in `exec.sv` (store on `mtc0`
r18/r19, read back on `mfc0`, reset 0; modeled on `Compare`) — a superset of RAZ/WI, so the kernel's
`mtc0 zero` clears and any read-back work without faulting.

## TLB / CP0 / physical-address requirements (MAME-session, dynamic + static, 2026-06-12/13)
Measured by driving headless MAME (`indy_4610`, R4600/mips3) + breakpoints; harness in the MAME-session memory.

- **TLB size:** 48 dual-entry JTLB on R4000/R4400/R4600/R4700/R5000/RM — **same 48**; only R10000/R12000
  go to 64. (The separate `utlbmiss_r5000` handler is NOT about capacity.) `start` sets `Wired=8`.
  r9999's 48-entry CAM matches.
- **R5000 vs R4000 refill (why two handlers):** R4000/R4600 fast refill = **blind `tlbwr`** (load 2 PTEs
  → `mtc0 entrylo0/1` → `tlbwr` → `eret`). R5000 does **`tlbp` first, `tlbwr` only if the entry is absent**
  (if present → diverts to the general-exc vector) — a guard against a **duplicate TLB entry**, which the
  R5000 mishandles. **r9999 = R4000 path** (blind tlbwr); just ensure r9999's CAM tolerates a duplicate
  write (last-wins/overwrite) rather than asserting a machine-check.
- **Page size: BOOT IS 4 KB-ONLY.** Fast refill is `utlbmiss_not_large_page` (Context-based, no large-page
  branch). Dynamically: **3000 explicit TLB writes during boot → 100% `PageMask=0` (4 KB), zero large
  pages.** Large-page machinery exists (`large_pages_enable`, `lpage_*`, `pmap_downgrade_*_page_size`) but
  is **on-demand/under-load**, never triggered by a vanilla boot. ⇒ r9999 can **boot with a 4 KB-only TLB**;
  variable-page-size CAM matching (16 KB…16 MB) is deferrable past boot. But `PageMask` is **not** RAZ/WI —
  the kernel writes `PageMask=0` before each `tlbw` and reads it back; it must hold its value.
- **Physical address width: 29 bits (512 MB) is the platform ceiling.** Highest PA the kernel forms is the
  device/PROM region `0x1f000000–0x1fffffff` (kseg1, unmapped). RAM at `0x08000000` (≤256 MB → ≤`0x18000000`);
  TLB-mapped PFNs observed only `0x0800_0000–~0x0900_0000` here (max `0x0881a000`, 28 bits). EntryLo PFN is
  arch-24-bit (36-bit-PA capable) but only ~17 significant bits are ever used. ⇒ r9999 needs PA to
  `0x1fffffff` only; cache/TLB physical tags need 29 bits (bits 31:29 always 0).
- **CP0 timer:** steady-state timekeeping is on-chip `Count`/`Compare` (handler re-arms `Compare = Count +
  ~0x25000` per tick) — confirmed live; not ARCS. (See `IRIX_CPU_REQUIREMENTS.md` P0-B/C.)
- **Status.FR (bit 26): FR=1 IS used.** FR=0 for kernel/idle, **FR=1 once N32/N64 userland runs** (first
  seen mid-boot, ~19% of samples by multiuser). ⇒ r9999's FP regfile must implement **FR=1 (32 independent
  64-bit FP registers)**, not just FR=0 even/odd 32-bit pairs; the Status.FR bit must switch the regfile
  aliasing. (Still no FP *arithmetic* in the kernel — this is the regfile mode for context save/restore +
  userland.)

## `cache` instruction — decode requirement + boot-execution histogram (MAME-session 2026-06-13)
r9999 must **fully decode `cache`** (op 0x2f) and route by op field — NOT treat it as one blanket NOP.
Measured by C++ instrumentation of MAME's mips3 interpreter (`g_cache_hist[32]` on the `case 0x2f`
dispatch). **5,208,585 cache ops executed over a 120 s boot.** Decode: `op=instr[20:16]`,
`cache_sel=op[1:0]` (0=I,1=D,2=SD,3=SI), `operation=op[4:2]`.

| op | cache/operation | boot count | % |
|----|----|----|----|
| 0x01 | D Index-Writeback-Invalidate | 1,483,598 | 28.5% |
| 0x00 | I Index-Invalidate | 1,481,976 | 28.5% |
| 0x15 | D Hit-Writeback-Invalidate | 1,400,427 | 26.9% |
| 0x10 | I Hit-Invalidate | 839,506 | 16.1% |
| 0x08 / 0x09 | I/D Index-Store-Tag (cache init) | 1,025 / 1,025 | — |
| 0x14 | I Fill | 512 | — |
| 0x11 | **D Hit-Invalidate (NO writeback)** | 489 | — |
| 0x19 | D Hit-Writeback | 21 | — |
| 0x0b | secondary Index-Store-Tag (L2 probe) | 6 | — |

**Four primary-cache ops = 99.94%. Secondary/L2 ops are ~0 (just the 6-hit probe) — this Indy has no
L2, so the ~30 static `cache_sel=3` code sites never execute. No L2 modeling needed.**

**r9999 cache reality (corrected 2026-06-13): caches are INCOHERENT → `cache`→NOP is a LATENT BUG.**
r9999 has separate **L1i + L1d** (`l1i.sv`/`l1d.sv`) over an **L2 that IS transparent/coherent** and is
hidden from the kernel via `Config.SC=1` (kernel sees "R4000PC", so the ~30 static `cache_sel=2/3`
secondary ops are gated out — confirmed 0 dynamic). The live coherence axis is **L1i vs. D-side stores**:
the kernel writes code (runtime CPU patching at boot — `R4000_jump_war`/`mtext_fixup`; loadable-module
`doelfrelocs`) through L1d/L2, and L1i then holds a stale copy. So the I-cache `cache` ops **must** be
honored, not NOP'd. (Early boot may get lucky if a patched line was never fetched into L1i yet — cold
L1i fetches the patched copy from coherent L2 — but module loading / re-patch of executed code fails
without it.) No DMA/snoop logic exists in L1d today, so the D-side DMA ops are moot **while I/O stays
backdoored**.

**Decode/handling obligations:**
- Decode the full op field; **privilege-check** (`cache` is kernel/CU0-only → user-mode = Coproc-Unusable);
  compute the EA (`base+signext(offset)`).
- **I-cache ops (`0x10` Hit-Inval-I, `0x00` Index-Inval-I, + I-side of any others): drive the existing
  L1i `flush_req`/`FLUSH_CACHE`.** The I-cache is never dirty, so a **whole-L1i flush is a correct
  over-approximation of EVERY I-cache op** — simplest wiring: any I-cache `cache` op → `flush_req`. This
  is the one real obligation today (it's a *wiring* task — the flush HW already exists in `l1i.sv`).
- **D-cache ops (`0x01`/`0x15`/`0x11`/`0x19`): NOP-safe while there is no incoherent DMA** (no snoop logic
  present). IF real incoherent DMA is ever added behind L1d, honor the invalidate-vs-writeback distinction
  — esp. **`0x11` D-Hit-Invalidate must invalidate WITHOUT writeback** (DMA-in); do NOT promote it to a
  writeback-invalidate or you reintroduce a dirty+stale-line corruption window over DMA'd data.
- **Index-Store-Tag (`0x08`/`0x09`) / Fill (`0x14`): NOP** — r9999's caches reset clean (no power-on tag
  scrub needed, unlike real R4000 silicon); cache *size* comes from `Config`, not the tag-probe.

## Serial console output — how IRIX prints (r9999 bring-up)
**MEASURED 2026-06-13 (graphics-console boot): the kernel does NOT route console through ARCS.**
Breakpoint-counted over a full boot: `arcs_write`=**0**, romvec[Write]=**0**, `du_putchar`=**0** (serial
not the console here), `call_prom_cached`=**2** (a non-console early PROM query). The boot text is produced
**directly by the kernel's own console driver** — the **graphics** console driver (framebuffer over GIO64)
for `console=g`, which MAME runs. So the static-symbol "Phase 1 = ARCS console" idea below is NOT what a
normal boot does.
1. ~~**Early boot = ARCS PROM console**~~ — `arcs_write`/`call_prom_cached` exist but are **not exercised**
   during boot (arcs_write=0 calls). IRIX's own console comes up early enough that ARCS console isn't used.
   **RESOLVED (serial boot measured 2026-06-13, `console=d`, graphics-less):** still **`arcs_write`=0,
   `call_prom_cached`=2 (non-console)** — so there is **NO early ARCS console window**. Captured the full
   serial console via a C++ hook on the IOC2 SCC TX register (`scc_dc_w` in `ioc2.cpp` — 972 console bytes;
   the kernel's `du_putchar`/`ducons_write` entry-breakpoints undercount because TX is buffered/interrupt-
   driven, but the SCC-write hook is ground truth). The PROM phase ("Running power-on diagnostics… press
   <Esc>") is **PROM code writing the Z8530 directly**; the IRIX phase ("IRIX Release 6.5 IP22…") is the
   **kernel's own serial driver writing the Z8530 directly**. **Conclusion for r9999:** the "free output via
   the ARCS Write hook (`arcs_fw`)" path does **NOT** work for IRIX kernel console — r9999 must **emulate a
   minimal Z8530/SCC** (TX data reg + RR0 Tx-empty status) at the IOC2 SCC address to capture IRIX serial
   console. (r9999 is sash-less/PROM-less, so the PROM-phase path is moot anyway.) How to get a graphics-less
   serial boot in MAME + capture: see the MAME-session memory [[mame-headless-harness]]. Reconstructed
   console saved at `~/code/mame/irix_serial_console.txt`.
2. **After console init = IRIX DUART driver → Z8530 SCC.** The `cn*` console subsystem dispatches to the
   serial driver `du_*` (`du_putchar`/`ducons_write`/`du_console`), which drives the **SCC85230 (Zilog
   Z8530-family)** in the **IOC2/INT2** ASIC. MAME: `src/mame/sgi/ioc2.cpp` `m_scc` (scc85230), mapped at
   IOC2 offset `0x0c-0x0f` (`ab_dc_r/w` = chan A/B data/control); canonical SGI IP22 serial SCC ≈ phys
   `0x1fbd9830` (confirm the absolute IOC2 base). Console device selected by the ARCS `console` env var
   (`arg_console`: `d`=serial duart, `g`/`G`=graphics).
   To keep capturing console after IRIX leaves the PROM: implement a **minimal Z8530** at that address
   (TX data reg + RR0 "Tx buffer empty" status) draining to stdout, or keep IRIX on the PROM console if it
   honors `console=d`. (`du_putchar` works through a per-port struct at kdata `0x8832d670 + port*0x84`; the
   mapped SCC base lives in that struct, set at driver init.)

## Kernel entry & boot handoff
- **ELF entry = `0x88005960`, symbol `start`** — kseg0 cached → **PA `0x08005960`**; the image loads at
  **PA `0x08000000`** (VA base `0x88000000`). DRAM at 0x08000000-0x0fffffff already exists in our sim
  (Linux used it: "Initmem … [mem 0x08000000-0x0fffffff]").
- Entered by the PROM with ~~the **ARCS calling convention**: `a0=argc, a1=argv[], a2=envp[]`~~
  **[CORRECTED by MAME ground truth 2026-06-12 — see `IRIX_CPU_REQUIREMENTS.md`]:** the real register
  state at `start` is **`a0=8, a1=0, a2=0`** — NOT argc/argv/envp pointer arrays (`a1`/`a2` are zero;
  there is no argv/envp array to walk). `start` still saves a0/a1/a2 to gp-relative globals immediately.
  It sets `gp=0x88332bf0`, loads `sp` from `0x8832bfa0`, then `jal`s `_check_dbg`(@0x880255e8) and
  `debug`(@0x880152c8) — both debug hooks that return — before the real bring-up. The kernel gets its
  config from the **SPB at phys 0x1000** (sig "ARCS") + romvec, NOT from registers.
- **To boot on r9999:** load the ELF (vaddr `0x88xxxxxx` → PA `0x08xxxxxx`), set up an ARCS `argc/argv/envp`
  + environment, jump to `0x88005960`. Natural fit: extend our `arcs_fw` (already does ARCS vectors for
  Linux) with an IRIX `LoadAndExecute` that enters `start` with those args. **Open:** the CPU mode at entry
  (32/64-bit, KX/EXL/ERL) the PROM is expected to leave set.

## First run attempt on the r9999 sim (2026-06-12)
`ooo_core -f unix --arcs arcs/arcs_fw.bin -c 0`: the N32 kernel ELF **loads and runs**. Path: `start`
(0x88005960) sets gp/sp, saves the ARCS a0/a1/a2, `jal`s init (`_check_dbg` returns), then at
`0x880059f0 lw $a0,($a0)` it **faults** (pointer derived from the garbage ARCS args we passed) → vectors to
the BEV=1 general-exception vector `0xbfc00180`, which is empty (zeros) → executes NOPs forever. The `[sr]`
probe confirms EXL 0→1 at cyc 236 (exception taken); reset Status `0x70400004` (KX=0, ERL=1, 32-bit kernel).
**No ISA/unsupported-instruction fault, and no console output** (derails before `arcs_write`).
**Blocker = the ARCS boot environment, not FP/ISA.** Needs a real IRIX-compatible ARCS shim: valid
`argc/argv/envp`, the SPB/romvec layout IRIX expects, env vars (`console`,…), and memory descriptors. Our
Linux `arcs_fw` doesn't match. Once past it, the Phase-1 PROM console (`arcs_write` → our putchar → stdout)
should produce output. **Encouraging:** the ISA ran clean; FP would only surface much later.

**Ground truth now captured by the MAME session → see `IRIX_CPU_REQUIREMENTS.md`** (IRIX 6.5.2 boots to
multiuser in MAME). It corrects two assumptions above and specs the r9999 boot shim:
- **Entry regs:** enter `start` (0x88005960) with **a0=8, a1=0, a2=0** — *not* argc/argv/envp arrays
  (a1/a2 are 0; the "garbage argv pointer" framing above is wrong). SR=0x30004801, clean GPRs.
- **ARCS SPB at phys 0x1000** (sig "ARCS" + the exact field layout in IRIX_CPU_REQUIREMENTS.md) → a
  35-entry romvec. The **running kernel calls the romvec exactly ONCE** (`GetEnvironmentVariable`); it is
  not a live-firmware-heavy interface — the shim mostly leaves correct *in-memory* state.
- **RAM sizing is via the SGI MC, NOT ARCS** (resolves the memory-map question): the kernel reads
  `MEMCFG0/MEMCFG1` at phys `0x1fa000c4/0xcc` (`szmem`@0x8800790c). r9999's MC model must return values
  describing its DRAM (example `MEMCFG0=0x23200000` → bank @ 0x08000000).
**Next: build the r9999 boot shim** per IRIX_CPU_REQUIREMENTS.md (plant SPB @0x1000 + enter start with
a0=8/a1=0/a2=0 + return sane MEMCFG0/1 from the MC + a minimal romvec with GetEnvironmentVariable), then
re-run — should clear the early derail. (Our derail at `0x880059f0` predates `szmem`; the missing SPB +
entry regs are the immediate cause, not an ISA gap.)

## Cross-refs
- `FPU_PORT_STUDY.md` — FP plumbing/dataflow to graft (rename, scheduler, mem-pipe moves).
- `FPU_ROUNDING_EXCEPTIONS.md` — R4000 rounding/exception spec; the E-trap punt strategy.
- Memory [[project_mame_fpu_instrumentation]] — MAME dynamic trace to confirm the *runtime* FP working set
  (this doc is the *static* set). [[project_r9999]] — IRIX is the ultimate target.

## Open items / to-verify
- Where/why the kernel runs `cvt.s.l`/`cvt.d.l` (only 2 static) — is it on the boot path? If not, even
  those could trap-and-emulate initially.
- Confirm the `emulate_*` trigger (unaligned FP access vs general BD precise-exception) by reading those
  routines' disassembly; derive the exact EPC/Cause.BD contract r9999 must honor.
- N32/64-bit-mode boot specifics (the kernel is N32 MIPS-III; entry 0x88005960) — segment/mode at entry.
- Validate every non-FP mnemonic actually decodes+executes in r9999 (the gap list assumes the MIPS-III
  integer/system/atomic set is complete — high confidence, but spot-run the kernel's hot ops).
- User-side FP (libc/X/apps) working set is larger than the kernel's — scope separately when past boot.
