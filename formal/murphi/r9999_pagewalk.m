-- r9999_pagewalk.m -- SCSI DMA coherence with a hardware PAGE-LIST walker (design B, per page)
-- Builds on r9999_dma.m's cache abstraction (blocking L1D; write-back L2 with early-acked
-- MEM_SW; IRIX's own prep: Hit ops / Index_WB_Inv_D (FIX_INDEX_INV = cb7d225) / skip;
-- speculative fills).  Addresses stand for PAGES (the SCSI extents are whole aligned pages).
--
-- A disk READ (DMA-in) of a set of pages:
--   IRIX preps each page (or skips it) -> ARM loads the pages into the walker, which for
--   each page WRITES BACK + INVALIDATES the L1D copy (a dirty line leaves as an early-acked
--   MEM_SW) and then the L2 copy (write back if dirty, drop) -> the ARM deposits every page
--   in DRAM -> the walker DROPS each page (no writeback) from the L2 and the L1D -> doorbell.
--   OVERFLOW: the ARM uses the whole-cache flush before and after instead.
-- A disk WRITE (DMA-out): IRIX prep -> walker write back + invalidate -> device reads DRAM.
--
-- Knobs
--   PRE_L1_FIRST   1 = per page, the L1D step precedes the L2 step before the transfer
--   POST_L2_FIRST  1 = per page, the L2 drop precedes the L1D drop after the deposit
--   CHECK_DIRTY    1 = assert no dirty copy (L1D, L2, in-flight MEM_SW) of a page it drops
--   CORE_DRAINED   1 = the core is frozen while the walker runs (injected-uop walker); the
--                  core still runs (and fills speculatively) while the device writes
--   OVERFLOW       1 = a transfer may take the whole-cache-flush path instead
--   IRIX_SKIP / SPEC_FILL / USE_INDEX_PREP / FIX_INDEX_INV  as in r9999_dma.m

const
  NADDR: 3;
  MAXV: 3;

  PRE_L1_FIRST: 1;
  POST_L2_FIRST: 1;
  CHECK_DIRTY: 1;
  CORE_DRAINED: 1;
  OVERFLOW: 1;
  IRIX_SKIP: 1;
  SPEC_FILL: 1;
  USE_INDEX_PREP: 1;
  FIX_INDEX_INV: 1;
  DMA_OUT: 1;
  WALK_PRE: 1;             -- 0 = negative control: the walker skips its write-back step

type
  Addr: 0..NADDR-1;
  Ver: 0..MAXV;
  LState: enum {L_I, L_V, L_VD};
  L1Line: record st: LState; tag: Addr; d: Ver; end;
  L2Line: record valid: boolean; dirty: boolean; tag: Addr; d: Ver; end;
  PendSW: record full: boolean; addr: Addr; d: Ver; end;
  XSt: enum {X_IDLE, X_IRIX, X_PRE, X_DEV, X_POST, X_OIRIX, X_OPRE, X_ODEV};
  PrepOp: enum {P_CHINV, P_CHWBINV, P_INDEX};

var
  latest: array[Addr] of Ver;
  mem: array[Addr] of Ver;
  l1d: L1Line;
  l2: L2Line;
  sw: PendSW;
  xs: XSt;
  ovf: boolean;                          -- this transfer took the whole-flush path
  inset: array[Addr] of boolean;         -- pages in the transfer
  irix: array[Addr] of boolean;          -- IRIX has prepped (or skipped) the page
  s1: array[Addr] of boolean;            -- walker step 1 done (pre: L1D / post: first level)
  s2: array[Addr] of boolean;            -- walker step 2 done
  wr: array[Addr] of boolean;            -- the device has written / read the page

------------------------------------------------------------------ helpers
function l1d_hit(a: Addr): boolean;
begin return l1d.st != L_I & l1d.tag = a; end;

function in_window(a: Addr): boolean;
begin return inset[a] & (xs = X_IRIX | xs = X_PRE | xs = X_DEV | xs = X_POST); end;

function out_window(a: Addr): boolean;
begin return inset[a] & (xs = X_OIRIX | xs = X_OPRE | xs = X_ODEV); end;

-- the injected-uop walker runs with the core drained (CORE_DRAINED=1)
function core_frozen(): boolean;
begin return CORE_DRAINED = 1 & (xs = X_PRE | xs = X_POST | xs = X_OPRE); end;

function l2_idle(): boolean;
begin return !sw.full; end;

procedure l2_fill(a: Addr; var d: Ver);
begin
  if !(l2.valid & l2.tag = a) then
    if l2.valid & l2.dirty then mem[l2.tag] := l2.d; endif;
    l2.valid := true; l2.dirty := false; l2.tag := a; l2.d := mem[a];
  endif;
  d := l2.d;
end;

procedure l2_store(a: Addr; d: Ver);
var t: Ver;
begin
  l2_fill(a, t);
  l2.d := d;
  l2.dirty := true;
end;

procedure l2_invl(a: Addr);            -- MEM_INVL: write back if dirty, drop
begin
  if l2.valid & l2.tag = a then
    if l2.dirty then mem[a] := l2.d; endif;
    l2.valid := false; l2.dirty := false;
  endif;
