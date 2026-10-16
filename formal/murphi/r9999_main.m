-- r9999_main.m -- Murphi model of the r9999 cache hierarchy at r9999 main 3b78e9b
-- (mem-sched merged; branch inclusive-l2-v2 starts here).  Step 1 of the inclusive-L2
-- work: model WHAT EXISTS, with explicit in-flight messages, then add L2->L1 messages.
-- RTL extract: r9999_main_l1_extract.md (L1D/L1I/arbiter); l2.sv read directly.
--
-- Structure modeled (all RTL facts, anchors in the extract):
--   * ONE L1->L2 transaction system-wide: the arbiter (core_l1d_l1i.sv:726-779) holds its
--     grant until the L2 responds; each L1 has at most one request outstanding.  -> req slot.
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
-- Checked: loads (cached, uncached) see the latest value; a fetch after an I-sync sees the
-- latest value; a DMA-out device read sees the latest value; optional inclusion invariants.
--
-- Knobs
--   L1I            model the instruction cache (0 = data side only, smaller state space)
--   DMA            model DMA-in/out with the silicon ARM page flush (XPG_WBINV before,
--                  XPG_INV after a DMA-in; XPG_WBINV before a DMA-out)
--   SPEC_FILL      wrong-path loads may fill a line inside its DMA-in window
--   CHECK_INCL_D   invariant: a valid L1D line is present in the L2
--   CHECK_INCL_I   invariant: a valid L1I line is present in the L2
--   negative controls (each re-introduces a bug fixed in the RTL; each MUST fail):
--   BUG_NEEDWB_DIRTY   L2 evicts on dirty alone (pre-fix l2.sv:746 comment)
--   BUG_RELOAD_DIRTY   L2 refill keeps a stale dirty bit (pre-fix l2.sv:811 comment)
--   BUG_INVL_NO_WB     MEM_INVL drops a dirty L2 line without writing it back (l2.sv:629)
--   BUG_VICTIM_DROP    L1D drops a dirty victim without the MEM_SW

const
  NADDR: 3;
  L2SETS: 2;
  MAXV: 3;

  L1I: 1;
  DMA: 1;
  SPEC_FILL: 1;
  CHECK_INCL_D: 0;
  CHECK_INCL_I: 0;

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
  Op: enum {OP_LW, OP_SW, OP_ULW, OP_USW, OP_WB, OP_INVL, OP_PGDROP};
  Req: record full: boolean; src: Src; op: Op; a: Addr; d: Ver; end;
  Rsp: record full: boolean; dst: Src; d: Ver; end;
  -- L2 FSM steps for one accepted request
  L2St: enum {L2_IDLE, L2_CHECK, L2_RELOAD, L2_UNC};
  L2Line: record valid: boolean; dirty: boolean; tag: Addr; d: Ver; end;
  L2Set: 0..L2SETS-1;
  L1Line: record st: LState; tag: Addr; d: Ver; end;
  -- L1D FSM
  DSt: enum {D_IDLE, D_VICT, D_RELOAD, D_FILL, D_OP, D_UNC_WB, D_UNC_ISSUE, D_UNC, D_FLUSH_WB, D_FLUSH_L2};
  DKind: enum {K_LOAD, K_STORE, K_SPEC};
  DOp: enum {CO_CHWB, CO_CHINV, CO_XPG_WBINV, CO_XPG_INV, CO_ULOAD, CO_USTORE, CO_NONE};
  DmaSt: enum {DM_IDLE, DM_IN_ARMED, DM_IN_DONE, DM_OUT_ARMED};

var
  latest: array[Addr] of Ver;          -- ghost: architecturally latest value
  dclean: array[Addr] of boolean;      -- ghost: a D-writeback of a completed since the last write
  icoh: array[Addr] of boolean;        -- ghost: an I-sync made the I-side see the current value
  mem: array[Addr] of Ver;

  req: Req;                            -- arbiter grant (one transaction system-wide)
  rsp: Rsp;                            -- L2 -> L1 response

  l2: array[L2Set] of L2Line;
  l2st: L2St;
  w: Req;                              -- the request the L2 is working on
  wacked: boolean;                     -- w was early-acked (cacheable MEM_SW)

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
begin return (dma = DM_IN_ARMED | dma = DM_IN_DONE) & daddr = a; end;

function dout_window(a: Addr): boolean;
begin return dma = DM_OUT_ARMED & daddr = a; end;

procedure issue(s: Src; o: Op; a: Addr; d: Ver);
begin
  assert !req.full "arbiter double grant";
  req.full := true; req.src := s; req.op := o; req.a := a; req.d := d;
end;

procedure respond(s: Src; d: Ver);
begin
  assert !rsp.full "response slot overrun";
  rsp.full := true; rsp.dst := s; rsp.d := d;
end;

