-- r9999_dma.m -- DMA coherence WITH SNOOPS for the r9999 / henry memory system
-- Builds on r9999_caches.m (same cache abstraction: NADDR colliding lines, versions,
-- ghost latest[]); this model adds the DMA transaction and the snoop machinery.
--
-- What exists (2026-09-25):
--   henry_soc.sv  snoop_fifo (16 deep): every line a HARDWARE DMA master writes
--                 (dma_memcpy / ENET engine, on the arbiter's store-done response) is
--                 pushed; the L2 pops it in IDLE (priority over L1 requests) and does
--                 MEM_SNOOP_INVL = drop the L2 copy, NO writeback.  L2 only.
--   SCSI on silicon is NOT a hardware master: the ARM driver memcpy()s the data into
--                 guest DRAM (scsi_move) and rings the completion doorbell -- no snoop.
--   r9999 l1d.sv (rdchk branch, not wired in henry): dma_inval port, a second
--                 FLUSH_CL requester: drop the L1D line (no WB) + MEM_INVL to the L2,
--                 and MEM_INVL WRITES BACK a dirty L2 copy before dropping it.
--
-- A DMA-in of line a:
--   IRIX prep (Hit ops or Index_WB_Inv_D, or skipped) -> ARMED
--   device write of DRAM (+ snoop push, before or after the write) -> WRITTEN
--   completion interrupt (optionally only once the snoop queue is drained) -> IDLE
-- Software touches the buffer only outside [prep, completion]; the OOO core may fill
-- it speculatively at any time (SPEC_FILL).  Queue entries of an earlier DMA may still
-- be pending when the CPU reuses the line (if completion does not wait for the drain).
--
-- Knobs
--   SNOOP          0 none (SCSI today)   1 L2 drop (henry engines today)
--                  2 L2 drop + L1D drop  3 L1D drop + MEM_INVL to L2 (the rdchk dma_inval port)
--   SNOOP_BEFORE   1 = the snoop is pushed BEFORE the DRAM write lands (else after)
--   WAIT_DRAIN     1 = completion waits until the snoop queue is empty
--   IRIX_SKIP      IRIX may skip the prep when the line is not in the L1D
--   SPEC_FILL      wrong-path fills allowed inside the window
--   USE_INDEX_PREP / FIX_INDEX_INV / FWD_INDEX  as in r9999_caches.m (FIX_INDEX_INV
--                  defaults ON: cb7d225)
--   ARM            1 = the ARM (or engine) invalidates the transferred range itself, after the
--                  DRAM write and BEFORE ringing the completion doorbell: every line is
--                  dropped from the L1D and the L2 with NO writeback (SNOOP should be 0)
--   GFLUSH         1 = after the DRAM write and before the doorbell, a GLOBAL flush:
--                  every L1D and L2 line written back if dirty, then invalidated
--   GFLUSH_PRE     1 = also a global flush before the device touches DRAM
--   ARM_PRE        1 = the ARM also writes back + invalidates the range (L1D and L2) BEFORE
--                  the device touches DRAM (DMA-in) / before the device reads it (DMA-out)
--   DMA_OUT        model device reads (SCSI write / ENET TX) too
--   L2_WT          the L2 is write-through: an L1D eviction also writes DRAM, never dirty
--   SW_DRAINED     timing assumption: the L2 has finished any early-acked MEM_SW before a
--                  device write lands (tens of cycles vs a DMA microseconds later)

const
  NADDR: 3;
  MAXV: 3;
  QD: 2;                 -- snoop queue depth (model)

  SNOOP: 1;
  SNOOP_BEFORE: 0;
  WAIT_DRAIN: 0;
  IRIX_SKIP: 0;
  SPEC_FILL: 1;
  USE_INDEX_PREP: 1;
  FIX_INDEX_INV: 1;
  FWD_INDEX: 0;
  L2_WT: 0;
  ARM: 0;
  GFLUSH: 0;
  GFLUSH_PRE: 0;
  ARM_PRE: 0;
  DMA_OUT: 1;
  SW_DRAINED: 0;

type
  Addr: 0..NADDR-1;
  Ver: 0..MAXV;
  LState: enum {L_I, L_V, L_VD};
  L1Line: record st: LState; tag: Addr; d: Ver; end;
  L2Line: record valid: boolean; dirty: boolean; tag: Addr; d: Ver; end;
  PendSW: record full: boolean; addr: Addr; d: Ver; end;
  DmaSt: enum {DM_IDLE, DM_ARMED, DM_CLEAN, DM_WRITTEN, DM_POSTED, DM_OUT, DM_OUT_CLEAN};
  PrepOp: enum {P_CHINV, P_CHWBINV, P_INDEX};

var
  latest: array[Addr] of Ver;
  mem: array[Addr] of Ver;
  l1d: L1Line;
  l2: L2Line;
  sw: PendSW;
  dma: DmaSt; daddr: Addr;
  pushed: boolean;                        -- this DMA's snoop is queued
  q: array[0..QD-1] of Addr; qn: 0..QD;   -- snoop queue (FIFO)

------------------------------------------------------------------ helpers
function l1d_hit(a: Addr): boolean;
begin return l1d.st != L_I & l1d.tag = a; end;

function in_window(a: Addr): boolean;
begin return dma != DM_IDLE & dma != DM_OUT & dma != DM_OUT_CLEAN & daddr = a; end;

function out_window(a: Addr): boolean;
begin return (dma = DM_OUT | dma = DM_OUT_CLEAN) & daddr = a; end;

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
  if L2_WT = 1 then mem[a] := d; else l2.dirty := true; endif;
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
    if FWD_INDEX = 1 & l2.valid then
      if l2.dirty then mem[l2.tag] := l2.d; endif;
      l2.valid := false; l2.dirty := false;
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

procedure push_snoop(a: Addr);
begin
  q[qn] := a; qn := qn + 1;
end;

------------------------------------------------------------------ core
ruleset a: Addr do
  rule "load hit"
    l1d_hit(a) & !in_window(a)
  ==>
  begin
    assert l1d.d = latest[a] "load returned a stale value";
  end;

  rule "store hit"
    l1d_hit(a) & !in_window(a) & !out_window(a) & latest[a] < MAXV
  ==>
  begin
    latest[a] := latest[a] + 1;
    l1d.d := latest[a]; l1d.st := L_VD;
  end;

  rule "L1D refill"
    !l1d_hit(a) & l1d.st != L_VD & l2_idle() & (!in_window(a) | SPEC_FILL = 1)
  ==>
  var d: Ver;
  begin
    l2_fill(a, d);
    l1d.st := L_V; l1d.tag := a; l1d.d := d;
  end;

  rule "uncached load"
    !l1d_hit(a) & l2_idle() & !in_window(a)
  ==>
  begin
    l2_invl(a);
    assert mem[a] = latest[a] "uncached load returned a stale value";
  end;
end;

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

------------------------------------------------------------------ DMA-in
ruleset a: Addr do
  ruleset op: PrepOp do
    rule "IRIX preps the buffer"
      dma = DM_IDLE & l2_idle() & (op != P_INDEX | USE_INDEX_PREP = 1)
    ==>
    begin
      do_prep(op, a);
      dma := DM_ARMED; daddr := a; pushed := false;
    end;
  end;

  rule "IRIX skips the prep (line not in the L1D)"
    IRIX_SKIP = 1 & dma = DM_IDLE & !l1d_hit(a)
  ==>
  begin
    dma := DM_ARMED; daddr := a; pushed := false;
  end;
end;

rule "snoop pushed before the DRAM write"
  SNOOP != 0 & SNOOP_BEFORE = 1 & dma = DM_ARMED & !pushed & qn < QD
==>
begin
  push_snoop(daddr); pushed := true;
end;

rule "ARM pre-clean: WB+invalidate the range in L1D and L2"
  ARM_PRE = 1 & dma = DM_ARMED & l2_idle()
==>
begin
  if l1d_hit(daddr) then
    if l1d.st = L_VD then l2_wb(daddr, l1d.d); endif;
    l1d.st := L_I;
  endif;
  l2_invl(daddr);
  dma := DM_CLEAN;
end;

rule "global flush before the device write"
  GFLUSH_PRE = 1 & dma = DM_ARMED & l2_idle()
==>
begin
  global_flush();
  dma := DM_CLEAN;
end;

rule "global flush after the device write"
  GFLUSH = 1 & dma = DM_WRITTEN & l2_idle()
==>
begin
  global_flush();
  dma := DM_POSTED;
end;

rule "device writes DRAM"
  (dma = DM_CLEAN | (dma = DM_ARMED & ARM_PRE = 0 & GFLUSH_PRE = 0)) & latest[daddr] < MAXV & (SW_DRAINED = 0 | !sw.full) &
  (SNOOP = 0 | SNOOP_BEFORE = 0 | pushed) & (SNOOP = 0 | SNOOP_BEFORE = 1 | qn < QD)
==>
begin
  latest[daddr] := latest[daddr] + 1;
  mem[daddr] := latest[daddr];
  if SNOOP != 0 & SNOOP_BEFORE = 0 then push_snoop(daddr); endif;
  dma := DM_WRITTEN;
end;

rule "ARM post-invalidate: drop the range from L1D and L2 (no writeback)"
  ARM = 1 & dma = DM_WRITTEN & l2_idle()
==>
begin
  if l1d_hit(daddr) then l1d.st := L_I; endif;
  l2_snoop_drop(daddr);
  dma := DM_POSTED;
end;

rule "completion interrupt"
  ((ARM = 0 & GFLUSH = 0 & dma = DM_WRITTEN) | ((ARM = 1 | GFLUSH = 1) & dma = DM_POSTED)) & (WAIT_DRAIN = 0 | qn = 0)
==>
begin
  dma := DM_IDLE;
end;

------------------------------------------------------------------ DMA-out
ruleset a: Addr do
  ruleset op: PrepOp do
    rule "DMA-out: IRIX preps (writeback) the buffer"
      DMA_OUT = 1 & dma = DM_IDLE & l2_idle() & op != P_CHINV & (op != P_INDEX | USE_INDEX_PREP = 1)
    ==>
    begin
      do_prep(op, a);
      dma := DM_OUT; daddr := a;
    end;
  end;
  rule "DMA-out: IRIX skips the prep (line not in the L1D)"
    DMA_OUT = 1 & IRIX_SKIP = 1 & dma = DM_IDLE & !l1d_hit(a)
  ==>
  begin
    dma := DM_OUT; daddr := a;
  end;
end;

rule "DMA-out: ARM pre-clean (writeback the range from L1D and L2)"
  DMA_OUT = 1 & (ARM_PRE = 1 | GFLUSH_PRE = 1) & dma = DM_OUT & l2_idle()
==>
begin
  if l1d_hit(daddr) & l1d.st = L_VD then l2_wb(daddr, l1d.d); l1d.st := L_V; endif;
  if l2.valid & l2.tag = daddr & l2.dirty then mem[daddr] := l2.d; l2.dirty := false; endif;
  dma := DM_OUT_CLEAN;
end;

rule "DMA-out: device reads DRAM"
  DMA_OUT = 1 & (dma = DM_OUT_CLEAN | (dma = DM_OUT & ARM_PRE = 0 & GFLUSH_PRE = 0))
==>
begin
  assert mem[daddr] = latest[daddr] "device read stale data (DMA-out)";
  dma := DM_IDLE;
end;

-- the snoop consumer (L2 IDLE priority over L1 requests; the L1D port competes with
-- the CPU's FLUSH_CL but is modeled atomically here)
rule "snoop processed"
  qn > 0 & l2_idle()
==>
var a: Addr;
begin
  a := q[0];
  for i: 0..QD-2 do q[i] := q[i+1]; endfor;
  qn := qn - 1;
  switch SNOOP
  case 1:
    l2_snoop_drop(a);
  case 2:
    if l1d_hit(a) then l1d.st := L_I; endif;
    l2_snoop_drop(a);
  case 3:
    if l1d_hit(a) then l1d.st := L_I; endif;
    l2_invl(a);
  endswitch;
end;

------------------------------------------------------------------ start
startstate
begin
  for a: Addr do latest[a] := 0; mem[a] := 0; endfor;
  l1d.st := L_I; l1d.tag := 0; l1d.d := 0;
  l2.valid := false; l2.dirty := false; l2.tag := 0; l2.d := 0;
  sw.full := false; sw.addr := 0; sw.d := 0;
  dma := DM_IDLE; daddr := 0; pushed := false;
  for i: 0..QD-1 do q[i] := 0; endfor; qn := 0;
end;
