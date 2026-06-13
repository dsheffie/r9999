# R4000 FPU — rounding & exceptions spec (what a *correct* FPU must do)

Companion to `FPU_PORT_STUDY.md` (which covers the dataflow/plumbing). This doc is the
**numerical correctness spec**: rounding modes, the FCSR, the exception model, and the
default (untrapped) results. Sourced from the **MIPS R4000 User's Manual, 2nd ed**
(in-tree `R4400_Uman_book_Ed2.pdf`), Chapter 6 (FPU) §6.x and Chapter 7 (FP Exceptions).

**Headline:** the R4000 lets hardware be *simple* and still be IEEE-754 correct, because of the
**Unimplemented Operation (E)** trap — HW may refuse denormals / hard cases and hand them to a
**software FP emulator** (IRIX & Linux both ship one: Linux `arch/mips/math-emu`). So "correct R4000
FPU" = correct **normalized** arithmetic + 4 rounding modes + correct exception detection/flags +
correct IEEE default results + a working **E escape hatch** for everything hard.

---

## 1. FCR31 — Floating-Point Control/Status register (the FCSR)

Readable/writable in Kernel **or** User mode (via `cfc1`/`ctc1` reg 31). Bit layout (Fig 6-4/6-5):

```
 31      25 24 23 22  18 17        12 11      7 6      2 1 0
 [ 0 (7) ] FS  C [0(5)]  Cause(6)     Enables(5) Flags(5) RM
                          E V Z O U I   V Z O U I  V Z O U I
```

| Field | Bits | Meaning |
|---|---|---|
| **RM** | 1:0 | rounding mode (Table below) |
| **Flags** | 6:2 | `V Z O U I` — **sticky** IEEE status flags; set by HW on untrapped exception, only cleared by `ctc1` |
| **Enables** | 11:7 | `V Z O U I` — trap enables |
| **Cause** | 17:12 | `E V Z O U I` — set by the **last** arith op (not by load/store/move); `E` = Unimplemented |
| **C** | 23 | condition bit — set by FP **compare** (and `ctc1`) |
| **FS** | 24 | flush-to-zero: denormalized **results** flushed to 0 instead of raising `E` |

- `cfc1` (read FCR31) **drains the FP pipe**; if a pending op faults as the pipe empties, the FP
  exception is taken and `cfc1` re-executes. `ctc1` (write) only when the FPU is idle.
- **FIR = FCR0** (read-only): implementation + revision fields. Minor; expose imp/rev.

### Rounding modes (RM, Table 6-4)
| RM | Mnem | Meaning |
|---|---|---|
| 0 | **RN** | round to nearest, **ties to even** (LSB 0) |
| 1 | **RZ** | toward zero (truncate) |
| 2 | **RP** | toward +∞ |
| 3 | **RM** | toward −∞ |

All ops use RM. Correct rounding requires guard/round/sticky bits in the datapath.

---

## 2. The exception model (Ch 7 §7.2–7.4)

Six causes: 5 IEEE — **V** Invalid, **Z** Div-by-zero, **O** Overflow, **U** Underflow, **I** Inexact —
plus the R4000-specific **E** Unimplemented.

**Trap rule:** a floating-point exception is delivered iff `Cause[x] & Enable[x]` (for any x), *or*
when `ctc1` writes a Cause+Enable pair. Delivery sets CP0 `Cause.ExcCode = 15` (FPE); the FCSR Cause
bits say which. **`E` has no enable bit — setting `E` *always* traps.**

**On a taken trap:** *no result is written*, only the FCSR Cause bit is set; **the HW does NOT set the
Flag bits** — the FP-exception software must set them before calling a user handler. Software must
clear the enabled Cause bits (via `ctc1`) before `eret`, or it re-faults. (So user handlers never see
enabled Cause bits still set.)

**Untrapped (Cause set but Enable clear):** no trap; HW stores the **IEEE default result** and sets the
**sticky Flag** bit. The Cause field reflects only the most-recent op.