procedure core_write(a: Addr);
begin
  latest[a] := latest[a] + 1;
  dclean[a] := false;
  icoh[a] := false;
end;

------------------------------------------------------------------ L2 (l2.sv)
rule "L2 accept"
  req.full & l2st = L2_IDLE & !rsp.full
==>
begin
  w := req; req.full := false;
  wacked := false;
  if w.op = OP_SW then
    respond(w.src, 0); wacked := true;         -- l2.sv:572 early ack
  endif;
  if w.op = OP_ULW | w.op = OP_USW then
    -- uncached: purge an aliasing L2 line first (write back if dirty), l2.sv:587-614
    if l2hit(w.a) then
      if l2[l2set(w.a)].dirty then mem[w.a] := l2[l2set(w.a)].d; endif;
      l2[l2set(w.a)].valid := false; l2[l2set(w.a)].dirty := false;
    endif;
    l2st := L2_UNC;
  else
    l2st := L2_CHECK;
  endif;
end;

-- CHECK_VALID_AND_TAG
rule "L2 check"
  l2st = L2_CHECK & !rsp.full
==>
begin
  switch w.op
  case OP_INVL:
    if l2hit(w.a) then
      if l2[l2set(w.a)].dirty & BUG_INVL_NO_WB = 0 then mem[w.a] := l2[l2set(w.a)].d; endif;
      l2[l2set(w.a)].valid := false; l2[l2set(w.a)].dirty := false;
    endif;
    respond(w.src, 0); l2st := L2_IDLE;
  case OP_PGDROP:
    if l2hit(w.a) then
      assert !l2[l2set(w.a)].dirty "PGDROP found a dirty L2 line (pre-transfer WBINV missed it)";
      l2[l2set(w.a)].valid := false; l2[l2set(w.a)].dirty := false;
    endif;
    respond(w.src, 0); l2st := L2_IDLE;
  case OP_WB:
    mem[w.a] := w.d;
    if l2hit(w.a) then l2[l2set(w.a)].valid := false; endif;    -- valid only: dirty survives (l2.sv:719)
    respond(w.src, 0); l2st := L2_IDLE;
  case OP_LW, OP_SW:
    if l2hit(w.a) then
      if w.op = OP_LW then
        respond(w.src, l2[l2set(w.a)].d);
      else
        l2[l2set(w.a)].d := w.d; l2[l2set(w.a)].dirty := true;
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
end;

-- CLEAN_RELOAD: the DRAM read is a separate step so a DMA write can land on either side
rule "L2 reload"
  l2st = L2_RELOAD
==>
begin
  l2[l2set(w.a)].valid := true; l2[l2set(w.a)].tag := w.a; l2[l2set(w.a)].d := mem[w.a];
  if BUG_RELOAD_DIRTY = 0 then l2[l2set(w.a)].dirty := false; endif;
  l2st := L2_CHECK;                                  -- WAIT_CLEAN_RELOAD -> WAIT_FOR_RAM
end;

rule "L2 uncached DRAM access"
  l2st = L2_UNC & !rsp.full
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

-- whole-L2 flush walk (FLUSH_WAIT/FLUSH_TRIAGE/FLUSH_STORE), only after the L1D flush
rule "L2 flush"
  dst = D_FLUSH_L2 & l2st = L2_IDLE & !req.full & !rsp.full
==>
begin
  for s: L2Set do
    if need_wb(s) then mem[l2[s].tag] := l2[s].d; endif;
    l2[s].valid := false; l2[s].dirty := false;
  endfor;
  dst := D_IDLE;
end;

------------------------------------------------------------------ L1D (l1d.sv)
ruleset a: Addr do
  rule "load hit"
    dst = D_IDLE & dhit(a) & !in_window(a)
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
      dst = D_IDLE & !dhit(a) & !req.full
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
      dst = D_IDLE & !req.full & (o = CO_CHWB | o = CO_CHINV) & !in_window(a)
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
    dst = D_IDLE & !req.full & !in_window(a)
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
    dst = D_IDLE & !req.full & !in_window(a) & !dout_window(a) & latest[a] < MAXV
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
  rsp.full & rsp.dst = S_D
==>
var d: Ver;
begin
  d := rsp.d; rsp.full := false;
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
    if dop = CO_CHWB then
      -- MEM_WB / MEM_INVL done: if the line was not re-dirtied, DRAM holds latest
      dclean[da] := true;
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

-- HANDLE_RELOAD: after the victim ack the lookup repeats, misses cleanly, sends MEM_LW
rule "L1D: reload after victim"
  dst = D_RELOAD & !req.full
==>
begin
  issue(S_D, OP_LW, da, 0);
  dst := D_FILL;
end;

-- after the alias writeback (early-acked MEM_SW) the uncached op itself goes out
rule "L1D: issue uncached after alias wb"
  dst = D_UNC_ISSUE & !req.full
