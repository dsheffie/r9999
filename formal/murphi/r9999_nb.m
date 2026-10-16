-- r9999_nb.m -- the inclusive-L2 probe protocol with a NON-BLOCKING L2 (several transactions in
-- flight, as rv64core's L2 has), so nothing in the protocol depends on today's serial L2.
-- dsheffie 2026-10-02: "lets not design a protocol that would prevent [many in-flight L2
-- requests] in a future design".
--
-- Agents: L1D (VA-indexed, NCOL colours, one outstanding miss, a 2-deep request queue so a
-- victim writeback and a fill can both be queued), L1I (tag-only, one outstanding miss), the
-- L2 (NM miss-tracking entries = MSHRs), DRAM, and a DMA requester (third agent: the ARM).
--
-- Protocol under test (INCLUSIVE_L2_PROTOCOL.md, generalised):
--  P1 per-line serialisation: one L2 transaction per L2 SET at a time (direct-mapped: a set
--     holds one line, and a fill must evict that set's victim) -- other sets proceed.
--  P2 probes are credit-limited: at most one outstanding probe per L1 (its 1-entry buffer).
--  P3 one ORDERED L2->L1 path per L1, shared by fills and probes (a probe never overtakes a
--     fill to the same L1).
--  P4 the ack travels on its own sideband, matched to its transaction by address; the L2
--     always sinks it (it belongs to an allocated MSHR).
--  P5 the ack carries the newest data the L1 holds for the line wherever it is: the array,
--     or a writeback still in the L1's request queue, which the L1 RETRACTS.  A writeback
--     the L2 already accepted precedes the probe by P1.
--  P6 DMA completion only after the transaction's probes are acked and dirty data is in DRAM.
-- L1D alias (colour) conflicts resolved by the L2 probing the old colour (push).
--
-- Checked: loads see the latest value; DMA-out reads the latest value; at most one L1D copy
-- per PA; presence (an L1-held line has its bit set, and the L1D colour matches); inclusion;
-- deadlock (run with CHECK_RULES=0).
--
-- Negative controls (each MUST fail):
--   BUG_NO_SET_SERIAL     two transactions may work on the same L2 set at once
--   BUG_NO_RETRACT        a probe ignores a queued writeback of its line (acks "clean")
--   BUG_NO_CREDIT         the L2 sends a probe while that L1's probe buffer is busy
--   BUG_ACK_VIA_QUEUE     the ack goes through the L1's REQUEST queue (no sideband) -> deadlock
--   BUG_PROBE_UNORDERED   a probe bypasses the ordered L2->L1 path (overtakes fills)
--   BUG_DMA_EARLY_DONE    DMA completion before the post-drop transaction finishes

const
  NADDR: 3;
  L2SETS: 2;
  MAXV: 1;
  NCOL: 2;
  NM: 2;                    -- L2 MSHRs
  QD: 2;                    -- L1D request queue depth
  RD: 2;                    -- L2->L1 ordered path depth

  L1I: 1;
  DMA: 1;
  SPEC_FILL: 1;
  CHECK_RULES: 1;

  BUG_NO_SET_SERIAL: 0;
  BUG_NO_RETRACT: 0;
  BUG_NO_CREDIT: 0;
  BUG_ACK_VIA_QUEUE: 0;
  BUG_PROBE_UNORDERED: 0;
  BUG_DMA_EARLY_DONE: 0;

type
  Addr: 0..NADDR-1;
  Ver: 0..MAXV;
  Col: 0..NCOL-1;
  L2Set: 0..L2SETS-1;
  MIdx: 0..NM-1;
  QIdx: 0..QD-1;
  RIdx: 0..RD-1;
  Src: enum {S_D, S_I};
  LState: enum {L_I, L_V, L_VD};
  L1Line: record st: LState; tag: Addr; d: Ver; end;
  L2Line: record valid: boolean; dirty: boolean; tag: Addr; d: Ver;
                 pd: boolean; pidx: Col; pi: boolean; end;

  -- L1D -> L2 request queue entries (ACK only with BUG_ACK_VIA_QUEUE)
  QOp: enum {Q_LW, Q_SW, Q_ACK};
  QEnt: record op: QOp; a: Addr; c: Col; d: Ver; dirty: boolean; end;

  -- L2 -> L1 ordered path entries
  ROp: enum {R_FILL, R_PROBE};
  REnt: record op: ROp; a: Addr; c: Col; d: Ver; end;

  -- MSHR
  TKind: enum {T_FILL, T_WBINV, T_DROP};
  TStage: enum {T_LOOK, T_PROBING, T_READ, T_RESP};
  Mshr: record busy: boolean; kind: TKind; src: Src; a: Addr; c: Col;
               pa: Addr;                 -- the line being probed
               waitd: boolean; waiti: boolean;   -- acks outstanding
               stage: TStage; end;

  Ack: record full: boolean; a: Addr; dirty: boolean; d: Ver; end;
  Prb: record full: boolean; a: Addr; c: Col; end;

  DSt: enum {D_IDLE, D_FILL};
  DKind: enum {K_LOAD, K_STORE, K_SPEC};
  DmaSt: enum {DM_IDLE, DM_IN_PRE, DM_IN_ARMED, DM_IN_DONE, DM_IN_DROP,
               DM_OUT_PRE, DM_OUT_ARMED};

var
  latest: array[Addr] of Ver;
  mem: array[Addr] of Ver;
  l2: array[L2Set] of L2Line;
  m: array[MIdx] of Mshr;

  l1d: array[Col] of L1Line;
  dst: DSt; dkind: DKind; da: Addr; dc: Col;
  dq: array[QIdx] of QEnt; dqn: 0..QD;          -- L1D request queue (FIFO, head = 0)

  l1i: L1Line; ifill: boolean; ia: Addr;
  iq: QEnt; iqf: boolean;                        -- L1I request (1 deep)

  rq: array[Src] of array[RIdx] of REnt;         -- ordered L2->L1 paths (head = 0)
  rqn: array[Src] of 0..RD;
  pbuf: array[Src] of Prb;                        -- L1 probe buffers (credit = 1)
  ack: array[Src] of Ack;                         -- sideband acks

  dma: DmaSt; daddr: Addr; dsnp: boolean;         -- dsnp: a DMA snoop request is waiting

------------------------------------------------------------------ helpers
function l2set(a: Addr): L2Set;
begin
  if L2SETS = 2 & a = NADDR-1 then return 1; endif;
  return 0;
end;
function l2hit(a: Addr): boolean;
begin return l2[l2set(a)].valid & l2[l2set(a)].tag = a; end;
function dhit(a: Addr; c: Col): boolean;
begin return l1d[c].st != L_I & l1d[c].tag = a; end;
function ihit(a: Addr): boolean;
begin return l1i.st != L_I & l1i.tag = a; end;
function in_window(a: Addr): boolean;
begin return (dma = DM_IN_PRE | dma = DM_IN_ARMED | dma = DM_IN_DONE | dma = DM_IN_DROP) & daddr = a; end;
function dout_window(a: Addr): boolean;
begin return (dma = DM_OUT_PRE | dma = DM_OUT_ARMED) & daddr = a; end;

-- is some MSHR already working on L2 set s?
function set_busy(s: L2Set): boolean;
begin
  for i: MIdx do
    if m[i].busy & l2set(m[i].a) = s then return true; endif;
  endfor;
  return false;
end;

function free_mshr(): boolean;
begin
  for i: MIdx do if !m[i].busy then return true; endif; endfor;
  return false;
end;

procedure alloc(k: TKind; s: Src; a: Addr; c: Col);
var done: boolean;
begin
  done := false;
  for i: MIdx do
    if !done & !m[i].busy then
      m[i].busy := true; m[i].kind := k; m[i].src := s; m[i].a := a; m[i].c := c;
      m[i].pa := a; m[i].waitd := false; m[i].waiti := false; m[i].stage := T_LOOK;
      done := true;
    endif;
  endfor;
  assert done "no free MSHR";
end;

procedure rq_push(s: Src; o: ROp; a: Addr; c: Col; d: Ver);
begin
  assert rqn[s] < RD "L2->L1 path overflow";
  rq[s][rqn[s]].op := o; rq[s][rqn[s]].a := a; rq[s][rqn[s]].c := c; rq[s][rqn[s]].d := d;
  rqn[s] := rqn[s] + 1;
end;

procedure rq_pop(s: Src);
begin
  for j: RIdx do
    if j < RD-1 then rq[s][j] := rq[s][j+1]; endif;
  endfor;
  rq[s][RD-1].op := R_FILL; rq[s][RD-1].a := 0; rq[s][RD-1].c := 0; rq[s][RD-1].d := 0;
  rqn[s] := rqn[s] - 1;
end;

procedure dq_push(o: QOp; a: Addr; c: Col; d: Ver; dirty: boolean);
begin
  assert dqn < QD "L1D request queue overflow";
  dq[dqn].op := o; dq[dqn].a := a; dq[dqn].c := c; dq[dqn].d := d; dq[dqn].dirty := dirty;
  dqn := dqn + 1;
end;

procedure dq_remove(k: QIdx);
begin
  for j: QIdx do
    if j >= k & j < QD-1 then dq[j] := dq[j+1]; endif;
  endfor;
  dq[QD-1].op := Q_LW; dq[QD-1].a := 0; dq[QD-1].c := 0; dq[QD-1].d := 0; dq[QD-1].dirty := false;
  dqn := dqn - 1;
end;

-- send probes for line a to the L1s that may hold it (P2: needs the credit)
function can_probe(a: Addr): boolean;
begin
  if BUG_NO_CREDIT = 1 then return true; endif;
  return (!l2[l2set(a)].pd | !pbuf[S_D].full)
       & (!l2[l2set(a)].pi | !pbuf[S_I].full);
end;

procedure deliver_probe(s: Src; a: Addr; c: Col);
begin
  if BUG_PROBE_UNORDERED = 1 then
    -- bypasses the ordered path: straight into the probe buffer
    assert !pbuf[s].full "probe buffer overrun";
    pbuf[s].full := true; pbuf[s].a := a; pbuf[s].c := c;
  else
    rq_push(s, R_PROBE, a, c, 0);
  endif;
end;

------------------------------------------------------------------ L2: accept
-- an L1D request at the head of its queue (writebacks are applied at once; fills need an
-- MSHR).  P1: wait while another transaction holds the set.
rule "L2 accept L1D"
  dqn > 0 & dq[0].op != Q_ACK
  & (BUG_NO_SET_SERIAL = 1 | !set_busy(l2set(dq[0].a)))
  & (dq[0].op = Q_SW | free_mshr())
==>
var e: QEnt; s: L2Set;
begin
  e := dq[0]; dq_remove(0);
  s := l2set(e.a);
  if e.op = Q_SW then
    -- victim writeback: the L1D gave the line up
    if l2hit(e.a) then
      l2[s].d := e.d; l2[s].dirty := true; l2[s].pd := false;
    else
      mem[e.a] := e.d;            -- not in the L2 (non-inclusive gap / already evicted)
    endif;
  else
    alloc(T_FILL, S_D, e.a, e.c);
  endif;
end;

rule "L2 accept L1I"
  iqf & (BUG_NO_SET_SERIAL = 1 | !set_busy(l2set(iq.a))) & free_mshr()
==>
begin
  iqf := false;
  alloc(T_FILL, S_I, iq.a, 0);
end;

rule "L2 accept DMA snoop"
  dsnp & (BUG_NO_SET_SERIAL = 1 | !set_busy(l2set(daddr))) & free_mshr()
==>
begin
  dsnp := false;
  if dma = DM_IN_DROP | (dma = DM_IDLE & BUG_DMA_EARLY_DONE = 1) then
    alloc(T_DROP, S_D, daddr, 0);
  else
    alloc(T_WBINV, S_D, daddr, 0);
  endif;
end;

------------------------------------------------------------------ L2: per-MSHR steps
ruleset i: MIdx do
  rule "MSHR look"
    m[i].busy & m[i].stage = T_LOOK
  ==>
  var s: L2Set; a: Addr;
  begin
    a := m[i].a; s := l2set(a);
    if m[i].kind = T_FILL then
      if l2hit(a) then
        if m[i].src = S_D & l2[s].pd & l2[s].pidx != m[i].c then
          -- alias: the L1D holds it at another colour -> probe that copy (push)
          if can_probe(a) then
            m[i].pa := a; m[i].waitd := true; m[i].waiti := false;
            deliver_probe(S_D, a, l2[s].pidx);
            m[i].stage := T_PROBING;
          endif;
        else
          m[i].stage := T_RESP;
        endif;
      elsif l2[s].valid & (l2[s].pd | l2[s].pi) then
        -- evicting a line an L1 may hold: probe the holders first
        if can_probe(l2[s].tag) then
          m[i].pa := l2[s].tag; m[i].waitd := l2[s].pd; m[i].waiti := l2[s].pi & L1I = 1;
          if l2[s].pd then deliver_probe(S_D, l2[s].tag, l2[s].pidx); endif;
          if l2[s].pi & L1I = 1 then deliver_probe(S_I, l2[s].tag, 0); endif;
          m[i].stage := T_PROBING;
        endif;
      else
        if l2[s].valid & l2[s].dirty then mem[l2[s].tag] := l2[s].d; endif;
        l2[s].valid := false; l2[s].dirty := false; l2[s].pd := false; l2[s].pi := false;
        m[i].stage := T_READ;
      endif;
    else
      -- DMA snoop (WBINV before the transfer, DROP after a DMA-in)
      if l2hit(a) & (l2[s].pd | l2[s].pi) then
        if can_probe(a) then
          m[i].pa := a; m[i].waitd := l2[s].pd; m[i].waiti := l2[s].pi & L1I = 1;
          if l2[s].pd then deliver_probe(S_D, a, l2[s].pidx); endif;
          if l2[s].pi & L1I = 1 then deliver_probe(S_I, a, 0); endif;
          m[i].stage := T_PROBING;
        endif;
      else
        if l2hit(a) then
          if m[i].kind = T_WBINV & l2[s].dirty then mem[a] := l2[s].d; endif;
          if m[i].kind = T_DROP then
            assert !l2[s].dirty "DMA post-drop found dirty data";
          endif;
          l2[s].valid := false; l2[s].dirty := false; l2[s].pd := false; l2[s].pi := false;
        endif;
        -- P6: completion only now
        if m[i].kind = T_WBINV then
          if dma = DM_IN_PRE then dma := DM_IN_ARMED; endif;
          if dma = DM_OUT_PRE then dma := DM_OUT_ARMED; endif;
        else
          if dma = DM_IN_DROP then dma := DM_IDLE; endif;
        endif;
        m[i].busy := false;
      endif;
    endif;
  end;

  -- the sideband ack for this transaction (P4: matched by address)
  ruleset s: Src do
    rule "MSHR takes ack"
      m[i].busy & m[i].stage = T_PROBING & ack[s].full & ack[s].a = m[i].pa
      & ((s = S_D & m[i].waitd) | (s = S_I & m[i].waiti))
    ==>
    begin
      assert l2hit(m[i].pa) "probed line left the L2 during the probe";
      if ack[s].dirty then
        l2[l2set(m[i].pa)].d := ack[s].d; l2[l2set(m[i].pa)].dirty := true;
      endif;
      if s = S_D then l2[l2set(m[i].pa)].pd := false; m[i].waitd := false;
      else l2[l2set(m[i].pa)].pi := false; m[i].waiti := false; endif;
      ack[s].full := false; ack[s].dirty := false; ack[s].d := 0;
      if !m[i].waitd & !m[i].waiti then m[i].stage := T_LOOK; endif;
    end;
  end;

  rule "MSHR refill from DRAM"
    m[i].busy & m[i].stage = T_READ
  ==>
  var s: L2Set;
  begin
    s := l2set(m[i].a);
    l2[s].valid := true; l2[s].dirty := false; l2[s].tag := m[i].a; l2[s].d := mem[m[i].a];
    l2[s].pd := false; l2[s].pi := false;
    m[i].stage := T_LOOK;
  end;

  rule "MSHR respond"
    m[i].busy & m[i].stage = T_RESP & rqn[m[i].src] < RD
  ==>
  var s: L2Set;
  begin
    s := l2set(m[i].a);
    if m[i].src = S_D then
      l2[s].pd := true; l2[s].pidx := m[i].c;
    else
      l2[s].pi := true;
    endif;
    rq_push(m[i].src, R_FILL, m[i].a, m[i].c, l2[s].d);
    m[i].busy := false;
  end;
end;

-- with BUG_ACK_VIA_QUEUE the L2 can only see an ack at the head of the request queue
rule "L2 takes queued ack"
  BUG_ACK_VIA_QUEUE = 1 & dqn > 0 & dq[0].op = Q_ACK
==>
var e: QEnt;
begin
  e := dq[0];
  for i: MIdx do
    if m[i].busy & m[i].stage = T_PROBING & m[i].waitd & m[i].pa = e.a then
      if e.dirty then l2[l2set(e.a)].d := e.d; l2[l2set(e.a)].dirty := true; endif;
      l2[l2set(e.a)].pd := false; m[i].waitd := false;
      if !m[i].waiti then m[i].stage := T_LOOK; endif;
    endif;
  endfor;
  dq_remove(0);
end;

------------------------------------------------------------------ L1D
ruleset a: Addr; c: Col do
  rule "load hit"
    CHECK_RULES = 1 & dst = D_IDLE & dhit(a, c) & !in_window(a)
  ==>
  begin
    assert l1d[c].d = latest[a] "load hit returned a stale value";
  end;

  rule "store hit"
    dst = D_IDLE & dhit(a, c) & !in_window(a) & !dout_window(a) & latest[a] < MAXV
  ==>
  begin
    latest[a] := latest[a] + 1;
    l1d[c].d := latest[a]; l1d[c].st := L_VD;
  end;

  ruleset k: DKind do
    rule "L1D miss"
      dst = D_IDLE & !dhit(a, c)
      & (k = K_SPEC ? (SPEC_FILL = 1 & in_window(a)) : !in_window(a))
      & !(k = K_STORE & (dout_window(a) | latest[a] = MAXV))
      & dqn + (l1d[c].st = L_VD ? 2 : 1) <= QD
    ==>
    begin
      dkind := k; da := a; dc := c;
      if l1d[c].st = L_VD then
        dq_push(Q_SW, l1d[c].tag, c, l1d[c].d, true);   -- victim leaves the array (EB)
      endif;
      l1d[c].st := L_I;                                -- a clean victim is dropped silently
      dq_push(Q_LW, a, c, 0, false);
      dst := D_FILL;
    end;
  end;
end;

-- the ordered L2->L1D path: fills install, probes move to the probe buffer (P3)
rule "L1D takes from L2 path"
  rqn[S_D] > 0 & (rq[S_D][0].op = R_FILL | !pbuf[S_D].full)
==>
var e: REnt;
begin
  e := rq[S_D][0]; rq_pop(S_D);
  if e.op = R_PROBE then
    pbuf[S_D].full := true; pbuf[S_D].a := e.a; pbuf[S_D].c := e.c;
  else
    assert dst = D_FILL & da = e.a & dc = e.c "unexpected L1D fill";
    l1d[dc].st := L_V; l1d[dc].tag := da; l1d[dc].d := e.d;
    if dkind = K_LOAD then
      assert e.d = latest[da] "load miss returned a stale value";
    elsif dkind = K_STORE then
      latest[da] := latest[da] + 1;
      l1d[dc].d := latest[da]; l1d[dc].st := L_VD;
    endif;
    dst := D_IDLE;
  endif;
end;

-- probe handling (R2: whatever the L1D is doing); P5: newest data wherever it is
rule "L1D handles probe"
  pbuf[S_D].full & (BUG_ACK_VIA_QUEUE = 1 ? dqn < QD : !ack[S_D].full)
==>
var a: Addr; c: Col; dirty: boolean; d: Ver; found: boolean;
begin
  a := pbuf[S_D].a; c := pbuf[S_D].c;
  dirty := false; d := 0;
  if dhit(a, c) then
    if l1d[c].st = L_VD then dirty := true; d := l1d[c].d; endif;
    l1d[c].st := L_I;
  endif;
  -- a writeback of this line still in the request queue: retract it, its data rides the ack
  if BUG_NO_RETRACT = 0 then
    found := false;
    for k: QIdx do
      if !found & k < dqn & dq[k].op = Q_SW & dq[k].a = a then
        dirty := true; d := dq[k].d;
        dq_remove(k);
        found := true;
      endif;
    endfor;
  endif;
  if BUG_ACK_VIA_QUEUE = 1 then
    dq_push(Q_ACK, a, 0, d, dirty);
  else
    ack[S_D].full := true; ack[S_D].a := a; ack[S_D].dirty := dirty; ack[S_D].d := d;
  endif;
  pbuf[S_D].full := false;
end;

------------------------------------------------------------------ L1I (tag-only)
ruleset a: Addr do
  rule "L1I miss"
    L1I = 1 & !ifill & !ihit(a) & !iqf & (!in_window(a) | SPEC_FILL = 1)
  ==>
  begin
    l1i.st := L_I; ifill := true; ia := a;
    iqf := true; iq.op := Q_LW; iq.a := a; iq.c := 0; iq.d := 0; iq.dirty := false;
  end;
end;

rule "L1I: invalidate (I-sync)"
  L1I = 1 & !ifill & l1i.st != L_I
==>
begin
  l1i.st := L_I;
end;

rule "L1I takes from L2 path"
  rqn[S_I] > 0 & (rq[S_I][0].op = R_FILL | !pbuf[S_I].full)
==>
var e: REnt;
begin
  e := rq[S_I][0]; rq_pop(S_I);
  if e.op = R_PROBE then
    pbuf[S_I].full := true; pbuf[S_I].a := e.a; pbuf[S_I].c := e.c;
  else
    assert ifill & ia = e.a "unexpected L1I fill";
    l1i.st := L_V; l1i.tag := e.a; l1i.d := 0;
    ifill := false;
  endif;
end;

rule "L1I handles probe"
  pbuf[S_I].full & !ack[S_I].full
==>
begin
  if ihit(pbuf[S_I].a) then l1i.st := L_I; endif;
  ack[S_I].full := true; ack[S_I].a := pbuf[S_I].a; ack[S_I].dirty := false; ack[S_I].d := 0;
  pbuf[S_I].full := false;
end;

------------------------------------------------------------------ DMA (third agent)
-- the driver starts the I/O after its stores drain (no CPU store in flight)
ruleset a: Addr do
  rule "DMA-in: request pre-snoop"
    DMA = 1 & dma = DM_IDLE & !dsnp & dst = D_IDLE
  ==>
  begin
    daddr := a; dsnp := true; dma := DM_IN_PRE;
  end;

  rule "DMA-out: request pre-snoop"
    DMA = 1 & dma = DM_IDLE & !dsnp & dst = D_IDLE
  ==>
  begin
    daddr := a; dsnp := true; dma := DM_OUT_PRE;
  end;
end;

rule "DMA-in: device writes DRAM"
  dma = DM_IN_ARMED & latest[daddr] < MAXV
==>
begin
  latest[daddr] := latest[daddr] + 1;
  mem[daddr] := latest[daddr];
  dma := DM_IN_DONE;
end;

rule "DMA-in: request post-drop"
  dma = DM_IN_DONE & !dsnp
==>
begin
  dsnp := true;
  if BUG_DMA_EARLY_DONE = 1 then dma := DM_IDLE; else dma := DM_IN_DROP; endif;
end;

rule "DMA-out: device reads DRAM"
  dma = DM_OUT_ARMED
==>
begin
  assert mem[daddr] = latest[daddr] "device read stale data (DMA-out)";
  dma := DM_IDLE;
end;

------------------------------------------------------------------ invariants
invariant "at most one L1D copy per physical line"
  forall c1: Col do forall c2: Col do
    c1 = c2 | l1d[c1].st = L_I | l1d[c2].st = L_I | l1d[c1].tag != l1d[c2].tag
  endforall endforall;

invariant "presence: an L1D-held line has pd set at its colour"
  forall c: Col do
    l1d[c].st = L_I | (l2hit(l1d[c].tag) & l2[l2set(l1d[c].tag)].pd
                       & l2[l2set(l1d[c].tag)].pidx = c)
  endforall;

invariant "inclusion: L1I subset of L2"
  L1I = 0 | l1i.st = L_I | (l2hit(l1i.tag) & l2[l2set(l1i.tag)].pi);

------------------------------------------------------------------ start
startstate
begin
  for a: Addr do latest[a] := 0; mem[a] := 0; endfor;
  for s: L2Set do
    l2[s].valid := false; l2[s].dirty := false; l2[s].tag := 0; l2[s].d := 0;
    l2[s].pd := false; l2[s].pidx := 0; l2[s].pi := false;
  endfor;
  for i: MIdx do
    m[i].busy := false; m[i].kind := T_FILL; m[i].src := S_D; m[i].a := 0; m[i].c := 0;
    m[i].pa := 0; m[i].waitd := false; m[i].waiti := false; m[i].stage := T_LOOK;
  endfor;
  for c: Col do l1d[c].st := L_I; l1d[c].tag := 0; l1d[c].d := 0; endfor;
  dst := D_IDLE; dkind := K_LOAD; da := 0; dc := 0;
  for k: QIdx do dq[k].op := Q_LW; dq[k].a := 0; dq[k].c := 0; dq[k].d := 0; dq[k].dirty := false; endfor;
  dqn := 0;
  l1i.st := L_I; l1i.tag := 0; l1i.d := 0; ifill := false; ia := 0;
  iq.op := Q_LW; iq.a := 0; iq.c := 0; iq.d := 0; iq.dirty := false; iqf := false;
  for s: Src do
    for j: RIdx do rq[s][j].op := R_FILL; rq[s][j].a := 0; rq[s][j].c := 0; rq[s][j].d := 0; endfor;
    rqn[s] := 0;
    pbuf[s].full := false; pbuf[s].a := 0; pbuf[s].c := 0;
    ack[s].full := false; ack[s].a := 0; ack[s].dirty := false; ack[s].d := 0;
  endfor;
  dma := DM_IDLE; daddr := 0; dsnp := false;
end;
