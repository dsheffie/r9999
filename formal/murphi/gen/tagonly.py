# exec'd by make_incl.py (operates on `s`, `rep`).
# L1I_TAGONLY=1: the L1I keeps its full line/fill/probe behaviour (which line it holds,
# when it is filled, invalidated, probed) but drops its DATA and the fetch-coherence
# ghosts (dclean/icoh), which only feed the fetch-after-I-sync check -- already proven on
# main (r9999_main.m).  Inclusion depends only on the L1I's tag/valid.  The ghosts are also
# dropped when L1I=0, where nothing reads them.  FETCH_GHOSTS = whether they are live.

rep('''  BUG_PROBE_BLOCKED: 0;
''', '''  BUG_PROBE_BLOCKED: 0;
  L1I_TAGONLY: 0;
''')
rep('''--   BUG_PROBE_BLOCKED  the L1D only answers a probe when idle''',
    '''--   L1I_TAGONLY    the L1I keeps line/fill/probe behaviour but no data and no fetch-coherence
--                  ghosts (inclusion only needs its tag/valid; fetch coherence is proven
--                  on main); the ghosts are also dropped when L1I=0
--   BUG_PROBE_BLOCKED  the L1D only answers a probe when idle''')

# helper: are the fetch ghosts live?
a = s.index('function dhit(a: Addr): boolean;')
s = s[:a] + ('function fetch_ghosts(): boolean;\n'
             'begin return L1I = 1 & L1I_TAGONLY = 0; end;\n\n') + s[a:]

rep('''  dclean[a] := false;
  icoh[a] := false;''', '''  if fetch_ghosts() then
    dclean[a] := false;
    icoh[a] := false;
  endif;''')
rep('''      dclean[da] := true;''', '''      if fetch_ghosts() then dclean[da] := true; endif;''')
rep('''  l1i.st := L_V; l1i.tag := ia; l1i.d := d;''',
    '''  l1i.st := L_V; l1i.tag := ia;
  if L1I_TAGONLY = 0 then l1i.d := d; endif;''')
rep('''    CHECK_RULES = 1 & ihit(a) & icoh[a] & !in_window(a)''',
    '''    CHECK_RULES = 1 & fetch_ghosts() & ihit(a) & icoh[a] & !in_window(a)''')
rep('''  for a: Addr do icoh[a] := dclean[a] & !in_window(a); endfor;''',
    '''  if fetch_ghosts() then
    for a: Addr do icoh[a] := dclean[a] & !in_window(a); endfor;
  endif;''')
rep('''  dclean[daddr] := true; icoh[daddr] := false;''',
    '''  if fetch_ghosts() then dclean[daddr] := true; icoh[daddr] := false; endif;''')
