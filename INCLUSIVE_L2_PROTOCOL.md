# Inclusive L2 with back-invalidate probes: protocol spec (inclusive-l2-v2)

This is the RTL-facing summary of what the Murphi models established.
- **Model:** `~/code/murphi/r9999_incl.m`, generated from `r9999_main.m` (the model of main `3b78e9b`) by `gen/make_incl.py` with `gen/{rsp_inline,tagonly,presence,dmasnoop}.py`. Edit the generators, not the `.m`.
- **Runners:** `run_main.sh`, `run_incl.sh`, `run_snp.sh` (`BIG=1 MEM=<MB>` for hash compaction).
- **Rumur** (`apt install rumur`) reads the same files: 3x faster, no compaction.

## Where inclusion breaks today (main)

The L1D, L1I and L2 are direct-mapped with 16 B lines, PA-indexed, and the L2 has more sets. So two lines that share an L2 set always share an L1 set. **The L1D can therefore never break inclusion against itself**: by the time the L2 evicts a line, the L1D has already evicted it as its own victim.

Inclusion breaks only across caches:
1. **An L1I miss evicts an L2 line the L1D holds, or the reverse.** The L1D copy may be dirty.
2. **The uncached-access purge** (l2.sv:587) drops an L2 line the L1I still holds. The L1D drops its own alias first.

Every other L2 drop is either preceded by the L1D dropping its own copy (CACHE ops, XPG) or is the flush walk.

## The message

**Probe(line):** "invalidate this line; if you hold it dirty, return the data." L2 to L1.
- The L1I only invalidates and acks.
- The L1D acks with `{dirty, data}`.

## Rules (each one has a negative control that fails without it)

| # | Rule | What breaks without it (knob) |
|---|---|---|
| R1 | Before the L2 drops or evicts a VALID line (miss victim, MEM_INVL/MEM_WB/MEM_PGDROP hit, uncached purge, flush walk, DMA snoop), it probes the L1s that may hold it and waits for every ack, merging returned dirty data into its copy, which becomes dirty. | `INCL=0`: inclusion violated |
| R2 | **An L1 answers a probe regardless of its own state machine**, including while it waits on the L2 for its own request. | `BUG_PROBE_BLOCKED`: deadlock (the August blocking-handshake bug) |
| R3 | **A probe must not overtake a fill response to the same L1.** Today the fill installs in the response cycle and the L2 accepts nothing new until then, so this holds by construction. If the response path is ever pipelined, probes must travel behind responses on the same ordered channel, or the L1 must drain responses before handling a probe. | `RSP_DECOUPLED=1, PROBE_ORDERED=0`: inclusion violated (the August reload-vs-backinval race, here in its L1I form) |
| R4 | Requests from the two L1s are latched separately (the existing arbiter); the L2 serves one at a time. A latched L1D victim `MEM_SW` can coexist with a probe for that same line, and that is safe because the L1D keeps the line VD until the SW ack (l1d.sv inhibit-write), so the probe still finds the dirty data. | (structural) |

## Presence bits (PRES=1)

Each L2 line gets two bits: `pd` and `pi`, meaning "the L1D / L1I may hold this line". The L2 probes only an L1 whose bit is set, and none at all if neither is.

- **Set** when the L2 answers that L1's fill.
- **Clear** when:
  - the L1D's victim `MEM_SW` completes;
  - its CACHE-op `MEM_WB` / `MEM_INVL` completes;
  - an uncached alias is dropped;
  - any L2 drop, replace, or probe completes.
- **Silent clean L1 evictions leave the bit set.** The bits are conservative: they may be stale-set, never stale-clear.
- **Invariant:** a valid L1 line has its presence bit set. This is stronger than inclusion.
- **Negative control:** `BUG_PRES_NOSET_I` (the L1I fill forgets to set `pi`) fails immediately.

## DMA coherence by L2 snoop (DMA_SNOOP=1)

