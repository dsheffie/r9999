-- r9999_va.m -- inclusive L2 that tracks WHERE (which VA colour / L1D index) the L1D holds
-- each line, so the L1D can be VIRTUALLY indexed (inclusive-l2-v2, step 3).
--
-- Why: the L1D is 16 KB VIPT with 4 KB pages, so index bits VA[13:12] (the "colour") can
-- differ from PA[13:12].  Today (VAIDX=0) a line always lives at its PHYSICAL index and an
-- access whose VA colour differs is replayed (CoreMark: 15.5% of cycles).  With VAIDX=1 the
-- L1D keeps the line at the VA index; two VAs mapping one PA with different colours are
-- SYNONYMS and could create two copies.  The L2 (PA-indexed, inclusive, presence bits from
-- r9999_incl.m) records pidx = the colour the L1D holds the line at, and enforces AT MOST ONE
-- L1D COPY per physical line:
--   L1D miss for PA a at colour c, L2 sees pd & pidx != c  ->  the old copy must go first.
--   PULL (ALIAS_PULL=1, dsheffie's direction after the August lost-write race): the L2
--        answers "alias at pidx" and changes NO state; the L1D evicts its own copy at pidx
--        (MEM_SW if dirty, a drop notice if clean or already silently gone) and retries.
--   PUSH (ALIAS_PULL=0): the L2 back-invalidates the old copy with a probe (data returned,
--        merged) and then fills at c -- relies on the proven probe rules R2/R3.
-- pidx is also what makes probes possible at all: a VA-indexed L1D cannot find a line by PA.
--
-- Abstraction (as r9999_incl.m): NADDR physical lines, all in the same L1 set position, two
-- L2 sets (the last address alone); NCOL colours -> the L1D is NCOL lines (one per colour).
-- With VAIDX=1 every access picks its colour nondeterministically (= any VA mapping,
-- synonyms included); with VAIDX=0 the colour is the PA colour pcol(a).
-- Requests from each L1 are latched separately; a response is delivered in the L2 step that
-- produces it (the RTL installs a fill in the response cycle).  Probes carry the colour.
-- No DMA here (deferred).  L1I = tag-only (its fetch coherence is proven on main).
--
-- Checked: loads (cached + uncached) return the latest value; at most one L1D copy per PA;
-- presence (a held L1D line has pd set and pidx = its colour); inclusion (L1D and L1I).
--
-- Knobs
--   VAIDX               1 = VA-indexed L1D with L2 alias tracking, 0 = PA-indexed (today)
--   ALIAS_PULL          1 = pull (L2 replies "alias"), 0 = push (L2 probes the old copy)
--   L1I                 model the L1I (tag-only)
--   CHECK_RULES         0 = drop the always-enabled check rules (for deadlock detection)
--   negative controls (each MUST fail):
--   BUG_NO_ALIAS_CHECK  the L2 ignores pidx on a fill (two copies)
--   BUG_ALIAS_DROP_DIRTY  the L1D's alias eviction drops a dirty copy without writing it back
--   BUG_PIDX_NOUPDATE   the L2 does not record the new colour on a fill
--   BUG_PROBE_BLOCKED   the L1D answers probes only when idle (PUSH)  -- must deadlock

const
  NADDR: 3;
  L2SETS: 2;
  MAXV: 2;
  NCOL: 2;

  VAIDX: 1;
  ALIAS_PULL: 1;
  L1I: 1;
  CHECK_RULES: 1;

  BUG_NO_ALIAS_CHECK: 0;
  BUG_ALIAS_DROP_DIRTY: 0;
  BUG_PIDX_NOUPDATE: 0;
  BUG_PROBE_BLOCKED: 0;

type
  Addr: 0..NADDR-1;
  Ver: 0..MAXV;
  Col: 0..NCOL-1;
  L2Set: 0..L2SETS-1;
  LState: enum {L_I, L_V, L_VD};
  Src: enum {S_D, S_I};
  -- L1->L2: LW (fill), SW (L1D writeback: victim or alias eviction), ADROP (alias eviction
  -- of a clean / already-gone copy: "I no longer hold it"), ULW/USW (uncached), WB/INVL
  -- (CACHE hit ops)
  Op: enum {OP_LW, OP_SW, OP_ADROP, OP_ULW, OP_USW, OP_WB, OP_INVL};
  Req: record full: boolean; op: Op; a: Addr; c: Col; d: Ver; end;
  -- fill response kinds
  RKind: enum {R_ACK, R_DATA, R_ALIAS};
  L2St: enum {L2_IDLE, L2_CHECK, L2_RELOAD, L2_UPURGE, L2_UNC, L2_PROBE};
  L2Line: record valid: boolean; dirty: boolean; tag: Addr; d: Ver;
                 pd: boolean; pidx: Col; pi: boolean; end;
  L1Line: record st: LState; tag: Addr; d: Ver; end;
  Probe: record full: boolean; a: Addr; c: Col; end;
  PAck: record full: boolean; dirty: boolean; d: Ver; end;
  DSt: enum {D_IDLE, D_VICT, D_RELOAD, D_FILL, D_AEVICT, D_OP, D_UNC_WB, D_UNC_ISSUE, D_UNC};
  DKind: enum {K_LOAD, K_STORE};
  DOp: enum {CO_CHWB, CO_CHINV, CO_ULOAD, CO_USTORE, CO_NONE};

var
  latest: array[Addr] of Ver;
  mem: array[Addr] of Ver;

  req: array[Src] of Req;
  prb: array[Src] of Probe;
  pack: array[Src] of PAck;
  pexp: array[Src] of boolean;

  l2: array[L2Set] of L2Line;
  l2st: L2St;
  w: Req; wsrc: Src;
  probed: boolean; pa: Addr; pret: L2St;

  l1d: array[Col] of L1Line;
  dst: DSt; dkind: DKind; da: Addr; dc: Col; dop: DOp; dsd: Ver;
  aliasc: Col;                         -- the colour of the copy being alias-evicted

  l1i: L1Line; ifill: boolean; ia: Addr;

------------------------------------------------------------------ helpers
function pcol(a: Addr): Col;            -- PA colour: PA[13:12] stand-in
begin return a % NCOL; end;

function okcol(a: Addr; c: Col): boolean; -- may an access to a use colour c?
begin return VAIDX = 1 | c = pcol(a); end;

function dhit(a: Addr; c: Col): boolean;
begin return l1d[c].st != L_I & l1d[c].tag = a; end;

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
begin return l2[s].valid & l2[s].dirty; end;

procedure issue(s: Src; o: Op; a: Addr; c: Col; d: Ver);
begin
  assert !req[s].full "L1 issued a second request";
  req[s].full := true; req[s].op := o; req[s].a := a; req[s].c := c; req[s].d := d;
end;

procedure core_write(a: Addr);
begin latest[a] := latest[a] + 1; end;

procedure l2_drop(s: L2Set);
begin
  l2[s].valid := false; l2[s].dirty := false; l2[s].pd := false; l2[s].pi := false;
end;

------------------------------------------------------------------ L1 response handlers
-- (called from the L2 step that responds: same-cycle install, as in the RTL)
procedure d_rsp(k: RKind; d: Ver; ac: Col);
begin
  switch dst
  case D_VICT:
    l1d[dc].st := L_I;                               -- inhibit-write ack invalidates
    dst := D_RELOAD;
  case D_FILL:
    if k = R_ALIAS then
      -- PULL: the L1D holds this PA at colour ac; evict that copy, then retry
      aliasc := ac;
      if dhit(da, ac) & l1d[ac].st = L_VD & BUG_ALIAS_DROP_DIRTY = 0 then
        issue(S_D, OP_SW, da, ac, l1d[ac].d);        -- line stays VD until the ack
      else
        if dhit(da, ac) then l1d[ac].st := L_I; endif;
        issue(S_D, OP_ADROP, da, ac, 0);
      endif;
      dst := D_AEVICT;
    else
      l1d[dc].st := L_V; l1d[dc].tag := da; l1d[dc].d := d;
      if dkind = K_LOAD then
        assert d = latest[da] "load miss returned a stale value";
      else
        core_write(da);
        l1d[dc].d := latest[da]; l1d[dc].st := L_VD;
      endif;
      dst := D_IDLE;
    endif;
  case D_AEVICT:
    if dhit(da, aliasc) then l1d[aliasc].st := L_I; endif;
    dst := D_RELOAD;                                 -- retry the fill
  case D_OP:
    dst := D_IDLE;
  case D_UNC_WB:
    dst := D_UNC_ISSUE;
  case D_UNC:
    if dop = CO_ULOAD then
      assert d = latest[da] "uncached load returned a stale value";
    endif;
    dst := D_IDLE;
  else
    error "unexpected L1D response";
  endswitch;
end;

procedure i_rsp();
begin
  assert ifill "L1I response without a miss";
  l1i.st := L_V; l1i.tag := ia; l1i.d := 0;
  ifill := false;
end;

procedure respond(s: Src; k: RKind; d: Ver; ac: Col);
begin
  if s = S_D then d_rsp(k, d, ac); else i_rsp(); endif;
end;

------------------------------------------------------------------ L2
function must_probe(): boolean;
begin return !probed; end;

-- probe the L1s that may hold line a (presence bits; the L1D probe carries pidx)
procedure send_probes(a: Addr; ret: L2St);
begin
  pexp[S_D] := l2[l2set(a)].pd;
  pexp[S_I] := L1I = 1 & l2[l2set(a)].pi;
  if pexp[S_D] then prb[S_D].full := true; prb[S_D].a := a; prb[S_D].c := l2[l2set(a)].pidx; endif;
  if pexp[S_I] then prb[S_I].full := true; prb[S_I].a := a; prb[S_I].c := 0; endif;
  pa := a; pret := ret;
  if pexp[S_D] | pexp[S_I] then
    l2st := L2_PROBE;
  else
    probed := true; l2st := ret;
  endif;
end;

ruleset s: Src do
  rule "L2 accept"
    req[s].full & l2st = L2_IDLE
  ==>
  begin
    w := req[s]; wsrc := s; req[s].full := false;
    probed := false;
    if w.op = OP_SW then respond(s, R_ACK, 0, 0); endif;   -- l2.sv:572 early ack
    if w.op = OP_ULW | w.op = OP_USW then l2st := L2_UPURGE; else l2st := L2_CHECK; endif;
  end;
end;

rule "L2 uncached purge"
  l2st = L2_UPURGE
==>
begin
  if l2hit(w.a) & must_probe() then
    send_probes(w.a, L2_UPURGE);
  else
    if l2hit(w.a) then
      if l2[l2set(w.a)].dirty then mem[w.a] := l2[l2set(w.a)].d; endif;
      l2_drop(l2set(w.a));
    endif;
    l2st := L2_UNC;
  endif;
end;

rule "L2 uncached DRAM access"
  l2st = L2_UNC
==>
begin
  if w.op = OP_USW then
    mem[w.a] := w.d; respond(wsrc, R_ACK, 0, 0);
  else
    respond(wsrc, R_ACK, mem[w.a], 0);
  endif;
  l2st := L2_IDLE;
end;

rule "L2 check"
  l2st = L2_CHECK
==>
var ln: L2Set;
begin
  ln := l2set(w.a);
  if (w.op = OP_INVL | w.op = OP_WB) & l2hit(w.a) & must_probe() then
    send_probes(w.a, L2_CHECK);
  elsif (w.op = OP_LW | w.op = OP_SW) & !l2hit(w.a) & l2[ln].valid & must_probe() then
    send_probes(l2[ln].tag, L2_CHECK);               -- the miss victim
  elsif w.op = OP_LW & wsrc = S_D & l2hit(w.a) & VAIDX = 1 & BUG_NO_ALIAS_CHECK = 0
        & l2[ln].pd & l2[ln].pidx != w.c & ALIAS_PULL = 1 then
    -- PULL: the L1D already holds this line at another colour: say so, change nothing
    respond(S_D, R_ALIAS, 0, l2[ln].pidx);
    l2st := L2_IDLE;
  elsif w.op = OP_LW & wsrc = S_D & l2hit(w.a) & VAIDX = 1 & BUG_NO_ALIAS_CHECK = 0
        & l2[ln].pd & l2[ln].pidx != w.c & ALIAS_PULL = 0 & must_probe() then
    send_probes(w.a, L2_CHECK);                      -- PUSH: back-invalidate the old copy
  else
    switch w.op
    case OP_INVL:
      if l2hit(w.a) then
        if l2[ln].dirty then mem[w.a] := l2[ln].d; endif;
        l2_drop(ln);
      endif;
      respond(wsrc, R_ACK, 0, 0); l2st := L2_IDLE;
    case OP_WB:
      mem[w.a] := w.d;
      if l2hit(w.a) then l2_drop(ln); endif;
      respond(wsrc, R_ACK, 0, 0); l2st := L2_IDLE;
    case OP_ADROP:
      -- the L1D gave up its (clean or already silently dropped) copy at colour w.c
      if l2hit(w.a) & l2[ln].pd & l2[ln].pidx = w.c then l2[ln].pd := false; endif;
      respond(wsrc, R_ACK, 0, 0); l2st := L2_IDLE;
    case OP_LW, OP_SW:
      if l2hit(w.a) then
        if w.op = OP_LW then
          if wsrc = S_D then
            l2[ln].pd := true;
            if BUG_PIDX_NOUPDATE = 0 then l2[ln].pidx := w.c; endif;
          else
            l2[ln].pi := true;
          endif;
          respond(wsrc, R_DATA, l2[ln].d, 0);
        else
          -- an L1D writeback (victim or alias eviction): it no longer holds the line
          l2[ln].d := w.d; l2[ln].dirty := true;
          if l2[ln].pd & l2[ln].pidx = w.c then l2[ln].pd := false; endif;
        endif;
        l2st := L2_IDLE;
      else
        if need_wb(ln) then mem[l2[ln].tag] := l2[ln].d; endif;
        l2st := L2_RELOAD;
      endif;
    else
      error "bad L2 op";
    endswitch;
  endif;
end;

rule "L2 reload"
  l2st = L2_RELOAD
==>
begin
  l2[l2set(w.a)].valid := true; l2[l2set(w.a)].tag := w.a; l2[l2set(w.a)].d := mem[w.a];
  l2[l2set(w.a)].dirty := false; l2[l2set(w.a)].pd := false; l2[l2set(w.a)].pi := false;
  l2st := L2_CHECK;
end;

rule "L2 probe acks in"
  l2st = L2_PROBE & (!pexp[S_D] | pack[S_D].full) & (!pexp[S_I] | pack[S_I].full)
==>
begin
  assert l2hit(pa) "probed line left the L2 during the probe";
  if pack[S_D].dirty then
    l2[l2set(pa)].d := pack[S_D].d; l2[l2set(pa)].dirty := true;
  endif;
  pack[S_D].full := false; pack[S_I].full := false; pack[S_D].dirty := false; pack[S_D].d := 0;
  pexp[S_D] := false; pexp[S_I] := false;
  l2[l2set(pa)].pd := false; l2[l2set(pa)].pi := false;
  probed := true;
  l2st := pret;
end;

------------------------------------------------------------------ L1D
ruleset a: Addr; c: Col do
  rule "load hit"
    CHECK_RULES = 1 & okcol(a, c) & dst = D_IDLE & dhit(a, c)
  ==>
  begin
    assert l1d[c].d = latest[a] "load hit returned a stale value";
  end;

  rule "store hit (commit)"
    okcol(a, c) & dst = D_IDLE & dhit(a, c) & latest[a] < MAXV
  ==>
  begin
    core_write(a);
    l1d[c].d := latest[a]; l1d[c].st := L_VD;
  end;

  ruleset k: DKind do
    rule "L1D miss"
      okcol(a, c) & dst = D_IDLE & !dhit(a, c) & !req[S_D].full
      & !(k = K_STORE & latest[a] = MAXV)
    ==>
    begin
      dkind := k; da := a; dc := c;
      if l1d[c].st = L_VD then
        issue(S_D, OP_SW, l1d[c].tag, c, l1d[c].d);   -- victim first, line stays VD
        dst := D_VICT;
      else
        l1d[c].st := L_I;                            -- clean victim: silent drop
        issue(S_D, OP_LW, a, c, 0);
        dst := D_FILL;
      endif;
    end;
  end;

  -- CACHE hit ops by VA (colour c): only line[c] is looked at; a synonym copy elsewhere is
  -- reached by the L2 (probe at pidx before it drops/writes the line)
  ruleset o: DOp do
    rule "CACHE hit op"
      okcol(a, c) & dst = D_IDLE & !req[S_D].full & (o = CO_CHWB | o = CO_CHINV)
      & !(o = CO_CHINV & dhit(a, c) & l1d[c].st = L_VD)
    ==>
    begin
      dop := o; da := a; dc := c;
      if o = CO_CHWB & dhit(a, c) & l1d[c].st = L_VD then
        issue(S_D, OP_WB, a, c, l1d[c].d);
      else
        issue(S_D, OP_INVL, a, c, 0);
      endif;
      if dhit(a, c) then l1d[c].st := L_I; endif;
      dst := D_OP;
    end;
  end;
end;

-- uncached (kseg1: unmapped, so the VA colour IS the PA colour)
ruleset a: Addr do
  rule "uncached load"
    dst = D_IDLE & !req[S_D].full
  ==>
  begin
    dop := CO_ULOAD; da := a; dc := pcol(a);
    if dhit(a, pcol(a)) & l1d[pcol(a)].st = L_VD then
      issue(S_D, OP_SW, a, pcol(a), l1d[pcol(a)].d); l1d[pcol(a)].st := L_I; dst := D_UNC_WB;
    else
      if dhit(a, pcol(a)) then l1d[pcol(a)].st := L_I; endif;
      issue(S_D, OP_ULW, a, pcol(a), 0); dst := D_UNC;
    endif;
  end;

  rule "uncached store"
    dst = D_IDLE & !req[S_D].full & latest[a] < MAXV
  ==>
  begin
    dop := CO_USTORE; da := a; dc := pcol(a);
    core_write(a); dsd := latest[a];
    if dhit(a, pcol(a)) & l1d[pcol(a)].st = L_VD then
      issue(S_D, OP_SW, a, pcol(a), l1d[pcol(a)].d); l1d[pcol(a)].st := L_I; dst := D_UNC_WB;
    else
      if dhit(a, pcol(a)) then l1d[pcol(a)].st := L_I; endif;
      issue(S_D, OP_USW, a, pcol(a), dsd); dst := D_UNC;
    endif;
  end;
end;

rule "L1D: reload after victim / alias eviction"
  dst = D_RELOAD & !req[S_D].full
==>
begin
  issue(S_D, OP_LW, da, dc, 0);
  dst := D_FILL;
end;

rule "L1D: issue uncached after alias wb"
  dst = D_UNC_ISSUE & !req[S_D].full
==>
begin
  if dop = CO_USTORE then issue(S_D, OP_USW, da, dc, dsd); else issue(S_D, OP_ULW, da, dc, 0); endif;
  dst := D_UNC;
end;

-- probes: handled whatever the L1D FSM is doing (R2)
rule "L1D: probe"
  prb[S_D].full & !pack[S_D].full & (BUG_PROBE_BLOCKED = 0 | dst = D_IDLE)
==>
var c: Col;
begin
  c := prb[S_D].c;
  pack[S_D].full := true; pack[S_D].dirty := false; pack[S_D].d := 0;
  if dhit(prb[S_D].a, c) then
    if l1d[c].st = L_VD then pack[S_D].dirty := true; pack[S_D].d := l1d[c].d; endif;
    l1d[c].st := L_I;
  endif;
  prb[S_D].full := false;
end;

------------------------------------------------------------------ L1I (tag-only)
ruleset a: Addr do
  rule "L1I miss"
    L1I = 1 & !ifill & !ihit(a) & !req[S_I].full
  ==>
  begin
    l1i.st := L_I; ifill := true; ia := a;
    issue(S_I, OP_LW, a, 0, 0);
  end;
end;

rule "L1I: invalidate (I-sync / flush)"
  L1I = 1 & !ifill & l1i.st != L_I
==>
begin
  l1i.st := L_I;
end;

rule "L1I: probe"
  prb[S_I].full & !pack[S_I].full
==>
begin
  pack[S_I].full := true; pack[S_I].dirty := false; pack[S_I].d := 0;
  if ihit(prb[S_I].a) then l1i.st := L_I; endif;
  prb[S_I].full := false;
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
  for s: Src do
    req[s].full := false; req[s].op := OP_LW; req[s].a := 0; req[s].c := 0; req[s].d := 0;
    prb[s].full := false; prb[s].a := 0; prb[s].c := 0;
    pack[s].full := false; pack[s].dirty := false; pack[s].d := 0;
    pexp[s] := false;
  endfor;
  for s: L2Set do
    l2[s].valid := false; l2[s].dirty := false; l2[s].tag := 0; l2[s].d := 0;
    l2[s].pd := false; l2[s].pidx := 0; l2[s].pi := false;
  endfor;
  l2st := L2_IDLE; w := req[S_D]; wsrc := S_D;
  probed := false; pa := 0; pret := L2_IDLE;
  for c: Col do l1d[c].st := L_I; l1d[c].tag := 0; l1d[c].d := 0; endfor;
  dst := D_IDLE; dkind := K_LOAD; da := 0; dc := 0; dop := CO_NONE; dsd := 0; aliasc := 0;
  l1i.st := L_I; l1i.tag := 0; l1i.d := 0; ifill := false; ia := 0;
end;
