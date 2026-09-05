# HANDOFF — rIC3 formal effort on r9999 (DIVA retirement checker)

Branch `formal-ric3-diva`, snapshot 2026-09-05. This documents the formal-verification
push against the r9999 core, what proved, what hit a wall, and exactly how to reproduce
and continue it. Companion scripts live in `formal/ric3/`; the older completed proofs
(l1d one-response, retire-count, p0, decode) are in `formal/` proper with their own
`run_*_formal.sh`.

## Why

Silicon hunt (`captures/`, `[[project_loaduse_stale_branch_capture]]`): a retired
conditional branch's `take_br` disagreed with its own operands — `bnez t9` branched with
`t9==0` — a wild jump to 0. The evidence points **physical** (clock shmoo: fault did not
track frequency; STA: 1.4–2.6 ns slack on every suspect path; discipline/lint clean), but
we wanted a formal statement that the *logic* cannot produce a wrong retired answer. That
is the **DIVA** property (Austin's Dynamic Implementation Verification Architecture): a
simple retirement-time recompute checks the complex out-of-order core.

## The DIVA property (what the RTL monitor asserts)

In `core.sv` under `` `ifdef FORMAL_DIVA `` (operand save in `rob.vh`, plumbed up through
`core_l1d_l1i.sv`):

- Save the **full 64-bit** execute-time operands (`diva_srcA/srcB`) into the ROB entry at
  completion (alongside `take_br` and `data`, written the same cycle from the same nets).
- At **retire**, for the covered opcodes, recompute from the saved operands and compare:
  - `fml_diva_bad[0]` — branch: `take_br != recompute(cond, srcA, srcB)` for
    BEQ/BNE/BLEZ/BGTZ/BLTZ/BGEZ.
  - `fml_diva_bad[1]` — ALU: `data != recompute(op, srcA, srcB)` for ADDU/AND/OR/XOR/NOR.
  - `fml_diva_act[0..1]` — the check actually **fired** (a covered op retired). These are
    the **non-vacuity controls** — see the trap below.

This spans execute → completion-write → ROB storage → retire, so it also covers the
misdirected/corrupted ROB-field class, not just the ALU/branch logic.

## Result: PARKED — did not close on a 60 GB box

| model | latches | outcome |
|---|---|---|
| `-top core` (exec-level, free fetch) | ~1.5K aig | **fabricated CEX** — free `insn`/predecode makes a branch "retire" that was never fetched. Not the DUT. Must use `-top core_l1d_l1i`. |
| `-top core_l1d_l1i`, full FORMAL | 58,467 | too big; BMC can't reach a branch retire |
| + PRF 128→64, BTB 128→4 | 41,580 | lossless shrink |
| + FP off, TLB identity, shadow-TLB stub | 35,845 | `ic3` **times out @30min**; `bmc` (non-vacuity) **OOMs** |
| + TLB CAM writes gated (`r_tlb_written` never set → CAM cone swept) | **30,515** | `ic3` still exceeds 60 GB → OOM |

**Bottom line:** the DIVA property (relating operands-at-completion to a flag-at-retire
across the 16-entry ROB + scheduler) is a wide relational obligation that IC3 could not
close within 60 GB, and BMC cannot reach a branch retirement from cold reset (icache fill
from DRAM + decode + issue + retire ≈ hundreds of cycles) before OOM. This is the point
where a machine with more RAM, or a commercial tool with **datapath abstraction**
(Jasper/etc. — treat the 64-bit operands as uninterpreted bitvector terms), is the real
lever. `reader-agreement` and `ds-identity` (see `[[project_retire_ds_formal]]`) are
blocked on the same wall — same model, same abstraction need.

## THE VACUITY TRAP (read this before trusting any UNSAT here)

An early `fml_diva_bad[0]` = **UNSAT in 151 s** looked like a win. It was **vacuous**. My
ROBWR monitor wiped its outstanding-request scoreboard (`r_fml_out`) on `t_clr_rob`
(machine clear). The tiny formal predictor (PHT=4) mispredicts constantly → constant
restarts → a load outstanding at a restart had its bit wiped → its legit late response
looked spurious → `r_fml_env_ok` dropped to 0 **forever** → the DIVA gate turned off →
no checked branch retire is reachable → `bad` is trivially UNSAT.

The non-vacuity control caught it: `fml_diva_act[0]` came back **UNSAT** (unreachable) too,
which is only possible if nothing is ever checked. **Always run the control (act must be
SAT) BEFORE trusting a property UNSAT.**

Fix applied: the `env_ok` gate exists only to defend against a *free* `core_mem_rsp` at
`-top core`. At `-top core_l1d_l1i` that response is **internal** (driven by the real l1d),
so the gate is unnecessary — dropped under `` `ifdef FORMAL_DIVA_TRUSTED_RSP ``. After the
fix, whether `act` is reachable was never definitively answered (BMC OOM'd), so **even the
30.5K result is not a proven non-vacuous UNSAT.** Nothing about DIVA is proved yet. Do not
cite a DIVA proof.

## Reproduce

```
formal/ric3/build_and_run.sh /tmp/divawork control   # MUST print SAT (branch retires)
formal/ric3/build_and_run.sh /tmp/divawork property   # UNSAT only means something if control=SAT
```
`RIC3=<path>` env var points at your rIC3 1.5.2 build (see below). Run **control first**.

## The formal gates (all in tracked RTL on this branch)

| define | effect | files |
|---|---|---|
| `FORMAL` | ROB=16, PHT=4, **PRF=64** (`LG_PRF_ENTRIES=6`), **BTB=4** (`LG_BTB_SZ=2`) | `machine.vh` |
| `FORMAL_MINSTATE` | FP off (`cu1=0`→COP1 CpU→fp_regfile swept), identity translate (`mapped=0` both fetch+data), TLB CAM writes gated, shadow-TLB stubbed | `exec.sv`, `l1i.sv`, `tlb.sv` |
| `FORMAL_DIVA` | operand save + retirement recompute monitor + ports | `rob.vh`, `core.sv`, `core_l1d_l1i.sv` |
| `FORMAL_DIVA_TRUSTED_RSP` | drop the `env_ok` gate (internal `core_mem_rsp`) | `core.sv` |
| `FORMAL_ROBWR_MON` | ROB write-integrity scoreboard (provides `r_fml_env_ok`, `act`) | `core.sv` |
| `FORMAL_DIVA_SLOT` | single-slot reduction: gate check on a frozen `fml_diva_slot` | `core.sv`, `core_l1d_l1i.sv` |

Do **NOT** shrink `N_TLB_ENTRIES` — the TLB index is architecturally 6-bit (hardcoded
`[5:0]` in `exec.sv`), a smaller array + 6-bit index = real OOB (56 WIDTH warnings). It's
neutered instead by gating its writes (above).

## Toolchain

- **yosys 0.64** / built-in `yosys-abc` (ABC). AIGER recipe: `memory_map; opt; techmap; opt;
  setundef -zero -init/-undriven; dffunmap (LAST); abc -fast -g AND; write_aiger -zinit`.
- **rIC3 1.5.2** — `git clone https://github.com/gipsyh/rIC3 && cd rIC3 &&
  git submodule update --init --recursive && cargo build --release`. Binary at
  `target/release/ric3`. It cracked the retire-count clause abc pdr couldn't (24 s vs
  14,000 s DNF), so it is worth having — but see the memory warnings.
- **abc/AIGER** for anything core-sized; `write_smt2`+cvc5 does NOT scale (memory_map blasts
  arrays, 188 MB SMT2, timed out at step 0). See `[[reference_pdr_core_flow]]`.

### rIC3 memory discipline (4 OOMs in one session — do not repeat)

- `portfolio` = **~19 processes**. It is not a "solo" run. It OOM'd a 60 GB box repeatedly.
  Use a **single** engine: `ic3`, `bmc`, `wl-kind`, `cegar`.
- Even single `ic3`/`bmc` can exceed 60 GB on the 30.5K model. `bmc` unrolls per frame; deep
  reachability blows memory before reaching a retire.
- After launch: `pgrep -cf 'target/release/ric3'` (the `[r]ic3` bracket trick self-matches
  your own shell — match the binary path). Watch `free -g`.

## What DID prove (kept; `formal/run_*_formal.sh`)

- **l1d never double/spurious-responds** (loads, unbounded) — `run_l1d_rsp_formal.sh`
- **exactly-one / zero retire after a mispredicted delay-slot branch** (unbounded, pdr) —
  `run_retire_formal.sh` (`[[project_retire_ds_formal]]`)
- **physreg-0 integrity** (decode ∀2³² + free-list + RF induction) — `run_rf_p0_formal.sh`,
  `run_decode_p0_formal.sh`; found+fixed `daddiu $0` and `jalr $0` decode gaps
- **decode never emits `dst_valid & dst==0`** — `run_decode_formal.sh`

## Recommended next steps (in order)

1. **The higher-value path is a silicon DIVA checker, not this proof.** The same monitor,
   synthesized on henry (the SoC — boots the binutils workload), un-gated for synthesis and
   wired to freeze the retire ring on `fml_diva_bad`, catches every *silent* wrong retired
   answer (not just the ~1e-13 that wild-jump). Since the bug looks physical, that is worth
   more than a logic-correctness proof. No proof required.
2. If pursuing the proof: run on a **bigger-RAM machine** (≥256 GB) — the model is correct
   and shrunk; it's a pure capacity wall.
3. Or **datapath abstraction**: the `wl-kind`/`cegar` word-level rIC3 engines on a BTOR2
   model (`write_btor` instead of `write_aiger`) keep the 64-bit operands as bitvector
   terms — the free analog of Jasper's abstraction. Started but not completed (OOM'd first).
4. Or the **single-slot reduction** (`FORMAL_DIVA_SLOT`, already wired): a frozen
   `slot_seed` restricts the check to one arbitrary ROB slot; combine with an abstracted
   ROB so IC3 reasons about one slot, not sixteen.