==>
begin
  if dop = CO_USTORE then issue(S_D, OP_USW, da, dsd); else issue(S_D, OP_ULW, da, 0); endif;
  dst := D_UNC;
end;

------------------------------------------------------------------ whole-cache flush
-- CACHE_FLUSH: L1D walk (dirty -> MEM_SW, invalidated on the ack; clean -> invalidate),
-- then the chained L2 flush walk.  L1I flushed as part of the sequence.
rule "CACHE_FLUSH: L1D walk"
  dst = D_IDLE & !req.full & !ifill
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
    ihit(a) & icoh[a] & !in_window(a)
  ==>
  begin
    assert l1i.d = latest[a] "fetch returned stale instructions after an I-sync";
  end;

  rule "L1I miss"
    L1I = 1 & !ifill & !ihit(a) & !req.full & (!in_window(a) | SPEC_FILL = 1)
  ==>
  begin
    l1i.st := L_I; ifill := true; ia := a;
    issue(S_I, OP_LW, a, 0);
  end;
end;

rule "L1I: fill"
  rsp.full & rsp.dst = S_I
==>
begin
  assert ifill "L1I response without a miss";
  l1i.st := L_V; l1i.tag := ia; l1i.d := rsp.d;
  rsp.full := false; ifill := false;
end;

-- IRIX I-sync: (CHWB of the line done earlier, ghost dclean) then the I-side CACHE op
-- invalidates the L1I (deferred until any fill lands)
rule "I-sync: invalidate L1I"
  L1I = 1 & !ifill
==>
begin
  l1i.st := L_I;
  -- software never executes a DMA-in buffer before the transfer completes (the XPG_INV
  -- drop runs before completion is signalled), so an I-sync does not cover a live window
  for a: Addr do icoh[a] := dclean[a] & !in_window(a); endfor;
end;

------------------------------------------------------------------ DMA + ARM page flush
-- silicon (EXTFLUSH+XFPAGES): the ARM pushes the touched pages; the core runs XPG_WBINV
-- before the transfer and XPG_INV (drop, no writeback) after a DMA-in, as injected
-- serializing uops (core drained: L1D idle).  l1d.sv FLUSH_PG: WBINV = dirty hit -> MEM_WB,
-- else invalidate-if-hit + MEM_INVL; INV = invalidate-if-hit + MEM_PGDROP.
ruleset a: Addr do
  rule "DMA-in: XPG_WBINV pre-flush"
    DMA = 1 & dma = DM_IDLE & dst = D_IDLE & !req.full
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
    DMA = 1 & dma = DM_IDLE & dst = D_IDLE & !req.full
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
  dma = DM_IN_ARMED & dst = D_IDLE & latest[daddr] < MAXV
==>
begin
  latest[daddr] := latest[daddr] + 1;
  mem[daddr] := latest[daddr];
  dclean[daddr] := true; icoh[daddr] := false;
  dma := DM_IN_DONE;
end;

rule "DMA-in: XPG_INV post-drop"
  dma = DM_IN_DONE & dst = D_IDLE & !req.full
==>
begin
  dop := CO_XPG_INV; da := daddr;
  if dhit(daddr) then l1d.st := L_I; endif;
  issue(S_D, OP_PGDROP, daddr, 0);
  dst := D_OP;
  dma := DM_IDLE;
end;

rule "DMA-out: device reads DRAM"
  dma = DM_OUT_ARMED & dst = D_IDLE
==>
begin
  assert mem[daddr] = latest[daddr] "device read stale data (DMA-out)";
  dma := DM_IDLE;
end;

------------------------------------------------------------------ invariants
invariant "inclusion: L1D subset of L2"
  CHECK_INCL_D = 0 | l1d.st = L_I | l2hit(l1d.tag);

invariant "inclusion: L1I subset of L2"
  CHECK_INCL_I = 0 | l1i.st = L_I | l2hit(l1i.tag);

------------------------------------------------------------------ start
startstate
begin
  for a: Addr do latest[a] := 0; mem[a] := 0; icoh[a] := true; dclean[a] := true; endfor;
  req.full := false; req.src := S_D; req.op := OP_LW; req.a := 0; req.d := 0;
  rsp.full := false; rsp.dst := S_D; rsp.d := 0;
  w := req; wacked := false;
  for s: L2Set do
    l2[s].valid := false; l2[s].dirty := false; l2[s].tag := 0; l2[s].d := 0;
  endfor;
  l2st := L2_IDLE;
  l1d.st := L_I; l1d.tag := 0; l1d.d := 0;
  dst := D_IDLE; dkind := K_LOAD; da := 0; dop := CO_NONE; dsd := 0;
  l1i.st := L_I; l1i.tag := 0; l1i.d := 0;
  ifill := false; ia := 0;
  dma := DM_IDLE; daddr := 0;
end;
