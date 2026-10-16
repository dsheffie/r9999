# exec'd by make_incl.py (operates on `s`, `rep`).
# PRES=1: per-L2-line presence bits pd/pi ("the L1D / L1I MAY hold this line").
#   set:    when the L2 answers that L1's fill (MEM_LW response)
#   clear:  when the L1D provably gave the line up (its victim MEM_SW completes, its CACHE-op
#           MEM_INVL/MEM_WB, uncached alias drop) and whenever the L2 line is dropped/replaced
#   NOT cleared on silent clean L1 evictions -> conservative (may be stale-set, never
#   stale-clear).  The L2 probes only the L1s whose bit is set (none -> no probe at all).
# Invariant (stronger than inclusion): a valid L1 line has its presence bit set in the L2.
# BUG_PRES_NOSET_I: the L1I fill forgets to set pi -> must break inclusion.

rep('''  L1I_TAGONLY: 0;
''', '''  L1I_TAGONLY: 0;
  PRES: 0;
  BUG_PRES_NOSET_I: 0;
''')
rep('''--   BUG_PROBE_BLOCKED  the L1D only answers a probe when idle''',
    '''--   PRES           per-L2-line presence bits (pd/pi); probe only an L1 that may hold the line
--   BUG_PRES_NOSET_I  an L1I fill forgets to set pi                              -- MUST fail
--   BUG_PROBE_BLOCKED  the L1D only answers a probe when idle''')

rep('''  L2Line: record valid: boolean; dirty: boolean; tag: Addr; d: Ver; end;''',
    '''  L2Line: record valid: boolean; dirty: boolean; tag: Addr; d: Ver; pd: boolean; pi: boolean; end;''')
rep('''  pack: array[Src] of PAck;            -- L1 -> L2 probe acks''',
    '''  pack: array[Src] of PAck;            -- L1 -> L2 probe acks
  pexp: array[Src] of boolean;         -- probe outstanding to this L1''')

# every drop/replace of an L2 line clears its presence bits
s = s.replace('l2[l2set(w.a)].valid := false; l2[l2set(w.a)].dirty := false;',
              'l2[l2set(w.a)].valid := false; l2[l2set(w.a)].dirty := false; '
              'l2[l2set(w.a)].pd := false; l2[l2set(w.a)].pi := false;')
rep('''    if l2hit(w.a) then l2[l2set(w.a)].valid := false; endif;''',
    '''    if l2hit(w.a) then
      l2[l2set(w.a)].valid := false;
      l2[l2set(w.a)].pd := false; l2[l2set(w.a)].pi := false;
    endif;''')
rep('''    l2[fset].valid := false; l2[fset].dirty := false;''',
    '''    l2[fset].valid := false; l2[fset].dirty := false;
    l2[fset].pd := false; l2[fset].pi := false;''')
rep('''    l2[s].valid := false; l2[s].dirty := false; l2[s].tag := 0; l2[s].d := 0;''',
    '''    l2[s].valid := false; l2[s].dirty := false; l2[s].tag := 0; l2[s].d := 0;
    l2[s].pd := false; l2[s].pi := false;''')
# a refill installs a new line: nobody holds it yet
rep('''  l2[l2set(w.a)].valid := true; l2[l2set(w.a)].tag := w.a; l2[l2set(w.a)].d := mem[w.a];''',
    '''  l2[l2set(w.a)].valid := true; l2[l2set(w.a)].tag := w.a; l2[l2set(w.a)].d := mem[w.a];
  l2[l2set(w.a)].pd := false; l2[l2set(w.a)].pi := false;''')
# fill response: set the requester's bit
rep('''        respond(w.src, l2[l2set(w.a)].d);''',
    '''        if PRES = 1 & w.src = S_D then
          l2[l2set(w.a)].pd := true;
        elsif PRES = 1 & BUG_PRES_NOSET_I = 0 then
          l2[l2set(w.a)].pi := true;
        endif;
        respond(w.src, l2[l2set(w.a)].d);''')
# the L1D's victim writeback completed: it no longer holds the line
rep('''        l2[l2set(w.a)].d := w.d; l2[l2set(w.a)].dirty := true;''',
    '''        l2[l2set(w.a)].d := w.d; l2[l2set(w.a)].dirty := true;
        if w.src = S_D then l2[l2set(w.a)].pd := false; endif;''')

# probe only the L1s that may hold the line
rep('''procedure send_probes(a: Addr; ret: L2St);
begin
  prb[S_D].full := true; prb[S_D].a := a;
  if L1I = 1 then prb[S_I].full := true; prb[S_I].a := a; endif;
  pa := a; pret := ret; l2st := L2_PROBE;
end;''', '''procedure send_probes(a: Addr; ret: L2St);
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
end;''')
rep('''  l2st = L2_PROBE & pack[S_D].full & (L1I = 0 | pack[S_I].full)''',
    '''  l2st = L2_PROBE & (!pexp[S_D] | pack[S_D].full) & (!pexp[S_I] | pack[S_I].full)''')
rep('''  pack[S_D].full := false; pack[S_I].full := false;''',
    '''  pack[S_D].full := false; pack[S_I].full := false;
  pexp[S_D] := false; pexp[S_I] := false;
  l2[l2set(pa)].pd := false; l2[l2set(pa)].pi := false;   -- both L1s just dropped it''')
rep('''    pack[s].full := false; pack[s].dirty := false; pack[s].d := 0;
  endfor;''', '''    pack[s].full := false; pack[s].dirty := false; pack[s].d := 0;
    pexp[s] := false;
  endfor;''')

# presence invariants (only meaningful with INCL & PRES)
rep('''invariant "inclusion: L1I subset of L2"''',
    '''invariant "presence: an L1D-held line has pd set"
  INCL = 0 | PRES = 0 | l1d.st = L_I | (l2hit(l1d.tag) & l2[l2set(l1d.tag)].pd);

invariant "presence: an L1I-held line has pi set"
  INCL = 0 | PRES = 0 | L1I = 0 | l1i.st = L_I | (l2hit(l1i.tag) & l2[l2set(l1i.tag)].pi);

invariant "inclusion: L1I subset of L2"''')
