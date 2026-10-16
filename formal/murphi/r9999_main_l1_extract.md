# r9999 L1D / L1I / L1->L2 arbiter -- RTL-anchored protocol extract (for a Murphi model)

Source: `/home/dsheffie/code/r9999-incl` @ `3b78e9b` (branch `inclusive-l2-v2`). All anchors are `file:line` in that tree.
Read-only extraction. "UNSURE" marks places where I am inferring rather than reading a definite fact.

## 0. Geometry and default knobs

| Item | Value | Anchor |
|---|---|---|
| L1D | 16KB direct-mapped, 1024 sets x 16B lines | machine.vh:171, 186 |
| L1I | 16KB direct-mapped, 1024 sets x 16B | machine.vh:195; l1i.sv:142-158 |
| L2 | 128KB direct-mapped, 16B lines (LG_L2_NUM_SETS=13), serial FSM | machine.vh:221; l2.sv:157-174 |
| PA width | 36 | machine.vh:233 |
| L1D tag | PA[35:12] (TAG_LSB = min(IDX_STOP=14, LG_PG_SZ=12) = 12), so the tag also carries the 2 index/alias bits PA[13:12] (LG_ALIAS_BITS=2). Index = PA[13:4] (VA[13:4] on the port-2 speculative read). | l1d.sv:245-253 |
| MQ ("miss queue" = request replay FIFO) | 8 entries (LG_MRQ_ENTRIES=3) | machine.vh:141; l1d.sv:282, 499 |
| LSU / store-buffer slots | 8 (LG_MEM_SCHED_ENTRIES=3) | machine.vh:134; l1d.sv:944-950 |

`ifdef knobs touched by l1d/l1i/l2, default state:

| Knob | Default | Effect | Anchor |
|---|---|---|---|
| `REG_L1D_RSP` | **ON** | core response is registered (r_core_mem_rsp*) | machine.vh:81; l1d.sv:598-613 |
| `LLSC_BREAK_ON_LOAD` | off | link broken only by a store to the linked line | machine.vh:42; l1d.sv:746-755 |
| `ENABLE_L1D_SKID`, `ENABLE_L2_TINY`, `ENABLE_L2_NOCACHE`, `TINY_DEBUG_L2`, `BIG_SIM_L2` | off | -- | machine.vh:54, 205-221 |
| l1d-local: `ENABLE_KERNEL_LOAD_FENCE`, `ENABLE_MEM_HEAD_SERIALIZE`, `L1D_PORT2_ALWAYS_MISS`, `L1D_ONE_MEMOP`, `FORCE_UNCACHED`, `FORMAL_DPRELOAD`, `SPEC_FILL_CHK`, `ENABLE_STORE_CHECK`, `CHOP_DEBUG`, `VERBOSE_L1D`, `L1D_STATE_PROFILE` | all off | diagnostics | l1d.sv:6,12,441,920,2330,2344,2359 |
| `l2_nocache` | runtime input (driver-set), not a define | l2.sv:67-74 |

`ifdef VERILATOR content in l1d.sv is assertions/$display only (COLORSHADOW 1105-1173, UCSPEC 1270-1282, collide checks 1248-1268, $stop in flush entry 3197-3210, push/pop checks 3614-3627). One NON-guarded sim-only side effect: `$display` for uncached SWR/SWL (2973-2992) -- harmless. The deferred fill response `r_fill_rsp` is explicitly functional and NOT guarded (1237-1246).

## 1. L1D per-line state

Per set (direct-mapped): `dc_tag` (24b PA tag), `dc_data` (128b), `dc_dirty` (1b), `dc_valid` (1b), each a `ram2r1w` (read port 0 = port-1/t_cache_idx, read port 1 = port-2/t_cache_idx2, ONE write port). l1d.sv:1656-1766.
**No `va_alias`, `pidx`, or any other per-line field exists on this branch** (grep: none). Other protocol-relevant state: the LL link `r_link_reg_val/r_link_reg` (line-granular PA) l1d.sv:669-673, 756-780; the per-LSU-slot store buffer `r_sb_pa/mask/op/cached/scok/data` l1d.sv:945-972.

Write-port priority (one write per array per cycle):

