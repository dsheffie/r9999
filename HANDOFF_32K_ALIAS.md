# HANDOFF — 32KB L1 / 256KB L2 inclusive cache, VA-index + PIdx synonym handling

Written 2026-08-18. Tree: `~/code/henry-gh/r9999` (this is the tree the work is in —
NOT `~/code/r9999`). Sim harness: `~/code/henry-gh/sim`.

## Goal (NOT met)

Boot **both** IRIX and Linux cleanly at **32KB L1D/L1I + 256KB L2**, inclusive L2,
with VA-indexed L1D and R10000 PIdx synonym handling.

## TL;DR

Both OSes fail at the goal geometry with VA-index+PIdx. Removing the synonym
machinery (PA-replay) makes IRIX clean. The failure is a **lost write**, and the
window has been measured directly.

| config (all 32KB L1 / 256KB L2, inclusive L2) | result |
|---|---|
| VA-index + PIdx, `l2.sv` as pushed | IRIX `PANIC: tlbmiss: invalid kptbl entry` @ cyc **224,815,628** |
| VA-index + PIdx, + presence fix (below) | same panic @ cyc **224,828,571** |
| VA-index + PIdx, + race detector build | same panic @ cyc **224,815,238** |
| **PA-replay** (no `L1D_VA_INDEX`, no `ENABLE_L2_PIDX`) | **clean past cyc 310M** |
| VA-index + PIdx, **Linux** (with `--disk`) | reaches userspace, then `Kernel panic - not syncing: Attempted to kill init! exitcode=0x0000000b` @ cyc **564.8M** |

The IRIX panic is deterministic to ~13k cycles out of 225M across three different
builds. That makes it a good bisect/instrument target.

## The measured mechanism — reload vs. back-invalidate race

A store **pops the mem queue at the moment it re-fires through port 1**
(`t_pop_mq = 1'b1` with `n_req = t_mem_head; t_got_req = 1'b1; n_is_retry = 1'b1`,
l1d.sv ~3781). From then on the store exists **only in `r_req`**. If port 1 misses,
it sits in `r_req` across the whole `INJECT_RELOAD` → `HANDLE_RELOAD` fill,
uncommitted.

During that window:
- `w_syn_busy_addrs2` / any pending-store gate scans `r_mq_addr_valid[]` — the
  **queue** — but the dangerous store has already left it.
- `t_snp_won`'s quiescence terms (`r_got_req | t_wr_array | r_last_wr | rr_last_wr`)
  cover the **pipeline**, but all go low during the reload wait.

So a back-invalidate can be acked for the line that is being filled. The L2 drops
the line and its presence bit; the fill then reinstalls it **dirty** behind the
L2's back, and the store can be lost.