end;

procedure l2_snoop_drop(a: Addr);      -- MEM_SNOOP_INVL: drop, no writeback
begin
  if l2.valid & l2.tag = a then l2.valid := false; l2.dirty := false; endif;
end;

procedure l2_wb(a: Addr; d: Ver);
begin
  mem[a] := d;
  if l2.valid & l2.tag = a then l2.valid := false; endif;
end;

procedure do_prep(op: PrepOp; a: Addr);
begin
  switch op
  case P_CHINV:
    if l1d_hit(a) then l1d.st := L_I; endif;
    l2_invl(a);
  case P_CHWBINV:
    if l1d_hit(a) & l1d.st = L_VD then
      l2_wb(a, l1d.d); l1d.st := L_I;
    else
      if l1d_hit(a) then l1d.st := L_I; endif;
      l2_invl(a);
    endif;
  case P_INDEX:
    if l1d.st = L_VD then
      l2_wb(l1d.tag, l1d.d);
      if FIX_INDEX_INV = 1 then l1d.st := L_I; endif;
    else
      l1d.st := L_I;
    endif;
  endswitch;
end;

procedure global_flush();
begin
  if l1d.st = L_VD then l2_wb(l1d.tag, l1d.d); endif;
  l1d.st := L_I;
  if l2.valid & l2.dirty then mem[l2.tag] := l2.d; endif;
  l2.valid := false; l2.dirty := false;
end;



function all_set(): boolean;   -- every page in the set has s1 & s2
begin
  for a: Addr do if inset[a] & !(s1[a] & s2[a]) then return false; endif; endfor;
  return true;
end;
function all_irix(): boolean;
begin
  for a: Addr do if inset[a] & !irix[a] then return false; endif; endfor;
  return true;
end;
function all_wr(): boolean;
begin
  for a: Addr do if inset[a] & !wr[a] then return false; endif; endfor;
  return true;
end;
procedure clear_steps();
begin
  for a: Addr do s1[a] := false; s2[a] := false; endfor;
end;

------------------------------------------------------------------ core
ruleset a: Addr do
  rule "load hit"
    l1d_hit(a) & !core_frozen() & !in_window(a)
  ==>
  begin
    assert l1d.d = latest[a] "load returned a stale value";
  end;

  rule "store hit"
    l1d_hit(a) & !core_frozen() & !in_window(a) & !out_window(a) & latest[a] < MAXV
  ==>
  begin
    latest[a] := latest[a] + 1;
    l1d.d := latest[a]; l1d.st := L_VD;
  end;

  rule "L1D refill"
    !l1d_hit(a) & !core_frozen() & l1d.st != L_VD & l2_idle() & (!in_window(a) | SPEC_FILL = 1)
  ==>
  var d: Ver;
  begin
    l2_fill(a, d);
    l1d.st := L_V; l1d.tag := a; l1d.d := d;
  end;

  rule "uncached load"
    !l1d_hit(a) & !core_frozen() & l2_idle() & !in_window(a)
  ==>
  begin
    l2_invl(a);
    assert mem[a] = latest[a] "uncached load returned a stale value";
  end;
end;

rule "L1D dirty eviction (MEM_SW, early ack)"
  l1d.st = L_VD & !core_frozen() & l2_idle()
==>
begin
  sw.full := true; sw.addr := l1d.tag; sw.d := l1d.d;
  l1d.st := L_I;
end;

rule "L2 performs the early-acked store"
  sw.full
==>
begin
  l2_store(sw.addr, sw.d);
  sw.full := false;
end;

------------------------------------------------------------------ transfers
-- start a transfer on page a alone or on pages {a, b}
ruleset a: Addr; b: Addr do
  rule "start disk READ (DMA-in)"
    xs = X_IDLE & a <= b & latest[a] < MAXV & latest[b] < MAXV
  ==>
  begin
    for c: Addr do inset[c] := (c = a | c = b); irix[c] := false; wr[c] := false; endfor;
    clear_steps(); ovf := false;
    xs := X_IRIX;
  end;

  rule "start disk WRITE (DMA-out)"
    DMA_OUT = 1 & xs = X_IDLE & a <= b
  ==>
  begin
    for c: Addr do inset[c] := (c = a | c = b); irix[c] := false; wr[c] := false; endfor;
    clear_steps(); ovf := false;
    xs := X_OIRIX;
  end;
endruleset;

-- IRIX's own preparation of each page (it never touches the pages until completion)
ruleset a: Addr; op: PrepOp do
  rule "IRIX preps a page"
    (xs = X_IRIX | xs = X_OIRIX) & inset[a] & !irix[a] & l2_idle() &
    (op != P_INDEX | USE_INDEX_PREP = 1) & !(xs = X_OIRIX & op = P_CHINV)
  ==>
  begin
    do_prep(op, a); irix[a] := true;
  end;
endruleset;

ruleset a: Addr do
  rule "IRIX skips a page (not in the primary)"
    IRIX_SKIP = 1 & (xs = X_IRIX | xs = X_OIRIX) & inset[a] & !irix[a] & !l1d_hit(a)
  ==>
  begin irix[a] := true; end;
