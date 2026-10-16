# exec'd by make_incl.py (operates on `s`, `rep`).
# DMA_SNOOP=1: replace the silicon ARM page flush (XPG_* = injected serializing uops the
# CORE runs on the L1D) with snoop operations the ARM queues to the L2 directly.  With an
# inclusive L2 the L2 reaches the L1s through its own back-invalidate probes, so the core
# never stops.  Same discipline the r9999_dma.m study proved necessary:
#   pre  (before the device transfer): SNP_WBINV -- probe L1s (dirty data comes back),
#        write a dirty line back, drop it.  A dirty stale copy surviving into the window
#        would be evicted OVER the device data.
#   post (DMA-in, after the device wrote DRAM): SNP_DROP -- probe L1s, drop WITHOUT
#        writeback (catches lines speculatively refilled inside the window).
#   completion is signalled only when the post-drop has finished.
# The snoop slot has priority over L1 requests in IDLE (as the DMA snoop does, l2.sv:533).
# Knobs: BUG_SNOOP_NO_PRE (skip the pre-snoop), BUG_SNOOP_EARLY_DONE (signal completion at
# post-snoop ISSUE) -- each MUST fail.  DMA_SNOOP with INCL=0 must fail too (an L2-only
# snoop cannot reach an L1-held copy).

rep('''  PRES: 0;
''', '''  PRES: 0;
  DMA_SNOOP: 0;
  BUG_SNOOP_NO_PRE: 0;
  BUG_SNOOP_EARLY_DONE: 0;
  BUG_SNOOP_NO_ABSORB: 0;
''')
rep('''--   PRES           per-L2-line presence bits''',
    '''--   DMA_SNOOP      DMA coherence by L2 snoop ops queued by the ARM (pre SNP_WBINV, post
--                  SNP_DROP, completion after the drop) instead of core-run XPG page walks
--   BUG_SNOOP_NO_PRE / BUG_SNOOP_EARLY_DONE   skip the pre-snoop / signal completion at
--                  post-snoop issue                                          -- MUST fail
--   BUG_SNOOP_NO_ABSORB  the snoop ignores an L1D writeback (MEM_WB/MEM_SW) to the same
--                  line that is LATCHED in the arbiter: the L1D already gave up the line
--                  (probe says "not here") but its dirty data is still in transit -- MUST fail
--   PRES           per-L2-line presence bits''')

rep('''  Op: enum {OP_LW, OP_SW, OP_ULW, OP_USW, OP_WB, OP_INVL, OP_PGDROP};''',
    '''  Op: enum {OP_LW, OP_SW, OP_ULW, OP_USW, OP_WB, OP_INVL, OP_PGDROP, OP_SNP_WBINV, OP_SNP_DROP};
  Snp: record full: boolean; op: Op; a: Addr; end;''')
rep('''  DmaSt: enum {DM_IDLE, DM_IN_ARMED, DM_IN_DONE, DM_IN_DROP, DM_OUT_ARMED};''',
    '''  DmaSt: enum {DM_IDLE, DM_IN_PRE, DM_IN_ARMED, DM_IN_DONE, DM_IN_DROP, DM_OUT_PRE, DM_OUT_ARMED};''')
rep('''begin return (dma = DM_IN_ARMED | dma = DM_IN_DONE | dma = DM_IN_DROP) & daddr = a; end;''',
    '''begin return (dma = DM_IN_PRE | dma = DM_IN_ARMED | dma = DM_IN_DONE | dma = DM_IN_DROP) & daddr = a; end;''')
rep('''begin return dma = DM_OUT_ARMED & daddr = a; end;''',
    '''begin return (dma = DM_OUT_PRE | dma = DM_OUT_ARMED) & daddr = a; end;''')
rep('''  pexp: array[Src] of boolean;         -- probe outstanding to this L1''',
    '''  pexp: array[Src] of boolean;         -- probe outstanding to this L1
  snp: Snp;                            -- ARM -> L2 DMA snoop request''')

# snoops win IDLE over L1 requests
rep('''    req[s].full & l2st = L2_IDLE & rsp_free(s)''',
    '''    req[s].full & l2st = L2_IDLE & rsp_free(s) & !snp.full''')

# L2: accept + execute snoops
a = s.index('-- all probe acks in:')
s = s[:a] + '''-- DMA snoop from the ARM: taken in IDLE ahead of L1 requests
rule "L2 accept snoop"
  snp.full & l2st = L2_IDLE & rsp_free(S_D) & rsp_free(S_I)
==>
begin
  w.full := true; w.src := S_D; w.op := snp.op; w.a := snp.a; w.d := 0;
  snp.full := false;
  wacked := false; probed := false;
  l2st := L2_CHECK;
end;

''' + s[a:]

rep('''  if (w.op = OP_INVL | w.op = OP_PGDROP | w.op = OP_WB) & l2hit(w.a) & must_probe() then''',
    '''  if (w.op = OP_INVL | w.op = OP_PGDROP | w.op = OP_WB | w.op = OP_SNP_WBINV | w.op = OP_SNP_DROP)
     & l2hit(w.a) & must_probe() then''')
rep('''  case OP_WB:''', '''  case OP_SNP_WBINV:
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
  case OP_WB:''')

# the core-run XPG flushes only without DMA_SNOOP
rep('''    DMA = 1 & dma = DM_IDLE & dst = D_IDLE & !req[S_D].full
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
    dma := DM_IN_ARMED; daddr := a;''',
    '''    DMA = 1 & DMA_SNOOP = 0 & dma = DM_IDLE & dst = D_IDLE & !req[S_D].full
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
    dma := DM_IN_ARMED; daddr := a;''')
rep('''    DMA = 1 & dma = DM_IDLE & dst = D_IDLE & !req[S_D].full
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
    dma := DM_OUT_ARMED; daddr := a;''',
    '''    DMA = 1 & DMA_SNOOP = 0 & dma = DM_IDLE & dst = D_IDLE & !req[S_D].full
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
    dma := DM_OUT_ARMED; daddr := a;''')
rep('''  dma = DM_IN_DONE & dst = D_IDLE & !req[S_D].full
==>''', '''  DMA_SNOOP = 0 & dma = DM_IN_DONE & dst = D_IDLE & !req[S_D].full
==>''')
# the device side no longer waits for an idle L1D in snoop mode (the core keeps running)
rep('''  dma = DM_IN_ARMED & dst = D_IDLE & latest[daddr] < MAXV''',
    '''  dma = DM_IN_ARMED & (DMA_SNOOP = 1 | dst = D_IDLE) & latest[daddr] < MAXV''')
rep('''  dma = DM_OUT_ARMED & dst = D_IDLE
==>''', '''  dma = DM_OUT_ARMED & (DMA_SNOOP = 1 | dst = D_IDLE)
==>''')

# the ARM's snoop rules
a = s.index('------------------------------------------------------------------ invariants')
s = s[:a] + '''-- DMA_SNOOP: the ARM queues L2 snoops; the core is never stopped
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

''' + s[a:]

rep('''  w := req[S_D]; wacked := false; probed := false; pa := 0; pret := L2_IDLE;
  fset := 0;''', '''  w := req[S_D]; wacked := false; probed := false; pa := 0; pret := L2_IDLE;
  fset := 0;
  snp.full := false; snp.op := OP_SNP_DROP; snp.a := 0;''')