**Detector added** (`l1d.sv`, `` `ifdef RELOAD_BI_RACE ``, inserted right after
`assign backinv_ack = r_backinv_ack;`):

```systemverilog
r_backinv_ack & r_l1d_outstanding &
  (r_snp_addr[`PA_WIDTH-1:`LG_L1D_CL_LEN] == r_mem_req_addr[`PA_WIDTH-1:`LG_L1D_CL_LEN])
```

**Result: 432 hits** on the IRIX run that panics. First 40 logged:
- 34/40 on page `0x00838` — the **same page** as the previously measured
  single-copy violation line `00838e290` in the `DROPDBG` comment in `l2.sv`.
  That is the kptbl page, and `tlbmiss: invalid kptbl entry` is the panic.
- `is_st` split 21 store / 19 load — the store cases are the lost-write candidates.

## Why the existing detectors all read clean

`L1D_SINGLE_COPY_CHECK` reported `single_copy_violations=0` through every failing
run. It looks for **two copies of one line**; this bug is a **store that never
lands**. A clean detector here is not a pass. Same for `bi_SURVIVED=0`.

## Fix direction (dsheffie's design, agreed but NOT implemented)

Do **not** keep trying to gate/stall the existing push protocol. Five variants were
tried and all failed: block-on-index (Linux clean / IRIX regressed), narrowed to
line (Linux clean / IRIX panics), + write-collision settle (no change),
escape on `~r_l1d_outstanding` (leaks 6/121 Linux, 15/49 IRIX), escape "hold the
line" (deadlocks). The deadlock is **structural**: `l2.sv` `BACKINV_WAIT`
(~line 2184) services ONLY acks — it cannot serve the fill the L1D is waiting on.

Instead, **invert alias handling from push to pull**:

1. L2 sees a read with `w_l1d_pres` set and `w_l1d_pidx != r_req_pidx`. Instead of
   `n_state = BACKINV_WAIT`, it **replies immediately** with a distinct "you have an
   alias" response type carrying the old PIdx, and **changes no state**. Idempotent,
   so a retry is always safe, and the L2 is never blocked — the cycle cannot form.
2. L1D takes that reply into new FSM states: write back the aliased line at
   `(old_pidx, index)` if dirty, invalidate it, then re-issue the original request.
3. **Why this is safe for free:** the L1D FSM is single-threaded on port 1 — the
   mem-queue pop is gated `if(!mem_q_empty && !t_got_miss && !r_lock_cache)`
   (l1d.sv:3744), and `n_lock_cache` is already used for the existing
   writeback-then-reload sequence (l1d.sv:3661, 3703). So the whole alias fixup is
   atomic w.r.t. every other memory op, reusing a proven mechanism. The store in
   `r_req` survives the sequence exactly as it already survives a reload.
4. **Presence must be explicit, not inferred.** Add a **`mem_req_drop` sideband bit**
   on the L1D→L2 request (`mem_req_pidx` already exists at l1d.sv:216, so the message
   already says *which* presence entry). `MEM_WB` today is ambiguous — issued both
   when the L1D drops a line and when it keeps one — and the L2 guesses. The measured
   trace in `l2.sv` shows the guess being wrong:
   `cyc 3367974 drop pres_d=1 pidx_d=2 op=26` (op 26 = `MEM_WB`) → orphan →
   `cyc 5538738 SINGLE-COPY VIOLATION`.
5. **`INJECT_RELOAD` must clear `mem_req_drop`.** The `n_mem_req_*` fields use HOLD
   semantics (`n_mem_req_opcode = r_mem_req_opcode;` l1d.sv:3241) and the writeback
   and fill **reuse the same registered request**. A held `drop=1` would ride onto
   the MEM_LW fill and clear presence on the very grant that hands the L1D its copy —
   an orphan on every miss-with-eviction, strictly worse than the bug. `n_inhibit_write`
   has the identical lifetime and is already cleared in `INJECT_RELOAD` on the
   writeback's ack — but it is **not** a clean twin to copy: it is set at 8 sites
   spanning both `MEM_SW` (3581, 3657, 3725, 4166) and `MEM_WB` (3524, 4025, 4120)
   plus one inheriting site (3646). `mem_req_drop` must be set **per site by intent**.
   Classifying those 8 sites drop-vs-keep is the first task; getting one wrong
   reintroduces the orphan silently.
6. Gate `t_wr_d0` on dirty in the L2 `MEM_WB` hit path — it currently writes data
   **unconditionally** (`t_d0 = r_store_data; t_wr_d0 = 1'b1;`), so a clean drop
   notification would clobber the L2 line (destroying newer DMA-merged data).

Longer term the same argument indicts the eviction probe: it reads private `snp_*`
shadow arrays on timing independent of the pipeline. Rocket runs the probe through
the *same* metadata pipeline as core requests (`metaArb.io.in(6)` = probe,
`in(7)` = CPU; lowest index wins), with `block_probe_for_ordering` and
`block_probe_for_core_progress` throttling **the probe**, and `s1_nack`/`s2_nack`
back-pressuring the core. Note the direction: Rocket throttles the probe, never the
ack. Every gate tried here throttled the ack, which is exactly what deadlocks.

## An experiment worth running first

The presence fix below is **correct in principle but is not this bug** (both arms
panic within 13k cycles). It is currently **reverted** out of the tree; kept at
`/tmp/l2.sv.presfix.keep`. It removes `w_line_dropped` from the presence write
enables in `l2.sv` (~line 568) so an L2 line drop can't orphan an L1 copy:

```systemverilog
t_wr_l1d_pres  = (w_l1_copy_made & ~r_from_l1i) | t_pres_clr;   /* w_line_dropped removed */
```

It measurably works as designed (`alias_bi` 0 → 528 on IRIX, `pres_clr_d == inline_bi`
exactly), i.e. it turns the alias check back on — it was **structurally disabled**
because `w_alias_d` is gated on `w_l1d_pres`. Caveat: `INITIALIZE` and `FLUSH_WAIT`
were relying on `w_line_dropped` to zero the presence RAM (it has no reset port), so
if it is restored, re-qualify the term by state instead of removing it wholesale.

## Repro

```bash
cd ~/code/henry-gh/sim
G="+define+ENABLE_L2_INCLUSION +define+ENABLE_L2_EVICT_BACKINV"
G="$G +define+LG_L1D_NUM_SETS=11 +define+LG_L1I_NUM_SETS=11 +define+LG_L2_NUM_SETS=14"
G="$G +define+L1D_SINGLE_COPY_CHECK +define+L1D_VA_INDEX +define+ENABLE_L2_PIDX"
G="$G +define+RELOAD_BI_RACE"          # the detector
rm -rf obj_dir && make VFLAGS_EXTRA="$G" -j16

SCSIDBG=0 ./obj_dir/henry_tb \
  --kernel ~/code/chd-dumper/extracted/unix \
  --arcs ~/code/r9999/arcs/henry_arcs.bin \
  --disk ~/code/iris/irix65-clean.img \
  --start-pc 0xbfc00000 --maxcyc 240000000 > /tmp/irix.log 2>&1
```
Panic lands ~40 min in at cyc ~224.82M. Drop `L1D_VA_INDEX`/`ENABLE_L2_PIDX` for the
PA-replay control (clean past 310M).

Linux: same defines, `--kernel ~/code/linux-mips/vmlinux.32`, **`--disk` REQUIRED**
(see traps), `--maxcyc 600000000`.

## TRAPS — these cost real time this session

- **A rising retire count is NOT progress.** After an IRIX panic the machine spins in
  "Press reset to restart the machine." and the retire counter keeps climbing while
  `alias_bi` / `dmaprobe edges,pushes` / `snoop_hits` freeze. A soak was reported
  clean at 267M retired that had actually panicked at 224.8M.
- **Grep IRIX's wording.** `PANIC:` and `Press reset to restart` — Linux's
  `Kernel panic` alone will not trip.
- **IRIX console output interleaves with `[sdma]`/`[rd]`/`[hpc3acc]` prints**, so the
  panic string is shredded across lines. Reconstruct:
  `sed -E 's/\[sdma\][^[]*//g' f | tr -d '\n'`.
- **25M retired proves nothing.** The prior "IRIX clean at 32KB/256KB" baseline was
  25M — ~10x short of the panic. Always run the control to at least the depth of the
  failure you are trying to beat.
- **Linux needs `--disk`** or it parks forever in the WD93 probe
  (`scsi0: Aborting connected command`, repeating `[rd] offs=11000`). A diskless
  Linux soak is worthless. (Any disk image works as a target.)
- **`pkill -f <name>` kills the launching shell** when the same command line mentions
  the binary. Launch long runs from a **script file**.
- **`single_copy_violations=0` is not a pass** — it cannot see a lost write.
- Verify `+define`s actually reached the build (`grep -c <DEFINE> build.log`); the
  harness silently ignores them if `obj_dir` is stale — `rm -rf obj_dir` first.

## Uncommitted state in `~/code/henry-gh/r9999`

`l1d.sv` (+217 lines) and `l2.sv` are dirty, but **only** with `` `ifdef ``-gated
instrumentation: `RELOAD_BI_RACE` (new, described above), plus pre-existing
`SNPCOLL`, `PGWATCH`, `RECWATCH`, `L2DATAFLOW`, `MIDXCHK`, `SLOTCHK`, `WBCHK`,
`DROPDBG`, `L1D_SINGLE_COPY_CHECK`, `L1I_ALIAS_CHECK`. The functional logic matches
pushed `8a6a3d9` (r9999) / `d830995` (henry-gh). Nothing here has been committed —
per repo policy, ask before committing.

## SEPARATE BUG — do not conflate

`main` failing to boot IRIX with
`xfs_iflush: Bad inode NNN magic number` → `Fatal error on root filesystem`
during `Automatically reconfiguring the operating system` is the **XFS/DMA
corruption family**, not this alias bug. See auto-memory
`project_dma_stale_root_cause` (DMA stale reads, 17.5% L1D-resident ⇒ an L2-only
snoop is insufficient), `project_be_corruption_tracking`, and
`project_l2_size_sweep_silicon` (4K/16K/64K/128K clean, only 256K panics). Note that
last one: **256KB L2 is independently implicated** on silicon, so a 256KB-L2 boot
failure may not be the alias path at all. Bisect against the PA-replay control before
assuming.

## NEGATIVE RESULT — kill-on-fill does NOT fix the panic (tried 2026-08-18)

The reload-vs-back-invalidate race above was **implemented and tested**, and it is
**not** the cause of the IRIX panic. Do not re-run this experiment.

Implementation (kept at `/tmp/l1d.sv.killfix.keep`, reverted out of the tree):
`w_kill_reload_now = r_backinv_ack & (r_state == INJECT_RELOAD) &
(r_mem_req_opcode == MEM_LW) & (r_snp_addr[PA-1:4] == r_mem_req_addr[PA-1:4])`,
made sticky in `r_kill_reload`, folded into
`t_valid_value = !r_inhibit_write & ~(r_kill_reload | w_kill_reload_now)` so the
filled line is marked INVALID; `HANDLE_RELOAD` then re-fires, misses, and re-runs the
miss after the L2's eviction completes. Cleared in `INJECT_RELOAD` on `mem_rsp_valid`.

Result: the fix **is** active — the panic cycle moved 224,815,628 → **224,792,410** —
but IRIX still panics `tlbmiss: invalid kptbl entry` at the same point. The 432 race
hits are therefore benign (already covered elsewhere, e.g. the data-carrying ack
merge), and correlate with the panic only because both are frequent on the kptbl page.

**What this rules in/out:** the cause is still inside the VA-index/PIdx path
(PA-replay remains clean past 310M) but it is NOT this window.

### Suggested next bisect (not yet run)
Separate the two defines instead of treating them as one knob:
- `L1D_VA_INDEX` **without** `ENABLE_L2_PIDX`
- `ENABLE_L2_PIDX` **without** `L1D_VA_INDEX`
- `L1D_VA_INDEX` + `ENABLE_L2_PIDX` at `LG_L1D_NUM_SETS=8` (4KB L1 ⇒
  `L1D_ALIAS_BITS = 0`, so VA index == PA index and no synonym can exist). If that
  still panics, the bug is in the VA-index **plumbing**, not in aliasing.

Because the panic reproduces to ~30k cycles out of 225M across four builds, each of
these is a single ~40-minute run with an unambiguous answer.

## THE KEY NARROWING — the bug needs THREE things at once (measured 2026-08-18)

Four arms, IRIX, `--maxcyc 400000000`:

| L1 (alias bits) | L2 | indexing | result |
|---|---|---|---|
| 32KB (3) | 256KB | VA + PIdx | **PANIC @ cyc 224.8M** |
| 32KB (3) | **2MB** | VA + PIdx | clean to 400M (181M retired) |
| **4KB (0)** | 256KB | VA + PIdx | clean to 400M (60M retired) |
| 32KB (3) | 256KB | **PA-replay** | clean past 310M |

Remove **any one** of {real L1 aliasing, small L2 (⇒ frequent evictions), VA
indexing} and the panic disappears. So it is an **interaction between the two
back-invalidate sources** — alias conflicts and evictions — not either alone.
This is the single most useful constraint available for the next attempt.

## SECOND NEGATIVE RESULT — alias-BI-vs-in-flight-BI guard is INERT (do not retry)

Hypothesis: the queued/eviction BI issue (l2.sv ~1676) is guarded
`~w_bq_empty & ~r_backinv_d & ~r_backinv_i & ~r_wb_pend`, while the alias BI issue
(l2.sv ~1945, `if(w_alias_conflict & ~r_bi_done)`) has **no such guard** and would
clobber an in-flight probe's `n_backinv_addr` / `n_backinv_pidx_*` / `n_backinv_ev`.

Implemented (spin in `WAIT_FOR_RAM` instead of clobbering; falling through to the
`w_hit` arm is NOT valid — that grants a second copy with no back-invalidate).

Result: **panic at cycle 224815238 — bit-identical to the prior build.** The guard
never fired: issuing a back-invalidate moves the FSM to `BACKINV_WAIT`, so the main
FSM cannot be in `CHECK_VALID_AND_TAG` while `r_backinv_d`/`r_backinv_i` is set. The
asymmetry between the two issue sites is real but **unreachable**. Reverted.

(Identical-to-the-digit results are the standard tell for an inert change — check for
that before interpreting any "no improvement" result as evidence about the theory.)

## Where the next attempt should look

Given the three-way condition, the interaction is most likely in state/flags **shared**
between the alias and eviction probe paths but with different meanings, rather than in
the issue arbitration (now ruled out). Candidates, in order:
- `r_bi_done` — gates alias re-entry (`w_alias_conflict & ~r_bi_done`); check whether an
  eviction probe's completion can set/clear it and thereby suppress a *later* alias probe.
- `n_backinv_ev` — alias forces `ev=0`, eviction sets `ev=1`; it drives writeback-credit
  accounting (`r_wb_credits`, `n_wb_credit_held`) and the `backinv_d_dirty & r_backinv_ev`
  arms at l2.sv 1105/1126/2428/3099. An alias probe returning dirty data with `ev=0`
  takes a different recovery path than an eviction probe with the same data.
- The presence/PIdx RAM write ports: `w_bi_pres_clr` (best-effort, yields to
  `t_wr_l1d_pres`/`w_snoop_wr_gnt`) versus `t_pres_clr` in `BACKINV_WAIT`. A dropped
  clear from one source with the other in flight leaves a stale PIdx, and
  `w_alias_d` compares `w_l1d_pidx != r_req_pidx`.
Instrument the *pairing* (which probe type serviced which line, and in what order)
rather than adding another gate.

## THIRD result — shared `r_bi_done` hypothesis, and a VACUOUS probe (read this before instrumenting)

Hypothesis: `r_bi_done` is shared by both probe types — the alias path gates on it
(`w_alias_conflict & ~r_bi_done`, l2.sv:1945) and the eviction path gates on it too
(`w_valid & (w_l1d_pres|w_l1i_pres) & ~r_bi_done`, l2.sv:2108) — and it is cleared
only on leaving `CHECK_VALID_AND_TAG` to a non-`BACKINV_WAIT` state (l2.sv:2178).
So a request needing BOTH probes would have the second silently skipped.

Counters `skip_alias` / `skip_evict` (gated on the existing
`w_restart_seen = (r_state == CHECK_VALID_AND_TAG) & r_bi_done`) read **0 through the
whole run, including the panic**.

**Do not read that as a refutation — the probe was VACUOUS.** `BACKINV_WAIT` asserts
`t_pres_clr` on completion, so on the return visit to `CHECK_VALID_AND_TAG`
`w_l1d_pres`/`w_l1i_pres` are already 0 and `w_alias_conflict` is already 0. Both
counters were structurally incapable of firing regardless of whether the bug exists.
A valid version needs a positive control (count `w_restart_seen` alone) and must
sample the condition BEFORE the presence clear.

Structurally the hypothesis is probably wrong anyway: both checks act on the line at
`t_idx` — the SAME line — so once either probe clears presence there, the other is
genuinely unnecessary. `r_bi_done` doing double duty is defensible.

## Running score — three mechanisms ruled out, one strong constraint left

| # | hypothesis | verdict |
|---|---|---|
| 1 | reload vs back-invalidate race (kill-on-fill) | implemented, ACTIVE (panic moved 224,815,628→224,792,410), did NOT fix |
| 2 | alias BI clobbers in-flight eviction BI | INERT — unreachable (issuing a BI moves the FSM to BACKINV_WAIT) |
| 3 | shared `r_bi_done` skips the second probe | untested — probe vacuous; structurally unlikely |

The durable result is the **four-arm bisect** above: the bug requires aliasing AND a
small L2 AND VA indexing, simultaneously. Next attempt should start from that
constraint and instrument the PAIRING of probe types per line (with a positive
control), not add another gate.

## FINAL AND MOST IMPORTANT RESULT — the goal is blocked by TWO INDEPENDENT bugs

Running BOTH OSes at the goal geometry with **PA-replay** (aliasing removed entirely)
does NOT make them pass. It only removes ONE of two failures:

| OS | indexing | failure | cycle |
|---|---|---|---|
| IRIX | VA + PIdx | `PANIC: tlbmiss: invalid kptbl entry` | 224.8M |
| IRIX | **PA-replay** | `PANIC: holding vnode on free list 88ac3240(4000000,0)` | **411.7M** |
| Linux | VA + PIdx | `Attempted to kill init! exitcode=0xb` | 564.8M |
| Linux | **PA-replay** | `Attempted to kill init! exitcode=0xb` | **574.8M** |

Read the rows in pairs:

1. **The alias bug is real and VA-index-specific.** IRIX's kptbl panic at 224.8M
   appears ONLY with VA-index+PIdx; PA-replay clears it and gets ~2x further
   (61M retired vs 18.7M, `dmaprobe pushes` 160187 vs 16704 — i.e. deep into
   `Automatically reconfiguring the operating system`). Narrowed to the three-way
   condition above; still unfixed.
2. **A SECOND, pre-existing bug blocks the goal regardless of indexing.** Linux dies
   at essentially the same point (564.8M vs 574.8M) in BOTH configs, and IRIX's
   PA-replay run dies on a corrupt vnode free list. Neither is aliasing.

**Therefore: no amount of alias/PIdx work can make this goal pass.** Even with the
synonym machinery entirely removed, both OSes still fail at 32KB/256KB. The second
family must be fixed first, and it is almost certainly the `be` corruption already
under investigation — see auto-memory `project_be_corruption_tracking`,
`project_irix_o32_userspace_crash` ("a long-lived-reg corruption randgen misses"),
`project_dma_stale_root_cause`, and `project_l2_size_sweep_silicon` (**on silicon
4K/16K/64K/128K L2 are clean and only 256K panics** — the goal geometry has a 256KB
L2, so that sweep is directly relevant here).

This also explains `main` failing to boot IRIX with
`xfs_iflush: Bad inode ... magic number` during reconfigure: same family, same phase
of boot, unrelated to the cache work in this document.

### Recommended order of work
1. Fix the `be`/corruption family first (it blocks the goal on its own, and blocks
   `main` today). Use PA-replay at 32KB/256KB as the vehicle — it reaches the failure
   in ~410M cycles with the alias variable removed, which is a cleaner repro than any
   VA-index build.
2. Only then return to the alias bug, starting from the three-way constraint and the
   three ruled-out mechanisms above.

## DECISION (2026-08-18): SHELVE this L2 design — do not keep patching it

dsheffie's call, and the evidence supports it. The structural problems are not a
sequence of independent bugs; they are one overloaded state machine:

- **One FSM owns everything**: fills, writebacks, uncached, the flush walk, CACHE
  ops, alias probes, eviction probes, DMA snoops and merges all run through
  `CHECK_VALID_AND_TAG`/`BACKINV_WAIT`.
- **`BACKINV_WAIT` services ONLY acks**, so it cannot serve the fill the L1D is
  waiting on. That is a structural deadlock, not a tuning problem — five separate
  gating variants were tried and every one either deadlocked or leaked.
- **Presence has three writers with contradictory rules**: `w_line_dropped`,
  `t_pres_clr`, and a best-effort `w_bi_pres_clr` that yields to the other two. The
  design's own comments document the resulting orphan, and `w_alias_d` is gated on
  presence — so a dropped bit silently DISABLES the alias check.
- **`r_bi_done` is shared** by the alias and eviction probe paths.
- **The two probe issue sites are asymmetric**: the queued path is guarded
  `~r_backinv_d & ~r_backinv_i`, the alias path is not.
- **The snoop takes the metadata write port only when the main FSM writes nothing**,
  so probe timing is coupled to unrelated traffic.
- Four ordering bugs in this hunt alone came from `always_comb` statement order
  inside that one block (see auto-memory `project_l2_backinv_ack_collision`,
  `project_l2_backinv_wb_clobber`).

Correctness here depends on reasoning about all of those at once, which is why three
well-founded fixes in a row missed. Restart from the agreed structure instead:
queue-based L1D/L2 with separate state machines (dsheffie's proposal), alias handling
inverted push -> pull (L2 replies "you have an alias", L1D fixes itself on port 1
under `r_lock_cache` and retries), an explicit `mem_req_drop` sideband, and the
eviction probe run through the same pipeline as core requests rather than off private
shadow arrays. All of that is specified earlier in this document.

**Independently: the second bug family (IRIX vnode @411.7M, Linux init SIGSEGV
@~575M) blocks the 32K/256K goal even with aliasing removed entirely, and blocks
`main` today. Fix that first — it does not depend on any of the above.**
