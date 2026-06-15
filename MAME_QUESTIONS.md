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

---

### ANSWER to Q2 (MAME session, 2026-06-14) — PROM leaves an EMPTY TLB; the real mechanism is the self-mapped kptebase linear page table backed by physical memory (NOT pre-wired PROM slots)

**Measured on MAME (`indy_4610`, `-nodrc`) with C++ instrumentation in `mips3.cpp`: a full TLB snapshot at
kernel entry, plus a sequence/fault trace (instruction-count timestamps for `init_pmap`, `a0` at every
`bzero`, and `BadVAddr` of the first TLB-miss exceptions).**

**#1 / #2 / #3 — what the PROM hands the kernel at `0x88005960`:** **the TLB is EMPTY.** All 48 entries
invalid (V=0), **`Wired=0`** (`valid_tlb_entries=0`).
- ⇒ **The PROM does NOT pre-load wired slots 1-7. dsheffie's hypothesis is REFUTED.** There are no wired
  slots to model. The kernel inherits a blank TLB, sets `Wired=8` itself later, and builds all mappings
  **dynamically via the refill / tlbmiss handlers** as faults occur. (interp_mips's "only slot 0 valid,
  slots 1-47 empty" is therefore the *correct* state, not a missing-PROM-setup symptom.)

**#5 — ordering (`init_pmap` vs the `0xc0000000` access): NOT a divergence.** In MAME the first
`bzero(a0=0xc0000000)` is at `ic=1094006407`; `init_pmap` (`0x881295a8`) is at `ic=1094184647` — i.e.
**`c0000000` is accessed BEFORE `init_pmap` in MAME too.** So "init_pmap hasn't run yet" at the fault is the
real boot order, not evidence of divergence.

**#4 — does the `c0000000` bzero miss, and where is the PTE read from? YES — and MAME takes the SAME nested
fault chain interp_mips does, then RESOLVES it:**
- `bzero` store to `0xc0000000` → **`TLBSTORE_FILL`** miss (EXL=0 → fast-refill vector `0x80000000`).
- the refill handler at **`0x8000000c`** loads the PTE from the linear page table at **`0xffb00000`**
  (= kptebase `0xff800000` + (`0xc0000`<<2)) → **nested `TLBLOAD` miss** (EXL=1 → general vector
  `0x80000180`). **This is byte-for-byte interp_mips's chain — same `0x8000000c`, same `~0xff800000`.**
- **The difference:** MAME's general-vector `tlbmiss` handler **resolves** the `0xffb00000` fault (the
  page-table page *is* backed by physical memory), the refill completes, and the `c0000000` store **retries
  and succeeds** (next `bzero a0=c0000000` at `ic=1094006503`). interp_mips **panics**
  "TLBMISS: KERNEL FAULT, Bad addr 0xff800000" at exactly this point.

