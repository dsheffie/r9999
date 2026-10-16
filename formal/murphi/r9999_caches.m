-- r9999_caches.m -- Murphi model of the r9999 (MIPS) cache hierarchy vs DMA / CACHE ops
-- Source: ~/code/r9999 origin/main @ d0481b8 (same cache/L2 code as rdchk-reader-agreement
-- fd026cc, the wb-shadow tree d0481b8 and the henry submodule; the branch only adds a
-- tied-off dma_inval port and formal hooks).
--   l1d.sv  direct-mapped, write-back, write-allocate, BLOCKING (one request in flight)
--   l2.sv   direct-mapped, write-back, write-allocate, serial FSM; a cacheable MEM_SW
--           (opcode 7) is acked at ACCEPT (IDLE: n_rsp_valid = opcode==7), the write
--           itself lands later
--   core_l1d_l1i.sv  L1D/L1I arbiter latches both request pulses, one grant at a time,
--           re-arms on the L2 response (so the next request queues behind an early-acked
--           store until the L2 is IDLE again)
-- RTL anchors (origin/main):
--   l1d.sv:2149  Hit CACHE ops (CHINV / CHWBINV / CHWB) from the mem pipe: dirty hit & !CHINV
--                -> MEM_WB + invalidate; otherwise invalidate-if-hit + MEM_INVL
--   l1d.sv:2690  FLUSH_CL (Index CACHE ops, core.sv:1824 flush_cl_req, inval=0): dirty line
--                -> MEM_WB, line stays VALID+DIRTY (no t_mark_invalid; FLUSH_CL_WAIT does not
--                clear it either) -> FIX_INDEX_INV.  Clean line -> invalidate, NO L2 request.
--   l1d.sv:2200  uncached op: UNCACHE_WB drops an aliasing L1D line (MEM_SW if dirty) first
--   l2.sv  MEM_INVL: drop, writing back first if dirty.  MEM_WB: data straight to DRAM, drop
--          the L2 copy.  MEM_SNOOP_INVL (henry DMA snoop; tied off on main): drop, NO writeback.
--          Uncached: drop an aliasing L2 line (write back if dirty), then go to DRAM.
--
-- IRIX side (unix.a2 disasm, see memory project_invisible_l2_dma_root_cause): IRIX sees NO
-- secondary cache.  __dcache_inval: <= 16 KB -> Hit ops per line; > 16 KB -> Index_WB_Inv_D
-- over the 16 KB primary.  IRIX skips invalidates for pages it believes are not in the
-- primary cache (IRIX_SKIP).  A DMA-in window is: prep (invalidate) -> device writes DRAM ->
-- the buffer is used.  Software never touches the buffer inside the window, but the OOO core
-- may fill it speculatively (SPEC_FILL).
--
-- Abstraction: NADDR line addresses that all collide in the one L1D line, the one L1I line
-- and the one L2 line.  Data = a version number.  Ghost latest[] = the architecturally
-- latest value of each line (CPU store, uncached store or DMA write).  Checked:
--   * a (non-speculative) load / uncached load returns latest
--   * a device read (DMA-out) after the WB prep returns latest
--   * an instruction fetch after an I-sync (D writeback + I invalidate) returns latest
-- Untimed: every enabled action fires in any order.
--
-- Knobs (0/1)
--   USE_HIT_PREP    IRIX may prep a DMA with Hit ops (<= 16 KB)
--   USE_INDEX_PREP  IRIX may prep a DMA with Index_WB_Inv_D (> 16 KB)
--   IRIX_SKIP       IRIX may skip the prep when the line is not in the L1D
--   SPEC_FILL       wrong-path loads may fill a line inside its DMA window
--   FIX_INDEX_INV   FLUSH_CL's dirty arm also invalidates the L1D line
--   SNOOP_L2        henry DMA snoop: a device write drops the L2 copy (no writeback)
--   SNOOP_L1D       hypothetical: a device write also drops the L1D copy
--   HAS_L2          0 = model the L2 as absent (ENABLE_L2_NOCACHE-like pass-through)
--   FWD_INDEX       the L1D forwards Index CACHE ops to the L2 as an index op on the same
--                   set: write back if dirty, then invalidate (the model has one L2 set, so
--                   this assumes the L2 is no bigger than the 16 KB IRIX sweeps)
--   L2_WT           the L2 is write-through: an L1D eviction also writes DRAM, L2 never dirty

const
  NADDR: 3;
  MAXV: 3;

  USE_HIT_PREP: 1;
  USE_INDEX_PREP: 1;
  IRIX_SKIP: 0;
  SPEC_FILL: 0;
  FIX_INDEX_INV: 0;
  SNOOP_L2: 0;
  SNOOP_L1D: 0;
  HAS_L2: 1;
  L2_WT: 0;
  FWD_INDEX: 0;