| Bit | Written by (priority order) | Value | Anchor |
|---|---|---|---|
| valid | `t_mark_invalid` at `r_cache_idx` | 0 | 1740-1747 |
| | else fill `w_cacheable_mem_rsp_valid` (= `r_state==INJECT_RELOAD & mem_rsp_valid`, 627) at `r_mem_req_addr` index | `!r_inhibit_write` | 1748-1753 |
| dirty | `t_mark_invalid` at `r_cache_idx` | 0 | 1702-1705 |
| | else fill at `r_mem_req_addr` index | 0 | 1706-1710 |
| | else store array write `t_wr_array` at `r_cache_idx` | 1 | 1711-1715 |
| tag | fill only (any response in INJECT_RELOAD) | `r_mem_req_addr[35:12]` | 1666-1668 |
| data | fill (`mem_rsp_valid` selects addr/data) or `t_wr_array` | rsp data / merged store line | 1628-1633, 1685-1687 |

`t_mark_invalid` sites (all clear valid AND dirty of the line currently indexed by `r_cache_idx`):

| Site | Condition | Anchor |
|---|---|---|
| INIT_CACHE (reset walk) | every set except the last (N-1 is skipped: goes ACTIVE without marking -- relies on RAM power-up 0) | 2856-2869 |
| CACHE hit-op retry, dirty WB arm | valid & tag hit & dirty & op!=CHINV | 2886-2892 |
| CACHE hit-op retry, other arm | valid & tag hit | 2917-2918 |
| uncached access aliasing a cached line | valid & tag hit | 2949-2955 |
| FLUSH_CL inval | valid & tag == flush addr tag | 3335-3336 |
| FLUSH_CL non-inval, dirty | `r_dirty_out` (no valid/tag check -- index op) | 3344-3354 |
| FLUSH_CL non-inval, clean | UNCONDITIONAL (no valid/tag check) | 3363-3367 |
| CHOP_BEAT2 (2nd 16B line) | same two arms as beat 0 | 3454-3474 |
| FLUSH_PG | `w_pg_hit` (valid & tag match on the page line) | 3492-3495 |
| FLUSH_CACHE | `!r_dirty_out` only (dirty lines are NOT invalidated -- see 5) | 3537-3539 |

`r_inhibit_write`: makes the "fill" write that happens on ANY INJECT_RELOAD response install valid=0. Set when the outstanding INJECT_RELOAD request is a dirty-victim writeback (3031, 3041), also set on MEM_WB/SW issue elsewhere (2899, 2966, 3360, 3464, 3500, 3553) where it is irrelevant because those states never assert `w_cacheable_mem_rsp_valid`. Cleared at clean-miss issue (3070), direct fill (2822), and on the response (3265, 3304, 3385, 3516, 3564, 3575).

Implied invariant (relied on, never asserted): **invalid => clean** (every valid-clear also clears dirty; fills write dirty=0). FLUSH_CL and FLUSH_CACHE test `r_dirty_out` without `r_valid_out` (3344, 3537).

## 2. L1D -> L2 requests

Interface: `mem_req_valid/addr/store_data/opcode/cacheable/mask` from registers (586-591). `n_mem_req_valid` defaults 0 every cycle (2489), so **`mem_req_valid` is a ONE-CYCLE PULSE**; the `mem_req_ack` input is declared but never used (216; grep). The arbiter latches the pulse (core_l1d_l1i.sv:711).

