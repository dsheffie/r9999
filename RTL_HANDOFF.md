# Handoff notes → r9999 RTL session

Findings from the MAME-oracle + interp_mips co-sim work (see `MAME_QUESTIONS.md`) that the **RTL** session
should verify against the actual r9999 core. Each entry: what the bug is, MAME's golden behavior, and how to
check whether r9999 RTL has it.

---

## 2026-06-15 (RTL session) — ANSWERED: the KPTEBASE/nested-EPC wall is NOT a r9999 RTL bug

**Bottom line: r9999's RTL already does the right thing.** Two things made the original check below a dead
lead:

1. **The premise was superseded the same day.** interp_mips's own `IRIX_BOOT_NOTES.md` (later 2026-06-15
   update) found the KPTEBASE wall was **not** `kvalloc`/`kptbl` — `kptbl[c0000000]` was a valid PTE all
   along. The real bug was **CPU exception semantics**: `set_exc_pc` updated EPC + Cause.BD *unconditionally*
   instead of **only when `Status.EXL==0`**. The self-mapped refill takes a *nested* TLB miss (EXL=1) inside
   the `0x80000000` handler; that nested miss must NOT clobber EPC, so the `eret` retries the original
   `0xc0000000` access. So don't check `kptbl[c0000000]==0x1` — check the EXL-gating of EPC.

2. **r9999's RTL already gates EPC on `EXL==0`.** `exec.sv:2582` latches the architectural EPC from the core
   only when `r_sr_exl==0`; a nested exception preserves EPC and `eret` retries correctly. The refill *vector*
   is likewise gated (`core.sv:1582`, `n_tlb_refill = tlb_refill & ~w_sr_exl` → nested refill falls through to
   the general `0x180` vector; this is why `test_xtlb_nested` passes). **So the nested-EPC wall that bit
   interp_mips cannot occur in r9999's RTL.**

**Landed anyway (conformance cleanups, commit `701db1e`):** the matching EXL-gate for **Cause.BD**
(`exec.sv` `n_exc_in_ds`; EPC was already gated, BD wasn't), the same fix in **`interpret.cc` `set_exc_pc`**
(it had the unconditional-EPC bug), and a directed regression **`tests/except/test_nested_epc.S`** (a syscall
whose handler issues a second syscall while EXL=1; on the nested entry EPC must still equal the original —
prints `P`, trace shows the `0x180` vector entered twice). Validated: `test_nested_epc` P (`-c0`), randgen
40/40, `except`/`xtlb`(incl. nested)/`eret` suite co-sim-clean.

**Co-sim caveat worth knowing:** `ooo_core -c1` compares **GPRs only** — not CP0 (`EPC`/`Cause`/`Status`) and
not `k0`/`k1`. A revert-test confirmed the interp's EPC bug produced **zero** `-c1` divergence, so it was
latent. To co-sim-validate CP0/exception behavior, fold the value into a non-`k0`/`k1` GPR and self-check.

**The actual next IRIX blocker for the RTL is upstream of all this:** r9999's RTL sim has **no IRIX boot
flow** — no `/unix` loader, no SoC/pseudo-BIOS wiring in `top.cc` (the SCC model + the `e451d50` wirepda fix
*are* in `main`, but the kernel image is never loaded). IRIX-on-r9999-RTL needs that bring-up before any of
the deeper `kvmsetup`/KPTEBASE questions can be exercised on silicon/Verilator.

---

## 2026-06-15 — Check: does r9999 back the IRIX kernel page table at the first `0xc0000000` access? (the KPTEBASE wall)

**Why you're being asked.** Booting real IRIX 6.5.22, `interp_mips` (the functional ISS) walls ~6.4M
instructions in with **`PANIC: TLBMISS KERNEL FAULT, Bad addr 0xff800000`** during `mlsetup`'s VM init. The
MAME oracle shows exactly what *should* happen; interp was doing it wrong. **The RTL needs the same check** —
if r9999 boots IRIX this far, does it back the page table the way MAME does, or does it wall the same way?

**The scenario.** Early in `mlsetup`, the kernel `kvalloc`'s a region at **VA `0xc0000000`** (base of mapped
kseg2) and `bzero`s it (`bzero` store at **PC `0x8801a860`**, `sdl zero,0(a0)` with `a0=0xc0000000`). That
store misses the TLB → the runtime refill handler at `0x80000000` walks the **self-mapped linear page table**:
the PTE for `0xc0000000` lives at VA `0xffb00000`, whose backing is the kptbl page itself. If that walk can't
resolve, it recurses toward `0xff800000` (the PT-of-PT root) and panics.

