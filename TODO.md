# r9999 — work queue

Ordered by measured evidence, not by intuition. Each item states what it is worth and
how that was established, so a future session can re-derive or refute it rather than
inherit an opinion. Measurements are ooo_core / henry_tb unless marked SILICON.

Baseline as of 2026-08-12 (main @ `9789594`): dhrystone **160.324 VAX MIPS @ 100 MHz**
(SILICON, `cc -Ofast -mips3`) = 1.7–2.0x an R4400 per clock, ~70% of an R10000 at half
the width. `dhry_henry.elf`: IPC 1.296, 280 cyc/iter (SILICON, bit `b5337d98`).

---

## 1. Memory system

### 1.1 Miss-queue depth > 1  — THE lever
r9999 allows exactly **one** outstanding fill. Fill matching is by FSM state
(`w_cacheable_mem_rsp_valid = (r_state == INJECT_RELOAD) & ...`), which structurally
forbids a second: there is no way to tell which response arrived. `r_n_inflight` is a
counter, not a bitmap.

**Evidence that this is the whole gap.** A dependent pointer chase (`pchase`) removes
all concurrency and measures pure load-to-use:

| working set | r9999 | rv64core |
|---|---|---|
| DRAM-resident | **46.002 cyc** | **46.001 cyc** |

Per-miss latency is *identical*. Yet membw throughput differs 2.7x (read) to 7.9x
(write). **The entire bandwidth gap is queue depth, not miss efficiency.**

Projection from the membw fit (`read cyc/acc = 9.90 + 0.750*lat`), read MB/s @ lat=30:
`N=1: 24.7 · N=2: 37.8 · N=4: 51.5 · N=8: 62.9` (rv64core measures 67.4).

**Port note:** rv64core's `nu_l1d` did NOT convert its blocking path to tagged
responses — it reserved one tag encoding for it
(`mem_rsp_tag == (1 << LG_MRQ_ENTRIES)` = "the FSM's own reload", tags 0..N-1 =
speculative). So this is ADDITIVE, not a rewrite of the existing path.

**Blocker:** speculative fills bring in lines the core has not committed to, which
reopens the DMA-coherence question. See §3 — the coherence domain must cover in-flight
state first.

### 1.2 ENABLE_L1D_SKID (3 → 2 cycle load-to-use)
Commented out at `machine.vh:41`. pchase L1D-hit latency: r9999 **3.022** vs rv64core
**2.014** — exactly the missing cycle, on *every* L1D hit.
Previously measured as ZERO gain on dhrystone (which has enough ILP to hide it) and
shelved; that conclusion is workload-specific and does not hold for dependent chains.
**Caveat:** skid-OFF is reportedly implicated in a henny-Linux timer-ISR livelock
(`project_density_knob_latent_bugs`) — reconcile before flipping.

### 1.3 L2 hit latency: 12 vs 9 cycles
pchase L2-resident: r9999 12.002, rv64core 9.008. Three cycles unexplained; worth one
look at the L2 lookup path before assuming it is inherent.

### 1.4 Larger L2 lines
Both caches are 16B. R4000 secondary lines are 4/8/16/32 words (up to 128B). Line size
divides the transaction count directly, so this helps even a fully blocking machine —
the only item here that does not depend on §1.1.
**Blocker for the L1 side:** 32B primary lines need an L1I fetch-group rewrite (fetch
is hardwired to 4 words/line). The L2 side has no such constraint.