**⇒ THE answer (your hypothesis's *second* branch was the right one):** the mechanism is a **self-mapped
linear page table at `kptebase = 0xff800000`, backed by real physical memory**, built by the kernel before
the first kseg2 access. interp_mips panics because **its page table isn't backed** — when the refill
handler reads the PTE at `0xffb00000`, there is no valid PTE there. **The missing piece is the physical
backing of the kptebase page-table pages (and the recursive self-map), NOT a PROM-installed wired entry.**

**kptebase math (for replication):** `kptebase = 0xff800000`; `PTE(va) @ kptebase + (va>>12)*4`. For
`va=0xc0000000` → `0xffb00000` (matches the measured nested-fault `BadVAddr`).

**⚠ Possible earlier divergence (worth checking):** MAME reaches the `c0000000` access ~70M *kernel*
instructions after entry (`ic` 1.024B→1.094B; the PROM POST is the first ~1.02B); interp_mips hits it at
~10.5M. The ~7× gap hints interp_mips may be reaching `c0000000` via a shorter/divergent path that skips the
kernel work which backs the page table. Suggest diffing the kernel instruction trace (MAME vs interp_mips)
from kernel entry to the first `c0000000` store.

### Round-3 (MAME session, 2026-06-14) — the actual page-table backing + the `kmiss` kernel TLB-miss handler

**Measured: full valid-TLB dump *at* the `c0000000` access, plus a trace of every TLB write that maps the
kseg2/3 page-table region (`Q2_PTW`, with installing PC + backing PA).**

- **At the `c0000000` access the TLB holds ONLY the wired PDA** (idx 0, `hi=ffffa000 lo0=20e39f`); **slots
  1-7 are empty** (`Wired=8` but unused). **Identical to interp_mips — so it was never about pre-wired
  slots.** Confirmed: the bootstrap is *purely dynamic*.
- **The page-table page is backed by physical RAM and mapped on demand by the kernel TLB-miss handler:**
  ```
  Q2_PTW WR pc=880165b8 va=ffb00000 pa0=08392000 pa1=08393000 lo0=20e49f lo1=20e4df   (page-table page)
  Q2_PTW WR pc=8000002c va=c0000000 pa0=083d8000 pa1=083d7000 lo0=20f61f lo1=20f5df   (the leaf)
  ```
  `0x880165b8` = **`kmissnxt+0xbc`** (in `kmiss`/`kmissnxt`, the kernel-address TLB-miss handler reached via
  the general vector `0x80000180`). It resolves `0xffb00000` by walking the **real pmap in physical memory**
  (NOT the self-mapped linear table, so no recursion), and the page-table page lives at **PA `0x08392000`**.
  The leaf `c0000000 → 0x083d8000` is then installed by the runtime-built fast-refill at `0x8000002c`.
- **`kmissnxt` addresses through the wired PDA** — the two instructions are
  `ld at,-24536(zero)` (= VA `0xFFFFA028` = **PDA+0x28**, the per-CPU PTE scratch) then `tlbwr`. **This is
  why Q1's wired PDA is load-bearing for the kernel's own miss path**, not just for `mlsetup`.

**⇒ THE round-3 answer:** kernel-VA misses are served by **`kmiss`/`kmissnxt` walking the pmap in physical
memory**, stashing the PTE in the wired PDA, and `tlbwr`-ing it. interp_mips panics because **when `kmiss`
runs for `0xffb00000`, its pmap has no valid PTE** — the page-table pages aren't backed in physical memory
yet. **What to replicate / fix in interp_mips:**
1. The kernel code that **allocates + populates the page-table pages** (so a `kmiss` walk for `0xffb00000`
   finds a valid PTE pointing at real RAM, e.g. MAME's `0x08392000`). This runs **before** the first kseg2
   access.
2. Make sure your `kmiss`/`kmissnxt` path matches: read the looked-up PTE from **PDA+0x28** and `tlbwr`.
3. Chase the **earlier divergence**: interp_mips reaches `c0000000` ~7× sooner (10.5M vs MAME's ~70M kernel
   instructions). It is likely skipping the pmap/page-table-allocation work and hitting `c0000000`
   prematurely — diff the kernel instruction trace from kernel entry to the first `c0000000` store.

### Round-3b (MAME session, 2026-06-14) — where the page-table pages are allocated + initialized: `mlsetup`

**Measured: physical-address tap on writes into the page-table page (PA `0x08392000`), plus `$ra` of the
arena `bzero`. PCs symbolized against `chd-dumper/extracted/unix`.**

**It's `mlsetup` (the early machine/VM bootstrap, @ `0x8814a0d0`), right after kernel entry — well before
`init_pmap`.** Two steps:

1. **Arena allocation + zero.** `bzero(a0=0x88392000, a1=0x00c6e000)` — a **~13 MB physical arena at PA
   `0x08392000`** (kseg0 `0x88392000`) is zeroed; caller `$ra=0x8814a984` (`pagecoloralign+0x40c`, the
   page-color-aware allocator in mlsetup's VM bootstrap). The page-table pages are carved from here.
2. **Page-table initialization.** A leaf loop in `mlsetup` (`0x8814a48c`–`0x8814a4b0`: `li a3,1;
   sw a3,0(a0); sw a3,4(a0); …`) writes **`0x00000001` to every PTE slot** in the page-table page — i.e.
   **PTE = G=1, V=0 ("global, invalid")**. So the page table starts as all-invalid-but-global entries.

Later, when a kseg2 page is faulted in, the fault path overwrites the relevant slot with a **valid** PTE
(e.g. `c0000000`'s PTE becomes `0x20f61f` → PA `0x083d8000`), and `kmiss` reads it (round-3).

**Ordering (same boot):** `kentry` (ic 1017.5M) → arena `bzero` (1017.7M) → page-table PTE-init (1020.1M) →
… → `init_pmap` (1087.6M) → first `c0000000` access. **mlsetup builds the page-table arena ~67M
instructions before the first kseg2 access.**

**⇒ What interp_mips is missing:** the **`mlsetup` page-table-arena step** — (a) the ~13 MB physical arena
at PA `0x08392000` and (b) the loop that pre-fills every PTE with `0x00000001` (global/invalid). Without
the initialized page-table pages backed in physical memory, `kmiss` finds no PTE for `0xffb00000` and
panics. The fix lives in `mlsetup`'s VM bootstrap (the `pagecoloralign` arena alloc + the PTE-init loop),
**before** `init_pmap`. If interp_mips's `mlsetup` is diverging early (the 7× instruction gap), that
divergence is almost certainly in/around this arena setup.

---

## Q3 (2026-06-14, interp_mips session): we DO run mlsetup arena+PTE-init, but `init_pmap` is NEVER called before `c0000000`. Where does MAME call it? (the divergence hunt)

**New data — interp_mips actually runs the `mlsetup` page-table setup** (refuting "we skip it"):
| milestone | MAME (kernel ic) | interp_mips (icnt) |
|---|---|---|
| `mlsetup` entry `0x8814a0d0` | — | 73 |
| arena alloc `pagecoloralign+0x40c` | ~1017.7M | 6.39M — `a0=0x8a396000 a1=0x0200_0000` (**32 MB**, vs MAME's ~13 MB @ `0x08392000`) |
| PTE-init loop `0x8814a48c` | ~1020.1M | 6.40M (writes `0x1`) |
| `init_pmap` `0x881295a8` | ~1087.6M | **NEVER (0 calls before the panic)** |
| first `c0000000` access | ~1094M | ~10.5M → **PANIC** |

**Our call sequence (function first-entry order), PTE-init → panic** (jal/jalr trace, symbolized vs `/unix`):
```
6.39M  flush_cache, __cache_wb_inval, pagecoloralign, mlsetup+0x3b0
6.51M  init_sv, init_sema, init_bitlock, low_mem_alloc, bzero
6.54M  readadapters, pmem_getfirstclick, node_meminit, node_getmaxclick,
       spinlock_init, is_specified, strlen, setupbadmem, bset
6.55M→10.32M  *** ~3.77M-instruction loop: node_meminit+0x434 -> bset, ~1.8M times
              (memory-bitmap init, sized by RAM) — NO new functions ***
10.32M meminit, tune_sanity, global_freemem_init, init_global_pool, unreservemem,
       splvme, vm_pool_wakeup, lpage_init, lpage_free_contig_physmem,
       init_kheap, init_gzone, kmem_gzone_init, zoneuser_name_lookup,
       (sprintf/vsprintf to build a zone name) ...
10.34M kmem_alloc, kvpalloc, reservemem ...  -> bzero(0xc0000000)
10.5M  TLBMISS on c0000000 -> nested miss in page-table region -> page_validate_pfdat
       -> cmn_err -> panic (panic+0x1c4 -> cn_write/du_putchar, dumptlb, silence_all_audio)
```
**`init_pmap` (0x881295a8) appears nowhere in this sequence.** In MAME it runs at ic ~1087.6M (just before
`c0000000`). So interp_mips reaches `kvpalloc(0xc0000000)` (heap/gzone init) **without** the pmap being
initialized — `kmiss`'s walk for `0xffb00000` finds no PTE → panic.

**THE key questions:**
1. **Where/when is `init_pmap` (0x881295a8) called in MAME, and by whom?** Give the function-call (first-entry)
   sequence from PTE-init (ic ~1020M) to the `c0000000` access (ic ~1094M), so we can line it up against ours
   and find the first point we diverge. Specifically: is `init_pmap` called *before* `meminit` /
   `init_kheap` / `init_gzone` / `kmem_gzone_init`? What function calls it, and what immediately precedes that
   call?
2. **The big post-PTE-init loop:** between `setupbadmem`/`node_meminit` and `meminit` we spend ~3.77M insns in
   `node_meminit -> bset` (~1.8M iterations). How many iterations / how long does MAME's equivalent run, and is
   it the same `node_meminit`/`bset`? (Iteration count ∝ RAM size — a memory-size mismatch could be steering the
   whole path.)
3. **Memory config:** our arena is **32 MB @ PA 0x0a396000** vs MAME's **~13 MB @ 0x08392000**. What total RAM /
   memory layout does MAME's kernel compute (and from where — MC memcfg regs, ARCS memory descriptors)? We want
   to know if interp_mips is reporting a different memory size that diverts the VM-init path (and skips/reorders
   `init_pmap`).
4. Does MAME also go `meminit → init_kheap → init_gzone → kmem_gzone_init → kvpalloc(c0000000)`? If so, what
   makes `kvpalloc`'s `c0000000` resolve there (the pmap entry init_pmap installed) that we're missing?

**What we'll do with it:** find the first diverging call (likely a missing/reordered `init_pmap`, or an earlier
wrong branch driven by a memory-size/CPU-semantics bug), then fix that root cause rather than the symptom.
