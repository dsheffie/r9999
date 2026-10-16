-- r9999_incl.m -- r9999 cache hierarchy (main 3b78e9b) + an INCLUSIVE L2 with L2->L1
-- back-invalidate probes (branch inclusive-l2-v2, step 2).  INCL=0 reproduces main
-- (r9999_main.m, but with per-L1 request/response slots -- see below).
-- GENERATED from r9999_main.m by gen/make_incl.py; edit the generator, not this file.
-- RTL extract: r9999_main_l1_extract.md (L1D/L1I/arbiter); l2.sv read directly.
--
-- Structure modeled (all RTL facts, anchors in the extract):
--   * The arbiter (core_l1d_l1i.sv:726-779) LATCHES each L1's request separately and grants
--     one at a time, holding the grant until the L2 responds; each L1 has at most one
--     request outstanding.  -> one request slot PER L1; the L2 accepts either when IDLE.
--     (An L1D victim MEM_SW can sit latched while the L2 works on an L1I miss that evicts
--     that very line -- exactly the window a back-invalidate must handle.)
--   * L2 = serial FSM (l2.sv).  A cacheable MEM_SW is acked AT ACCEPT (l2.sv:572) and the
--     write lands later; the next request is not accepted until IDLE.  Everything else
--     responds when done.  -> l2 work record + rsp slot; accept needs IDLE and rsp empty.
--   * L1D miss with a dirty victim is serial: MEM_SW(victim) (line stays VD until the ack;
--     the ack's inhibit-write invalidates it, l1d.sv:1700-1751), then MEM_LW(refill).
--   * NADDR addresses all collide in the one L1D set and L1I set, but NOT all in one L2 set.
--     The L1s are PA-indexed (a writeback rebuilds the PA from r_cache_idx) and the L2 has
--     8x the sets, so an L2-set collision implies an L1-set collision but NOT the converse:
--     an L1D victim and the line replacing it usually live in DIFFERENT L2 sets, so a dirty
--     victim survives in the L2.  L2SETS=2: the last address has its own L2 set, the others
--     share set 0.  (L2SETS=1 collapses everything and hides every dirty-L2-line bug.)
--     While the L1D works on a miss its (only) set is frozen = r_fill_conflict2.
--   * L2 line has SEPARATE valid/dirty bits: MEM_WB clears valid only (l2.sv:719), so
--     need_wb = valid & dirty (l2.sv:235) and a refill writes dirty=0 (l2.sv:815).
--
-- Inclusion protocol (INCL=1): before the L2 drops or evicts a VALID line -- miss victim,
-- MEM_INVL/MEM_WB/MEM_PGDROP hit, uncached purge, flush walk -- it sends a probe for that
-- line to BOTH L1s and waits for both acks.  An L1 invalidates the line if it holds it and
-- acks, returning the data if it was dirty (L1D); the L2 merges dirty data into its copy
-- (dirty) and then proceeds exactly as main does.  The L1's ack never depends on the L1's
-- own FSM (a probe is handled whatever the L1 is waiting on).
--
-- Checked: loads (cached, uncached) see the latest value; a fetch after an I-sync sees the
-- latest value; a DMA-out device read sees the latest value; inclusion invariants.
--
-- Knobs
--   L1I            model the instruction cache (0 = data side only, smaller state space)
--   DMA            model DMA-in/out with the silicon ARM page flush (XPG_WBINV before,
--                  XPG_INV after a DMA-in; XPG_WBINV before a DMA-out)
--   SPEC_FILL      wrong-path loads may fill a line inside its DMA-in window
--   CHECK_INCL_D   invariant: a valid L1D line is present in the L2
--   CHECK_INCL_I   invariant: a valid L1I line is present in the L2
--   INCL           inclusive L2 with back-invalidate probes
--   RSP_DECOUPLED  the L2 may accept the next request while a response is still undelivered
--                  (a pipelined response path); RTL today installs the fill the same cycle
--   PROBE_ORDERED  an L1 consumes any pending response to it before it handles a probe
--                  (probes travel behind responses on one ordered channel)
--   CHECK_RULES    0 = drop the pure check rules (load hit / fetch hit / idle I-sync) that are
--                  always enabled self-loops, so Murphi's deadlock detection can see a deadlock
--   L1I_TAGONLY    the L1I keeps line/fill/probe behaviour but no data and no fetch-coherence
--                  ghosts (inclusion only needs its tag/valid; fetch coherence is proven
--                  on main); the ghosts are also dropped when L1I=0
--   DMA_SNOOP      DMA coherence by L2 snoop ops queued by the ARM (pre SNP_WBINV, post
--                  SNP_DROP, completion after the drop) instead of core-run XPG page walks
--   BUG_SNOOP_NO_PRE / BUG_SNOOP_EARLY_DONE   skip the pre-snoop / signal completion at
--                  post-snoop issue                                          -- MUST fail
--   BUG_SNOOP_NO_ABSORB  the snoop ignores an L1D writeback (MEM_WB/MEM_SW) to the same
--                  line that is LATCHED in the arbiter: the L1D already gave up the line
--                  (probe says "not here") but its dirty data is still in transit -- MUST fail
--   PRES           per-L2-line presence bits (pd/pi); probe only an L1 that may hold the line
--   BUG_PRES_NOSET_I  an L1I fill forgets to set pi                              -- MUST fail
--   BUG_PROBE_BLOCKED  the L1D only answers a probe when idle (the summer's blocking-handshake
--                  deadlock: L2 waits for the ack, L1D waits for the L2)  -- MUST deadlock
--   negative controls (each re-introduces a bug fixed in the RTL; each MUST fail):
--   BUG_NEEDWB_DIRTY   L2 evicts on dirty alone (pre-fix l2.sv:746 comment)
--   BUG_RELOAD_DIRTY   L2 refill keeps a stale dirty bit (pre-fix l2.sv:811 comment)
--   BUG_INVL_NO_WB     MEM_INVL drops a dirty L2 line without writing it back (l2.sv:629)
--   BUG_VICTIM_DROP    L1D drops a dirty victim without the MEM_SW

const
  NADDR: 3;
  L2SETS: 2;
  MAXV: 2;

  L1I: 1;
  DMA: 1;
  SPEC_FILL: 1;
  CHECK_INCL_D: 1;
  CHECK_INCL_I: 1;
  INCL: 1;
  RSP_DECOUPLED: 0;
  PROBE_ORDERED: 1;
  CHECK_RULES: 1;
  BUG_PROBE_BLOCKED: 0;
  L1I_TAGONLY: 0;
  PRES: 0;
  DMA_SNOOP: 0;
  BUG_SNOOP_NO_PRE: 0;
  BUG_SNOOP_EARLY_DONE: 0;
  BUG_SNOOP_NO_ABSORB: 0;
  BUG_PRES_NOSET_I: 0;

  BUG_NEEDWB_DIRTY: 0;
  BUG_RELOAD_DIRTY: 0;
  BUG_INVL_NO_WB: 0;
  BUG_VICTIM_DROP: 0;

type
  Addr: 0..NADDR-1;
  Ver: 0..MAXV;
  LState: enum {L_I, L_V, L_VD};
  Src: enum {S_D, S_I};
  -- L1->L2 opcodes (l2.sv): LW=4, SW=7 (cacheable or uncached), WB, INVL, PGDROP
  Op: enum {OP_LW, OP_SW, OP_ULW, OP_USW, OP_WB, OP_INVL, OP_PGDROP, OP_SNP_WBINV, OP_SNP_DROP};
  Snp: record full: boolean; op: Op; a: Addr; end;
  Req: record full: boolean; src: Src; op: Op; a: Addr; d: Ver; end;
  Rsp: record full: boolean; dst: Src; d: Ver; end;
  -- L2 FSM steps for one accepted request
  L2St: enum {L2_IDLE, L2_CHECK, L2_RELOAD, L2_UPURGE, L2_UNC, L2_PROBE, L2_FLUSH};
  Probe: record full: boolean; a: Addr; end;
  PAck: record full: boolean; dirty: boolean; d: Ver; end;
  L2Line: record valid: boolean; dirty: boolean; tag: Addr; d: Ver; pd: boolean; pi: boolean; end;
  L2Set: 0..L2SETS-1;
  L1Line: record st: LState; tag: Addr; d: Ver; end;
  -- L1D FSM
  DSt: enum {D_IDLE, D_VICT, D_RELOAD, D_FILL, D_OP, D_UNC_WB, D_UNC_ISSUE, D_UNC, D_FLUSH_WB, D_FLUSH_L2};
  DKind: enum {K_LOAD, K_STORE, K_SPEC};
  DOp: enum {CO_CHWB, CO_CHINV, CO_XPG_WBINV, CO_XPG_INV, CO_ULOAD, CO_USTORE, CO_NONE};
  DmaSt: enum {DM_IDLE, DM_IN_PRE, DM_IN_ARMED, DM_IN_DONE, DM_IN_DROP, DM_OUT_PRE, DM_OUT_ARMED};

var
  latest: array[Addr] of Ver;          -- ghost: architecturally latest value
  dclean: array[Addr] of boolean;      -- ghost: a D-writeback of a completed since the last write
  icoh: array[Addr] of boolean;        -- ghost: an I-sync made the I-side see the current value
  mem: array[Addr] of Ver;

  req: array[Src] of Req;              -- each L1's latched request
  rsp: array[Src] of Rsp;              -- L2 -> L1 responses
  prb: array[Src] of Probe;            -- L2 -> L1 back-invalidate probes
  pack: array[Src] of PAck;            -- L1 -> L2 probe acks
  pexp: array[Src] of boolean;         -- probe outstanding to this L1
  snp: Snp;                            -- ARM -> L2 DMA snoop request

  l2: array[L2Set] of L2Line;
  l2st: L2St;
  w: Req;                              -- the request the L2 is working on
  wacked: boolean;                     -- w was early-acked (cacheable MEM_SW)
  probed: boolean;                     -- the line this step drops/evicts has been probed
  pa: Addr;                            -- the line being probed
  pret: L2St;                          -- where the L2 resumes after the probe
  fset: L2Set;                         -- flush walk position

  l1d: L1Line;
  dst: DSt;
  dkind: DKind;
  da: Addr;                            -- the L1D's pending address
  dop: DOp;
  dsd: Ver;                            -- the pending uncached store's value

  l1i: L1Line;
  ifill: boolean;  ia: Addr;

  dma: DmaSt; daddr: Addr;

------------------------------------------------------------------ helpers
function fetch_ghosts(): boolean;
begin return L1I = 1 & L1I_TAGONLY = 0; end;

function dhit(a: Addr): boolean;
begin return l1d.st != L_I & l1d.tag = a; end;

function ihit(a: Addr): boolean;
begin return l1i.st != L_I & l1i.tag = a; end;

function l2set(a: Addr): L2Set;
begin
  if L2SETS = 2 & a = NADDR-1 then return 1; endif;
  return 0;
end;

function l2hit(a: Addr): boolean;
begin return l2[l2set(a)].valid & l2[l2set(a)].tag = a; end;

function need_wb(s: L2Set): boolean;
begin
  if BUG_NEEDWB_DIRTY = 1 then return l2[s].dirty; endif;
  return l2[s].valid & l2[s].dirty;
end;

-- a DMA-in window on a: the device may write DRAM; the core must not use the line
function in_window(a: Addr): boolean;
begin return (dma = DM_IN_PRE | dma = DM_IN_ARMED | dma = DM_IN_DONE | dma = DM_IN_DROP) & daddr = a; end;

function dout_window(a: Addr): boolean;
begin return (dma = DM_OUT_PRE | dma = DM_OUT_ARMED) & daddr = a; end;

procedure issue(s: Src; o: Op; a: Addr; d: Ver);
begin
  assert !req[s].full "L1 issued a second request";
  req[s].full := true; req[s].src := s; req[s].op := o; req[s].a := a; req[s].d := d;
end;


function rsp_free(s: Src): boolean;
begin
  -- RTL: the fill installs in the response cycle, so nothing new is accepted while ANY
  -- response is undelivered; RSP_DECOUPLED relaxes that to the requester's own slot
  if RSP_DECOUPLED = 1 then return !rsp[s].full; endif;
  return !rsp[S_D].full & !rsp[S_I].full;
end;

function must_probe(): boolean;
begin
  return INCL = 1 & !probed;
end;

procedure send_probes(a: Addr; ret: L2St);
begin
  pexp[S_D] := PRES = 0 | l2[l2set(a)].pd;
  pexp[S_I] := L1I = 1 & (PRES = 0 | l2[l2set(a)].pi);
  if pexp[S_D] then prb[S_D].full := true; prb[S_D].a := a; endif;
  if pexp[S_I] then prb[S_I].full := true; prb[S_I].a := a; endif;
  pa := a; pret := ret;
  if pexp[S_D] | pexp[S_I] then
    l2st := L2_PROBE;
  else
    probed := true; l2st := ret;               -- nobody may hold it: no probe
  endif;
end;

procedure core_write(a: Addr);
begin
  latest[a] := latest[a] + 1;
  if fetch_ghosts() then
    dclean[a] := false;
    icoh[a] := false;
  endif;
end;

-- the L1D's handling of an L2 response (l1d.sv: mem_rsp_valid)
procedure d_rsp(d: Ver);
begin
  switch dst
  case D_VICT:
    l1d.st := L_I;                                   -- inhibit-write ack invalidates
    dst := D_RELOAD;
  case D_FILL:
    l1d.st := L_V; l1d.tag := da; l1d.d := d;
    if dkind = K_LOAD then
      assert d = latest[da] "load miss returned a stale value";
    elsif dkind = K_STORE then
      core_write(da);
      l1d.d := latest[da]; l1d.st := L_VD;
    endif;
    dst := D_IDLE;
  case D_OP:
    if dop = CO_XPG_INV then
      dma := DM_IDLE;                                -- completion signalled after the drop
    endif;
    if dop = CO_CHWB then
      -- MEM_WB / MEM_INVL done: if the line was not re-dirtied, DRAM holds latest
      if fetch_ghosts() then dclean[da] := true; endif;
    endif;
    dst := D_IDLE;
  case D_UNC_WB:
    dst := D_UNC_ISSUE;                              -- now the uncached op
  case D_UNC:
    if dop = CO_ULOAD then
      assert d = latest[da] "uncached load returned a stale value";
    endif;
    dst := D_IDLE;
  case D_FLUSH_WB:
    l1d.st := L_I;
    dst := D_FLUSH_L2;
  else
    error "unexpected L1D response";
  endswitch;
end;

-- the L1I fill
procedure i_rsp(d: Ver);
begin
  assert ifill "L1I response without a miss";
  l1i.st := L_V; l1i.tag := ia;
  if L1I_TAGONLY = 0 then l1i.d := d; endif;
  ifill := false;
end;

-- RSP_DECOUPLED=0: delivered in this same step (the RTL installs the fill in the
-- response cycle); =1: queued in the per-L1 response slot
procedure respond(s: Src; d: Ver);
begin
  if RSP_DECOUPLED = 0 then
    if s = S_D then d_rsp(d); else i_rsp(d); endif;
  else
    assert !rsp[s].full "response slot overrun";
    rsp[s].full := true; rsp[s].dst := s; rsp[s].d := d;
  endif;
end;

------------------------------------------------------------------ L2 (l2.sv)
ruleset s: Src do
  rule "L2 accept"
    req[s].full & l2st = L2_IDLE & rsp_free(s) & !snp.full
  ==>
  begin
    w := req[s]; req[s].full := false;
    wacked := false; probed := false;
    if w.op = OP_SW then
      respond(w.src, 0); wacked := true;         -- l2.sv:572 early ack
    endif;
    if w.op = OP_ULW | w.op = OP_USW then
      l2st := L2_UPURGE;
    else
      l2st := L2_CHECK;
    endif;
  end;
end;

-- uncached: purge an aliasing L2 line first (write back if dirty), l2.sv:587-614
rule "L2 uncached purge"
  l2st = L2_UPURGE
==>
begin
  if l2hit(w.a) & must_probe() then
    send_probes(w.a, L2_UPURGE);
  else
    if l2hit(w.a) then
      if l2[l2set(w.a)].dirty then mem[w.a] := l2[l2set(w.a)].d; endif;
      l2[l2set(w.a)].valid := false; l2[l2set(w.a)].dirty := false; l2[l2set(w.a)].pd := false; l2[l2set(w.a)].pi := false;
    endif;
    l2st := L2_UNC;
  endif;
end;

-- CHECK_VALID_AND_TAG
rule "L2 check"
  l2st = L2_CHECK & rsp_free(w.src)
==>
begin
  if (w.op = OP_INVL | w.op = OP_PGDROP | w.op = OP_WB | w.op = OP_SNP_WBINV | w.op = OP_SNP_DROP)
     & l2hit(w.a) & must_probe() then
    send_probes(w.a, L2_CHECK);
  elsif (w.op = OP_LW | w.op = OP_SW) & !l2hit(w.a) & l2[l2set(w.a)].valid & must_probe() then
    send_probes(l2[l2set(w.a)].tag, L2_CHECK);       -- the miss victim
  else
  switch w.op
  case OP_INVL:
    if l2hit(w.a) then
      if l2[l2set(w.a)].dirty & BUG_INVL_NO_WB = 0 then mem[w.a] := l2[l2set(w.a)].d; endif;
      l2[l2set(w.a)].valid := false; l2[l2set(w.a)].dirty := false; l2[l2set(w.a)].pd := false; l2[l2set(w.a)].pi := false;
    endif;
    respond(w.src, 0); l2st := L2_IDLE;
  case OP_PGDROP:
    if l2hit(w.a) then
      assert !l2[l2set(w.a)].dirty "PGDROP found a dirty L2 line (pre-transfer WBINV missed it)";
      l2[l2set(w.a)].valid := false; l2[l2set(w.a)].dirty := false; l2[l2set(w.a)].pd := false; l2[l2set(w.a)].pi := false;
    endif;
    respond(w.src, 0); l2st := L2_IDLE;
  case OP_SNP_WBINV:
    -- dirty data in TRANSIT: an L1D writeback to this line latched in the arbiter (e.g. a
    -- CHWB issued after the probe was sent: the L1D invalidated, so the probe ack said
    -- "not here").  Absorb it before finishing, or it lands after the device transfer.
    if BUG_SNOOP_NO_ABSORB = 0 & req[S_D].full & req[S_D].a = w.a
       & (req[S_D].op = OP_WB | req[S_D].op = OP_SW) then
      if l2hit(w.a) then
        l2[l2set(w.a)].d := req[S_D].d; l2[l2set(w.a)].dirty := true;
      else
        mem[w.a] := req[S_D].d;
      endif;
      req[S_D].full := false;
      respond(S_D, 0);                               -- the absorbed request completes
    endif;
    if l2hit(w.a) then
      if l2[l2set(w.a)].dirty then mem[w.a] := l2[l2set(w.a)].d; endif;
      l2[l2set(w.a)].valid := false; l2[l2set(w.a)].dirty := false;
      l2[l2set(w.a)].pd := false; l2[l2set(w.a)].pi := false;
    endif;
    if dma = DM_IN_PRE then dma := DM_IN_ARMED; endif;
    if dma = DM_OUT_PRE then dma := DM_OUT_ARMED; endif;
    l2st := L2_IDLE;
  case OP_SNP_DROP:
    assert !(req[S_D].full & req[S_D].a = w.a & (req[S_D].op = OP_WB | req[S_D].op = OP_SW))
      "CPU writeback to a DMA-in buffer in flight at the post-drop";
    if l2hit(w.a) then
      assert !l2[l2set(w.a)].dirty "DMA post-drop found dirty data (pre-snoop missed it)";
      l2[l2set(w.a)].valid := false; l2[l2set(w.a)].dirty := false;
      l2[l2set(w.a)].pd := false; l2[l2set(w.a)].pi := false;
    endif;
    if dma = DM_IN_DROP then dma := DM_IDLE; endif;      -- completion after the drop
    l2st := L2_IDLE;
  case OP_WB:
    mem[w.a] := w.d;
    if l2hit(w.a) then
      l2[l2set(w.a)].valid := false;
      l2[l2set(w.a)].pd := false; l2[l2set(w.a)].pi := false;
    endif;    -- valid only: dirty survives (l2.sv:719)
    respond(w.src, 0); l2st := L2_IDLE;
  case OP_LW, OP_SW:
    if l2hit(w.a) then
      if w.op = OP_LW then
        if PRES = 1 & w.src = S_D then
          l2[l2set(w.a)].pd := true;
        elsif PRES = 1 & BUG_PRES_NOSET_I = 0 then
          l2[l2set(w.a)].pi := true;
        endif;
        respond(w.src, l2[l2set(w.a)].d);
      else
        l2[l2set(w.a)].d := w.d; l2[l2set(w.a)].dirty := true;
        if w.src = S_D then l2[l2set(w.a)].pd := false; endif;
      endif;
      l2st := L2_IDLE;
    else
      if need_wb(l2set(w.a)) then
        mem[l2[l2set(w.a)].tag] := l2[l2set(w.a)].d;                         -- DIRTY_STORE
      endif;
      l2st := L2_RELOAD;
    endif;
  else
    error "bad L2 op";
  endswitch;
  endif;
end;

-- CLEAN_RELOAD: the DRAM read is a separate step so a DMA write can land on either side
rule "L2 reload"
  l2st = L2_RELOAD
==>
begin
  l2[l2set(w.a)].valid := true; l2[l2set(w.a)].tag := w.a; l2[l2set(w.a)].d := mem[w.a];
  l2[l2set(w.a)].pd := false; l2[l2set(w.a)].pi := false;
  if BUG_RELOAD_DIRTY = 0 then l2[l2set(w.a)].dirty := false; endif;
  l2st := L2_CHECK;                                  -- WAIT_CLEAN_RELOAD -> WAIT_FOR_RAM
end;

rule "L2 uncached DRAM access"
  l2st = L2_UNC & rsp_free(w.src)
==>
begin
  if w.op = OP_USW then
    mem[w.a] := w.d;
    respond(w.src, 0);
  else
    respond(w.src, mem[w.a]);
  endif;
  l2st := L2_IDLE;
end;

-- DMA snoop from the ARM: taken in IDLE ahead of L1 requests
rule "L2 accept snoop"
  snp.full & l2st = L2_IDLE & rsp_free(S_D) & rsp_free(S_I)
==>
begin
  w.full := true; w.src := S_D; w.op := snp.op; w.a := snp.a; w.d := 0;
  snp.full := false;
  wacked := false; probed := false;
  l2st := L2_CHECK;
end;

-- all probe acks in: merge a dirty L1D copy (newer than the L2's) and resume
rule "L2 probe acks in"
  l2st = L2_PROBE & (!pexp[S_D] | pack[S_D].full) & (!pexp[S_I] | pack[S_I].full)
==>
begin
  assert l2hit(pa) "probed line left the L2 during the probe";
  assert !pack[S_I].dirty "L1I returned dirty data";
  if pack[S_D].dirty then
    l2[l2set(pa)].d := pack[S_D].d; l2[l2set(pa)].dirty := true;
  endif;
  pack[S_D].full := false; pack[S_I].full := false;
  pexp[S_D] := false; pexp[S_I] := false;
  l2[l2set(pa)].pd := false; l2[l2set(pa)].pi := false;   -- both L1s just dropped it
  pack[S_D].dirty := false; pack[S_D].d := 0;
  probed := true;
  l2st := pret;
end;

-- whole-L2 flush walk (FLUSH_WAIT/FLUSH_TRIAGE/FLUSH_STORE), only after the L1D flush; it
-- is taken in IDLE ahead of L1 requests (l2.sv:526)
rule "L2 flush: start"
  dst = D_FLUSH_L2 & l2st = L2_IDLE & rsp_free(S_D) & rsp_free(S_I)
==>
begin
  fset := 0; probed := false;
  l2st := L2_FLUSH;
end;

rule "L2 flush: one set"
  l2st = L2_FLUSH
==>
begin
  if l2[fset].valid & must_probe() then
    send_probes(l2[fset].tag, L2_FLUSH);
  else
    if need_wb(fset) then mem[l2[fset].tag] := l2[fset].d; endif;
    l2[fset].valid := false; l2[fset].dirty := false;
    l2[fset].pd := false; l2[fset].pi := false;
    probed := false;
    if fset = L2SETS-1 then
      l2st := L2_IDLE; dst := D_IDLE;
    else
      fset := fset + 1;
    endif;
  endif;
end;

------------------------------------------------------------------ L1D (l1d.sv)
ruleset a: Addr do
  rule "load hit"
    CHECK_RULES = 1 & dst = D_IDLE & dhit(a) & !in_window(a)
  ==>
  begin
    assert l1d.d = latest[a] "load hit returned a stale value";
  end;

  rule "store hit (commit)"
    dst = D_IDLE & dhit(a) & !in_window(a) & !dout_window(a) & latest[a] < MAXV
  ==>
  begin
    core_write(a);
    l1d.d := latest[a]; l1d.st := L_VD;
  end;

  ruleset k: DKind do
    rule "L1D miss"
      dst = D_IDLE & !dhit(a) & !req[S_D].full
      & (k = K_SPEC ? (SPEC_FILL = 1 & in_window(a)) : !in_window(a))
      & !(k = K_STORE & (dout_window(a) | latest[a] = MAXV))
    ==>
    begin
      dkind := k; da := a;
      if l1d.st = L_VD & BUG_VICTIM_DROP = 0 then
        issue(S_D, OP_SW, l1d.tag, l1d.d);           -- victim first, line stays VD
        dst := D_VICT;
      else
        l1d.st := L_I;                               -- clean (or dropped) victim
        issue(S_D, OP_LW, a, 0);
        dst := D_FILL;
      endif;
    end;
  end;

  -- CACHE hit ops (l1d.sv CHOP path): dirty hit & !CHINV -> MEM_WB, else
  -- invalidate-if-hit + MEM_INVL.  CHWB behaves like CHWBINV.
  ruleset o: DOp do
    rule "CACHE hit op"
      dst = D_IDLE & !req[S_D].full & (o = CO_CHWB | o = CO_CHINV) & !in_window(a)
      -- Hit_Invalidate DISCARDS dirty data by definition; software only uses it on a
      -- buffer it is about to overwrite, so never on a line holding the only latest copy
      & !(o = CO_CHINV & dhit(a) & l1d.st = L_VD)
    ==>
    begin
      dop := o; da := a;
      if o = CO_CHWB & dhit(a) & l1d.st = L_VD then
        issue(S_D, OP_WB, a, l1d.d);
      else
        issue(S_D, OP_INVL, a, 0);
      endif;
      if dhit(a) then l1d.st := L_I; endif;
      dst := D_OP;
    end;
  end;

  -- uncached access to a (kseg1 alias): the L1D drops an aliasing line first
  -- (MEM_SW if dirty), then the L2 purges its copy and goes to DRAM.
  rule "uncached load"
    dst = D_IDLE & !req[S_D].full & !in_window(a)
  ==>
  begin
    dop := CO_ULOAD; da := a;
    if dhit(a) & l1d.st = L_VD then
      issue(S_D, OP_SW, a, l1d.d); l1d.st := L_I; dst := D_UNC_WB;
    else
      if dhit(a) then l1d.st := L_I; endif;
      issue(S_D, OP_ULW, a, 0); dst := D_UNC;
    endif;
  end;

  rule "uncached store"
    dst = D_IDLE & !req[S_D].full & !in_window(a) & !dout_window(a) & latest[a] < MAXV
  ==>
  begin
    dop := CO_USTORE; da := a;
    core_write(a); dsd := latest[a];
    if dhit(a) & l1d.st = L_VD then
      issue(S_D, OP_SW, a, l1d.d); l1d.st := L_I; dst := D_UNC_WB;
    else
      if dhit(a) then l1d.st := L_I; endif;
      issue(S_D, OP_USW, a, dsd); dst := D_UNC;
    endif;
  end;
end;

rule "L1D: response"
  rsp[S_D].full
==>
var d: Ver;
begin
  d := rsp[S_D].d; rsp[S_D].full := false;
  d_rsp(d);
end;

-- HANDLE_RELOAD: after the victim ack the lookup repeats, misses cleanly, sends MEM_LW
rule "L1D: reload after victim"
  dst = D_RELOAD & !req[S_D].full
==>
begin
  issue(S_D, OP_LW, da, 0);
  dst := D_FILL;
end;

-- after the alias writeback (early-acked MEM_SW) the uncached op itself goes out
rule "L1D: issue uncached after alias wb"
  dst = D_UNC_ISSUE & !req[S_D].full
==>
begin
  if dop = CO_USTORE then issue(S_D, OP_USW, da, dsd); else issue(S_D, OP_ULW, da, 0); endif;
  dst := D_UNC;
end;

------------------------------------------------------------------ whole-cache flush
-- CACHE_FLUSH: L1D walk (dirty -> MEM_SW, invalidated on the ack; clean -> invalidate),
-- then the chained L2 flush walk.  L1I flushed as part of the sequence.
rule "CACHE_FLUSH: L1D walk"
  dst = D_IDLE & !req[S_D].full & !ifill
==>
begin
  if l1d.st = L_VD then
    issue(S_D, OP_SW, l1d.tag, l1d.d);
    dst := D_FLUSH_WB;
  else
    l1d.st := L_I;
    dst := D_FLUSH_L2;
  endif;
  l1i.st := L_I;
end;

------------------------------------------------------------------ L1I (l1i.sv)
ruleset a: Addr do
  rule "fetch hit"
    CHECK_RULES = 1 & fetch_ghosts() & ihit(a) & icoh[a] & !in_window(a)
  ==>
  begin
    assert l1i.d = latest[a] "fetch returned stale instructions after an I-sync";
  end;

  rule "L1I miss"
    L1I = 1 & !ifill & !ihit(a) & !req[S_I].full & (!in_window(a) | SPEC_FILL = 1)
  ==>
  begin
    l1i.st := L_I; ifill := true; ia := a;
    issue(S_I, OP_LW, a, 0);
  end;
end;

rule "L1I: fill"
  rsp[S_I].full
==>
var d: Ver;
begin
  d := rsp[S_I].d; rsp[S_I].full := false;
  i_rsp(d);
end;

------------------------------------------------------------------ probes (INCL)
rule "L1D: probe"
  prb[S_D].full & !pack[S_D].full
  & (BUG_PROBE_BLOCKED = 0 | dst = D_IDLE)
  & (PROBE_ORDERED = 0 | !rsp[S_D].full)
==>
begin
  pack[S_D].full := true; pack[S_D].dirty := false; pack[S_D].d := 0;
  if dhit(prb[S_D].a) then
    if l1d.st = L_VD then pack[S_D].dirty := true; pack[S_D].d := l1d.d; endif;
    l1d.st := L_I;
  endif;
  prb[S_D].full := false;
end;

rule "L1I: probe"
  prb[S_I].full & !pack[S_I].full
  & (PROBE_ORDERED = 0 | !rsp[S_I].full)
==>
begin
  pack[S_I].full := true; pack[S_I].dirty := false; pack[S_I].d := 0;
  if ihit(prb[S_I].a) then l1i.st := L_I; endif;
  prb[S_I].full := false;
end;

-- IRIX I-sync: (CHWB of the line done earlier, ghost dclean) then the I-side CACHE op
-- invalidates the L1I (deferred until any fill lands)
rule "I-sync: invalidate L1I"
  L1I = 1 & !ifill & (CHECK_RULES = 1 | l1i.st != L_I)
==>
begin
  l1i.st := L_I;
  -- software never executes a DMA-in buffer before the transfer completes (the XPG_INV
  -- drop runs before completion is signalled), so an I-sync does not cover a live window
  if fetch_ghosts() then
    for a: Addr do icoh[a] := dclean[a] & !in_window(a); endfor;
  endif;
end;

------------------------------------------------------------------ DMA + ARM page flush
-- silicon (EXTFLUSH+XFPAGES): the ARM pushes the touched pages; the core runs XPG_WBINV
-- before the transfer and XPG_INV (drop, no writeback) after a DMA-in, as injected
-- serializing uops (core drained: L1D idle).  l1d.sv FLUSH_PG: WBINV = dirty hit -> MEM_WB,
-- else invalidate-if-hit + MEM_INVL; INV = invalidate-if-hit + MEM_PGDROP.
ruleset a: Addr do
  rule "DMA-in: XPG_WBINV pre-flush"
    DMA = 1 & DMA_SNOOP = 0 & dma = DM_IDLE & dst = D_IDLE & !req[S_D].full
  ==>
  begin
    dop := CO_XPG_WBINV; da := a;
    if dhit(a) & l1d.st = L_VD then
      issue(S_D, OP_WB, a, l1d.d);
    else
      issue(S_D, OP_INVL, a, 0);
    endif;
    if dhit(a) then l1d.st := L_I; endif;
    dst := D_OP;
    dma := DM_IN_ARMED; daddr := a;
  end;

  rule "DMA-out: XPG_WBINV pre-flush"
    DMA = 1 & DMA_SNOOP = 0 & dma = DM_IDLE & dst = D_IDLE & !req[S_D].full
  ==>
  begin
    dop := CO_XPG_WBINV; da := a;
    if dhit(a) & l1d.st = L_VD then
      issue(S_D, OP_WB, a, l1d.d);
    else
      issue(S_D, OP_INVL, a, 0);
    endif;
    if dhit(a) then l1d.st := L_I; endif;
    dst := D_OP;
    dma := DM_OUT_ARMED; daddr := a;
  end;
end;

rule "DMA-in: device writes DRAM"
  dma = DM_IN_ARMED & (DMA_SNOOP = 1 | dst = D_IDLE) & latest[daddr] < MAXV
==>
begin
  latest[daddr] := latest[daddr] + 1;
  mem[daddr] := latest[daddr];
  if fetch_ghosts() then dclean[daddr] := true; icoh[daddr] := false; endif;
  dma := DM_IN_DONE;
end;

rule "DMA-in: XPG_INV post-drop"
  DMA_SNOOP = 0 & dma = DM_IN_DONE & dst = D_IDLE & !req[S_D].full
==>
begin
  dop := CO_XPG_INV; da := daddr;
  if dhit(daddr) then l1d.st := L_I; endif;
  issue(S_D, OP_PGDROP, daddr, 0);
  dst := D_OP;
  dma := DM_IN_DROP;
end;

rule "DMA-out: device reads DRAM"
  dma = DM_OUT_ARMED & (DMA_SNOOP = 1 | dst = D_IDLE)
==>
begin
  assert mem[daddr] = latest[daddr] "device read stale data (DMA-out)";
  dma := DM_IDLE;
end;

-- DMA_SNOOP: the ARM queues L2 snoops; the core is never stopped
ruleset a: Addr do
  -- the I/O is STARTED by the driver's device-register write, which executes only after
  -- the core's earlier stores have drained (wbflush/SYNC; uncached ops issue in order at
  -- the ROB head) -> start only with no CPU store in flight (dst = D_IDLE).  From then on
  -- the snoops run while the core keeps running.
  rule "DMA-in: ARM queues pre-snoop (SNP_WBINV)"
    DMA = 1 & DMA_SNOOP = 1 & dma = DM_IDLE & !snp.full & dst = D_IDLE
  ==>
  begin
    daddr := a;
    if BUG_SNOOP_NO_PRE = 1 then
      dma := DM_IN_ARMED;
    else
      snp.full := true; snp.op := OP_SNP_WBINV; snp.a := a;
      dma := DM_IN_PRE;
    endif;
  end;

  rule "DMA-out: ARM queues pre-snoop (SNP_WBINV)"
    DMA = 1 & DMA_SNOOP = 1 & dma = DM_IDLE & !snp.full & dst = D_IDLE
  ==>
  begin
    daddr := a;
    snp.full := true; snp.op := OP_SNP_WBINV; snp.a := a;
    dma := DM_OUT_PRE;
  end;
end;

rule "DMA-in: ARM queues post-drop (SNP_DROP)"
  DMA_SNOOP = 1 & dma = DM_IN_DONE & !snp.full
==>
begin
  snp.full := true; snp.op := OP_SNP_DROP; snp.a := daddr;
  if BUG_SNOOP_EARLY_DONE = 1 then
    dma := DM_IDLE;                                  -- completion before the drop ran
  else
    dma := DM_IN_DROP;
  endif;
end;

------------------------------------------------------------------ invariants
invariant "inclusion: L1D subset of L2"
  CHECK_INCL_D = 0 | l1d.st = L_I | l2hit(l1d.tag);

invariant "presence: an L1D-held line has pd set"
  INCL = 0 | PRES = 0 | l1d.st = L_I | (l2hit(l1d.tag) & l2[l2set(l1d.tag)].pd);

invariant "presence: an L1I-held line has pi set"
  INCL = 0 | PRES = 0 | L1I = 0 | l1i.st = L_I | (l2hit(l1i.tag) & l2[l2set(l1i.tag)].pi);

invariant "inclusion: L1I subset of L2"
  CHECK_INCL_I = 0 | l1i.st = L_I | l2hit(l1i.tag);

------------------------------------------------------------------ start
startstate
begin
  for a: Addr do latest[a] := 0; mem[a] := 0; icoh[a] := true; dclean[a] := true; endfor;
  for s: Src do
    req[s].full := false; req[s].src := s; req[s].op := OP_LW; req[s].a := 0; req[s].d := 0;
    rsp[s].full := false; rsp[s].dst := s; rsp[s].d := 0;
    prb[s].full := false; prb[s].a := 0;
    pack[s].full := false; pack[s].dirty := false; pack[s].d := 0;
    pexp[s] := false;
  endfor;
  w := req[S_D]; wacked := false; probed := false; pa := 0; pret := L2_IDLE;
  fset := 0;
  snp.full := false; snp.op := OP_SNP_DROP; snp.a := 0;
  for s: L2Set do
    l2[s].valid := false; l2[s].dirty := false; l2[s].tag := 0; l2[s].d := 0;
    l2[s].pd := false; l2[s].pi := false;
  endfor;
  l2st := L2_IDLE;
  l1d.st := L_I; l1d.tag := 0; l1d.d := 0;
  dst := D_IDLE; dkind := K_LOAD; da := 0; dop := CO_NONE; dsd := 0;
  l1i.st := L_I; l1i.tag := 0; l1i.d := 0;
  ifill := false; ia := 0;
  dma := DM_IDLE; daddr := 0;
end;