| Opcode (cacheable) | Issued from | L1 state at issue | L1 state at response | L2 behaviour / response timing |
|---|---|---|---|---|
| `MEM_LW` (1) fill | port-1 clean/invalid miss 3061-3099 (ACTIVE -> INJECT_RELOAD); direct fill from port-2 miss 2813-2830 | none (old line untouched) | tag/data written, valid=1, dirty=0 (inhibit=0) 1666, 1706, 1748 | hit: rsp after lookup (l2.sv:726-731). miss: evict L2 victim to DRAM if valid&dirty, DRAM reload, re-lookup, rsp (752-787, 790-829) |
| `MEM_SW` (1) dirty-victim WB | port-1 dirty miss 3026-3059; also the `rr_last_wr` clean-miss arm 3083-3090 via WAIT_INJECT_RELOAD 3236-3241 | none (victim stays valid+dirty in array) | INJECT_RELOAD "fill" write: tag=victim tag, data=L2 `r_rsp_data` (stale, meaningless), dirty=0, valid=`!inhibit` (=0 for the dirty arm) | **EARLY ACK**: L2 sets rsp the cycle after accepting in IDLE (l2.sv:567-572), before lookup; then hit -> write line + dirty (732-738); miss -> write-allocate: evict/reload from DRAM, re-lookup, write (752-787) |
| `MEM_SW` (1) uncached-alias WB | UNCACHE_WB arm 2949-2967 | line invalidated at issue | none | early ack (as above) |
| `MEM_SW` (1) whole-flush WB | FLUSH_CACHE 3547-3555 | none | none -- **line stays valid+dirty** (see 5) | early ack |
| `MEM_SW`/`MEM_LW` (cacheable=0) uncached | port-1 uncached arm 2969-2998; mask = byte mask, addr line-aligned | none | load: data to core (3284-3296); store: `st_done` (3274-3283) | L2 looks up first; hit -> invalidate L2 copy, WB to DRAM if dirty, turnaround, then the uncached DRAM op; rsp after DRAM (l2.sv:555-563, 587-624, 896-950) |
| `MEM_WB` (26) | CACHE hit-op dirty arm 2886-2902 / 3454-3467; FLUSH_CL dirty 3344-3362; FLUSH_PG WBINV dirty hit 3496-3501 | line invalidated at issue | none | data written straight to DRAM; L2 copy valid:=0 (dirty bit NOT cleared); rsp after DRAM ack (l2.sv:706-719, 891-902) |
| `MEM_INVL` (24) | CACHE hit-op non-dirty arm 2903-2926 / 3468-3482; FLUSH_CL inval 3327-3343; FLUSH_PG WBINV not-dirty 3504 | hit line invalidated at issue | none | L2 hit&dirty: write L2 line to DRAM, drop, rsp after DRAM+turnaround; else drop (if hit) + rsp (l2.sv:626-664, 933-942) |
| `MEM_PGDROP` (31) | FLUSH_PG with `flush_cl_inval` 3504 | hit line invalidated at issue | dirty-count bookkeeping only | L2 drops without WB; `rsp_data[0]` = was dirty (l2.sv:666-680) |
| never from L1D | `MEM_SNOOP_INVL` (L2-internal, l2.sv:533-552), `MEM_CHWB/CHWBINV/CHINV/MOV/TLBP` (core->L1D only) | | | |

**Outstanding requests to L2: exactly one, ever.** Every issue site moves the FSM to a wait state (INJECT_RELOAD, INJECT_UNCACHE_*, UNCACHE_WB, FLUSH_CL_WAIT, FLUSH_PG_WAIT, FLUSH_CACHE_*WAIT) that leaves only on `mem_rsp_valid`. There is no MSHR file, no write-back buffer, no eviction buffer. `r_n_inflight` (783-798) counts core ops accepted-but-unanswered, NOT L2 requests. The MQ is a replay FIFO that only pops in ACTIVE (3107).

**Dirty-victim miss ordering (exact):**
1. ACTIVE, port-1 pass, `valid & dirty & tag!=req` (3026): issue `MEM_SW {victim tag, idx}` with the line data, `inhibit=1`, `r_reload_issue=1`, `r_lock_cache=1`, -> INJECT_RELOAD (or WAIT_INJECT_RELOAD for one cycle first if port-1 wrote this set two cycles ago, `rr_last_wr`, 3046-3058; data re-read there 3240).
2. INJECT_RELOAD: L2 early-acks the SW; on that response the array "fill" write marks the set valid=0/dirty=0 (inhibit) -> HANDLE_RELOAD (3263).
3. HANDLE_RELOAD (3313-3324) re-presents `r_req` on port 1 (`r_did_reload=1`) -> ACTIVE: line now invalid -> clean-miss arm (3061; passes via `r_lock_cache`) -> issue `MEM_LW` -> INJECT_RELOAD.
4. Fill response: install valid line. If `r_req` is a simple LSU-held load (`MEM_LW` opcode & lsu_hold & !store), answer from the fill data (`w_fill_bypass`, 637-639, 3247-3260) and go to ACTIVE; otherwise HANDLE_RELOAD -> re-pass hits -> store writes / load answers.

So the L2 sees **SW(victim) strictly before LW(refill)**; the LW is not even generated until the SW response has been received and a re-lookup done. Because the L2 is serial and acked the SW early, the LW waits in the arbiter (r_req held) until the L2 finishes the SW (including any L2 eviction/DRAM reload) and returns to IDLE.

## 3. Miss path end to end (cacheable load)

Two "ports" share the arrays: **port 2** = first pass of every core request (in-order, VA-indexed speculative read + dtlb), **port 1** = replay from the MQ head, HANDLE_RELOAD re-pass, or UNCACHE_WB re-pass (physical).