endruleset;

rule "ARM hands the pages to the walker"
  (xs = X_IRIX | xs = X_OIRIX) & all_irix()
==>
begin
  if xs = X_IRIX then xs := X_PRE; else xs := X_OPRE; endif;
end;

rule "OVERFLOW: whole-cache flush before the transfer"
  OVERFLOW = 1 & (xs = X_PRE | xs = X_OPRE) & !ovf & l2_idle() & !(exists a: Addr do s1[a] | s2[a] endexists)
==>
begin
  global_flush(); ovf := true;
  for a: Addr do s1[a] := true; s2[a] := true; endfor;
end;

-- walker, BEFORE the transfer: write back + invalidate each page (L1D, then L2)
ruleset a: Addr do
  rule "walker pre: L1D write back + invalidate"
    (xs = X_PRE | xs = X_OPRE) & inset[a] & !s1[a] & l2_idle() & (PRE_L1_FIRST = 1 | true)
  ==>
  begin
    if WALK_PRE = 1 & l1d_hit(a) then
      if l1d.st = L_VD then sw.full := true; sw.addr := a; sw.d := l1d.d; endif;   -- early-acked MEM_SW
      l1d.st := L_I;
    endif;
    s1[a] := true;
  end;

  rule "walker pre: L2 write back + invalidate"
    (xs = X_PRE | xs = X_OPRE) & inset[a] & !s2[a] & l2_idle() & (PRE_L1_FIRST = 0 | s1[a])
  ==>
  begin
    if WALK_PRE = 1 then l2_invl(a); endif;
    s2[a] := true;
  end;
endruleset;

rule "walker pre done"
  (xs = X_PRE | xs = X_OPRE) & all_set() & l2_idle()
==>
begin
  clear_steps();
  if xs = X_PRE then xs := X_DEV; else xs := X_ODEV; endif;
end;

-- the device (the ARM) moves each page; the core runs meanwhile
ruleset a: Addr do
  rule "device writes a page (disk read)"
    xs = X_DEV & inset[a] & !wr[a]
  ==>
  begin
    latest[a] := latest[a] + 1; mem[a] := latest[a]; wr[a] := true;
  end;

  rule "device reads a page (disk write)"
    xs = X_ODEV & inset[a] & !wr[a]
  ==>
  begin
    assert mem[a] = latest[a] "DEVICE READ STALE DATA (disk write)";
    wr[a] := true;
  end;
endruleset;

rule "disk write complete"
  xs = X_ODEV & all_wr()
==>
begin
  for a: Addr do inset[a] := false; endfor;
  xs := X_IDLE;
end;

rule "deposit complete -> walker post"
  xs = X_DEV & all_wr()
==>
begin
  xs := X_POST;
  if ovf then for a: Addr do s1[a] := false; s2[a] := false; endfor; endif;
end;

rule "OVERFLOW: whole-cache flush after the deposit"
  xs = X_POST & ovf & l2_idle() & !all_set()
==>
begin
  global_flush();
  for a: Addr do s1[a] := true; s2[a] := true; endfor;
end;

-- walker, AFTER the deposit: drop each page, no writeback (L2, then L1D); nothing in the
-- range may be dirty
ruleset a: Addr do
  rule "walker post: L2 drop"
    xs = X_POST & !ovf & inset[a] & !s1[a] & l2_idle()
  ==>
  begin
    if CHECK_DIRTY = 1 then
      assert !(l2.valid & l2.tag = a & l2.dirty) "DIRTY L2 COPY OF A DMA PAGE AT THE POST DROP";
      assert !(sw.full & sw.addr = a) "IN-FLIGHT WRITEBACK OF A DMA PAGE AT THE POST DROP";
    endif;
    l2_snoop_drop(a);
    s1[a] := true;
  end;

  rule "walker post: L1D drop"
    xs = X_POST & !ovf & inset[a] & !s2[a] & (POST_L2_FIRST = 0 | s1[a])
  ==>
  begin
    if CHECK_DIRTY = 1 then
      assert !(l1d_hit(a) & l1d.st = L_VD) "DIRTY L1D COPY OF A DMA PAGE AT THE POST DROP";
    endif;
    if l1d_hit(a) then l1d.st := L_I; endif;
    s2[a] := true;
  end;
endruleset;

rule "doorbell (completion)"
  xs = X_POST & all_set()
==>
begin
  for a: Addr do inset[a] := false; endfor;
  clear_steps();
  xs := X_IDLE;
end;

------------------------------------------------------------------ start
startstate
begin
  for a: Addr do
    latest[a] := 0; mem[a] := 0;
    inset[a] := false; irix[a] := false; s1[a] := false; s2[a] := false; wr[a] := false;
  endfor;
  l1d.st := L_I; l1d.tag := 0; l1d.d := 0;
  l2.valid := false; l2.dirty := false; l2.tag := 0; l2.d := 0;
  sw.full := false; sw.addr := 0; sw.d := 0;
  xs := X_IDLE; ovf := false;
end;