type
  Addr: 0..NADDR-1;
  Ver: 0..MAXV;
  LState: enum {L_I, L_V, L_VD};
  L1Line: record st: LState; tag: Addr; d: Ver; end;
  L2Line: record valid: boolean; dirty: boolean; tag: Addr; d: Ver; end;
  PendSW: record full: boolean; addr: Addr; d: Ver; end;
  DmaSt: enum {DM_IDLE, DM_IN, DM_OUT};
  PrepOp: enum {P_CHINV, P_CHWBINV, P_CHWB, P_INDEX};

var
  latest: array[Addr] of Ver;
  icoh: array[Addr] of boolean;        -- an I-sync made the I-side see this line
  mem: array[Addr] of Ver;
  l1d: L1Line;
  l2: L2Line;
  l1i_valid: boolean; l1i_tag: Addr; l1i_d: Ver;
  sw: PendSW;                          -- early-acked MEM_SW still being processed by the L2
  dma: DmaSt; daddr: Addr;

------------------------------------------------------------------ helpers
function l1d_hit(a: Addr): boolean;
begin return l1d.st != L_I & l1d.tag = a; end;

function in_window(a: Addr): boolean;
begin return dma = DM_IN & daddr = a; end;

-- the L2 is free for a new L1 request (arbiter: the next grant waits for L2 IDLE)
function l2_idle(): boolean;
begin return !sw.full; end;

-- L2 read of line a for an L1 miss (CHECK_VALID_AND_TAG / DIRTY_STORE / CLEAN_RELOAD)
procedure l2_fill(a: Addr; var d: Ver);
begin
  if HAS_L2 = 0 then d := mem[a]; return; endif;
  if !(l2.valid & l2.tag = a) then
    if l2.valid & l2.dirty then mem[l2.tag] := l2.d; endif;   -- w_need_wb
    l2.valid := true; l2.dirty := false; l2.tag := a; l2.d := mem[a];
  endif;
  d := l2.d;
end;

-- L2 cacheable store (write-allocate)
procedure l2_store(a: Addr; d: Ver);
var t: Ver;
begin
  if HAS_L2 = 0 then mem[a] := d; return; endif;
  l2_fill(a, t);
  l2.d := d;
  if L2_WT = 1 then mem[a] := d; else l2.dirty := true; endif;
end;

-- MEM_INVL: drop, write back first if dirty
procedure l2_invl(a: Addr);
begin
  if HAS_L2 = 0 then return; endif;
  if l2.valid & l2.tag = a then
    if l2.dirty then mem[a] := l2.d; endif;
    l2.valid := false; l2.dirty := false;
  endif;
end;

-- MEM_WB: data straight to DRAM, drop the L2 copy (valid only)
procedure l2_wb(a: Addr; d: Ver);
begin
  mem[a] := d;
  if HAS_L2 = 1 & l2.valid & l2.tag = a then l2.valid := false; endif;
end;

-- the L1D ops a CACHE instruction performs (l2 must be idle: the op's request queues
-- behind any early-acked store and the op completes on its response)
procedure do_prep(op: PrepOp; a: Addr);
begin
  switch op
  case P_CHINV:
    if l1d_hit(a) then l1d.st := L_I; endif;
    l2_invl(a);
  case P_CHWBINV, P_CHWB:          -- CHWB is treated as WB-Invalidate in the RTL
    if l1d_hit(a) & l1d.st = L_VD then
      l2_wb(a, l1d.d);
      l1d.st := L_I;
    else
      if l1d_hit(a) then l1d.st := L_I; endif;
      l2_invl(a);
    endif;
  case P_INDEX:                    -- Index_WB_Inv_D on the (only) set: FLUSH_CL
    if l1d.st = L_VD then
      l2_wb(l1d.tag, l1d.d);
      if FIX_INDEX_INV = 1 then l1d.st := L_I; endif;
    else
      l1d.st := L_I;
    endif;
    if FWD_INDEX = 1 & HAS_L2 = 1 & l2.valid then
      if l2.dirty then mem[l2.tag] := l2.d; endif;
      l2.valid := false; l2.dirty := false;
    endif;
  endswitch;
end;

function prep_allowed(op: PrepOp): boolean;
begin
  return (op = P_INDEX) ? USE_INDEX_PREP = 1 : USE_HIT_PREP = 1;
end;