1. Accept (cycle T): `t_p2_accept` in ACTIVE (3173-3191) or INJECT_RELOAD (3268-3272); conditions `t_p2_ok` (2509-2515): not stale color, MQ not almost-full/full, not a load to the set of the previous cycle's store address pass (`r_last_wr2`), `w_uncachable_req` (uncached non-LSU ops / CACHE ops only at ROB head or committable delay slot or drain, 2383-2385), atomics need empty MQ, rob slot not already inflight (one op per {color,rob}). In ACTIVE also `n_state==ACTIVE`, `!t_got_miss`, `!t_got_rd_retry` (no MQ pop this cycle), `!t_cm_block_stall`. Ack + read arrays at VA index (3587-3611).
2. Port-2 decision (T+1, 2621-2848), priority: commit -> push MQ; drain -> answer without access; MOV/TLBP; bad_addr/TLB refill/invalid/modified/out-of-range faults; store address pass (write SB slot, ack, no cache access); uncached speculative simple load -> `BLK_UNCACHEABLE`; `t_sb_blk` -> `BLK_SB_CONFLICT`/`BLK_SB_DATA`; SB forward; CACHE hit-op -> push MQ; **fast hit** (`valid & tag==TLB PA tag & !r_hit_busy_addr2 & !r_fill_conflict2 & cached`) -> data rsp; else: direct fill if `t_direct_fill_ok` (2594-2602: ACTIVE, simple cacheable load, MQ empty, port 1 idle, no rr_last_wr, no flush pending, victim not valid+dirty, VA idx == PA idx) else push MQ; a cacheable LSU-held load additionally returns `BLK_MISS` (or `BLK_ST_CONFLICT` if it was actually a tag hit blocked by an MQ store / fill conflict) 2842-2846.
3. MQ head pop (ACTIVE only, `!t_got_miss & !r_lock_cache & !t_mh_block`, 3107-3170): stale-color non-commit entries dropped (3111-3119); commits pop at once; CACHE ops pop at once; loads pop if cached or non-speculative. Pop = port-1 read (`n_is_retry=1`).
4. Port-1 pass (ACTIVE, 2875-3101): hit -> load rsp with data (3017-3024) / commit store writes (`t_wr_array` requires `r_is_retry|r_did_reload`, 2178-2309) + `st_done` (3008-3012); dirty miss -> section 2; clean/invalid miss -> `MEM_LW`, INJECT_RELOAD.
5. INJECT_RELOAD (3242-3273): waits for `mem_rsp_valid`; meanwhile accepts port-2 requests (hit-under-miss, non-atomic). Fill writes arrays (1628-1766), then bypass rsp (-> ACTIVE) or HANDLE_RELOAD.
6. HANDLE_RELOAD -> ACTIVE re-pass -> hit -> rsp/write.

The `BLK_MISS` load is answered later by its own MQ entry's port-1 pass **with data** (`core_mem_rsp_valid`), not by a wakeup: `n_core_mem_wake_valid` is never set to 1 anywhere (only default 0 at 2498) -- the wake output is dead on this branch.

**While a miss (INJECT_RELOAD) is outstanding:**

| Request | Proceeds? | Anchor |
|---|---|---|
| port-2 load hit to another set | YES (hit-under-miss) | 2621, 2789, 3268 |
| port-2 load to the set being filled / victim-WB set | treated as miss (`r_fill_conflict2`, computed at accept vs `r_mem_req_addr` idx) -> MQ + BLK | 1445-1446, 1786, 2789 |
| port-2 load hitting a set with an overlapping MQ store | `r_hit_busy_addr2` -> MQ + `BLK_ST_CONFLICT` | 1431-1432, 2845 |
| port-2 miss | pushed to MQ (no direct fill: needs ACTIVE) + `BLK_MISS` | 2594, 2833 |
| store address pass | YES (SB write + ack, no array access) | 2725-2744 |
| store commit | accepted, pushed to MQ; written only after the fill when popped | 2635-2639 |
| atomics (LL/SC) | NO (`!core_mem_req.is_atomic`) | 3268 |
| MQ pops, second miss, flushes, CACHE ops, uncached | NO (ACTIVE only) | 3107, 3192-3234 |
| WAIT_INJECT_RELOAD / HANDLE_RELOAD / any non-ACTIVE/INJECT_RELOAD state | no port-2 accept at all | 3583, 3268 |

## 4. Store path

