-- rv64core_dma.m -- rv64core_caches.m + a DMA agent that uses the L2's EXTERNAL PROBE
-- (l2_2way ext_probe_*: the same PROBE_IDLE/PROBE_WAIT engine and nu_l1d FLUSH_CL the page
-- walker uses) to make DMA coherent the way MARK_PTE is: probe the L1D (write back +
-- invalidate the line, FLUSH_CL_WAIT until drained), then on the ack perform the DMA write
-- (DMA_GATE=1: in the same atomic step, i.e. the L2 grants no L1 request in between, as
-- w_mark_gate does for the PTE RMW).  Device reads (DMA_OUT) probe (write back) and then
-- read through the L2.  rv64core main @ 0194a80/fbe9a2a: ext_probe is tied off in
-- core_l1d_l1i, and l2_2way never asserts ext_probe_ack (n_ext_probe_ack is never set) ->
-- DMA_ACK_BUG models that.
--
-- DMA knobs
--   DMA           model the DMA agent
--   DMA_GATE      1 = the DMA write happens atomically with the probe ack (no L1 service in
--                 between); 0 = separate step, the L2 may serve L1 requests in the gap
--   DMA_WRITE_L2  1 = the L2 merges the DMA data (hit: update + dirty; miss: DRAM, no
--                 allocate); 0 = DMA writes DRAM and the L2 drops its copy (no writeback)
--   DMA_ACK_BUG   1 = RTL as is: the external probe is never acked (expect a deadlock)
--   DMA_OUT       model device reads too
--
-- rv64core_caches.m -- Murphi model of the rv64core cache hierarchy
-- Source: ~/code/rv64core main @ 454c931 (the cache protocol is identical to the
-- hacky_fp32_for_quake branch the first extraction read: the main-vs-quake diffs in
-- nu_l1d / l1i_2way / l2_2way / core_l1d_l1i are debug $display/$stop guards only).
--   nu_l1d.sv (direct-mapped, write-back, eviction buffer, early port-2 loads)
--   l1i_2way.sv (read-only, reads the L2 directly, no probe)
--   l2_2way.sv (2-way, write-back, write-allocate, refill-first / victim-buffer writeback)
--   mmu.sv (page walk probes the L1D, then reads the L2; MARK_PTE does A-bit RMW in the L2)
--   fence.i / WB_CACHES flush sequence (core.sv:1167)
-- RTL anchors on main:
--   nu_l1d.sv:443   w_eb_port2_hit computed, never used            -> EARLY_LW / FIX_EB_P2
--   nu_l1d.sv:2377  flush entry needs mem_q_empty & !w_eb_full only -> FIX_FLUSH_DRAIN
--   nu_l1d.sv:2500/2511  FLUSH_CACHE_(LAST_)WAIT advance on any response
--   nu_l1d.sv:2434/2459  FLUSH_CL / FLUSH_CL_WAIT: dirty probe hit written back, stays VD -> FIX_PROBE
--   nu_l1d.sv:802   w_queues_drained (used by the probe, not by the flush)
--   core.sv:1167    FENCEI/WB_CACHES/MONITOR start on ROB-empty only (skip memq_empty,
--                   which the general serialize path requires at core.sv:1228)
--   decode_riscv.sv:278  fence.i -> FENCEI in EVERY privilege mode on main (the quake
--                   branch's user-mode WB_CACHES gating from eff5d167 is not on main), so
--                   the default here is WB_NO_INV = 0
--   l2_2way.sv:1383 MARK_PTE replay falls to `default` ($stop only under VERILATOR; in
--                   hardware the entry is dropped and the walker hangs) -> FIX_MARK_MISS
--
-- Abstraction: NADDR line addresses that ALL collide in the one L1D line, the one L1I
-- line and the one L2 set, so every access is a conflict.  Data = a small version
-- number (v) plus the PTE Accessed bit (a).  Ghost state records the latest value of
-- every line; a load / fetch / page-walk that returns anything else is a coherence bug.
-- Untimed: every enabled action may fire in any order, so timing-dependent hazards the
-- RTL "avoids" by latency show up here.
--
-- Knobs (0/1).  Each hazard can be switched on alone; all FIX_* = 1 should verify clean.
--   EARLY_LW    model nu_l1d's early port-2 MEM_LW (needs FIX_EB_P2 to be safe)
--   FIX_EB_P2   block an early LW whose line is still in the eviction buffer (w_eb_port2_hit)
--   MMU         model the page walker probe + MARK_PTE
--   FIX_PROBE   a probe hit on a DIRTY line invalidates it after the writeback (RTL keeps VD)
--   FIX_MARK_MISS  a MARK_PTE that misses in the L2 refills (RTL: $stop / hang)
--   FENCE       model fence.i / WB_CACHES
--   WB_NO_INV   the fence is the WB_CACHES flavour (no L1I invalidate); on main plain
--               fence.i never is -- set 1 only to model the quake branch's user-mode gating
--   FIX_FLUSH_DRAIN  L1D flush completes only when its writebacks reached the L2 and the
--               L2 flush waits for the L1D->L2 channel to drain (RTL: "any response")
--   CHECK_MEM_AT_FENCE  after a fence, DRAM must hold the latest value (host readback)
--   MMU_CONCURRENT  the data side keeps running during a walk (an I-side TLB miss) -- the
--               L1D may re-fetch / dirty the PTE line between the walk read and MARK_PTE
--   CHECK_A_ON_LOAD a load of the PTE line must also see the latest A bit
--   FIX_MARK_COHERENT  MARK_PTE is coherent with the L1D: before the L2 RMW, a clean L1D
--               copy is invalidated and a dirty one written back + invalidated, atomically
--               with the mark (no L1D refill of the line can slip in between, and no stale
--               copy may still sit in the eviction buffer)
--   PMH_EVICT_RMW  dsheffie's design: the PMH MARK request itself evicts the line from the
--               L1D (dirty -> writeback + invalidate, clean -> invalidate), waits for the
--               eviction's writeback to drain (the L1D is frozen in FLUSH_CL meanwhile), then
--               on that ack the L2 pipe does the RMW directly -- before granting any other
--               L1D request -- and acks the PMH.

const
  NADDR: 3;           -- line addresses; address 0 is also the PTE line
  MAXV: 2;            -- stores per address are bounded (versions 0..MAXV)
  EBSZ: 2;            -- nu_l1d eviction buffer entries
  QSZ: 3;             -- L1D->L2 request FIFO / L2->L1D response FIFO depth (model)
  CREDITS: 3;         -- L1D request credits (RTL 7 < FIFO 8; scaled down)

  EARLY_LW: 1;
  FIX_EB_P2: 0;
  MMU: 1;
  FIX_PROBE: 0;
  FIX_MARK_MISS: 0;
  FENCE: 1;
  WB_NO_INV: 0;
  FIX_FLUSH_DRAIN: 0;
  FLUSH_WAIT_EB_ONLY: 0;
  L1I_FETCH: 1;            -- 0 = no instruction fetch (so a stuck L2/L1D shows up as a Murphi deadlock)
  PMH_L2_STALL_PROBE: 0;   -- the L2's mark states stop serving L1D requests while waiting for the probe ack   -- POST_FLUSH_CACHE waits for w_eb_empty only (not the credits)
  CHECK_MEM_AT_FENCE: 0;
  MMU_CONCURRENT: 1;
  CHECK_A_ON_LOAD: 1;
  FIX_MARK_COHERENT: 0;
  PMH_EVICT_RMW: 0;
  PMH_RMW_GAP: 0;          -- negative control: the L1D acks, then the RMW happens LATER
  DMA: 1;
  DMA_GATE: 1;
  DMA_WRITE_L2: 1;
  DMA_ACK_BUG: 0;
  DMA_OUT: 1;

type
  Addr: 0..NADDR-1;
  Ver: 0..MAXV;
  Data: record v: Ver; a: boolean; end;
  LState: enum {L_I, L_V, L_VD};
  L1Line: record st: LState; tag: Addr; d: Data; end;
  L2Way: record valid: boolean; dirty: boolean; tag: Addr; d: Data; end;
  MsgKind: enum {M_LW, M_SW};
  Req: record k: MsgKind; addr: Addr; d: Data; end;           -- L1D -> L2
  Rsp: record k: MsgKind; addr: Addr; d: Data; end;           -- L2 -> L1D
  EBEnt: record addr: Addr; d: Data; end;
  WayOrMiss: 0..2;                                            -- 2 = L2 miss
  CoreOp: enum {C_IDLE, C_LD, C_ST};
  MmuSt: enum {W_IDLE, W_PROBE, W_DRAIN, W_READ, W_MARK, W_MEVICT, W_MDRAIN, W_MGAP};
  FenceSt: enum {F_IDLE, F_L1D, F_L1D_WAIT, F_L2, F_L1I};
  DmaSt: enum {D_IDLE, D_PROBE, D_DRAIN, D_ACKED};

var
  -- ghost: the architecturally latest value of every line
  latest: array[Addr] of Data;
  icoherent: array[Addr] of boolean;   -- a fence.i has made the I-side see this line

  mem: array[Addr] of Data;             -- DRAM

  -- L1D (one direct-mapped line), eviction buffer, credits
  l1d: L1Line;
  eb: array[0..EBSZ-1] of EBEnt;
  ebn: 0..EBSZ;
  credits: 0..CREDITS;

  -- in-order channels
  rq: array[0..QSZ-1] of Req;  rqn: 0..QSZ;
  rs: array[0..QSZ-1] of Rsp;  rsn: 0..QSZ;

  -- L2: one 2-way set, LRU bit (= index of the MRU way), single victim buffer
  l2: array[0..1] of L2Way;
  lru: 0..1;
  vbuf_full: boolean;
  vbuf: EBEnt;

  -- core: one outstanding memory op (the miss-queue head)
  cop: CoreOp;
  caddr: Addr;
  cwait: boolean;          -- a refill for caddr is in flight
  ca_at_issue: boolean;    -- ghost: the line's A bit when this load issued

  -- L1I (one line, reads the L2 directly)
  l1i_valid: boolean;
  l1i_tag: Addr;
  l1i_d: Data;

  -- MMU page walk of the PTE line (address 0)
  mmu: MmuSt;

  -- fence.i / WB_CACHES
  fence: FenceSt;
  fence_rsp: boolean;      -- FLUSH_CACHE_WAIT has seen a response (ANY response, as in the RTL)

  -- DMA agent (external probe)
  dma: DmaSt;
  daddr: Addr;
  dout: boolean;           -- device READ (else a device write of daddr)
  cload_inwin: boolean;    -- ghost: the pending load was issued inside a DMA-in window

------------------------------------------------------------------ helpers
function eb_has(a: Addr): boolean;
begin
  for i: 0..EBSZ-1 do
    if i < ebn & eb[i].addr = a then return true; endif;
  endfor;
  return false;
end;

procedure rq_push(k: MsgKind; a: Addr; d: Data);
begin
  assert rqn < QSZ "request FIFO overflow";
  rq[rqn].k := k; rq[rqn].addr := a; rq[rqn].d := d;
  rqn := rqn + 1;
end;

procedure rq_pop();
begin
  for i: 0..QSZ-2 do
    if i + 1 < rqn then rq[i] := rq[i+1]; endif;
  endfor;
  rqn := rqn - 1;
  rq[rqn].k := M_LW; rq[rqn].addr := 0; rq[rqn].d.v := 0; rq[rqn].d.a := false;
end;

procedure rs_push(k: MsgKind; a: Addr; d: Data);
begin
  assert rsn < QSZ "response FIFO overflow";
  rs[rsn].k := k; rs[rsn].addr := a; rs[rsn].d := d;
  rsn := rsn + 1;
end;

procedure rs_pop();
begin
  for i: 0..QSZ-2 do
    if i + 1 < rsn then rs[i] := rs[i+1]; endif;
  endfor;
  rsn := rsn - 1;
  rs[rsn].k := M_LW; rs[rsn].addr := 0; rs[rsn].d.v := 0; rs[rsn].d.a := false;
end;

procedure eb_pop();
begin
  for i: 0..EBSZ-2 do
    if i + 1 < ebn then eb[i] := eb[i+1]; endif;
  endfor;
  ebn := ebn - 1;
  eb[ebn].addr := 0; eb[ebn].d.v := 0; eb[ebn].d.a := false;
end;

function l2_way(a: Addr): WayOrMiss;
begin
  for w: 0..1 do
    if l2[w].valid & l2[w].tag = a then return w; endif;
  endfor;
  return 2;
end;

-- L2 allocate: victim = an invalid way, else the non-MRU way; a dirty victim moves to the
-- single victim buffer (written back later, after the refill -- "refill first").
procedure l2_alloc(a: Addr; d: Data; dirty: boolean; var w: WayOrMiss);
begin
  if !l2[0].valid then w := 0;
  elsif !l2[1].valid then w := 1;
  else w := 1 - lru;
  endif;
  if l2[w].valid & l2[w].dirty then
    assert !vbuf_full "L2 victim buffer clobbered (H8)";
    vbuf_full := true; vbuf.addr := l2[w].tag; vbuf.d := l2[w].d;
  endif;
  l2[w].valid := true; l2[w].dirty := dirty; l2[w].tag := a; l2[w].d := d;
  lru := w;
end;

function probe_busy(): boolean;
begin
  return mmu = W_PROBE | mmu = W_DRAIN | mmu = W_MEVICT | mmu = W_MDRAIN;
end;

procedure dma_write();
var w: WayOrMiss;
begin
  latest[daddr].v := latest[daddr].v + 1;
  w := l2_way(daddr);
  if DMA_WRITE_L2 = 1 then
    if w != 2 then
      l2[w].d.v := latest[daddr].v; l2[w].dirty := true; lru := w;
    else
      mem[daddr].v := latest[daddr].v;
    endif;
  else
    mem[daddr].v := latest[daddr].v;
    if w != 2 then l2[w].valid := false; l2[w].dirty := false; endif;
  endif;
  icoherent[daddr] := false;
end;

------------------------------------------------------------------ core
ruleset a: Addr do
  rule "core issues load"
    cop = C_IDLE & fence = F_IDLE & (mmu = W_IDLE | MMU_CONCURRENT = 1)
  ==>
  begin cop := C_LD; caddr := a; cwait := false; ca_at_issue := latest[a].a;
        cload_inwin := (dma != D_IDLE & !dout & daddr = a); end;

  rule "core issues store"
    cop = C_IDLE & fence = F_IDLE & (mmu = W_IDLE | MMU_CONCURRENT = 1) & latest[a].v < MAXV &
    !(dma != D_IDLE & daddr = a)
  ==>
  begin cop := C_ST; caddr := a; cwait := false; end;
endruleset;

-- port 1: the op hits in the L1D (a load returns data, a store writes the array)
rule "L1D port-1 hit"
  cop != C_IDLE & !cwait & mmu != W_MDRAIN & dma != D_DRAIN & l1d.st != L_I & l1d.tag = caddr
==>
begin
  if cop = C_LD then
    assert cload_inwin | l1d.d.v = latest[caddr].v "STALE LOAD: L1D returned an old value";
    if CHECK_A_ON_LOAD = 1 then
      -- a load issued AFTER the hardware set A must see it (one ordered before may not)
      assert !ca_at_issue | l1d.d.a "STALE PTE LOAD: a load after MARK_PTE missed the hardware A bit";
    endif;
  else
    latest[caddr].v := latest[caddr].v + 1;
    l1d.d.v := latest[caddr].v;
    l1d.st := L_VD;
    icoherent[caddr] := false;
  endif;
  cop := C_IDLE;
end;

-- port 1: miss.  A dirty resident line goes to the eviction buffer first (CLEAR_DIRTY),
-- then MEM_LW for the wanted line.  Port 1 is blocked while the line sits in the EB.
rule "L1D port-1 miss: evict + refill"
  cop != C_IDLE & !cwait & mmu != W_MDRAIN & dma != D_DRAIN & !(l1d.st != L_I & l1d.tag = caddr) &
  !eb_has(caddr) & credits > 0 & rqn < QSZ &
  (l1d.st != L_VD | ebn < EBSZ)
==>
begin
  if l1d.st = L_VD then
    eb[ebn].addr := l1d.tag; eb[ebn].d := l1d.d; ebn := ebn + 1;
  endif;
  l1d.st := L_I; l1d.tag := 0; l1d.d.v := 0; l1d.d.a := false;
  rq_push(M_LW, caddr, l1d.d);
  credits := credits - 1;
  cwait := true;
end;

-- port 2: early MEM_LW for a load miss whose resident line is not dirty.  The RTL does
-- NOT check the eviction buffer here (w_eb_port2_hit is computed but unused) -- H1.
rule "L1D port-2 early LW"
  EARLY_LW = 1 & cop = C_LD & !cwait & mmu != W_MDRAIN & dma != D_DRAIN & !(l1d.st != L_I & l1d.tag = caddr) &
  l1d.st != L_VD & credits > 0 & rqn < QSZ &
  (FIX_EB_P2 = 0 | !eb_has(caddr))
==>
var d0: Data;
begin
  d0.v := 0; d0.a := false;
  rq_push(M_LW, caddr, d0);
  credits := credits - 1;
  cwait := true;
end;

-- eviction buffer drains to the L2 as MEM_SW (tag 15)
rule "L1D EB drain"
  ebn > 0 & credits > 0 & rqn < QSZ
==>
begin
  rq_push(M_SW, eb[0].addr, eb[0].d);
  eb_pop();
  credits := credits - 1;
end;

-- L2 response arrives at the L1D: a fill lands in the line (no check of what is there)
rule "L1D consumes L2 response"
  rsn > 0
==>
begin
  if rs[0].k = M_LW then
    assert l1d.st != L_VD "FILL OVERWROTE A DIRTY L1D LINE (I1)";
    l1d.st := L_V; l1d.tag := rs[0].addr; l1d.d := rs[0].d;
    if cop != C_IDLE & cwait & caddr = rs[0].addr then cwait := false; endif;
  endif;
  if fence = F_L1D_WAIT then fence_rsp := true; endif;
  credits := credits + 1;
  rs_pop();
end;

------------------------------------------------------------------ L2
-- the L2 serves the head of the in-order L1D queue; grants are blocked while a dirty
-- victim waits in the victim buffer (r_need_wb)
rule "L2 serves L1D request"
  rqn > 0 & !vbuf_full & rsn < QSZ & !(PMH_L2_STALL_PROBE = 1 & mmu = W_MEVICT) & (fence = F_IDLE | fence = F_L1D | fence = F_L1D_WAIT | fence = F_L1I)
==>
var w: WayOrMiss; m: Req;
begin
  m := rq[0];
  w := l2_way(m.addr);
  if m.k = M_LW then
    if w = 2 then l2_alloc(m.addr, mem[m.addr], false, w); endif;
    lru := w;
    rs_push(M_LW, m.addr, l2[w].d);
  else
    -- L1D writeback: a PTE line whose A bit the hardware set must not lose it (H2)
    if MMU = 1 then
      assert !(latest[m.addr].a & !m.d.a) "L1D WRITEBACK DROPPED THE HARDWARE A BIT (H2)";
    endif;
    if w = 2 then
      l2_alloc(m.addr, m.d, true, w);
    else
      l2[w].d := m.d; l2[w].dirty := true; lru := w;
    endif;
    rs_push(M_SW, m.addr, m.d);
  endif;
  rq_pop();
end;

rule "L2 victim writeback to DRAM"
  vbuf_full
==>
begin
  mem[vbuf.addr] := vbuf.d;
  vbuf_full := false; vbuf.addr := 0; vbuf.d.v := 0; vbuf.d.a := false;
end;

------------------------------------------------------------------ L1I
ruleset a: Addr do
  rule "L1I fetch"
    L1I_FETCH = 1 & fence = F_IDLE & !vbuf_full
  ==>
  var w: WayOrMiss; d: Data;
  begin
    if l1i_valid & l1i_tag = a then
      d := l1i_d;
    else
      w := l2_way(a);                           -- the L1I reads the L2 directly (no probe)
      if w = 2 then l2_alloc(a, mem[a], false, w); endif;
      lru := w;
      d := l2[w].d;
      l1i_valid := true; l1i_tag := a; l1i_d := d;
    endif;
    if icoherent[a] then
      assert d.v = latest[a].v "STALE FETCH after fence.i";
    endif;
  end;
endruleset;

------------------------------------------------------------------ MMU page walk of line 0
rule "MMU walk begins (TLB miss)"
  MMU = 1 & mmu = W_IDLE & (cop = C_IDLE | MMU_CONCURRENT = 1) & fence = F_IDLE
==>
begin mmu := W_PROBE; end;

-- probe the L1D: a dirty copy is written back (port-1 MEM_SW) but stays VD in the RTL;
-- a clean copy is invalidated
rule "MMU probe of L1D"
  mmu = W_PROBE & credits > 0 & rqn < QSZ & (dma = D_IDLE | dma = D_ACKED)
==>
begin
  if l1d.st != L_I & l1d.tag = 0 then
    if l1d.st = L_VD then
      rq_push(M_SW, 0, l1d.d);
      credits := credits - 1;
      if FIX_PROBE = 1 then
        l1d.st := L_I; l1d.tag := 0; l1d.d.v := 0; l1d.d.a := false;
      endif;
    else
      l1d.st := L_I; l1d.tag := 0; l1d.d.v := 0; l1d.d.a := false;
    endif;
  endif;
  mmu := W_DRAIN;
end;

-- FLUSH_CL_WAIT: wait until every L1D transaction has been answered
rule "MMU probe drained"
  mmu = W_DRAIN & credits = CREDITS & ebn = 0 & rqn = 0 & rsn = 0 & !vbuf_full
==>
begin mmu := W_READ; end;

rule "MMU reads PTE line from the L2"
  mmu = W_READ & !vbuf_full
==>
var w: WayOrMiss;
begin
  w := l2_way(0);
  if w = 2 then l2_alloc(0, mem[0], false, w); endif;
  lru := w;
  -- a walk racing a concurrent PTE store (no sfence.vma) may legally see the older PTE
  if MMU_CONCURRENT = 0 then
    assert l2[w].d.v = latest[0].v "PAGE WALK READ A STALE PTE";
  endif;
  if PMH_EVICT_RMW = 1 then mmu := W_MEVICT; else mmu := W_MARK; endif;
end;

-- PMH_EVICT_RMW step 1 (L1D FLUSH_CL entry): only once the L1D has drained
-- (w_queues_drained) and has no refill outstanding; then evict the PTE line -- a dirty copy
-- goes out as a MEM_SW, both cases invalidate -- and freeze the L1D (FLUSH_CL_WAIT).
rule "PMH: L1D evicts the PTE line"
  PMH_EVICT_RMW = 1 & mmu = W_MEVICT & ebn = 0 & rqn = 0 & rsn = 0 & credits = CREDITS & !cwait &
  (dma = D_IDLE | dma = D_ACKED)
==>
begin
  if l1d.st != L_I & l1d.tag = 0 then
    if l1d.st = L_VD then
      rq_push(M_SW, 0, l1d.d);
      credits := credits - 1;
    endif;
    l1d.st := L_I; l1d.tag := 0; l1d.d.v := 0; l1d.d.a := false;
  endif;
  mmu := W_MDRAIN;
end;

-- step 2: the eviction's writeback has been answered -> the L1D acks; the L2 pipe does the
-- RMW directly on that ack, before granting any other L1D request, then acks the PMH
-- negative control: the L1D ack and the L2 RMW are separate steps; the L1D is unfrozen and
-- the L2 may grant L1D requests in between
rule "PMH (gap): eviction drained -> L1D acks"
  PMH_EVICT_RMW = 1 & PMH_RMW_GAP = 1 & mmu = W_MDRAIN & rqn = 0 & rsn = 0 & credits = CREDITS
==>
begin mmu := W_MGAP; end;

rule "PMH (gap): L2 RMW later"
  PMH_EVICT_RMW = 1 & PMH_RMW_GAP = 1 & mmu = W_MGAP & !vbuf_full
==>
var w: WayOrMiss;
begin
  w := l2_way(0);
  if w = 2 then l2_alloc(0, mem[0], false, w); endif;
  l2[w].d.a := true; l2[w].dirty := true; lru := w;
  latest[0].a := true;
  mmu := W_IDLE;
end;

rule "PMH: eviction drained -> L2 RMW + ack"
  PMH_EVICT_RMW = 1 & PMH_RMW_GAP = 0 & mmu = W_MDRAIN & rqn = 0 & rsn = 0 & credits = CREDITS & !vbuf_full
==>
var w: WayOrMiss;
begin
  assert !(l1d.st != L_I & l1d.tag = 0) "PMH RMW WITH A COPY STILL IN THE L1D";
  assert !eb_has(0) "PMH RMW WITH A COPY STILL IN THE EVICTION BUFFER";
  w := l2_way(0);
  if w = 2 then l2_alloc(0, mem[0], false, w); endif;
  l2[w].d.a := true; l2[w].dirty := true; lru := w;
  latest[0].a := true;
  mmu := W_IDLE;
end;

-- FIX_MARK_COHERENT, dirty case: write the L1D copy back and invalidate it, then wait for
-- the writeback to land before the RMW (the rule below needs the channel drained)
rule "MMU MARK_PTE: evict dirty L1D copy first"
  FIX_MARK_COHERENT = 1 & mmu = W_MARK & l1d.st = L_VD & l1d.tag = 0 & credits > 0 & rqn < QSZ
==>
begin
  rq_push(M_SW, 0, l1d.d);
  credits := credits - 1;
  l1d.st := L_I; l1d.tag := 0; l1d.d.v := 0; l1d.d.a := false;
end;

-- MARK_PTE: A-bit RMW in the L2 -- NOT probed in the RTL; the L1D may hold a copy
rule "MMU MARK_PTE in the L2"
  mmu = W_MARK & !vbuf_full &
  (FIX_MARK_COHERENT = 0 |
   (!(l1d.st = L_VD & l1d.tag = 0) & !eb_has(0) & rqn = 0 & rsn = 0 & credits = CREDITS &
    !(cop != C_IDLE & cwait & caddr = 0)))
==>
var w: WayOrMiss;
begin
  w := l2_way(0);
  if w = 2 then
    if FIX_MARK_MISS = 1 then
      l2_alloc(0, mem[0], false, w);
    else
      error "MARK_PTE MISSED IN THE L2: RTL replay type hits $stop / MMU hangs (H3)";
    endif;
  endif;
  if FIX_MARK_COHERENT = 1 & l1d.st = L_V & l1d.tag = 0 then
    -- clean L1D copy: invalidate it in the same atomic step as the RMW
    l1d.st := L_I; l1d.tag := 0; l1d.d.v := 0; l1d.d.a := false;
  endif;
  l2[w].d.a := true; l2[w].dirty := true; lru := w;
  latest[0].a := true;
  mmu := W_IDLE;
end;

------------------------------------------------------------------ DMA via the external probe
ruleset a: Addr do
  rule "DMA-in: request the external probe"
    DMA = 1 & a != 0 & dma = D_IDLE & !probe_busy() & fence = F_IDLE & latest[a].v < MAXV &
    !(cop = C_ST & caddr = a)
  ==>
  begin dma := D_PROBE; daddr := a; dout := false; end;

  rule "DMA-out: request the external probe"
    DMA = 1 & DMA_OUT = 1 & a != 0 & dma = D_IDLE & !probe_busy() & fence = F_IDLE &
    !(cop = C_ST & caddr = a)
  ==>
  begin dma := D_PROBE; daddr := a; dout := true; end;
endruleset;

-- nu_l1d FLUSH_CL, entered only once the L1D has drained (w_queues_drained, mem_q_empty):
-- a dirty hit goes out as a port-1 MEM_SW and is invalidated (t_mark_invalid), a clean hit
-- is invalidated; the L1D then sits in FLUSH_CL_WAIT until drained
rule "external probe: L1D FLUSH_CL"
  dma = D_PROBE & !probe_busy() & ebn = 0 & rqn = 0 & rsn = 0 & credits = CREDITS & !cwait
==>
begin
  if l1d.st != L_I & l1d.tag = daddr then
    if l1d.st = L_VD then
      rq_push(M_SW, daddr, l1d.d);
      credits := credits - 1;
    endif;
    l1d.st := L_I; l1d.tag := 0; l1d.d.v := 0; l1d.d.a := false;
  endif;
  dma := D_DRAIN;
end;

-- FLUSH_CL_WAIT -> ack.  DMA_GATE=1: the DMA write (or read) is done in the same step.
rule "external probe drained -> ack"
  DMA_ACK_BUG = 0 & dma = D_DRAIN & rqn = 0 & rsn = 0 & credits = CREDITS & !vbuf_full
==>
var w: WayOrMiss; d: Data;
begin
  if dout then
    w := l2_way(daddr);
    if w != 2 then d := l2[w].d; else d := mem[daddr]; endif;
    assert d.v = latest[daddr].v "DEVICE READ STALE DATA (DMA-out)";
    dma := D_IDLE;
  elsif DMA_GATE = 1 then
    assert !(l1d.st != L_I & l1d.tag = daddr) "DMA WRITE WITH A COPY STILL IN THE L1D";
    dma_write();
    dma := D_IDLE;
  else
    dma := D_ACKED;
  endif;
end;

rule "DMA write after the ack (ungated)"
  DMA_GATE = 0 & dma = D_ACKED & !vbuf_full
==>
begin
  dma_write();
  dma := D_IDLE;
end;

------------------------------------------------------------------ fence.i / WB_CACHES
rule "fence.i starts (ROB empty, miss queue empty)"
  FENCE = 1 & fence = F_IDLE & cop = C_IDLE & mmu = W_IDLE
==>
begin fence := F_L1D; end;

-- L1D FLUSH_CACHE: the dirty line goes to the eviction buffer, the line is invalidated
rule "fence: L1D flush"
  fence = F_L1D & (l1d.st != L_VD | ebn < EBSZ)
==>
begin
  fence_rsp := false;
  if l1d.st = L_VD then
    -- dirty: push to the EB and wait in FLUSH_CACHE_LAST_WAIT for a response
    eb[ebn].addr := l1d.tag; eb[ebn].d := l1d.d; ebn := ebn + 1;
    fence := F_L1D_WAIT;
  elsif FIX_FLUSH_DRAIN = 1 then
    -- FIX: even a clean flush waits for the EB / in-flight writebacks to reach the L2
    fence := F_L1D_WAIT;
  else
    -- clean: FLUSH_CACHE finishes at once (flush_complete) -- the EB may still hold a
    -- dirty victim from an earlier miss (fence entry only needs "EB not full")
    fence := F_L2;
  endif;
  l1d.st := L_I; l1d.tag := 0; l1d.d.v := 0; l1d.d.a := false;
end;

-- FLUSH_CACHE_LAST_WAIT: the RTL advances on ANY L2 response (not necessarily the ack of
-- its own writeback).  FIX: wait until every L1D transaction has been answered.
rule "fence: L1D flush complete"
  fence = F_L1D_WAIT &
  ((FIX_FLUSH_DRAIN = 0 & fence_rsp) |
   (FIX_FLUSH_DRAIN = 1 & FLUSH_WAIT_EB_ONLY = 0 & ebn = 0 & credits = CREDITS & rqn = 0 & rsn = 0) |
   (FIX_FLUSH_DRAIN = 1 & FLUSH_WAIT_EB_ONLY = 1 & ebn = 0))
==>
begin fence := F_L2; end;

-- L2 flush: write every dirty way back (and invalidate unless WB_NO_INV)
rule "fence: L2 flush"
  fence = F_L2 & !vbuf_full
==>
begin
  for w: 0..1 do
    if l2[w].valid & l2[w].dirty then
      mem[l2[w].tag] := l2[w].d;
      l2[w].dirty := false;
    endif;
    if WB_NO_INV = 0 then
      l2[w].valid := false; l2[w].dirty := false; l2[w].tag := 0; l2[w].d.v := 0; l2[w].d.a := false;
    endif;
  endfor;
  fence := F_L1I;
end;

rule "fence: L1I flush + complete"
  fence = F_L1I
==>
begin
  if WB_NO_INV = 0 then
    l1i_valid := false; l1i_tag := 0; l1i_d.v := 0; l1i_d.a := false;
  endif;
  for a: Addr do
    icoherent[a] := true;
    if CHECK_MEM_AT_FENCE = 1 then
      assert mem[a].v = latest[a].v "DRAM NOT UP TO DATE AFTER FLUSH (host readback)";
    endif;
  endfor;
  fence := F_IDLE;
end;

------------------------------------------------------------------ start + invariants
startstate "reset"
begin
  for a: Addr do
    latest[a].v := 0; latest[a].a := false;
    mem[a].v := 0; mem[a].a := false;
    icoherent[a] := false;
  endfor;
  l1d.st := L_I; l1d.tag := 0; l1d.d.v := 0; l1d.d.a := false;
  for i: 0..EBSZ-1 do eb[i].addr := 0; eb[i].d.v := 0; eb[i].d.a := false; endfor;
  ebn := 0;
  credits := CREDITS;
  for i: 0..QSZ-1 do
    rq[i].k := M_LW; rq[i].addr := 0; rq[i].d.v := 0; rq[i].d.a := false;
    rs[i].k := M_LW; rs[i].addr := 0; rs[i].d.v := 0; rs[i].d.a := false;
  endfor;
  rqn := 0; rsn := 0;
  for w: 0..1 do
    l2[w].valid := false; l2[w].dirty := false; l2[w].tag := 0; l2[w].d.v := 0; l2[w].d.a := false;
  endfor;
  lru := 0;
  vbuf_full := false; vbuf.addr := 0; vbuf.d.v := 0; vbuf.d.a := false;
  cop := C_IDLE; caddr := 0; cwait := false; ca_at_issue := false;
  l1i_valid := false; l1i_tag := 0; l1i_d.v := 0; l1i_d.a := false;
  mmu := W_IDLE;
  fence := F_IDLE;
  fence_rsp := false;
  dma := D_IDLE; daddr := 0; dout := false; cload_inwin := false;
end;

invariant "L1D dirty implies valid"
  l1d.st = L_VD -> l1d.st != L_I;

invariant "credits account for every in-flight L1D transaction"
  credits + rqn + rsn <= CREDITS;

-- every line's latest value exists somewhere in the hierarchy (no silent loss)
invariant "latest value is held somewhere"
  forall a: Addr do
    (l1d.st = L_VD & l1d.tag = a & l1d.d.v = latest[a].v) |
    (exists i: 0..EBSZ-1 do i < ebn & eb[i].addr = a & eb[i].d.v = latest[a].v endexists) |
    (exists i: 0..QSZ-1 do i < rqn & rq[i].k = M_SW & rq[i].addr = a & rq[i].d.v = latest[a].v endexists) |
    (exists w: 0..1 do l2[w].valid & l2[w].tag = a & l2[w].d.v = latest[a].v endexists) |
    (vbuf_full & vbuf.addr = a & vbuf.d.v = latest[a].v) |
    mem[a].v = latest[a].v
  endforall;