### 1.5 No-write-allocate / write-combining on full-line stores
A streaming store fetches the line it is about to overwrite entirely: ~25% of triad's
memory traffic is a discarded write-allocate read. Helps in the bandwidth-bound regime
where there is no idle window to hide anything (dsheffie: "when you have to evict every
load, there's not going to be a window to hide a writeback").

### 1.6 NOT worth doing on current evidence
- **Eviction buffer / fill-before-writeback reordering.** With one outstanding request,
  reordering two serialized round trips changes nothing; the R4000's win comes from the
  victim draining *concurrently*, which needs §1.1 first. rv64core's `CLEAR_DIRTY` is
  only 1.9% of cycles.
- **FSM-hop cleanup in the miss path.** pchase shows per-miss latency already matches
  rv64core.

---

## 2. Front end

### 2.1 Fetch group cannot span a branch + delay slot
`l1d`/`l1i` multi-push is gated `if(!(t_is_cflow || r_delay_slot))`. The `r_delay_slot`
term is REQUIRED (the instructions after a delay slot are not what executes next); the
`t_is_cflow` term is redundant (a taken branch already forces `t_first_branch == 0`).
So this is not "delete a condition" — it is "extend the group to *include* the taken
branch's delay slot", which rv64core has no analogue for since it has no delay slots.
Bounded by how often the branch is not in the last slot of a line.

### 2.2 Branch-likely trains the PHT
R10000 spec (manual, quoted): *"Branch Likely instructions are always predicted as
taken"* and *"the branch predictor is neither used nor updated by branch-likely
instructions"*. r9999 satisfies the first (`pd == 4'd2` always ends the group) but NOT
the second — `t_do_pht_wr = r_pht_update` has no branch-type gate, so every `beql`
retire trains a counter shared with ordinary `beq`s.
`r_pd` exists, is registered, and is never read — an abandoned attempt at this gate,
and it captures the *fetched* op's pd, not the retiring one, so it cannot be used as-is.
**Priority depends on:** whether the IRIX kernel contains branch-likely. MIPSpro
`-Ofast` emits **zero** (verified: `dis | egrep -c 'beql|bnel|...'` = 0), so
user binaries are clean; `dis /unix | egrep -c ...` would settle the kernel.

---

## 3. Coherence (branch `inclusive-l2`)

### 3.1 DMA completion is not ordered against snoop delivery
`scsi_dma_done = w_eng_done` and `r_dma_done` (dma_memcpy) reflect engine state only;
the snoop FIFO drains independently. An engine can report DONE with invalidates still
queued — the CPU polls DONE, reads the buffer, gets stale data. **Real on silicon**:
IRIX's SCSI driver polls completion then reads. Leading candidate for the XFS
corruption seen on the 16KB-L1 bit.
Caught by `tests/dma/dma_coherence.S` going P→F after rebasing onto the BPU work — the
faster core simply started winning a race it used to lose. Pre/post A/B confirms it is
not a mis-merge.
**TRAP:** the micro drives `dma_memcpy`; IRIX drives the separate `scsi_dma` engine.
Fixing one leaves the other broken.

### 3.2 Partition the L2 FSM
One monolithic FSM serializes CPU requests, snoops, flushes and back-invalidates. That
is why the snoop cannot block, why the back-invalidate had to go fire-and-forget, and
why "coherence complete" cannot be expressed at all. Split into CPU-request /
coherence / flush-walk engines. Main cost is arbitration over the single-ported arrays
(tag/data/valid/dirty/2x presence all share `t_idx`); the L1D's option-B duplication is
the precedent.
Suggested order: flush walker out first (no ordering semantics), then the coherence
engine still fire-and-forget, then a blocking snoop with completion-ack.

### 3.3 The coherence domain must cover in-flight state
Any structure that holds a line OUTSIDE the tag array must be snoop-visible. nu_l1d has
four such (eviction buffer, tagged fill FIFO, miss queue, speculative fills) and **none
are probe-visible** — correct for rv64core, which has no external prober, wrong for
r9999's SoC. This is ONE piece of work that amortises across every structure in §1;
doing it per-structure would rebuild the out-of-band dirty-writeback corruption the
earlier bisect already proved.

### 3.4 `l2.sv` does not build without ENABLE_L2_INCLUSION
14 errors. Fixed in the working tree of the branch (nest the `[incl]` counters under
both defines; move `r_backinv_ev`/`r_wb_pend`/`r_wb_addr`/`r_wb_data`/`r_n_wb`
declarations out, since the main always_ff uses them unconditionally). Verified clean
at all three define combinations. **Uncommitted.**

---

## 4. Tooling and traps

- **`make` does not reliably relink `ooo_core`.** `make ooo_core` regenerates `obj_dir`
  and stops; a stale binary then silently reports old results. Cost real time twice in
  one day. Check the binary's mtime, not make's exit code.
- **No `+define+` passthrough in the Makefile.** Geometry and profile knobs require
  editing `machine.vh`, which is easy to leave enabled by accident.
- **`pipeline_record` lacks the effective address.** Blocks any address-based analysis
  (line pairing, merge behaviour). rv64core's record additionally carries
  `sched_cycle`, `p1_hit/miss_cycle`, `l1d_replay` and an `l1d_blocks` list — r9999's
  has none of these and they were the most useful fields in the whole exercise.
- **`L1D_STATE_PROFILE` mis-attributes writeback vs fill.** It discriminates on
  `r_reload_issue`, which means "a fill is owed", so a dirty miss's writeback wait is
  counted as fill wait. Use the outstanding request's opcode (`MEM_SW` vs `MEM_LW`).
  The profiler itself is **uncommitted** in `l1d.sv`.
- **Micros not yet in the repo:** `triad-henry`, `membw-{mips,shared}`, `pchase-mips`
  (and rv64 twins under `~/rv64-standalone-apps/`), plus `plog_dump`. They currently
  live outside version control, which is exactly the provenance problem that cost a day.

---

## 5. Measurement discipline (learned the hard way, 2026-08-11/12)

- **Confirm the counter was sampled AFTER the event.** A periodic readout whose last
  sample precedes the event reports zeros that look like "the mechanism never ran".
- **Confirm the knob took.** `+define+LG_L1D_NUM_SETS=8` is silently IGNORED on trees
  before `93a6ff7` (no `ifndef` guards). Identical-to-the-digit results across a
  supposed A/B are a RED FLAG, not a clean negative.
- **Measure a representative window.** `--maxicnt 400000` on a payload whose loop is
  18M instructions measured mostly boot; MPKI read 1.24 instead of the true 0.031.
- **md5 the bitstream before believing any silicon number.** An unidentified bit
  (`7c2c3e9d`, built with `ENABLE_L1_TINY` + `ENABLE_L2_NOCACHE` active) ran 3.6x slow
  and cost hours.
- **Dhrystone's cache sensitivity is a layout lottery.** `Proc_1` and `strcmp` landing
  0x2000 apart produced 4968 conflict misses from six cache lines and a 9% swing that
  a 256-byte link pad removed entirely. Conclusions about cache structure drawn from
  one binary do not transfer.