| Phase | What happens | Anchor |
|---|---|---|
| Address pass (port 2, speculative, may be OoO w.r.t. loads) | TLB/fault checks; write PA, mask, op, cacheability, SC link result into SB slot `lsu_idx`; ack; no cache access. SC/SCD answer the reservation here. | 2725-2744, 958-967 |
| Data | arrives separately from the LSU (`lsu_sb.data_valid/idx`) | 968-971; exec.sv:3323-3329 |
| Load vs SB | load compares against older live stores it saw at issue (epoch-checked); full-cover forward from youngest whole-access cached store (SB/SH/SW/SD only), else block `BLK_SB_CONFLICT`/`BLK_SB_DATA`; uncached load waits for ALL older stores | 994-1047, 2752-2768 |
| Retire -> commit | after retirement the LSU sends a `commit=1` request (addr 0, cached=1, mapped=0) | exec.sv:3734-3745 |
| Commit pass (port 2) | always `t_push_miss`: MQ entry rebuilt from the SB slot (PA/op/data/cached/sc_ok) | 2635-2639, 1049-1067 |
| Array write | at MQ head (in FIFO order with replayed loads/CACHE ops) via port 1: hit -> `t_wr_array`, dirty:=1, `st_done` (frees LSU slot); miss -> write-allocate fill (sec 2/3) then HANDLE_RELOAD re-pass writes | 3120-3131, 3006-3012, 2237-2241 |
| Uncached commit | port-1 uncached arm: purge aliasing line, then `MEM_SW` cacheable=0 with byte mask; `st_done` at response | 2947-3005, 3274-3283 |
| SC commit | writes only if `sc_ok` | 2249-2266 |