This replaces the silicon ARM page flush. Today the flush makes the core run injected `XPG_*` page walks on the L1D, which serializes the core. With snoop, the ARM queues L2 snoop operations and the inclusive L2 reaches the L1s with its own probes, so the **core never stops**.

| # | Rule | What breaks without it (knob) |
|---|---|---|
| D1 | **Pre-snoop** `SNP_WBINV` before the device transfer: probe, write back dirty, drop. | `BUG_SNOOP_NO_PRE`: the post-drop finds dirty data, and a stale copy is evicted over the device data |
| D2 | **Post-drop** `SNP_DROP` after a DMA-in: probe, then drop WITHOUT writeback. This catches speculative refills inside the window. **Completion is signalled only after it finishes.** | `BUG_SNOOP_EARLY_DONE`: stale load |
| D3 | **Absorb in-transit writebacks.** Before a snoop completes, an L1D `MEM_WB`/`MEM_SW` to the same line that is latched in the arbiter must be applied (data into the L2 copy or DRAM, request acked and retired). Example: a CHWB issued after the probe left. The L1D invalidated at issue, so its probe ack says "not here", while its dirty data still sits in the request latch. | `BUG_SNOOP_NO_ABSORB`: the device reads stale data on DMA-out. On DMA-in, the late writeback would land after the device write and clobber it. |
| D4 | The I/O is started by the driver's device-register write, which is ordered after the core's earlier stores (wbflush / SYNC; uncached ops issue in order at the ROB head). The snoops themselves run while the core keeps running. | (model: DMA start requires no CPU store in flight) |
| D5 | A snoop takes the L2 in IDLE ahead of L1 requests (like today's `snoop_req_valid`, l2.sv:533). | |
| -- | An L2-only snoop **requires inclusion.** | `DMA_SNOOP` with `INCL=0`: stale data |

D3 is the general hazard. Dirty data can be **in transit** in the L1-to-L2 request path when a probe arrives, so "not here" from the L1 is not proof that no newer data exists. For plain L2 evictions this is benign: the latched writeback eventually lands, and DRAM converges. It is fatal whenever a third party (the DMA device) reads or writes DRAM between the probe and that landing.

## Proof status (no error found, exhaustive)

| Config | Versions | States | Notes |
|---|---|---|---|
| data side, inclusion | 2 | 14.2M | |
| data + DMA (XPG), inclusion | 2 | 569M | |
| data + L1I (tag-only), inclusion | 2 | 447M | |
| full (L1I + DMA + spec fill), inclusion | **1** | 549M | Versions=1 is blind to two-write bugs (`BUG_NEEDWB_DIRTY` passes there); the version-2 pair runs cover that class. Full at 2 versions is over 3.6B states. |
| data + DMA (XPG), inclusion + presence | 2 | 299.5M | |
| data + L1I, inclusion + presence | 2 | running | |
| full, inclusion + presence | 1 | queued | |
| data + DMA **snoop**, inclusion + presence | 2 | **938M** | all snoop negative controls fail as required |

`L1I_TAGONLY` keeps the L1I's line, fill and probe behaviour but drops its data and the fetch-coherence ghosts. Fetch coherence is proven separately, on main.

## Open, for RTL

- **Probe and ack wiring.** A probe channel to each L1 and an ack channel back. The L1D ack carries 128 bits of data plus a dirty bit. Acks must not go through the request arbiter (R2).
- **Presence bits.** Two bits per L2 line, in the tag RAM.
- **L1I.** An external single-line invalidate port. Today it only has a whole-cache flush. The 2-wide-fetch rework (`FE_FIXES.md`) is parked and orthogonal.
- **L1D.** A probe handler that is independent of its FSM. Where does it read tags while the FSM is mid-miss? The L1D currently has one tag-RAM read port plus port 2.
- **D3 in RTL.** The L2 must compare the snoop address against the arbiter's latched L1D request (address and opcode) and absorb it.
- **ARM side.** A snoop queue with pre/post ops per page, and completion signalled to the driver.

## Next: VA-indexed L1D with L2 alias tracking (dsheffie 2026-10-02: presence bits always on; DMA later)

**Model:** `~/code/murphi/r9999_va.m` (runner `run_va.sh`).
- The L1D has one line per VA colour.
- The L2 line holds `pd` plus `pidx`, the colour where the L1D holds it.
- There is AT MOST ONE L1D copy per PA.

**Pull** (`ALIAS_PULL=1`): a request from the L1D whose colour conflicts with `pidx` gets the reply "alias at pidx", and the L2 changes no state. The L1D then evicts its own copy (MEM_SW if dirty, else an ADROP notice) and retries.

Negative controls, each of which fails:
- no alias check: two copies;
- the alias eviction drops dirty data: stale load;
- the fill does not record the colour: colour invariant;
- push mode with a blocking ack: deadlock.

### Today (main), l1d.sv:237-252

The tag includes PA[13:12]. Port 2 reads at the VA index, so a colour-mismatched access tag-misses and **replays through the miss queue with the PA**. The line always lives at its PA index, so no synonyms can form. The cost is one replay per mismatched access, even on a hit: 15.5% of CoreMark cycles (COREMARK_STUDY.md).

### Staged RTL plan

| Stage | What | Behaviour change | Check |
|---|---|---|---|
| A | The L2 tag RAM gains `pd`, `pidx[1:0]`. The L1D's L2 requests carry the line's colour (today = PA colour). The L2 maintains pd/pidx: set on an L1D fill; clear on the L1D victim MEM_SW, MEM_WB, MEM_INVL, uncached alias drop, and any L2 drop/replace. | none | Cycle-identical to main. A VERILATOR shadow check asserts the presence invariant (every valid L1D line has pd and pidx = its index colour) every cycle. |
| B | L2 to L1D probe on an L2 drop/evict of a `pd` line: probe(PA, pidx) and ack{dirty, data}. The L1D answers independently of its FSM (R2). Today this only fires on L1I-miss-induced evictions and the flush walk. | rare | randgen / directed tests with an L1I-thrash pattern; the VERILATOR inclusion check (L1D ⊆ L2) |
| C1 | Writeback/invalidate PA reconstruction takes the alias bits from the TAG, not `r_cache_idx`: all 8 `{r_tag_out[...:LG_ALIAS_BITS], r_cache_idx, ...}` sites become `w_line_pa = {r_tag_out, r_cache_idx[IDX_IN_PG-1:0], 0}`. | none | cycle-identical to stage B (directed cache tests + go XPG checkpoints) |
| C2 | **C2a** (cycle-identical): the line's L1D set travels with the request (`r_req_idx`, `r_mem_req_idx`, `r_sb_idx`, MQ `r_mq_addr`) instead of being re-derived from the PA. **C2b**: lines live at the **VA** set; every L1D->L2 request carries its colour (`mem_req_colour`), which the L2 records as `pidx`; probes index the L1D at `{probe_colour, PA in-page bits}`; MQ conflict checks compare in-page bits only (a synonym sits in another set). **Probe rules (push, R10000 precedent):** (1) before evicting ANY `pd` line, whoever caused the eviction (L1I miss, or an L1D miss at any colour -- with VA indexing the victim can sit in another set), probe at `pidx`; dirty data is the victim writeback. (2) an L1D LW/INVL/PGDROP that hits a `pd` line whose `pidx` differs from the request colour probes `pidx` first; a dirty copy is served and kept dirty (LW), written to DRAM (INVL), or reported (PGDROP). WB/SW carry the L1D's own copy (colour == pidx). Knobs: `L1D_PA_INDEX` (old PA indexing, same source), `C2_NO_ALIAS_PROBE` (sim-only negative control). | the perf change: CoreMark 2.56 -> 2.86 CM/MHz (memlat 37, ROB16) | `test_l1_synonym.S` (retargeted to 16KB, both directions, stores drained): C1 P / no-alias F / C2b P; `test_l1i_probe` 512/512/512; CoreMark ckpt -c1 8M insns 0 divergences; 16 Linux ckpts x {16K/32K/128K, 64K/64K/2M}: 0 inclusion misses, 0 duplicates; mmap alias test (20 aliases, 502K checks) PASS at both sizes. Bugs found on the way: rule 1 originally excluded L1D-miss evictions (72 lines missing on go); a stale `r_probe_dirty` after an eviction writeback made the reload serve the victim's data (L1I fetched data as code). |
| C3 | 64 KB L1D with 4 KB pages (`pidx` widens automatically). | IRIX can use the big L1 | henry build, silicon CINT95 |

The L1I stays as it is (read-only; duplicate copies are harmless). Its inclusion (`pi`) is not needed for alias tracking and can follow later.

Lesson from August: the push back-invalidate died on a fill-vs-backinval race. Pull keeps every alias eviction inside the L1D's own single-threaded miss FSM, so the old copy is gone before the new fill is even requested.

**Decision 2026-10-08: push, not pull** (supersedes the pull wording above). The R10000 did exactly this in hardware (User's Manual §5.5, "SCTag(3:2), PIdx"; Errata, "Virtual Coherency Exception"). Each L2 tag holds `PIdx` = VA[13:12]. On a mismatch, the on-chip secondary-cache controller ("external interface", a separate requester with priority for its "refill and interrogate" operations on the L1D arrays, §1) purges the old-index L1 line and rewrites `PIdx`, costing 6 cycles beyond the refill. Our stage B probe is that interrogate path, so push reuses validated hardware. August's race came from a blocking handshake on a shared path; the dedicated ack channel (below) removes it, and Murphi proves push (`r9999_va.m`, 436M states). The R10000 gives its interrogate priority over L1D traffic. Ours waits for the L1D pipes to drain (`PROBE_CHK`); priority is a later performance refinement.

## Channel decision (dsheffie 2026-10-02): separate reply channel, no NACK, no virtual channels

**Why the ack needs its own channel.** The L2 cannot make progress until the probed L1 replies. Meanwhile the L1->L2 request queue (the one-entry arbiter latch per L1) can be full with a request the L2 will not accept until the transaction finishes. If the reply had to use that queue, the L1D could never hand back a dirty line: the data would be stranded and the system would deadlock.

**Message classes:**

| message | path | always sinkable because |
|---|---|---|
| probe (L2->L1) | separate today; may share the L2->L1 response path later | the L1 sinks all responses unconditionally, and holds the one outstanding probe in a 1-entry register |
| ack (L1->L2) {dirty, data, wb-in-flight} | **dedicated sideband** | the L2 is sitting in its wait state for it |
| DMA request (ARM->L2) | own input port | (may block; nothing the L2 waits on depends on it) |
| DMA completion (L2->ARM) | sideband | the ARM always sinks it |

There are no cycles in the wait-for graph.

**Writeback in flight (D3, generalised).** If the L1D's latched request is a writeback of the probed line, its ack says so. The L2 then consumes that one latched entry as part of the transaction before completing.

**Invariant:** the L1->L2 queue stays one entry deep. If it ever grows, the ack must carry the in-flight writeback's data and the L2 must drop the later duplicate.

**Rejected: NACK-based** (SGI Origin style). It removes the sideband, but every L1D wait state would need retry, and it brings forward-progress/starvation machinery. Origin still needed a reply network.

## Refinement, deferred (dsheffie: "do the simple thing first"): clean-eviction notices

The L1->L2 sideband can also carry clean-eviction notices, which would make the presence bits exact. 29% of Linux probes found nothing: their pd bits were stale. Two rules apply:
1. **Notices are droppable hints.** Send one only when the L2 can take it; otherwise drop it, so it never blocks the ack.
2. **Ordering.** A notice for X must take effect before any later request from that L1 for X, or a late notice stale-CLEARs pd. Either the L2 drains a 1-entry notice buffer before accepting the next request, or the miss request carries the clean victim's tag.

Model knob to add when this is picked up: EVICT_NOTICE. Its negative control is a notice applied after a later fill of the same line.
