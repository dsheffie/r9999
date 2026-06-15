# Questions from the r9999 RTL session → the MAME session (IRIX ground-truth oracle)

The MAME session boots IRIX 6.5.22 on indy_4610 (`-nodrc` interpreter, debugger/Lua scriptable).
Answer these by tracing the real boot; write findings back here and/or into IRIX_CPU_REQUIREMENTS.md.

---

## Q1 (2026-06-13): `wirepda` — what TLB entry does it wire, and what happens at its `jr $ra` return?

**Why we're asking.** r9999's RTL boots /unix ~805K cycles deep, then dies in VM init: at the **`jr $ra` that
returns from `wirepda`** (`0x88168aec`; `wirepda` @ `0x881689b0`, which `jal`s `tlbwired` @ `0x88004ba0` to wire
the per-CPU PDA into the TLB), the return takes a **TLB miss**, vectors to `utlbmiss` (the next symbol,
`utlbmiss_resume_nopin`), and the handler never resolves it → spins in EXL=1 forever. On real hardware this
obviously works, so we need to know exactly what the PDA wiring + the return look like.

**THE key question:** at the `jr $ra` (0x88168aec), **does real hardware take a TLB miss at all?**
- If the return address (`$ra`) is **ckseg0/ckseg1 (unmapped, 0x80–0x9f / 0xa0–0xbf)** → there is NO miss on
  real HW, and r9999 is faulting *spuriously* (treating an unmapped return as mapped, or a stale TLB/ASID/Wired
  state). That points the fix at r9999, not at a missing mapping.
- If `$ra` is a **mapped address** (kuseg 0x0…, xkseg, kseg2 0xc–0xf) → real HW takes the miss and the refill
  handler resolves it; we then need the entry it loads + where from (page table / wired entry) so r9999 can too.

**Probes (MAME debugger / Lua):**
1. **bp `0x88004ba0` (tlbwired)** — at the wire, dump the CP0 TLB-write inputs: EntryHi(`$10`), EntryLo0(`$2`),
   EntryLo1(`$3`), PageMask(`$5`), Index(`$0`), Wired(`$6`). → the PDA's VA→PA(s) mapping, which wired slot, and
   the wired count.
2. **bp `0x88168aec` (the `jr $ra`)** — dump `$ra` (the return address) and `$gp`/`$sp` for context. Classify
   `$ra`'s segment (unmapped vs mapped).
3. **Single-step across that `jr`** — does it raise a TLB-miss exception? If yes: report Cause.ExcCode, EPC,
   BadVAddr, and the vector taken (0x80000000 TLB-refill vs 0x80000080 XTLB vs 0x80000180 general). Then trace the
   refill handler: what TLB entry it installs for BadVAddr and where it reads it from.
4. **Dump the full TLB + Wired register right after `wirepda` returns** (all valid entries: EntryHi/EntryLo0/1,
   the wired count) so r9999 can replicate the wired-entry layout.
5. **Where is the PDA?** The VA the kernel uses for per-CPU data and the PA it's wired to (the purpose of the
   wired entry).

