# Where r9999's cycles go: top-down + stage latency (dhrystone), and candidate fixes

Measured 2026-09-27 on the Verilator model (`ooo_core`). Configuration: 16 KB L1D/L1I,
128 KB L2, 16-entry ROB, 8-entry uop queue, 4-entry memory uop queue, skid off,
`REG_L1D_RSP` on, 2-wide allocate and retire.

## How to measure

```
make VFLAGS_EXTRA=+define+TOPDOWN            # Verilator-only hooks; henry/FPGA builds unaffected
./ooo_core --file tests/dhrystone/dhrystone.mips -c 0 --topdown true --pipestart 60000 --pipeend 110000
```

- `--pipestart/--pipeend` bound a retired-instruction window. For dhrystone, 60000..110000 is
  about 85 iterations of the timed loop. A wider window (30000..130000) picks up `printf`,
  whose console writes are `mtc0` (serializing) and add ~3% of fake "serializing" stalls.
- **Top-down** is measured at allocation (the dispatch point, 2 slots per cycle). Each cycle,
  `core.sv` reports the state, how many uops the decode queue offers (0/1/2), how many
  allocate and retire, and why an offered slot did not allocate. `top.cc` turns that into:
  - **retiring**;
  - **bad speculation**: squashed uops plus recovery cycles;
  - **frontend bound**: latency (nothing offered) vs. bandwidth (1 of 2 offered);
  - **backend bound**, by cause.

  The categories sum to 100%.
- **Stage latency**: `core.sv`/`exec.sv` stamp allocation, scheduler entry (`t_pop_uq`), ALU
  issue (`r_start_int`) and memory dispatch (`t_pop_mem_uq`) by ROB index. `top.cc` joins
  them at retirement with the ROB's completion stamp.
- `--pipelog` + `gen_html -s 1 -l N` gives a per-instruction pipetrace of the same window.
  `-s` is the record index in the file, not a retired-instruction number.

## Findings (dhrystone loop, IPC 1.35)

| Top-down | Share of slots |
|---|---|
| Retiring | 67.4% |
| Bad speculation | 0.0% (no mispredicts in the loop) |
| Frontend bound | 10.9% (all *bandwidth*: the decode queue offered 1 uop, never 0) |
| Backend bound | 21.7%: ROB full 12.0%, uop queue full 8.4%, branch-pairing alloc rule 1.4% |

The machine is backend bound first. The backend is not execution-latency bound (dependent ALU
ops issue back to back). It is **occupancy** bound: each uop holds a ROB entry for ~8.7
cycles, and 16 / 8.7 = 1.85 IPC is the Little's-law ceiling. Average ROB occupancy is 11.6 of 16.

Stage latency, mean (min) cycles:

| Class | alloc->scheduler | scheduler->issue | issue->complete | alloc->complete | complete->retire |
|---|---|---|---|---|---|
| ALU | 2.15 (1) | 2.86 (2) | 1.04 (1) | 6.06 (4) | 2.55 (1) |
| branch | 2.23 (1) | 3.68 (2) | 1.00 (1) | 6.91 (4) | 1.62 (1) |
| load | 2.45 (1) | n/a | 4.10 (4) | 6.56 (5) | 2.28 (1) |
| store | 2.17 (1) | n/a | 4.01 (4) | 6.18 (5) | 1.29 (1) |

(For memory ops the first column is dispatch from the memory uop queue to address generation.)

Structure experiments (with the branch-pairing relaxations below):

| Config | IPC | Frontend | Backend |
|---|---|---|---|
| ROB 16 (current) | 1.360 | 11.2% | 20.8% (ROB 11.7%, uq 9.0%) |
| ROB 32 | 1.373 | 11.3% | 20.0% (uq **17.7%**: the stall moves to the uop queue) |
| ROB 32 + 2x uop/mem queues | 1.426 | **18.0%** | 10.7% (the frontend becomes the next limiter) |

Bigger buffers buy ~5% and then hit the frontend. Shortening each uop's residency attacks the
same backend stall without the area.

## Candidate fixes

Expected gains are rough, from the stage table; each should be verified by rerunning the report.