Store to a line with an outstanding miss: the commit sits in the MQ (MQ doesn't pop outside ACTIVE) and is written after the fill when it reaches the head; it never merges into the fill. Loads behind it in the MQ that overlap see it in order; port-2 loads that overlap are blocked by `r_hit_busy_addr2` (byte-mask overlap, 1426-1432).
Port-1 write -> same-set reads: MQ head to the same set is not popped the cycle after a port-1 write (`t_mh_block`, 2569-2570); a port-2 read accepted the same cycle as a port-1 write to the same set takes the written line from `r_array_wr_data` (`t_cm_block` -> `r_must_forward2`, 2583-2584, 1607, 1778). (`r_must_forward` for port 1 is always 0: it needs `t_mh_block & t_pop_mq`, which are exclusive, 1606/3109.)
Flush entry waits for `!lsu_sb.retired_pending` (retired-but-uncommitted stores) for FLUSH_CACHE and FLUSH_CL (3192, 3206) but **not** for FLUSH_PG or DMA inval (3218, 3225) -- UNSURE whether the core guarantees it elsewhere for XPG.

## 5. CACHE ops and flushes

Decode split (decode_mips.sv:1921-1958): kernel-mode **primary-D Hit ops** 0x11/0x15/0x19 (insn[17:16]=01, op 100/101/110) -> mem uops `MEM_CHINV/CHWBINV/CHWB` (dtlb-translated EA); **every other CACHE op** -> serializing `CACHE_OP` handled by the core at the ROB head (core.sv:2709-2760): D-side -> `flush_cl_req` at `EA & 0x1fffffff` with `flush_cl_inval = (op==100)`; I-side -> whole-L1I `flush_req_l1i`; injected `XFLUSH` -> whole L1D + L2; `XPG_WBINV/XPG_INV` -> `flush_pg_req`.

| Op | L1D action | To L2 | Waits / completes | Anchor |
|---|---|---|---|---|
| CHWB / CHWBINV / CHINV (mem pipe) | admitted only non-speculative (2376, 2383); port 2 pushes to MQ (2769-2774); MQ head pops at once (3132-3147); port-1 retry: dirty hit & !CHINV -> invalidate + `MEM_WB`; else (clean hit, miss, or CHINV even if dirty) -> invalidate if hit + `MEM_INVL` of the line. **CHWB == CHWBINV** (no clean-keep-valid). Then beat 2 on line+16 (CHOP_BEAT2_RD/CHOP_BEAT2, same rules; INVL addr = line+16). | 2 requests (beat0, beat1), each awaited | core rsp only after beat-1 L2 response (3406-3412). `rob_inflight` cleared on the retry pass (902-905). The `!n_chop_wait` shortcut (2931-2935) is now unreachable (every arm issues). | 2877-2936, 3439-3483, 3381-3412 |
| FLUSH_CL, inval (D Hit-Invalidate via funnel, e.g. secondary ops) | invalidate on tag hit (no WB) | `MEM_INVL flush_cl_addr` | FLUSH_CL_WAIT -> beat 2 re-runs FLUSH_CL on set+1, but **still sends `MEM_INVL` for `flush_cl_addr` (beat-0 line), not +16** (3337) -- L2 copy of line+16 not dropped. UNSURE if intended. `flush_complete` pulse after beat 2. | 3325-3343, 3413-3438 |
| FLUSH_CL, non-inval (Index-WB-Inv, Index load/store tag, etc. -- ALL treated alike) | index semantics: dirty -> `MEM_WB` of the line by its own tag + invalidate; clean -> invalidate unconditionally (no tag check) | `MEM_WB` or nothing | WB beats wait on rsp; then beat 2 on set+1; `flush_complete` | 3344-3379 |
| DMA inval (`dma_inval_req`) | reuses FLUSH_CL with `r_cl_is_dma`: always inval semantics, one 16B line, no beat 2 | `MEM_INVL dma_inval_addr` | `dma_inval_ack` pulse on L2 rsp | 3225-3234, 3387-3395, 429-432 |
| FLUSH_CACHE (whole L1D; from `XFLUSH`) | walk all sets: clean -> invalidate; dirty -> `MEM_SW` (cacheable, early-acked) and wait. **The dirty line is NOT invalidated or cleaned** (no `t_mark_invalid` in the dirty arm 3547-3555, and the walk advances `t_cache_idx=r_cache_idx+1` at 3536 so it never revisits). After the walk the sequencer chains a full L2 flush (L2 FLUSH_WAIT/TRIAGE: WB dirty to DRAM, invalidate all). Net: L1D dirty lines remain valid+dirty, data now == DRAM. UNSURE whether intended; looks like a gap vs the comment at 3346-3353. | `MEM_SW` per dirty line | `flush_complete` at end; core waits L1D + L2 completes | 3534-3577; core_l1d_l1i.sv:559-650; l2.sv:342-362, 830-890 |
| FLUSH_PG (XPG_WBINV / XPG_INV) | per line of the 4KB page (256 lines): WBINV: dirty hit -> invalidate + `MEM_WB`; else invalidate hit + `MEM_INVL`. INV: invalidate hit + `MEM_PGDROP` (dirty hits counted as a bug). | 1 request per line, awaited | one `flush_complete` after line 255 | 3218-3224, 3484-3533 |
| I-side CACHE op | whole L1I FLUSH_CACHE (valid:=0 all sets); L1D untouched (complete faked) | L2 flush handshake completes WITHOUT a walk (`skip_walk`) | core waits L1I + L2 complete | core.sv:2754-2759; l1i.sv:1051-1058; l2.sv:360, 517-525 |

Entry to FLUSH_CACHE/FLUSH_CL/FLUSH_PG/DMA-inval: ACTIVE only, `mem_q_empty`, no port-1 write/chop in flight, and only when no port-2 request is accepted that cycle (it is the `else` of the accept, 3173-3234). Priority: FLUSH_CACHE > FLUSH_CL > FLUSH_PG > DMA inval. Requests are sticky latches (2541-2546). `flush_complete` is ONE shared output pulsed by INIT_CACHE end, FLUSH_CL, FLUSH_PG and FLUSH_CACHE completion (2863, 3376, 3425, 3523, 3544, 3565).

## 6. Uncached accesses

- Cacheability: unmapped -> segment (`r_req2.cached`); mapped -> TLB C==3 (923).
- Simple uncached loads are bounced (`BLK_UNCACHEABLE`) until non-speculative (2745-2751); others gated at accept by `w_uncachable_req` (2383-2385); queued uncached loads pop only when non-speculative (3148). Dead uncached loads at drain are answered with no access (2937-2946).
- Port-1 uncached arm (2947-3005): if the line at that index is **valid with the same tag** (alias): invalidate it; if dirty issue cacheable `MEM_SW` of it (UNCACHE_WB waits for the ack), else no request; then re-present the uncached op on port 1 (3298-3312), which now misses and issues `MEM_SW/MEM_LW` cacheable=0 (INJECT_UNCACHE_STORE/LOAD). 
- The L2 independently purges its own copy on an uncached request (lookup; hit -> invalidate, WB to DRAM if dirty) before doing the DRAM access (l2.sv:587-624). The L1D WB above lands in L2 as dirty and is then immediately purged to DRAM by the uncached op's L2 lookup (serial L2 => ordered).
- Uncached store data = `t_array_data` (cache-line merge of the indexed set's data with the store bytes, 2997); only `mask` bytes are meaningful.

## 7. Snoop / back-invalidate / probe inputs

| Input | Where | Wired? | Effect |
|---|---|---|---|
| `dma_inval_req/addr/ack` | l1d.sv:167-176 | core_l1d_l1i top-level port -> l1d (core_l1d_l1i.sv:335-337, 929-931). Not referenced by `shell_for_ultra96v2/*.v` or `top.cc` in this tree (grep) => effectively 0. | One-line L1D invalidate (no WB) + `MEM_INVL` to L2, ack after L2 rsp (sec 5). This is the only L1D "external invalidate" hook; it is serviced only from ACTIVE with an empty MQ (3225), lowest priority. |
| `snoop_req_valid` on l2 | l2.sv:533-552 | **tied to 1'b0** at core_l1d_l1i.sv:864 (port exists, henry wires `w_snoop_valid` into core_l1d_l1i but this file drops it) | L2-only `MEM_SNOOP_INVL` drop-without-WB, no L1 response, no L1 effect |
| anything on l1i | -- | none | L1I has no external invalidate; only whole-cache flush |

There is **no L2->L1 request channel**; L2->L1 traffic is only `l1_mem_rsp_valid` + data to whichever L1 holds the grant.

## 8. L1I

| Item | Fact | Anchor |
|---|---|---|
| Per-line state | valid (`ram1r1w`), tag (PA[35:12]), 128b insn data (byte-swapped at fill), predecode bits. No dirty. | l1i.sv:1437-1490 |
| Fill | on `mem_rsp_valid` write tag/data/predecode at `r_miss_pc` index, valid:=1 -- **regardless of `r_cached`**: an uncached (kseg1) fetch is installed as a valid line (UNSURE if intended; tag is the PA) | 1233-1238, 1448-1468 |
| Miss | ACTIVE `t_miss` (valid & PA-tag compare, 647) -> `MEM_LW` (opcode hardwired, 383) line address, `cacheable=r_cached`, one-cycle pulse -> INJECT_RELOAD | 843-850 |
| Outstanding | exactly 1 (INJECT_RELOAD waits for rsp; restart/flush requests are latched and handled in RELOAD_TURNAROUND, so the fill always completes and installs even for a squashed fetch) | 1015-1049 |
| Invalidation | only FLUSH_CACHE: all sets valid:=0 (entered from ACTIVE/RELOAD_TURNAROUND/WAIT_FOR_NOT_FULL/WAIT_FOR_TLB on `flush_req`, and at reset after INIT_PHT) -> `flush_complete`, IDLE until restart | 756-764, 791-796, 1051-1058, 1236 |
| Coherence with L1D | none; L1I refills from L2, so L1D-dirty code is invisible to fetch until written back to L2. An I-side CACHE op does not write back the L1D. | core.sv:2754-2759 |

## 9. Arbiter (core_l1d_l1i.sv:657-788) and L2 interface

- 3 states IDLE / GNT_L1D / GNT_L1I. Request pulses latched sticky (`n_l1d_req = r_l1d_req || l1d_mem_req_valid`, 710-711). IDLE: single requester wins; both -> round-robin on `r_last_gnt` (726-743).
- Grant holds until the L2 response: `w_l1_mem_rsp_valid` in GNT_x -> pass `mem_rsp_valid` to that L1 combinationally, back to IDLE (744-779). **One L1->L2 transaction system-wide at a time** (L1D+L1I combined); response routed by grant state; the 128b response data bus is shared (`w_l1_mem_load_data` to both, 943, 1007).
- `l1_mem_req_valid = r_req | t_l2_passthru` (840); passthru lets an L1D request reach the L2 in the grant cycle when the arbiter was IDLE (787). `r_req` drops on `l1_mem_req_ack` (750-753). L2 only samples requests in its IDLE (l2.sv:553-581), so a held `r_req` waits for the L2 to finish prior work.
- Store data always comes from the L1D (`l1d_mem_req_store_data`, 844); the L1I never stores. `l1d_mem_req_ack`/`l1i_mem_req_ack` are declared (664, 672) but never driven (and unused by the L1s).
- **Early-acked MEM_SW**: the L2 responds to a cacheable SW one cycle after accept (l2.sv:572) and keeps working (lookup, possible L2-victim WB to DRAM, DRAM reload, write). The arbiter returns to IDLE on that response, so the L1D (or L1I) can issue and be GRANTED the next request while the L2 is still processing the SW; it is not ACCEPTED (acked) until the L2 is back in IDLE. Hence the L2 processes requests strictly in grant order; no reordering, no overlap inside the L2.
- Uncached SW (cacheable=0) is NOT early-acked (rsp after DRAM, l2.sv:896-902). MEM_WB/INVL/PGDROP/LW respond at completion.

## 10. Modeling hazards (timing/ordering an untimed model must capture)

1. **Single outstanding L1->L2 transaction overall**, but the L2 may still be busy with an early-acked `MEM_SW` when the next request is granted. Model: L1D "SW done" event decoupled from the L2 actually writing the line; the next request queues behind it (L2 serial).
2. **Victim not invalidated at WB issue**: during the dirty-victim `MEM_SW` the victim remains valid+dirty in the L1D array until the ack arrives; port-2 hit-under-miss is fenced only by the same-index `r_fill_conflict2` check (1445). A back-invalidate arriving in that window would see a valid dirty L1D line whose data is already in flight to L2.
3. **Fill installs on ANY INJECT_RELOAD response** (627): the victim-WB ack writes tag/garbage data with valid=`!inhibit`. In the `rr_last_wr` clean-miss arm (3083-3090) inhibit is 0, so the SW ack transiently installs a VALID, CLEAN line with the victim's tag and meaningless data, until the immediately following refill overwrites the set. I believe it is unobservable (no port-2 accept in HANDLE_RELOAD; the ACTIVE re-pass sets `t_got_miss`), but UNSURE -- a model of back-invalidates/snoops must not assume valid => data correct across this window.
4. **Fills are never cancelled**: a squashed (stale-color) load's fill still installs the line; only the core response is suppressed (`w_rsp_stale`, 614-622). Same for L1I fetch fills. Speculative fills persist.
5. **Same-cycle RAM read/write**: port-2 read of the set port 1 is writing uses `r_array_wr_data` (1778, 2583); MQ head to that set is held one cycle (`t_mh_block`). One write port per array with priority invalidate > fill > store (1697-1716): a store write coinciding with an invalidate/fill loses its dirty=1 (the `dirtydrop` watch, 53-58, 3688). Not reachable by construction I believe (invalidates/fills happen in non-ACTIVE states or with `t_got_miss` blocking pops), UNSURE.
6. **Request is a 1-cycle pulse, ack ignored**: correctness relies on the arbiter latch and on the L1 never issuing while waiting. The arbiter clears `n_l1d_req` while in GNT_L1D (747): a second L1D pulse during its own grant would be LOST -- safe only because each L1 has <=1 outstanding.
7. **Response routing is by grant state, not by tag**: a response can only belong to the granted L1. An L2->L1 back-invalidate channel would need its own path (the L1 FSMs only consume `mem_rsp_valid` in their wait states; an unexpected `mem_rsp_valid` in ACTIVE would still steer `t_array_wr_addr/data` (1630-1631) but not enable the write).
8. **Write-allocate stores and replay ordering**: committed stores, replayed loads and CACHE ops share the in-order MQ; nothing pops while a miss/flush is outstanding (3107). Port-2 hits continue meanwhile, so port-2 reads can be younger-than-MQ-content: guarded by byte-overlap `r_hit_busy_addr2` and the LSU SB compare.
9. **CACHE hit-ops are two beats** (line and line+16), each a separate awaited L2 request; FLUSH_CL index ops also two beats with index (not tag) semantics; FLUSH_CL-inval beat 2 re-sends the beat-0 address to L2 (3337).
10. **Whole-L1D flush leaves dirty lines valid+dirty** (3547-3555) and pushes them to L2 as `MEM_SW` (dirty in L2), relying on the chained L2 flush to reach DRAM.
11. **Flushes start only from ACTIVE with an empty MQ and no port-2 accept that cycle** (3192-3234): a continuous port-2 request stream can delay a flush/DMA-inval indefinitely (no priority to the flush). FLUSH_PG and DMA-inval do not wait for `lsu_sb.retired_pending`.
12. **Uncached access double purge**: L1D purges (WB via cacheable SW, early-acked) then the L2 purges its own copy to DRAM before the uncached DRAM access -- order guaranteed only by the L2 being serial.
13. **Restart color**: stale requests are acked-and-dropped at accept (3583-3586); stale non-commit MQ entries are dropped at the head (3111-3119); commits are exempt. Per-color counters (`r_color_cnt`, 1086-1104) and `mem_quiet` (1188-1189) gate the core's color flip-back.
14. **L1I squash**: restart/flush during an L1I miss is deferred to RELOAD_TURNAROUND; the fill always lands.
15. **L2 MEM_WB clears L2 valid but not dirty** (l2.sv:713-717); L2 evictions test valid&dirty (`w_need_wb`, 235) so this is benign, but a model of L2 state should keep the "invalid-but-dirty" encoding or prove it irrelevant.
