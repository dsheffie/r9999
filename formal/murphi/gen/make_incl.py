# derives r9999_incl.m from r9999_main.m (inclusive L2 + back-invalidate probes)
s=open('r9999_main.m').read()
def rep(old,new,cnt=1):
    global s
    n=s.count(old); assert n==cnt,(n,old[:100]); s=s.replace(old,new)

rep('''-- r9999_main.m -- Murphi model of the r9999 cache hierarchy at r9999 main 3b78e9b
-- (mem-sched merged; branch inclusive-l2-v2 starts here).  Step 1 of the inclusive-L2
-- work: model WHAT EXISTS, with explicit in-flight messages, then add L2->L1 messages.''',
'''-- r9999_incl.m -- r9999 cache hierarchy (main 3b78e9b) + an INCLUSIVE L2 with L2->L1
-- back-invalidate probes (branch inclusive-l2-v2, step 2).  INCL=0 reproduces main
-- (r9999_main.m, but with per-L1 request/response slots -- see below).
-- GENERATED from r9999_main.m by gen/make_incl.py; edit the generator, not this file.''')
rep('''--   * ONE L1->L2 transaction system-wide: the arbiter (core_l1d_l1i.sv:726-779) holds its
--     grant until the L2 responds; each L1 has at most one request outstanding.  -> req slot.''',
'''--   * The arbiter (core_l1d_l1i.sv:726-779) LATCHES each L1's request separately and grants
--     one at a time, holding the grant until the L2 responds; each L1 has at most one
--     request outstanding.  -> one request slot PER L1; the L2 accepts either when IDLE.
--     (An L1D victim MEM_SW can sit latched while the L2 works on an L1I miss that evicts
--     that very line -- exactly the window a back-invalidate must handle.)''')
rep('''-- Checked: loads (cached, uncached) see the latest value; a fetch after an I-sync sees the
-- latest value; a DMA-out device read sees the latest value; optional inclusion invariants.''',
'''-- Inclusion protocol (INCL=1): before the L2 drops or evicts a VALID line -- miss victim,
-- MEM_INVL/MEM_WB/MEM_PGDROP hit, uncached purge, flush walk -- it sends a probe for that
-- line to BOTH L1s and waits for both acks.  An L1 invalidates the line if it holds it and
-- acks, returning the data if it was dirty (L1D); the L2 merges dirty data into its copy
-- (dirty) and then proceeds exactly as main does.  The L1's ack never depends on the L1's
-- own FSM (a probe is handled whatever the L1 is waiting on).
--
-- Checked: loads (cached, uncached) see the latest value; a fetch after an I-sync sees the
-- latest value; a DMA-out device read sees the latest value; inclusion invariants.''')
rep('''--   negative controls (each re-introduces a bug fixed in the RTL; each MUST fail):''',
'''--   INCL           inclusive L2 with back-invalidate probes
--   RSP_DECOUPLED  the L2 may accept the next request while a response is still undelivered
--                  (a pipelined response path); RTL today installs the fill the same cycle
--   PROBE_ORDERED  an L1 consumes any pending response to it before it handles a probe
--                  (probes travel behind responses on one ordered channel)
--   CHECK_RULES    0 = drop the pure check rules (load hit / fetch hit / idle I-sync) that are
--                  always enabled self-loops, so Murphi's deadlock detection can see a deadlock
--   BUG_PROBE_BLOCKED  the L1D only answers a probe when idle (the summer's blocking-handshake
--                  deadlock: L2 waits for the ack, L1D waits for the L2)  -- MUST deadlock
--   negative controls (each re-introduces a bug fixed in the RTL; each MUST fail):''')
rep('''  CHECK_INCL_D: 0;
  CHECK_INCL_I: 0;
''','''  CHECK_INCL_D: 1;
  CHECK_INCL_I: 1;
  INCL: 1;
  RSP_DECOUPLED: 0;
  PROBE_ORDERED: 1;
  CHECK_RULES: 1;
  BUG_PROBE_BLOCKED: 0;
''')
rep('''  MAXV: 3;''','''  MAXV: 2;''')
rep('''  L2St: enum {L2_IDLE, L2_CHECK, L2_RELOAD, L2_UNC};''',
'''  L2St: enum {L2_IDLE, L2_CHECK, L2_RELOAD, L2_UPURGE, L2_UNC, L2_PROBE, L2_FLUSH};
  Probe: record full: boolean; a: Addr; end;
  PAck: record full: boolean; dirty: boolean; d: Ver; end;''')
