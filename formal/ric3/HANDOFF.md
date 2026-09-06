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

## Result: the model WORKS — earlier failures were two harness bugs (mine)

| model | latches | note |
|---|---|---|
| `-top core` (exec-level, free fetch) | small | **fabricated CEX** — free `insn`/predecode "retires" branches never fetched. Not the DUT. Use `-top core_l1d_l1i`. |
| `-top core_l1d_l1i`, full FORMAL | 58,467 | |
| + PRF 128→64, BTB 128→4 | 41,580 | lossless shrink |
| + FP off, TLB identity, shadow-TLB stub | 35,845 | |
| + TLB CAM writes gated (`r_tlb_written` never set → CAM cone swept) | **30,515** | current |

**Confirmed reachable on a large-memory box (2026-09-05, dsheffie):**
`fml_diva_act[0]` (branch retire, DIVA-checked) **SAT at depth 31**;
`fml_diva_act[1]` (ALU retire) **SAT at depth 37**. ~3.5 GB per single engine.
Non-vacuity is therefore ESTABLISHED — a subsequent `fml_diva_bad[*]` UNSAT is a real proof.

### The two harness bugs that made everything look impossible

Both were in `gen_cl2_wrapper.py`; both made the DUT **a core that never runs**, so every
control was unreachable and every property vacuously UNSAT:

1. **DRAM scoreboard gated on a non-existent `mem_req_ack`.** `core_l1d_l1i` has NO ack on
   the memory interface — it is **valid-held-until-response** (`mem_req_valid` held until
   `mem_rsp_valid`). The phantom `mem_req_ack` became an undriven implicit net → `setundef
   -zero` → 0 → the outstanding flag never set → **the DRAM never responded** → no icache
   fill → nothing ever fetched.
2. **`resume`/`resume_pc` left as free inputs.** The core resets into FLUSH_FOR_HALT/HALT
   and does nothing until `resume` is pulsed (see `top.cc`: wait `ready_for_resume`, then
   assert `resume` with `resume_pc`). Free → the solver can simply never start the core.

Both are fixed in `gen_cl2_wrapper.py` (resume handshake off `ready_for_resume`, `resume_pc`
= `0xffffffffbfc00000`; DRAM outstanding tracked from `mem_req_valid` alone).

### Wrong theories I published before finding them (do not repeat)

- "the `env_ok` scoreboard bug caused the vacuity" — `env_ok` **is** a real bug (see below)
  but was NOT why controls were unreachable; the core was never running.
- "BMC can't reach a branch retire, cold-start is hundreds of cycles" — **false**, it is
  depth **31**.
- "IC3 needs >60 GB / needs bigger iron or a commercial tool" — **false**, ~3.5 GB per
  engine. The OOMs were `portfolio`'s ~19-process fan-out plus leftover processes on a
  thin-swap box.

**Rule that would have caught all of it in one step:** before believing any control is
unreachable, **validate the environment** — check that the core resumes and that memory
actually responds (a `retire_any` cover reaching SAT). Positive-control the harness, not
just the property. This is the same discipline applied to silicon probes all session; I
failed to apply it to my own testbench.

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

## Reproduce — RUN IN THIS ORDER, EACH MUST PASS

```
formal/ric3/build_and_run.sh /tmp/divawork liveness   # MUST be SAT: any insn retires
formal/ric3/build_and_run.sh /tmp/divawork control    # MUST be SAT: a DIVA-checked branch retires
formal/ric3/build_and_run.sh /tmp/divawork property   # UNSAT = the proof (only if both above SAT)
```

`liveness` covers `fml_retire_any` (sticky "any instruction retired"). It exists because a
broken environment silently models a **dead core**, and then every control is unreachable
and every property is vacuously UNSAT. If `liveness` is not SAT, **debug the harness**
(is `resume` pulsed after `ready_for_resume`? does the DRAM scoreboard ever respond?) —
do NOT theorize about proof depth or memory.

`RIC3=<path>` points at your rIC3 build (see below). Use ONE engine; never `portfolio`.

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

**DMA-invalidate ports** (`dma_inval_req`/`dma_inval_addr`, exposed by `l1d` at this top)
are tied to 0 in the wrapper (`gen_cl2_wrapper.py` `TIE0`). The DIVA branch/ALU property is
coherence-independent — a result is a function of its operands, not of whether a concurrent
DMA evicted a line — so free DMA invalidation is pure input/state bloat for this proof.
NOTE: the 2026-09-05 latch-count/OOM runs were built with these ports FREE (the tie-off
came after), so those numbers carried unnecessary DMA input space; a re-run with them tied
will be a touch smaller. For a separate "DIVA holds under adversarial concurrent DMA"
coverage run, drop `dma_inval_req/addr` from `TIE0`.

## Toolchain

- **yosys 0.64** / built-in `yosys-abc` (ABC). AIGER recipe: `memory_map; opt; techmap; opt;
  setundef -zero -init/-undriven; dffunmap (LAST); abc -fast -g AND; write_aiger -zinit`.
- **rIC3 1.5.2** (git `7149d56`, 2026-06-28) — `git clone https://github.com/gipsyh/rIC3 &&
  cd rIC3 && git checkout 7149d56 && git submodule update --init --recursive &&
  cargo build --release`. Binary at
  `target/release/ric3`. It cracked the retire-count clause abc pdr couldn't (24 s vs
  14,000 s DNF), so it is worth having — but see the memory warnings.
- **abc/AIGER** for anything core-sized; `write_smt2`+cvc5 does NOT scale (memory_map blasts
  arrays, 188 MB SMT2, timed out at step 0). See `[[reference_pdr_core_flow]]`.

### rIC3 memory discipline (4 OOMs in one session — do not repeat)

- **`portfolio` races ~17 differently-tuned solver configs as SEPARATE PROCESSES**, each
  with its own copy of the model + clause DB. See `src/portfolio/portfolio.toml`: the
  `bl_default` set is 11 `ic3` variants (no-preproc, no-parent-lemma, abs-cst,
  abs-cst+abs-trans, pred-prop, ctg-limited, inn, inn+ctp, inn-noctg, inn-dynamic) +
  4 `bmc` variants (step 1, kissat 10/65/dyn) + `kind`; `wl_default` adds word-level
  `wl-bmc`/`wl-kind`. It is doing exactly what it should — it is just **17–34× the
  single-engine footprint**.
  MEASURED on the 2026-09-05 OOM (kernel OOM process table): **34 `ric3` processes holding
  57.7 GB of private anon memory** on a 60 GB box — that, and nothing else, was the OOM.
  (`gvfsd-trash` showed 444 procs / 62 GB raw but only 0.3 GB private — shared-library
  double-counting, a red herring.) A single engine is ~1.7–4 GB.
  **Rule: budget ~17 × 2 GB ≈ 35 GB minimum before using `portfolio`.** Below that use a
  single engine — `ic3` for proofs, `bmc` for reachability. On a large-memory box portfolio
  is the *best* mode (highest chance of closing a hard property fast).
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