**Precise / one-at-a-time:** the FPU pre-examines operand exponents; if an op *might* fault it executes
in "stall mode" so at most one possibly-faulting op is in flight → precise FP exceptions. (Matters for
r9999's OOO + EPC model: the faulting FP op must surface at retire with the right EPC.)

### Default (untrapped) results — Table 7-1
| Exc | Default result |
|---|---|
| **I** Inexact | the rounded result |
| **Z** Div-by-zero | correctly-signed ∞ |
| **V** Invalid | a **quiet NaN** |
| **O** Overflow | RN→signed ∞; RZ→signed largest-finite; RP→ +∞ (pos) / −largest-finite (neg); RM→ +largest-finite (pos) / −∞ (neg) |
| **U** Underflow | RN/RZ→ signed 0; RP→ smallest +finite (pos) / −0 (neg); RM→ smallest −finite (neg) / 0 (pos) |

---

## 3. The crux — Table 7-2: what HW does vs IEEE, and when it forces `E`

This table is the whole strategy. "Trap Enabled / Disabled" = the relevant IEEE enable bit.

| FPA internal result | IEEE | Trap **enabled** | Trap **disabled** | Condition |
|---|---|---|---|---|
| Inexact result | I | I | I | loss of accuracy |
| Exponent overflow | O,I | O,I | O,I | normalized exp > Emax |
| Division by zero | Z | Z | Z | divisor 0, dividend finite≠0 |
| **Overflow on convert** | V | **E** | **E** | float→int source out of range |
| Signaling-NaN source | V | V | V | |
| Invalid operation | V | V | V | 0/0, ∞−∞, 0·∞, √(neg)… |
| **Exponent underflow** | U | **E** | **U,I** ‡ | normalized exp < Emin |
| **Denormal or QNaN operand** | None | **E** | **E** | denormal (exp=Emin−1, mant≠0) |

‡ Exponent underflow → sets `U,I` Cause bits **iff** both U,I enables are clear **and** FS=1; otherwise
it raises **E**.

**Reading it:** the HW computes only with **normalized** numbers. Anything involving denormals, QNaN
operands (in convert/compute), out-of-range float→int convert, or underflow it can't flush — it raises
**E** and the software emulator finishes the job. Compare and plain Move are exempt (they tolerate
denorm/NaN operands without trapping E).

---

## 4. Per-exception conditions (Ch 7 §7.4)

- **Invalid (V):** ∞−∞ add/sub; 0·∞ mul; 0/0 or ∞/∞ div; `<`/`>` compare (without `?`) on unordered
  operands; compare/convert on a signaling NaN; any arith on sNaN (`MOV` exempt; `ABS`/`NEG` are arith →
  trap); √(x<0). Untrapped → quiet NaN.
- **Div-by-zero (Z):** divisor 0, dividend finite nonzero. Untrapped → signed ∞.
- **Overflow (O):** rounded magnitude (unbounded exp) > format max. **Also sets I.** Untrapped →
  per-RM (Table 7-1).
- **Underflow (U):** tininess detected **after rounding** (|result| strictly in ±2^Emin); loss of
  accuracy detected as **inexact**. Untrapped (U,I enables clear **and** FS=1) → per-RM; otherwise → **E**.
- **Inexact (I):** rounded result not exact, or overflowed, or underflowed-with-FS. If I traps are
  enabled, *all* multi-cycle FP ops run in stall mode (perf hit) so the trap is precise.
- **Unimplemented (E):** reserved opcode/format; format-invalid op (e.g. `CVT.S.S`); denormal operand
  (except compare/move); QNaN operand (except compare/move); denormal result or underflow when U/I
  enabled or FS=0; overflow-on-convert. **Cannot be disabled.** Operands/dest undisturbed → software
  emulates, and any IEEE exceptions from the emulation are simulated by software.

---

## 5. Implementation strategy for r9999 (a *correct*, HW-tractable R4000 FPU)

**What the hardware MUST get right** (can't punt):
1. The 4 rounding modes with round-to-nearest-**even**, i.e. proper guard/round/sticky in add/sub/mul/
   div/sqrt/convert.
2. Normalized-operand IEEE arithmetic (the common path).
3. Exception **detection** + correct **default results** for I/O/Z/V and the per-RM O/U defaults.
4. The **E escape**: raise `E` (→ FPE trap, no result) for denormal/QNaN operands, overflow-on-convert,
   reserved/format-invalid ops, and the U/denormal-result cases per Table 7-2 / FS.
5. FCSR Cause/Flag/Enable/RM/C/FS semantics exactly (sticky flags; Cause = last op; HW doesn't set
   flags on a trap).

**What the hardware may PUNT to software (via `E`):** denormals / gradual underflow, sNaN/qNaN
corner emulation, out-of-range conversions, transcendental/remainder (those are already software).
This is exactly what IRIX/Linux expect — Linux `arch/mips/math-emu` is the handler. So a first correct
FPU can be a *normalized-only* unit that traps everything hard.

**Ties into existing r9999 work / the plumbing study:**
- **CU1 → Coprocessor Unusable.** COP1 must raise CpU (cause 11, `Cause.CE=1`) when `Status.CU1=0` —
  reuse the `CPU` uop / cause-11 mechanism just added for CP0 (gate on `~CU1` instead of `~kernel`).
- **FPE = cause 15.** New arch-fault class in the ROB (mirror the `is_cpu`/`is_ii` plumbing): an FP op
  whose enabled Cause bit fires sets a `faulted` ROB entry → ARCH_FAULT → `n_cause = 5'd15`, with the
  FCSR Cause bits as the sub-reason. Must be **precise** (right EPC; BD bit if in a delay slot).
- **FCSR is the FCR PRF** from the plumbing study — compares write the C/condition bit there; `ctc1`
  writes enables/RM/FS; `cfc1` reads (and must drain/serialize).
- **Status.FR** selects 32- vs 64-bit FP reg mode (the even/odd MERGE path in the plumbing study).
- The bogo `fp_*` units in `mipscore` produce wrong bits but the *interfaces* (start/result/latency,
  metadata shift) are the integration contract — replace their internals with correctly-rounded units,
  keep the wrapper.

---

## 6. To verify / decide when implementing
- Exact float→int convert range checks (when to raise V vs E) and the integer overflow result.
- Whether to implement HW gradual-underflow/denormals or punt all to `E` (recommend punt first; add
  later if perf needs it). With FS=1, denormal *results* flush to 0 in HW — cheap and common for OSes.
- Round-to-nearest-even tie handling in each unit (mul/div/sqrt sticky-bit correctness).
- NaN propagation/quieting rules (which input NaN survives; sNaN→qNaN payload) — MIPS has specific
  rules; verify vs Appendix B and the cosim reference model (e.g. softfloat/QEMU) used for checking.
- Co-sim: the interp/checker needs a correctly-rounded soft-float reference (Berkeley softfloat or
  glibc) to validate against — the current checker has no FP model.
- The "stall mode for precise inexact traps" is likely unnecessary for r9999 (the ROB already gives
  precise exceptions); confirm the OOO retire path makes FP exceptions precise without it.
```