1. **Same-cycle select for scheduler-entering uops.** A uop written into the ALU scheduler cannot
   be selected until the next cycle, and pick->execute is registered (`int_uop <= t_picked_uop`),
   so scheduler->issue is at least 2 even with ready operands.
   - *Fix:* bypass the select for an incoming uop whose sources are ready (the allocation-time
     wakeup match already exists: `t_alu_alloc_srcA_match` / `srcB`).
   - *Saves:* 1 cycle of ROB residency per ALU uop (~11% of ALU lifetime).
   - *Risk:* select-path timing. That path was already trimmed for WNS (scheduler 8->4 was
     considered), so check it in a build.
2. **Skip the uop queue when the scheduler has room.** alloc->scheduler is at least 1 and averages
   2.15, from the extra queue stage plus queueing when the scheduler is full.
   - *Fix:* write straight into the scheduler when it isn't full; keep the queue as overflow.
   - *Saves:* ~1 cycle per uop when not full.
   - *Risk:* allocation-path timing; interaction with flash-clear/restart.
3. **Drop the registered L1D response (`REG_L1D_RSP`)** for load-to-use.
   - Every load pays a 4-cycle dispatch->data minimum; the register is 1 of those.
   - Its correctness motivation was refuted (the stale-forward bug was the forwarded-data
     capture, fixed separately), so it is purely a timing trade: ~3.3% dhrystone on main's 4 KB
     config for WNS margin on silicon.
4. **Larger ROB / uop queues.** ROB 32 + 2x queues: +4.9% IPC. It needs the 32-bit
   `dbg_rob_inflight` debug port widened (a 32-entry ROB makes `{l1d, core}` 64 bits), and costs
   area in a LUT-bound design. Only worth it after 1-2 shrink residency, or it just exposes the
   frontend.
5. **Frontend bandwidth.** 11% of slots see only one uop offered, and with bigger buffers it
   rises to 18%.
   - *Look at:* fetch-group formation around taken branches and delay slots, 16 B line
     alignment, and the predicted-taken fetch groups.
   - *Tool:* the pipetrace (`dhry.txt`: fetch cycles of consecutive retired instructions).
6. **Retire drain (complete->retire 1.3-2.6 cycles).** In-order retire waits behind older uops,
   mostly loads. It mostly falls out of 1-3; there is no separate fix.

## Measured: fixes 1-2 and the skid buffer (2026-09-27)

Both fixes are behind `ifdef`s in `exec.sv`, off by default:
- `ENABLE_SCHED_BYPASS` (fix 1): when no scheduler entry is ready, the uq head issues straight
  to the ALU if its operands pass the same `!inflight | alloc-match` test the allocation path
  uses (div/mult/oldest_first excluded; needs the ALU writeback slot free).
- `ENABLE_UQ_DUAL_POP` (fix 2, reworked): writing a uop into the scheduler at push time is no
  faster than fix 1 (both select it the cycle after allocation). The actual int-side limit is
  that the uq pops one uop per cycle while allocation pushes two, so this pops a second uq
  entry into a second free scheduler entry.

Dhrystone, same tree and flags (cycles/run; window IPC over 60000..110000):

| Config | cycles/run | IPC | ALU sched->issue | load dispatch->data | Frontend | Backend |
|---|---|---|---|---|---|---|
| baseline | 447 | 1.360 | 2.86 | 4.10 | 11.2% | 20.8% |
| fix 1 | 444 (-0.7%) | 1.376 | 2.00 | 4.04 | 12.6% | 18.6% |
| fix 2 | 444 (-0.7%) | 1.376 | 3.80 (alloc->sched 2.15 -> 1.01) | 4.04 | 11.4% | 19.8% |
| fix 1 + 2 | 442 (-1.1%) | 1.383 | 3.17 | 4.04 | 12.7% | 18.2% |
| fix 1 + mem uq 4 -> 8 | 437 (-2.2%) | 1.396 | 2.00 | 4.04 | 11.8% | 18.5% (uq full 8.7 -> 4.0) |
| fix 1 + skid | 435 (-2.7%) | 1.402 | 1.89 | 3.04 | 13.6% | 16.3% |
| fix 1 + 2 + skid | 432 (-3.4%) | 1.413 | 3.28 | 3.04 | **16.3%** | 13.0% |

- The ALU side is not the limiter: removing the queue/select cycles just moves the wait into
  sched->issue (operands, mostly load results) and complete->retire (behind loads).
