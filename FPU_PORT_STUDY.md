# FPU plumbing study — porting `~/code/mipscore` (branch `superscalar`) FP dataflow into r9999

**Goal:** understand the *complete* FP plumbing/dataflow in the older `mipscore` design (rename,
scheduler, FP PRF, ALU↔FPU moves, writeback/retire) and assess grafting it onto current r9999.
The FP **arithmetic** in mipscore is deliberately wrong (the units are literally named `bogo_fp32_*`),
but the **plumbing is correct and complete**. This doc captures the plumbing only.

Source studied: `/home/dsheffie/code/mipscore` @ `superscalar` (`ad48926`). Same idiomatic lineage as
r9999 (`r_*`/`n_*`/`t_*` convention, dual-issue OOO, ROB, split issue queues). r9999's own FPU was
ripped out later (`ac057b8 first bit of removed fpu` → `a886fc8 remove all fpu source` on the
`ss32-mips2-rf-nofpu` branch), so a port = re-introducing this, adapted to today's 64-bit +
system-instruction design.

---

## 1. Register domains — there are FOUR independently-renamed register files

Every domain has its own **PRF**, **alloc RAT**, **retire RAT**, and **free list**. (core.sv ~228–274)

| Domain | PRF | Arch regs | RATs | Free list | Notes |
|---|---|---|---|---|---|
| **Integer** | `r_prf` (in exec) | 32 | `r_alloc_rat[31:0]`, `r_retire_rat[31:0]` | `r_prf_free` bitmask | baseline (still in r9999) |
| **FP** | `r_fp_prf[]` 64-bit (exec.sv:123) | 32 | `r_fp_alloc_rat[31:0]`, `r_fp_retire_rat[31:0]` | `r_fp_prf_free` split **even/odd** (`w_fp_prf_free_even/odd`) | even/odd split = 32-bit FP reg-pair mode |
| **HI/LO** | `r_hilo_prf` | the mult/div HI:LO pair | `r_hilo_alloc_rat`, `r_hilo_retire_rat` (scalar, 1 arch entry) | `r_hilo_prf_free` | already renamed in r9999 too |
| **FCR** (FP control/cond) | `r_fcr_prf[]` 8-bit (exec) | FP condition codes + control | `r_fcr_alloc_rat`, `r_fcr_retire_rat` (scalar) | (small) | holds the 8 FP condition-code bits |

Inflight tracking per domain: `r_prf_inflight`, `r_fp_prf_inflight` (exec.sv:132). "inflight" = result not
yet produced → a consumer must stall until the bit clears (wakeup).

**Even/odd FP free list:** in 32-bit FP register mode a 64-bit double lives in an even/odd *pair* of
32-bit arch regs. The physical FP reg is 64-bit; the split free list + `MERGE` move variants (below)
let a 32-bit write update one half of the 64-bit physical reg. `t_in_32fp_reg_mode` /
`in_64b_fpreg_mode` selects.

---

## 2. The uop contract (uop.vh ~233–267) — sources carry a *per-source domain flag*

```
srcA / srcA_valid / fp_srcA_valid      <- each source independently int-valid OR fp-valid
srcB / srcB_valid / fp_srcB_valid
srcC / srcC_valid / fp_srcC_valid
dst  / dst_valid  / fp_dst_valid       <- dst can be int OR fp
fcr_dst_valid                          <- writes the FP condition/control reg
hilo_dst_valid / hilo_dst
fcr_src_valid
hilo_src_valid / hilo_src              <- NOTE: FCR source is overloaded onto the hilo_src field
is_fp                                  <- routes to the FP issue queue
```

The decisive idea: **a single uop reads/writes a mix of domains.** `srcA_valid` vs `fp_srcA_valid`
tells rename which RAT to consult for that one source. That's what makes cross-domain moves fall out
naturally (no special "mover" datapath needed in rename).

---

## 3. Decode (decode_mips32.sv, `6'd17` = COP1) — esp. the cross-domain moves

- **FP arith** `ADD.fmt` etc. (`~911+`): `fp_srcA_valid`, `fp_srcB_valid`, `fp_dst_valid`, `is_fp=1`;
  op = `SP_ADD`/`DP_ADD`/… by fmt field `insn[25:21]` (16=single, 17=double).
- **`mtc1` (int→FP)** (`~887`): `srcA=rt; srcA_valid=1` (read **int**), `dst=fd; fp_dst_valid=1`
  (alloc **FP**), `is_mem=1`. **Routed through the memory pipe, not the FP pipe.**
- **`mfc1` (FP→int)** (`~869`): `srcB=fs; fp_srcB_valid=1` (read **FP**), `dst=rt; dst_valid=1`
  (alloc **int**), `is_mem=1`.