**MAME golden behavior (what correct looks like):**
- `kptbl` base = global `*(0x8832cf58)` = **`0x88392000`** (kseg0 of PA **`0x08392000`** — the page-table
  arena `mlsetup` allocates).
- **`kptbl[c0000000]` @ PA `0x08392000` = `0x4020f61f`** — a **VALID** leaf PTE (hw EntryLo `0x20f61f`: V=1,
  D=1, G=1, C=3 cached, PFN `0x83d8` → PA `0x083d8000`; bit30 is a SW flag, masked when loaded into the TLB).
  It is written by **`kvalloc+0x2dc` (PC `0x880fd07c`)** *before* the bzero — kvalloc overwrites mlsetup's
  `0x1` (global/invalid) placeholder with the real PTE.
- `kptbl[ffb00000]` (@ PA `0x08490c00`) and `kptbl[ff800000]` (@ PA `0x08490000`) are both **`0x00000000` —
  unused**. MAME resolves VA `0xffb00000` by having **`kmissnxt` (PC `0x880165b8`) compute the PA from
  `kptbl_base` directly** (the kptbl self-reference: `0xffb00000` → PA `0x08392000`) and `tlbwr` it
  (EntryHi=`ffb00000`, EntryLo0=`0x20e49f`/PFN `0x8392`, EntryLo1=`0x20e4df`/PFN `0x8393`; a **regular tlbwr,
  not wired**). MAME therefore **never reads `kptbl[0xffb00000]` and never touches `0xff800000`.**

**interp_mips's failure (the bug — confirm whether RTL shares it):**
1. **`kptbl[c0000000]` = `0x1`** (invalid) — its `kvalloc` left the placeholder instead of writing the valid
   PTE. ⇒ even once `0xffb00000` is mapped, the leaf PTE is invalid.
2. Its refill/`kmissnxt` **reads `kptbl[0xffb00000]`** (=0) and **recurses to `0xff800000`** instead of
   computing the self-reference from `kptbl_base` → nested-fault → panic.

**How to check in r9999 RTL (Verilator or FPGA single-step — `read32(7)`=last PC, single-step is wired):**
1. Boot the IRIX image far enough to reach `mlsetup`. If r9999 RTL doesn't get this far yet, note where it
   stops (prior walls: `wirepda` Q1 — already fixed in RTL `e451d50`; then the platform-constant cascade that
   interp hit, which is **SoC/firmware**, not CPU — see below).
2. Breakpoint **PC `0x8801a860`** (the `c0000000` bzero). Read **PA `0x08392000`** (= `kptbl[c0000000]`,
   VA `0x88392000`). **Expect `0x4020f61f`.** If it's `0x1` → same bug as interp: kvalloc isn't writing the
   leaf PTE — find out why (a store not landing? a cache/TLB issue? or kvalloc took a divergent path).
3. Single-step the store. **Expect**: TLB-store miss → refill `0x80000000` → nested miss on `0xffb00000` →
   general vector → `kmissnxt` `0x880165b8` installs `0xffb00000`→PA `0x08392000` → store retries & succeeds.
   **Bug**: a recurse to `0xff800000` / `PANIC TLBMISS KERNEL FAULT`.

**Likely category.** Most of interp's boot bugs were **SoC/firmware** (MC `mconfig0=0x23200000`, CP0
`Config=0x0002e4b3`, IOC2 SYSID `0x26`, the ARCS/sash `argc/argv/envp` handoff, romvec stubs) — those live in
the **Henry SoC / pseudo-BIOS**, NOT the r9999 core, so the RTL's platform must supply them too (they are
documented in `MAME_QUESTIONS.md` Q4/round-4 device-register batch + `IRIX_CPU_REQUIREMENTS.md` /
`firmware-arcs.md`). This page-table item is **kernel software** (`kvalloc`/`kmissnxt`) running on the core —
so if RTL gets the wrong `kptbl[c0000000]`, the root cause is either (a) a **core bug** that makes those
stores/TLB ops misbehave, or (b) a **platform divergence** earlier that steers `kvalloc` wrong (as it did in
interp). Check the core-level path first: the `cache`/TLB ops around the PTE store (r9999's incoherent-L1 +
`CACHE`-flush model — see `coherence-cache-tlb` / `IRIX_KERNEL_GAPS.md`) and the `tlbwr`/refill behavior.

Full analysis + all the golden values: `MAME_QUESTIONS.md`, **Q5 round-6** (and rounds 3/3b/4 for the
`kvalloc`/`kmissnxt`/kptbl-arena trace).