- The load path is the limiter. The "uop queue full" stall is the 4-entry **memory** uq
  (doubling it halves the stall), and the skid buffer's 4 -> 3 cycle load-to-use is the single
  biggest win. Skid costs ~2650 LUT on henry (timing DSE), which is why it is off.
- With all three, frontend bandwidth (16.3%) overtakes backend (13.0%): item 5 is next.
- Validation (fix 1 + 2, and fix 1 + 2 + skid): randgen 3000/3000; all 27 directed ELFs
  identical to baseline under co-sim. Negative control: dropping the bypass's srcA readiness
  term fails 30/500 randgen seeds, so randgen does exercise the bypass.

## Frontend: fetch groups and the branch-in-group fix (2026-09-27)

`l1i.sv` (TOPDOWN) reports each fetch cycle's group size and why it ended. Baseline dhrystone
loop: 1.36 insns/cycle, **70% of fetch cycles push one instruction**.

| Why the group ended | baseline %cyc (insns) | `ENABLE_FETCH_BR_GROUP` %cyc (insns) |
|---|---|---|
| full group of 4 | 7.0 (4.00) | 6.9 (4.00) |
| cut at 16B line end | 23.3 (1.58) | 25.3 (1.58) |
| cut before taken cflow | 11.9 (1.65) | 4.2 (1.24) |
| cflow insn alone | 18.2 | 10.4 |
| delay slot alone | 18.2 | 10.4 |
| group + taken branch + delay slot | - | 9.0 (3.81) |
| resteer bubble | - | 9.0 |
| fetch queue full (queue holds >= 5, not a real loss) | 16.9 | 19.3 |

A taken branch used to cost three fetch cycles: the group up to it, the branch alone, then the
delay slot alone (that cycle hides the redirect, since the array was read sequentially).
`ENABLE_FETCH_BR_GROUP` ports rv64core's multi-push-with-branch: a predicted-taken **direct**
branch (conditional, likely, `j`, `b`) in slot 1-2 is pushed together with the insns before it
and its delay slot (same 16B line), the target is computed from that slot, and one resteer
bubble follows. Calls and BTB/return targets keep the branch-alone path. The branch's fetch
entry carries `pred`/`pred_target` (j's immediate comes from `pred_target`); spec history
shifts in one taken bit, as for a head-slot branch.

| Config | cycles/run | IPC (window) | Frontend | Backend |
|---|---|---|---|---|
| baseline | 447 | 1.360 | 11.2% | 20.8% |
| `ENABLE_FETCH_BR_GROUP` | 418 (-6.5%) | 1.452 | 1.2% | 26.2% |
| + sched bypass + uq dual pop + skid | 401 (-10.3%) | 1.520 | 4.4% | 19.6% |

Validation: randgen 3000/3000 (alone and combined); 27 directed ELFs identical to baseline.
Negative control: skewing the in-group target by 4 bytes fails every seed (even crt0's loop),
so the path is heavily exercised.

On main's tree (whose baseline is 463 cycles/run; the table above was measured on the rdchk
branch's tree), all four knobs on give 426 (-8.0%), randgen 3000/3000, 27 directed ELFs
identical. Branch prediction is unaffected: dhrystone mispredicts 806 (baseline) / 772
(`ENABLE_FETCH_BR_GROUP`) / 807 (all four); `tests/csmith/new_csmith.elf` 5M insns 1473 vs 1472,
same checksum.

Remaining frontend bucket: the 16B line-end cut (25%). Fixing it means reading across two lines
per cycle; rv64core has the same limit.

### Done / ruled out
- **Branch-pairing rules** (a branch could neither allocate nor retire together with its delay
  slot). Relaxed to "at most one branch per cycle", as in rv64core.
  - Branch training now selects the slot holding the branch; it used to assume slot 2 whenever
    two retired.
  - The allocate-side rule was a leftover of the branch-order buffer removed in 6cd6864.
  - Correct (randgen 3000/3000, delay-slot tests incl. `tests/except/test_after_ds_epc.S`), but
    only +0.9% IPC, because the backend limit dominates.
  - rv64core's call/return-in-second-retire-slot attempt (720c670) broke the RSB and was
    reverted (67c2516). Calls/returns stay out of slot 2.
- **"Frontend bound"** was an early mis-read of the pipetrace (it used fetch time as a proxy for
  decode-queue presence). Top-down measures it directly: 11%, behind backend's 21%.