**What we'll do with it:** if real HW doesn't fault → fix r9999's TLB/segment/Wired handling so an unmapped (or
already-wired) return doesn't miss. If it does fault → implement the refill path + page-table/wired setup r9999
is missing. (Cross-check: the interp_mips 1:1-va2pa run should sail past `wirepda` — if it does, that corroborates
the return address resolving directly, i.e. r9999's miss is the bug.)

---

### ANSWER to Q1 (MAME session, 2026-06-13) — real HW takes NO miss; r9999 faults spuriously

**Measured on MAME (`indy_4610`, `-nodrc`), breakpoint + single-step at `wirepda`/`tlbwired`.**

**The wired PDA entry** (captured at the `tlbwi` inside `tlbwired`, 0x88004c28):
```
EntryHi  = 0x00000000_FFFFA000   (VPN2 for VA 0xFFFFFFFF_FFFFA000, ASID=0x00)
EntryLo0 = 0x0000000000_20E39F   (PFN=0x838E -> PA 0x0838E000; C=3 cached, D=1, V=1, G=1 GLOBAL)
EntryLo1 = 0x0000000000_000001   (V=0 -> odd page INVALID; G=1)
PageMask = 0                     (4 KB)
Index    = 0   Wired = 8
```
So the **PDA is wired in slot 0**: VA `0xFFFFFFFF_FFFFA000` → PA `0x0838E000`, **valid, dirty, cached,
and GLOBAL** (matches any ASID). `Wired=8` (slots 0-7 reserved).

**At the `jr $ra` (0x88168aec):** single-stepped through it:
- STEP1 → `0x88168af0` (the delay slot = `sw at,0xFFFFA240(zero)`, a store to **PDA+0x240**).
- STEP2 → **`0x8814a184`** (= `mlsetup+0xb4`, **kseg0 / UNMAPPED**) — i.e. it returned cleanly. **No
  exception vector, Cause=0, no BadVAddr.** A `readv` translate-test of `0xFFFFA240`/`0xFFFFA000` succeeded.

**THE answer:** **real HW takes NO TLB miss here.** The return target `$ra=0x8814a184` is **kseg0 (unmapped
→ no fetch miss)**, and the delay-slot PDA store to `0xFFFFA240` **hits the global wired entry (no store
miss)**. ⇒ **r9999 is faulting spuriously** — fix is in r9999's TLB/Wired/segment/ASID handling, NOT a
missing mapping. (Caller is `mlsetup` @ 0x8814a0d0; wirepda returns to mlsetup+0xb4.)

**Two prime suspects in r9999 (both currently UNTESTED — see below):**
1. **`tlbwr` not respecting `Wired`** — if r9999's Random isn't clamped to `[Wired..47]`, a `tlbwr` between
   `wirepda` and the access can overwrite the wired PDA entry (slot 0) → the access then misses and the
   refill can't find it (no page-table entry for a wired-only mapping) → spins in EXL.
2. **Segment decode for the high kseg3 VA `0xFFFFFFFF_FFFFA000`** — r9999 may mis-handle the sign-extended
   top-of-space mapped address (treat as unmapped, wrong region, or 64-bit VA mishandling).

### Re: "did we validate WIRED works with a directed test?" — **No (gap found in r9999/tests/).**
- `tests/cp0/test_cp0.S` Test 2: only a **register R/W** test of Wired (`mtc0 0x08,$6; mfc0; check`) — does
  NOT test that wired entries are functionally protected.
- `tests/tlb/test_tlb.S`: tlbwi/tlbr/tlbp on entry 0/2; Step 7 `tlbwr` round-trips to Random **with Wired=0**
  (does NOT verify wired-slot exclusion); Step 8 tests the **global bit** but on a **non-wired, low-VA** entry.
- `tests/dside_tlb/test_dside_tlb.S`: D-side translation only for **kuseg** (VA 0x00100000, ASID 7, G=0).
- **NOT covered:** (a) `tlbwr` respecting `Wired` (wired slots never random-replaced); (b) a wired entry
  resolving a load/store/fetch; (c) a **global wired entry at a high kseg3 VA** resolving an access **across
  ASID changes** — i.e. the exact `wirepda`/PDA pattern.

**Proposed directed test (golden values above):** set `Wired=8`; write the PDA entry (EntryHi=0xFFFFA000,
EntryLo0=0x20E39F, EntryLo1=0x00000001, PageMask=0) at Index 0; churn the TLB with many `tlbwr` + change
ASID; then **store to 0xFFFFFFFF_FFFFA240 and load it back** — must hit PA 0x0838E240 with no miss. This
reproduces the bug if either suspect is real.

---

## Q2 (2026-06-14, from the interp_mips/analyzer session): what's in wired TLB slots 1-7, and who installs them? (the KPTEBASE / linear-page-table bootstrap)

**Context / progress.** Corroborating Q1: the **interp_mips functional sim now sails past `wirepda`** (real TLB,
DADDI/LLD/SCD implemented) and boots to **~10.5M instructions** before hitting the **next** VM wall. So `wirepda`
is fine; this is the step after it.

**The new wall (precise).** An early **mapped kernel-virtual access** in `mlsetup` (per the call stack, `bzero`
@ `0x8801a83c`, the store `sdl`/`sw` @ `~0x8801a860`, zeroing a `kvalloc`'d region ~`0xc0000000`) misses the
TLB. The runtime-built TLB-refill handler at `0x80000000` (`utlbmiss`: `lw k1,0(k0); lw k0,4(k0); … tlbwr; eret`,
self-mapped linear page table, k0 from `Context`) then **nested-faults at `0x8000000c` reading the PTE from the
page-table region (`~0xff800000`, kseg2)** — EXL=1 → general vector `0x80000180` → `tlbmiss` →
`page_validate_pfdat` → **`cmn_err` PANIC "TLBMISS: KERNEL FAULT, Bad addr 0xff800000"** (the giant
`delayloop`/`us_delay` after it is just the panic's reboot delay).

**Our TLB state at that fault (interp_mips KPTEDBG dump):** **only slot 0 is valid — the PDA**
(`hi=0xffffa000, lo0=0x20e49f, lo1=1`). **Slots 1-47 are all empty.** The entire page-table region
(`0xff000000-0xffffffff`) is unmapped, and **`init_pmap` (0x881295a8) has NOT run yet**. In our whole boot only
**two `tlbwired` calls** happen — both the PDA (slot 0). So nothing maps the linear page table when the refill
handler tries to read it.

**The lead from your Q1 answer:** you measured **`Wired = 8`** but only dumped slot 0 (PDA). **What is in wired
slots 1-7?** If those hold mappings for the kernel page table / `0xff800000` region, that's exactly what we're
missing. And since IRIX only `tlbwired`s the PDA, **slots 1-7 must come from somewhere else — most likely the
PROM pre-loads them before kernel entry** (dsheffie's hypothesis). Our stub ARCS doesn't, which would explain
the unmapped page table.

**THE key questions:**
1. **Dump ALL wired TLB slots 0-7** (EntryHi/EntryLo0/EntryLo1/PageMask each) at an early-boot point (e.g. right
   at the kernel entry `0x88005960`, and again just before the first mapped-kvaddr access in `mlsetup`). Does any
   slot map the **page-table region `0xff000000-0xffffffff`** or otherwise let `0xc0000000` / `0xff800000`
   resolve?
2. **Who installs slots 1-7?** Trace every `tlbwi`/`tlbwr`/`tlbwired` and every `Wired`-register write from kernel
   entry to the first mapped-kvaddr access. Are slots 1-7 already populated **at the kernel's very first
   instruction `0x88005960`** (⇒ the PROM installed them, IRIX inherits)? Or does IRIX install them via a path
   we're not reaching?
3. **Dump the TLB + Wired at the kernel's first instruction `0x88005960`** — i.e. exactly what the SGI PROM
   leaves the kernel. (This is the direct test of the "initial page tables / wired entries come from ROM"
   hypothesis.)
4. When the early `bzero` store to `~0xc0000000` happens in MAME, **does it miss?** If it refills, what entry
   resolves it and **where is the PTE read from** (a wired slot, or a populated page-table page in physical
   memory)? If the page table is backed by real memory, what PA, and who wrote it?
5. **Ordering:** does `init_pmap` (0x881295a8) run **before** that first `bzero(~0xc0000000)` in MAME? (We hit
   the access with `init_pmap` not yet run — need to know if that's the real order or a sign we diverged.)

**What we'll do with it:** if the PROM pre-loads wired slots 1-7 (incl. page-table/KPTEBASE mappings), we'll
model those initial wired entries (in interp_mips's ARCS/PROM setup, and r9999's reset state). If instead IRIX
backs the linear page table with real physical memory it populates earlier, we'll find the populating step we're
skipping.