- **32-bit FP mode** → `MTC1_MERGE`/`MFC1_MERGE`: address the even reg (`rd[4:1],0`) and carry the
  low bit in `jmp_imm`; `MTC1_MERGE` also sets `fp_srcB_valid` to **read the current 64-bit FP reg and
  splice in the new 32-bit half** (read-modify-write of the pair).
- **FP compare** writes FCR: `fcr_dst_valid`; **FP cond-move/branch** read FCR via `fcr_src_valid` +
  `srcC = CC index` (`{FCR_ZP, insn[20:18]}`).

`is_mem` for the moves is the crux: the **mem unit is the universal cross-domain mover** because it
already reads/writes both register files (for FP loads/stores `lwc1/ldc1/swc1/sdc1`).

---

## 4. Rename (core.sv ~1371–1420) — per-source RAT pick, per-dst free-list alloc

Source mapping is literally a per-source mux on the domain flag:
```verilog
t_alloc_uop.srcA = t_uop.fp_srcA_valid ? r_fp_alloc_rat[t_uop.srcA[4:0]]
                                       : r_alloc_rat   [t_uop.srcA[4:0]];
```
(same for srcB, srcC). `hilo_src` field is reused: `= r_hilo_alloc_rat` (hilo) or `= r_fcr_alloc_rat`
(fcr) depending on which `*_src_valid` is set.

Dst: allocate a physical reg from the matching free list (`n_prf_entry` int / `n_fp_prf_entry` fp;
even/odd-aware for fp), write it into the matching alloc RAT (`n_alloc_rat[fd]` or `n_fp_alloc_rat[fd]`).
Allocation is **gated** on enough free regs per domain before the bundle can issue:
`t_enough_iprfs / t_enough_fprfs / t_enough_hlprfs` (core.sv ~785, 974, 1058) — if the needed domain is
out of physical regs, stall the alloc.

**Mispredict / fault recovery:** on `t_rat_copy`, *every* alloc RAT is restored from its retire RAT
(`r_fp_alloc_rat <= r_fp_retire_rat`, `r_hilo_alloc_rat <= r_hilo_retire_rat`, fcr likewise; core.sv
~1307–1331). So all four domains recover together.

---

## 5. Dispatch — three issue queues (exec.sv)

`is_fp → FP UQ` (`r_fp_uq`), `is_mem → MEM UQ` (`r_mem_uq`, includes FP ld/st + mtc1/mfc1),
else `→ INT UQ` (`r_uq`). Global `uq_full = t_uq_full || t_mem_uq_full || t_fp_uq_full` (exec.sv:288).
`r_fq_wait[rob_ptr]` coordinates the dual-issue case where one of a pair is FP and the other isn't.
FP UQ is a normal circular queue with head/tail/next pointers, same structure as the int UQ.

---

## 6. Execution

### FP pipe (exec.sv ~660, 1987, 2075, 1225)
1. Pop `fp_uq`; read operands `t_fp_srcA/B/C = r_fp_prf[fp_uq.srcA/B/C]`; FCR src
   `r_fcr_prf[fp_uq.hilo_src]`.
2. Wakeup/select waits on `r_fp_prf_inflight[...]` for each FP source.
3. Drive `fpu` (`.start`, operands, `dst_ptr_in`, `rob_ptr_in`, `fcr_ptr_in`, `fcr_sel`).
4. On `val`: write `r_fp_prf[t_fpu_dst_ptr] <= t_fpu_result`; on compare,
   `r_fcr_prf[t_fpu_fcr_ptr] <= t_fpu_result[7:0]`; signal complete to the ROB with `rob_ptr_out`.
5. **FP branches / cond-moves** read the condition bit directly: `r_fcr_prf[fp_uq.hilo_src][fp_uq.srcC[2:0]]`.

### Mem pipe = cross-domain mover (exec.sv ~658, 2369–2397, 2480, 1191)
- Reads **both** files: int operand `r_prf[mem_uq.srcA]` and fp operand `t_mem_fp_srcB = r_fp_prf[mem_uq.srcB]`.
- Stalls until **both** inflight bits clear:
  `!(mem_q_full || r_prf_inflight[mem_uq.srcA] || r_fp_prf_inflight[mem_uq.srcB])`.
- Handles: FP store (data = `t_mem_fp_srcB`, "needs byte swap" note), FP load + `mtc1` (set
  `t_mem_tail.fp_dst_valid=1; is_fp=1`), `mfc1` (fp src → int dst).
- Writeback routing: the mem response carries **`mem_rsp_fp_dst_valid`** (exec.sv:105/1191) so the
  result lands in the FP PRF vs int PRF.

### FPU module (fpu.sv) — fixed-latency, metadata rides along
- `FPU_LAT = 2` pipelined. Units: `fp_add` (SP/DP), `fp_mul` (SP/DP), `fp_compare` (SP/DP).
  **Div / convert / trunc / int↔fp-convert are separate units** (`fp_div.sv`, `fp_convert.sv`,
  `fp_trunc*.sv`), variable latency, driven outside this fixed pipe — port them as their own
  scheduler clients.
