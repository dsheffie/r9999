-- rv64core nu_l1d -> l2_2way request-credit model (cycle accurate).
--
-- Companion to rv64core_caches.m.  That model is untimed; this bug needs
-- two requesters reading the SAME registered counter in the SAME cycle, so
-- this one advances the whole L1D by one clock per rule firing.
--
-- Mirrors rv64core main nu_l1d.sv:
--   r_mrq_credits: 3 bits, reset 7, -1 on n_mem_req_valid, +1 on mem_rsp_valid
--   port-1 accept from mem_q    (ACTIVE, !t_got_miss, !eb_full) : credits >= P1_GATE
--   port-2 early LW             (r_got_req ? port-1 hit : 1)     : credits >= P2_GATE
--   EB drain                    (no port-1/port-2 push)          : credits >= EB_GATE
--   port-1 refill push (clean miss)                               : NO credit check
--   arbiter: port-2 overrides port-1 (a same-cycle port-1 push would be lost)
--   dirty miss: t_push_eb -> CLEAR_DIRTY -> replay (clean miss) -> refill
--     (or WAIT_INJECT_RELOAD first when rr_last_wr hits the same index)
--   EB: 2 entries (LG_EB_ENTRIES 1); w_eb_empty/full read registered ptrs,
--     so an eviction pushed this cycle drains next cycle at the earliest
--   l2_2way holds 8 L1D requests; mem_rdy is ignored, credits are the only
--     flow control.  Every request (LW and SW) gets exactly one response.
-- mem_q contents, port-2 misses, lookup outcomes and L2 response timing are
-- chosen nondeterministically every cycle.

const
  NCRED: 7;
  EBSZ: 2;
  P1_GATE: 2;
  P2_GATE: 3;
  EB_GATE: 1;
  -- 1 = restore WAIT_FOR_CREDIT: the refill waits for a free credit
  FIX_WAIT_CREDIT: 0;
  -- 1 = EB drain also leaves a credit for a refill port-1 still owes
  FIX_EB_RESERVE: 0;
  -- 1 = port-1 accept requires an EMPTY EB (w_eb_empty instead of !w_eb_full)
  P1_EB_EMPTY: 0;

type
  CredT: 0..NCRED;
  P1St: enum {ACTIVE, WAIT_INJECT, CLEAR_DIRTY, WAIT_CREDIT, INJECT_RELOAD, HANDLE_RELOAD};
  Outcome: enum {HIT, CLEAN, DIRTY};
  Kind: enum {K_NEW, K_AFTER_CLEAN, K_AFTER_RELOAD};

var
  cred: CredT;
  eb: 0..EBSZ;
  st: P1St;
  got: boolean;          -- r_got_req
  kind: Kind;            -- what the pending lookup is
  reload_out: boolean;   -- port-1 refill is at the L2
  other: 0..NCRED;       -- every other outstanding request

-- port-1 owes a refill that has not been pushed yet
function owes_refill(): boolean;
begin
  return st = CLEAR_DIRTY | st = WAIT_INJECT | st = WAIT_CREDIT
       | (got & kind = K_AFTER_CLEAN);
end;

ruleset mq: boolean; p2: boolean; oc: Outcome; rsp: 0..2; wv: boolean do
rule "clock"
  -- prune input combinations that cannot matter / cannot happen
  (got | oc = HIT) &
  !(got & kind = K_AFTER_RELOAD & oc != HIT) &
  !(got & kind = K_AFTER_CLEAN & oc != CLEAN) &
  (oc = DIRTY | !wv) &
  (st = ACTIVE | !mq) &
  !(rsp = 1 & !reload_out) &
  !(rsp = 2 & other = 0)
==>
var
  p1push, p2push, ebpush, pusheb, gotmiss, p1hit: boolean;
  nst: P1St; ngot: boolean; nkind: Kind;
  npush: 0..1; ncred: 0..NCRED+1; neb: 0..EBSZ+1;
begin
  p1push := false; p2push := false; ebpush := false; pusheb := false;
  gotmiss := false; p1hit := false;
  nst := st; ngot := false; nkind := K_NEW;

  switch st
  case ACTIVE:
    if got then
      if oc = HIT then
        p1hit := true;
      elsif oc = CLEAN then
        gotmiss := true;
        if FIX_WAIT_CREDIT = 1 & cred = 0 then
          nst := WAIT_CREDIT;
        else
          p1push := true;
          nst := INJECT_RELOAD;
        endif;
      else
        gotmiss := true;
        if wv then
          nst := WAIT_INJECT;
        else
          pusheb := true;
          nst := CLEAR_DIRTY;
        endif;
      endif;
    endif;
    -- accept the mem_q head (not qualified on r_got_req)
    if mq & !gotmiss & (P1_EB_EMPTY = 1 ? eb = 0 : eb < EBSZ) & cred >= P1_GATE then
      ngot := true;
      nkind := K_NEW;
    endif;
  case WAIT_INJECT:
    pusheb := true;
    nst := CLEAR_DIRTY;
  case CLEAR_DIRTY:
    ngot := true;
    nkind := K_AFTER_CLEAN;
    nst := ACTIVE;
  case WAIT_CREDIT:
    if cred >= 1 then
      p1push := true;
      nst := INJECT_RELOAD;
    endif;
  case INJECT_RELOAD:
    if rsp = 1 then
      nst := HANDLE_RELOAD;
    endif;
  case HANDLE_RELOAD:
    ngot := true;
    nkind := K_AFTER_RELOAD;
    nst := ACTIVE;
  endswitch;

  -- port-2 early LW (w_gen_early_req)
  if p2 & cred >= P2_GATE & (!got | p1hit) then
    p2push := true;
  endif;

  assert !(p1push & p2push) "port-2 early request overrode a port-1 push";

  -- EB drain
  if !p1push & !p2push & eb > 0 &
     cred >= EB_GATE + ((FIX_EB_RESERVE = 1 & owes_refill()) ? 1 : 0) then
    ebpush := true;
  endif;

  npush := (p1push | p2push | ebpush) ? 1 : 0;
  assert !(npush = 1 & cred = 0) "trying to push with no free credits";

  -- credits: -1 on push, +1 on response
  ncred := cred + (rsp != 0 ? 1 : 0) - npush;
  assert ncred <= NCRED "credit counter overflow";

  -- outstanding bookkeeping
  if rsp = 1 then reload_out := false; endif;
  if rsp = 2 then other := other - 1; endif;
  if p1push then reload_out := true; endif;
  if p2push | ebpush then other := other + 1; endif;

  neb := eb - (ebpush ? 1 : 0) + (pusheb ? 1 : 0);
  assert neb <= EBSZ "eviction buffer overflow";

  cred := ncred;
  eb := neb;
  st := nst;
  got := ngot;
  kind := nkind;
end;
end;

startstate
  cred := NCRED; eb := 0; st := ACTIVE; got := false; kind := K_NEW;
  reload_out := false; other := 0;
end;

invariant "credits account for every outstanding request"
  cred + other + (reload_out ? 1 : 0) = NCRED;