------------------------------------------------------------------ core data side
ruleset a: Addr do
  rule "load hit"
    l1d_hit(a) & !in_window(a)
  ==>
  begin
    assert l1d.d = latest[a] "load returned a stale value";
  end;

  rule "store hit"
    l1d_hit(a) & !in_window(a) & !(dma = DM_OUT & daddr = a) & latest[a] < MAXV
  ==>
  begin
    latest[a] := latest[a] + 1;
    l1d.d := latest[a]; l1d.st := L_VD;
    icoh[a] := false;
  end;

  -- L1D miss to a, clean/invalid victim: MEM_LW, install V (any load/store, or a
  -- wrong-path load when SPEC_FILL)
  rule "L1D refill"
    !l1d_hit(a) & l1d.st != L_VD & l2_idle() & (!in_window(a) | SPEC_FILL = 1)
  ==>
  var d: Ver;
  begin
    l2_fill(a, d);
    l1d.st := L_V; l1d.tag := a; l1d.d := d;
  end;

  -- uncached load / store of a (kseg1 alias): UNCACHE_WB drops the L1D copy first
  rule "uncached load"
    !l1d_hit(a) & l2_idle() & !in_window(a)
  ==>
  begin
    l2_invl(a);
    assert mem[a] = latest[a] "uncached load returned a stale value";
  end;

  rule "uncached store"
    !l1d_hit(a) & l2_idle() & !in_window(a) & !(dma = DM_OUT & daddr = a) & latest[a] < MAXV
  ==>
  begin
    l2_invl(a);
    latest[a] := latest[a] + 1;
    mem[a] := latest[a];
    icoh[a] := false;
  end;

  rule "uncached: UNCACHE_WB drops the aliasing L1D line"
    l1d_hit(a) & !in_window(a)
  ==>
  begin
    if l1d.st = L_VD then sw.full := true; sw.addr := a; sw.d := l1d.d; endif;
    l1d.st := L_I;
  end;

  -- a Hit CACHE op outside any DMA (IRIX uses them freely)
  ruleset op: PrepOp do
    rule "CACHE op"
      l2_idle() & op != P_INDEX & op != P_CHINV & prep_allowed(op)
    ==>
    begin
      do_prep(op, a);
    end;
  end;
end;

rule "Index_WB_Inv_D"
  l2_idle() & USE_INDEX_PREP = 1
==>
begin
  do_prep(P_INDEX, 0);
end;

-- dirty victim: MEM_SW, early-acked by the L2; the line is re-installed INVALID
-- (r_inhibit_write) when the ack arrives
rule "L1D dirty eviction (MEM_SW, early ack)"
  l1d.st = L_VD & l2_idle()
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

------------------------------------------------------------------ instruction side
ruleset a: Addr do
  rule "fetch hit"
    l1i_valid & l1i_tag = a & icoh[a]
  ==>
  begin
    assert l1i_d = latest[a] "fetch returned stale instructions after an I-sync";
  end;

  rule "L1I refill"
    !(l1i_valid & l1i_tag = a) & l2_idle() & (!in_window(a) | SPEC_FILL = 1)
  ==>
  var d: Ver;
  begin
    l2_fill(a, d);
    l1i_valid := true; l1i_tag := a; l1i_d := d;
  end;

  -- IRIX code sync: D writeback of the line, then the I-side CACHE op (nukes the L1I)
  ruleset op: PrepOp do
    rule "I-sync"
      l2_idle() & !in_window(a) & op != P_CHINV & prep_allowed(op)
    ==>
    begin
      do_prep(op, a);
      l1i_valid := false;
      icoh[a] := true;
    end;
  end;
end;

------------------------------------------------------------------ DMA
ruleset a: Addr do
  ruleset op: PrepOp do
    rule "DMA-in: IRIX preps (invalidate) the buffer"
      dma = DM_IDLE & l2_idle() & op != P_CHWB & prep_allowed(op)
    ==>
    begin
      do_prep(op, a);
      dma := DM_IN; daddr := a;
    end;

    rule "DMA-out: IRIX preps (writeback) the buffer"
      dma = DM_IDLE & l2_idle() & op != P_CHINV & prep_allowed(op)
    ==>
    begin
      do_prep(op, a);
      dma := DM_OUT; daddr := a;
    end;
  end;

  rule "DMA-in: IRIX skips the prep (line not in the primary)"
    IRIX_SKIP = 1 & dma = DM_IDLE & !l1d_hit(a)
  ==>
  begin
    dma := DM_IN; daddr := a;
  end;
end;

rule "DMA-in: device writes DRAM"
  dma = DM_IN & latest[daddr] < MAXV
==>
begin
  latest[daddr] := latest[daddr] + 1;
  mem[daddr] := latest[daddr];
  icoh[daddr] := false;
  if SNOOP_L2 = 1 & HAS_L2 = 1 & l2.valid & l2.tag = daddr then l2.valid := false; l2.dirty := false; endif;
  if SNOOP_L1D = 1 & l1d_hit(daddr) then l1d.st := L_I; endif;
  dma := DM_IDLE;
end;

rule "DMA-out: device reads DRAM"
  dma = DM_OUT
==>
begin
  assert mem[daddr] = latest[daddr] "device read stale data (DMA-out)";
  dma := DM_IDLE;
end;

------------------------------------------------------------------ start
startstate
begin
  for a: Addr do latest[a] := 0; mem[a] := 0; icoh[a] := true; endfor;
  l1d.st := L_I; l1d.tag := 0; l1d.d := 0;
  l2.valid := false; l2.dirty := false; l2.tag := 0; l2.d := 0;
  l1i_valid := false; l1i_tag := 0; l1i_d := 0;
  sw.full := false; sw.addr := 0; sw.d := 0;
  dma := DM_IDLE; daddr := 0;
end;