- A `valid` shift-register (`r_val`) + parallel metadata shift-regs (`r_ptr`, `r_rob`, `r_fcr`,
  `r_fcr_sel`, `r_fcr_reg`, `r_opcode`) carry dst/rob/fcr pointers through the pipe so they emerge
  aligned with the result. No back-pressure inside the pipe (fixed latency).
- Compare result is spliced into the FCR at the CC index via `handle_fcr(sel)`.

---

## 7. Writeback / complete / retire
- Complete: per-domain result + `rob_ptr` mark the ROB entry done (`valid_fp_dst`, `valid_fcr_dst`,
  `valid_hilo_dst` flags in rob.vh).
- Retire (core.sv ~619): `retire_reg_fp_valid <= t_rob_head.valid_fp_dst && t_retire`; frees the
  *old* physical reg into the retire free list and advances the retire RAT — same machinery as int,
  replicated per domain.

---

## 8. Applicability to current r9999 — assessment

**What r9999 already has and can reuse:** the int PRF/RAT/free-list, the HI/LO domain (renamed),
the ROB, the dual-issue rename, the MEM UQ and mem pipe, and the per-domain retire/recovery pattern.
r9999 is now **64-bit**, which *aligns well* with the 64-bit FP PRF (no width retrofit needed).

**What must be (re-)introduced — essentially the deltas above:**
1. FP PRF + alloc/retire RAT + even/odd free list + inflight bits.
2. FCR PRF + RAT (condition codes).
3. FP issue queue (`r_fp_uq`) + `is_fp` routing + `t_enough_fprfs` alloc gating.
4. uop fields: `fp_src{A,B,C}_valid`, `fp_dst_valid`, `fcr_{src,dst}_valid`, `is_fp` (+ rob.vh
   `valid_fp_dst`, `valid_fcr_dst`).
5. Decode of COP1 (arith + `mtc1/mfc1/cfc1/ctc1` + `lwc1/swc1/ldc1/sdc1` + BC1x) with the
   per-source domain flags and the `MERGE` variants.
6. Rename: the per-source RAT mux + per-dst domain alloc + 4-way RAT recovery.
7. Extend the **existing mem pipe** to read/write the FP PRF and carry `mem_rsp_fp_dst_valid`.
8. Instantiate `fpu` + the variable-latency div/convert/trunc units as FP-UQ clients.

**New challenges specific to *today's* r9999 (didn't exist when the FPU was removed):**
- **CP1 enable / Coprocessor-Unusable.** r9999 now models privilege (I just added a `CPU` uop for
  CP0-in-non-kernel → cause 11). FP needs the **CU1**-gated CpU: COP1 instructions must raise CpU
  (cause 11, `Cause.CE=1`) when `Status.CU1=0`. Today CU1 is hard-wired 1 (exec.sv readback). This is
  the natural tie-in to the just-added CpU mechanism — a second `CPU`-style decode gate on `~CU1`.
- **FP exceptions / FCSR.** Real FP traps (inexact/overflow/etc.) interact with the now-real exception
  model (EXL/EPC/cause). The bogo units don't raise these; a correct port must decide whether to model
  the FP trap enables in FCSR or stub them.
- **64-bit FP reg mode (FR bit).** `in_64b_fpreg_mode` here keys off a mode bit; r9999 must source it
  from `Status.FR`. The even/odd MERGE path must coexist with the 64-bit datapath.
- **Mode/serialization hazards.** mode-changing `ctc1`/`mtc0(Status.FR)` need the same
  restart-on-commit discipline r9999 uses for the KX 64-bit-mode hazard.

**Verdict (preliminary):** the plumbing is a clean, modular graft — the hard architectural pieces
(per-source domain flags, mem-pipe-as-mover, per-domain RAT/free-list/recovery) are all reusable and
match r9999's structure. The real work is (a) re-threading the uop/rob fields and rename, (b) wiring
the mem pipe to the FP PRF, and (c) the *new* privilege/exception integration (CU1→CpU, FCSR traps,
Status.FR) that the old design never had.

---

## 9. To verify when actually porting (didn't fully trace yet)
- Exact even/odd free-list allocation logic (`w_fp_ffs_even/odd`, full conditions) and the
  `MERGE` read-modify-write timing.
- FP load/store byte-swap ("needs byte swap" comments in the mem pipe) vs r9999's endian handling.
- `cfc1/ctc1` (FCR move) decode + rename path (FCR-as-`hilo_src` overload details).
- Dual-issue constraints when both slots are FP, or one FP + one mem move (`r_fq_wait`).
- Div/convert/trunc completion handshake (variable latency) into the ROB.
- Whether r9999's current rename width/ports can absorb a 3rd source domain without timing regressions.