rep('''  req: Req;                            -- arbiter grant (one transaction system-wide)
  rsp: Rsp;                            -- L2 -> L1 response''','''  req: array[Src] of Req;              -- each L1's latched request
  rsp: array[Src] of Rsp;              -- L2 -> L1 responses
  prb: array[Src] of Probe;            -- L2 -> L1 back-invalidate probes
  pack: array[Src] of PAck;            -- L1 -> L2 probe acks''')
rep('''  wacked: boolean;                     -- w was early-acked (cacheable MEM_SW)''','''  wacked: boolean;                     -- w was early-acked (cacheable MEM_SW)
  probed: boolean;                     -- the line this step drops/evicts has been probed
  pa: Addr;                            -- the line being probed
  pret: L2St;                          -- where the L2 resumes after the probe
  fset: L2Set;                         -- flush walk position''')
rep('''procedure issue(s: Src; o: Op; a: Addr; d: Ver);
begin
  assert !req.full "arbiter double grant";
  req.full := true; req.src := s; req.op := o; req.a := a; req.d := d;
end;

procedure respond(s: Src; d: Ver);
begin
  assert !rsp.full "response slot overrun";
  rsp.full := true; rsp.dst := s; rsp.d := d;
end;''','''procedure issue(s: Src; o: Op; a: Addr; d: Ver);
begin
  assert !req[s].full "L1 issued a second request";
  req[s].full := true; req[s].src := s; req[s].op := o; req[s].a := a; req[s].d := d;
end;

procedure respond(s: Src; d: Ver);
begin
  assert !rsp[s].full "response slot overrun";
  rsp[s].full := true; rsp[s].dst := s; rsp[s].d := d;
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
  prb[S_D].full := true; prb[S_D].a := a;
  if L1I = 1 then prb[S_I].full := true; prb[S_I].a := a; endif;
  pa := a; pret := ret; l2st := L2_PROBE;
end;''')
rep('''rule "L2 accept"
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
end;''','''ruleset s: Src do
  rule "L2 accept"
    req[s].full & l2st = L2_IDLE & rsp_free(s)
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
      l2[l2set(w.a)].valid := false; l2[l2set(w.a)].dirty := false;
    endif;
    l2st := L2_UNC;
  endif;
end;''')
rep('''rule "L2 check"
  l2st = L2_CHECK & !rsp.full
==>
begin
  switch w.op''','''rule "L2 check"
  l2st = L2_CHECK & rsp_free(w.src)
==>
begin
  if (w.op = OP_INVL | w.op = OP_PGDROP | w.op = OP_WB) & l2hit(w.a) & must_probe() then
    send_probes(w.a, L2_CHECK);
  elsif (w.op = OP_LW | w.op = OP_SW) & !l2hit(w.a) & l2[l2set(w.a)].valid & must_probe() then
    send_probes(l2[l2set(w.a)].tag, L2_CHECK);       -- the miss victim
  else
  switch w.op''')
rep('''  else
    error "bad L2 op";
  endswitch;
end;''','''  else
    error "bad L2 op";
  endswitch;
  endif;
end;''')
rep('''rule "L2 uncached DRAM access"
  l2st = L2_UNC & !rsp.full''','''rule "L2 uncached DRAM access"
  l2st = L2_UNC & rsp_free(w.src)''')
rep('''-- whole-L2 flush walk (FLUSH_WAIT/FLUSH_TRIAGE/FLUSH_STORE), only after the L1D flush
rule "L2 flush"
  dst = D_FLUSH_L2 & l2st = L2_IDLE & !req.full & !rsp.full
==>
begin
  for s: L2Set do
    if need_wb(s) then mem[l2[s].tag] := l2[s].d; endif;
    l2[s].valid := false; l2[s].dirty := false;
  endfor;
  dst := D_IDLE;
end;''','''-- all probe acks in: merge a dirty L1D copy (newer than the L2's) and resume
rule "L2 probe acks in"
  l2st = L2_PROBE & pack[S_D].full & (L1I = 0 | pack[S_I].full)
==>
begin
  assert l2hit(pa) "probed line left the L2 during the probe";
  assert !pack[S_I].dirty "L1I returned dirty data";
  if pack[S_D].dirty then
    l2[l2set(pa)].d := pack[S_D].d; l2[l2set(pa)].dirty := true;
  endif;
  pack[S_D].full := false; pack[S_I].full := false;
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
    probed := false;
    if fset = L2SETS-1 then
      l2st := L2_IDLE; dst := D_IDLE;
    else
      fset := fset + 1;
    endif;
  endif;
end;''')
s=s.replace('& !req.full','& !req[S_D].full')
rep('''    L1I = 1 & !ifill & !ihit(a) & !req[S_D].full & (!in_window(a) | SPEC_FILL = 1)''',
    '''    L1I = 1 & !ifill & !ihit(a) & !req[S_I].full & (!in_window(a) | SPEC_FILL = 1)''')
rep('''rule "L1D: response"
  rsp.full & rsp.dst = S_D
==>
var d: Ver;
begin
  d := rsp.d; rsp.full := false;''','''rule "L1D: response"
  rsp[S_D].full
==>
var d: Ver;
begin
  d := rsp[S_D].d; rsp[S_D].full := false;''')
rep('''rule "L1I: fill"
  rsp.full & rsp.dst = S_I
==>
begin
  assert ifill "L1I response without a miss";
  l1i.st := L_V; l1i.tag := ia; l1i.d := rsp.d;
  rsp.full := false; ifill := false;
end;''','''rule "L1I: fill"
  rsp[S_I].full
==>
begin
  assert ifill "L1I response without a miss";
  l1i.st := L_V; l1i.tag := ia; l1i.d := rsp[S_I].d;
  rsp[S_I].full := false; ifill := false;
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
end;''')
rep('''  rule "load hit"
    dst = D_IDLE & dhit(a) & !in_window(a)''','''  rule "load hit"
    CHECK_RULES = 1 & dst = D_IDLE & dhit(a) & !in_window(a)''')
rep('''  rule "fetch hit"
    ihit(a) & icoh[a] & !in_window(a)''','''  rule "fetch hit"
    CHECK_RULES = 1 & ihit(a) & icoh[a] & !in_window(a)''')
rep('''rule "I-sync: invalidate L1I"
  L1I = 1 & !ifill''','''rule "I-sync: invalidate L1I"
  L1I = 1 & !ifill & (CHECK_RULES = 1 | l1i.st != L_I)''')
rep('''  req.full := false; req.src := S_D; req.op := OP_LW; req.a := 0; req.d := 0;
  rsp.full := false; rsp.dst := S_D; rsp.d := 0;
  w := req; wacked := false;''','''  for s: Src do
    req[s].full := false; req[s].src := s; req[s].op := OP_LW; req[s].a := 0; req[s].d := 0;
    rsp[s].full := false; rsp[s].dst := s; rsp[s].d := 0;
    prb[s].full := false; prb[s].a := 0;
    pack[s].full := false; pack[s].dirty := false; pack[s].d := 0;
  endfor;
  w := req[S_D]; wacked := false; probed := false; pa := 0; pret := L2_IDLE;
  fset := 0;''')

# the DMA-in window closes when the XPG_INV drop COMPLETES (completion is signalled after
# the post-flush), not when it is issued -- with per-L1 request slots an L1I request can
# overtake the latched drop, so closing at issue lets software "use" the buffer early
rep('''  DmaSt: enum {DM_IDLE, DM_IN_ARMED, DM_IN_DONE, DM_OUT_ARMED};''',
    '''  DmaSt: enum {DM_IDLE, DM_IN_ARMED, DM_IN_DONE, DM_IN_DROP, DM_OUT_ARMED};''')
rep('''begin return (dma = DM_IN_ARMED | dma = DM_IN_DONE) & daddr = a; end;''',
    '''begin return (dma = DM_IN_ARMED | dma = DM_IN_DONE | dma = DM_IN_DROP) & daddr = a; end;''')
rep('''  issue(S_D, OP_PGDROP, daddr, 0);
  dst := D_OP;
  dma := DM_IDLE;''','''  issue(S_D, OP_PGDROP, daddr, 0);
  dst := D_OP;
  dma := DM_IN_DROP;''')
rep('''  case D_OP:
    if dop = CO_CHWB then''','''  case D_OP:
    if dop = CO_XPG_INV then
      dma := DM_IDLE;                                -- completion signalled after the drop
    endif;
    if dop = CO_CHWB then''')

exec(open("gen/rsp_inline.py").read())
exec(open("gen/tagonly.py").read())
exec(open("gen/presence.py").read())
exec(open("gen/dmasnoop.py").read())
bad=[l for l in s.split('\n') if 'req.full' in l or 'rsp.full' in l or 'rsp.d ' in l]
assert not bad, bad
import sys
open(sys.argv[1] if len(sys.argv) > 1 else 'r9999_incl.m','w').write(s)
print("written")
