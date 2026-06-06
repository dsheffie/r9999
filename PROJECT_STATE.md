# R9999 MIPS-III OOO Simulator — Project State

**Last updated:** 2026-06-05

---

## Goal

Run IRIX 6.5 on a simulated SGI Indigo2 (IP22 / R4000). The immediate milestone is passing a large corpus of N32 ABI csmith tests to validate the ISA implementation before tackling the OS.

---

## Architecture

| Component | Description |
|-----------|-------------|
| RTL       | SystemVerilog OOO core (Verilator), `M_WIDTH=64`, scalar rename+ROB, L1D/L1I/L2 caches |
| Checker   | C++ software interpreter (`interpret.cc`) runs in lockstep, signals mismatches |
| Build     | `make` in repo root → Verilator → `obj_dir/`; binary is `ooo_core` |
| ABI       | N32 (MIPS-III ISA, 32-bit pointers, 64-bit registers) |
| Boot      | `tests/csmith/start_csmith.S` → `reset_init` → sets KX/SX/UX in CP0 Status → `jal main` → `break` |
| Linker    | `hello/baremetal.ld`: boot ROM at `0xBFC00000`, code at `0x80020000` |

---

## Test Framework

`tests/csmith/run_tests.sh [N [cbmc_k [maxicnt [fail_N.c]]]]`

- Generates N random C programs with csmith (`--no-float --no-builtins -mips3 -mabi=n32`)
- cbmc gates out programs with unbounded loops (k=20)
- Reference: `mips-linux-gnu-gcc -O1 -static` under `qemu-mips-static`
- Bare-metal: cross-compiled with `-mips3 -mabi=n32 -mno-abicalls -ffreestanding -nostdlib`
- Compares `checksum = ...` output lines; mismatches saved as `fail_N.c` / `fail_N.elf`

**Last run score: 984 pass / 16 skip / 0 fail (1000 tests, --timer-irq)**

`run_tests.sh` accepts `--timer-irq` flag anywhere in argv: compiles `start_csmith.S` with `-DENABLE_TIMER_IRQ`, arming Compare=20000 / interval=10000 cycles, enabling IM[7]+IE in SR, clearing EXL/ERL. Timer handler rearms via `g_timer_next_compare += g_timer_interval`; never reads Count (mfc0 $9 in OOO captures Count at issue time, checker compares at retire — diverges by pipeline depth).

History: 333/132/35 → 366/128/6 (ldl/ldr/sdl/sdr) → 356/141/3 (bgez fix) → 340/160/0 (exc_handler) → 984/16/0 (1000 tests, timer IRQs)

---

## Implemented Instructions (both interpreter + RTL)

### Integer ALU (32-bit)
ADD, ADDU, ADDI, ADDIU, SUB, SUBU, AND, ANDI, OR, ORI, XOR, XORI, NOR, LUI, SLT, SLTU, SLTI, SLTIU, SLL, SRL, SRA, SLLV, SRLV, SRAV

### Integer ALU (64-bit — MIPS-III)
DADD, DADDU, DADDI, DADDIU, DSUB, DSUBU, DSLL, DSRL, DSRA, DSLL32, DSRL32, DSRA32, DSLLV, DSRLV, DSRAV

### Multiply / Divide (32-bit)
MULT, MULTU, DIV, DIVU — result in HI/LO; MFHI, MFLO

### Multiply / Divide (64-bit — MIPS-III)
DMULT, DMULTU, DDIV, DDIVU — result in HI/LO  
RTL: multiplier (`mul.sv`) and divider (`divider.sv`) both have `is_32b` port; hooked up

### Branches / Jumps
BEQ, BNE, BLEZ, BGTZ, BGEZ, BLTZ, BLTZAL, BGEZAL, BEQL, BNEL, BLEZL, BGTZL, J, JAL, JR, JALR

### Loads (32-bit)
LB, LBU, LH, LHU, LW, LWL, LWR, LWU

### Stores (32-bit)
SB, SH, SW, SWL, SWR

### Loads / Stores (64-bit — MIPS-III)
LD, SD — aligned 64-bit doubleword load/store

### CP0 / System
MFC0, MTC0, DMFC0, DMTC0, SYSCALL, BREAK, ERET, TLBWI, TLBWR, TLBR, TLBP

### CP0 Timer
CP0 Count (reg 9) increments every cycle; Compare (reg 11) fires IP[7] when Count==Compare; writing Compare clears the interrupt. Exposed as `cp0_count` output port and `irq_pending` signal. Checker syncs Count via `tb->cp0_count` each cycle; `took_irq` fires `raise_int()` in the interpreter.

---

## Key File Inventory

| File | Purpose |
|------|---------|
| `uop.vh` | `opcode_t` enum (all ISA opcodes, values 0–107) |
| `machine.vh` | `mem_op_t` enum (5-bit, values 0–16); error codes |
| `decode_mips.sv` | MIPS→UOP decoder; all 64-bit insns gated by `w_in_64b_mode` |
| `exec.sv` | Integer/FP/branch execution, multiplier/divider dispatch |
| `l1d.sv` | D-cache; all `mem_op_t` cases including LWU, MEM_LD, MEM_SD |
| `l1i.sv` | I-cache |
| `l2.sv` | L2 cache; all DRAM interface signals are `[4:0]` |
| `core_l1d_l1i.sv` | Top-level integration |
| `interpret.cc` | Software interpreter; all implemented insns |
| `mips_insns.hh` | X-macro list for `mipsInsn` enum |
| `mul.sv` | Multiplier; `is_32b` selects 32b vs 64b; `is_signed` for signed |
| `divider.sv` | Divider; `is_32b` selects 32b vs 64b |
| `tests/csmith/start_csmith.S` | Bare-metal startup; sets KX/SX/UX |
| `tests/csmith/run_tests.sh` | Test harness |
| `tests/csmith/baremetal_support.c` | memcpy/memset/strcmp/exc_handler |
| `hello/baremetal.ld` | Linker script |
| `hello/arith64.c` | 64-bit helper routines (used by N32 ABI code) |

---

## Notable Implementation Details

### 64-bit mode gating
`w_in_64b_mode` in `decode_mips.sv` — requires CP0 Status KX=SX=UX=1 (bits [7:5]). Set at boot in `start_csmith.S` via `mfc0/ori/mtc0`.

### mem_op_t width
`mem_op_t` is `logic [4:0]` (5-bit). All DRAM interface wires in `l1d.sv`, `l1i.sv`, `l2.sv`, `core_l1d_l1i.sv` are `[4:0]`.

### Multiplier (64-bit)
`exec.sv` passes `is_32b = (int_uop.op == MULT || int_uop.op == MULTU)` — zero for DMULT/DMULTU.

### Divider (64-bit)
`exec.sv` has two start signals: `t_start_div32` and `t_start_div64`. `start_div = t_start_div32 | t_start_div64`. `is_32b = t_start_div32` (so 0 for 64-bit divides). `n_wb_bitvec[DIV32_LAT]` fires on either.

### Funnel shifter for 64-bit shifts
`shift_right` module with `LG_W=6`. `t_32b_shift=0` for all D-prefix shifts. `t_shift_amt = {1'b1, sa}` for DSLL32/DSRL32/DSRA32 (adds 32 to the shift amount).

### DADDIU register field bug (fixed)
DADDIU is I-type: `srcA=rs`, `dst=rt`. Was incorrectly using R-type fields (`srcA=rt`, `dst=rd`) in an earlier version — caused results to land in wrong register.

---

## Recently Implemented

- `sub` (SPECIAL func=0x22): 32-bit subtract with overflow trap (ExcCode=12); RTL `w_sub32_overflow` condition and matching interpreter `raise_overflow` path
- `add`/`dadd`/`dsub` overflow traps: all now consistent between RTL `w_{add32,sub32,add64,sub64}_overflow` and interpreter
- CP0 timer IRQ csmith integration: `--timer-irq` flag for `run_tests.sh`; Compare=20000 / interval=10000; avoids `mfc0 $9` (Count) divergence by using fixed literals
- `ldl` / `ldr` (opcodes 0x1A/0x1B): 64-bit unaligned load (MIPS-III counterpart to lwl/lwr)
- `sdl` / `sdr` (opcodes 0x2C/0x2D): 64-bit unaligned store (counterpart to swl/swr)
- `BGEZ`/`BGEZAL` branch condition fixed: was checking `t_srcA[31]` (32-bit sign bit) instead of `t_srcA[M_WIDTH-1]` (64-bit sign bit)
- `exc_handler` in `baremetal_support.c` now writes the halt sentinel for ExcCode 4 (AdEL), 5 (AdES), and 13 (Tr) in addition to 9 (Bp) and 10 (RI)

## Completed Items (no longer blocking)

### `ldl` / `ldr` — Load Doubleword Left / Right (opcodes 0x1A / 0x1B) — **IMPLEMENTED**

64-bit unaligned load — the MIPS-III counterpart to LWL/LWR.

- **Interpreter**: I-type switch in `interpret.cc` at `switch(opcode)` (~line 1920). Add cases `0x1a` and `0x1b`. Reference: existing `_lwl<EL>` / `_lwr<EL>` helpers.
- **RTL**: Need opcode entries in `uop.vh`, `mem_op_t` entries in `machine.vh`, decoder cases in `decode_mips.sv`, execution dispatch in `exec.sv`, and L1D cache handling in `l1d.sv`.

**LDL semantics (big-endian):**  
`ea = rs + offset`; `vAddr[2:0]` selects how many bytes to load from the most-significant side.  
`ldl rt, offset(rs)` merges the left (high) bytes of the doubleword containing `ea` into `rt`.

**LDR semantics (big-endian):**  
Complement: merges the right (low) bytes into `rt`, leaving the rest of `rt` unchanged.

Together `ldl rt, 7(base); ldr rt, 0(base)` loads an unaligned 64-bit value.

### `sdl` / `sdr` — Store Doubleword Left / Right (opcodes 0x2C / 0x2D) — **IMPLEMENTED**

---

## Serializing Instructions (must_restart)

All of these drain the ROB before executing and restart the pipeline afterward (`serializing_op=1`, `must_restart=1`). The restart PC must be valid at the time the instruction retires.

| Instruction | Notes |
|-------------|-------|
| TLBR        | Reads TLB entry at Index into EntryHi/EntryLo0/EntryLo1 |
| TLBWI       | Writes TLB entry at Index from EntryHi/EntryLo0/EntryLo1 |
| TLBWR       | Writes TLB entry at random index |
| MFC0        | Reads CP0 register to GPR |
| MTC0        | Writes GPR to CP0 register |
| ERET        | Exception return; restores EPC→PC, clears EXL/ERL |

**TLBP** is NOT must_restart — it executes through the memory unit and returns the result via TLBP-style 64-bit retirement writeback (same mechanism as dcache 64b reads).

### Delay-slot interaction with must_restart ops

When a must_restart instruction is in the delay slot of a **taken** branch, the restart PC is set to `branch_pc + 8` (sequential fall-through) rather than the branch target. This is architecturally UNPREDICTABLE but can cause incorrect simulator behavior in practice.

**Findings from SGI O2 firmware (ip32prom-decompiler/output/firmware.S):**

| Instruction in delay slot | Count | Impact |
|---------------------------|-------|--------|
| `cache` (opcode 47)       | 16    | Safe — treated as NOP in sim; all are flush/invalidate ops, not INDEX_LOAD_TAG |
| `mfc0`                    | 5     | Bug: 4× `beqz + mfc0 $TagHi`, 1× `beqz + mfc0 $Status`. For taken branches restart goes to wrong PC. |
| `mtc0`                    | 0     | Not present |
| `eret`                    | 0     | Not present (architecturally UNPREDICTABLE, firmware avoids it) |

**Known issue**: MFC0 has `must_restart=1` in the decoder. The 5 firmware instances are all in `beqz` delay slots. Fix: make MFC0 non-serializing (remove `serializing_op` and `must_restart`; read CP0 directly at execute time since CP0 state doesn't alias with integer PRF).

---

## Next Steps / Open Work

| Task | Priority | Notes |
|------|----------|-------|
| Implement `cache` as NOP | High | Opcode 47 currently decodes as II (illegal); 77 occurrences in firmware; all are cache maintenance — safe to NOP in sim since caches are reset by FSMs at boot |
| Fix MFC0 must_restart | High | 5 instances in firmware delay slots cause wrong restart PC for taken branches |
| FPU stubs | Low | `lwc1`/`swc1`/`ldc1`/`sdc1` + FP arithmetic; blocked on FPU datapath |

(The `sdl`/`sdr` and `ldl`/`ldr` implementation sections below are retained for reference.)

---

## Failure Pattern Analysis (from last run — 0 failures)

No failures in the last 500-test run. The three categories of prior failures are all resolved:

1. **ldl/ldr/sdl/sdr** (was ~29 failures): implemented in both interpreter and RTL.
2. **BGEZ/BGEZAL 32-bit sign check** (was 2 failures): `t_srcA[31]` → `t_srcA[M_WIDTH-1]`.
3. **Exception handler spin** (was ~4 failures): `exc_handler` now halts cleanly on AdEL (4), AdES (5), and Tr (13), in addition to Bp (9) and RI (10). Tests that exercise `teq` (divide-by-zero trap) or unaligned `ld`/`sd` now terminate quickly rather than looping until the 30-second sim timeout.

The higher skip count (160 vs 128 before) reflects tests that were previously burning the full 30-second timeout now completing quickly and being counted as skips (no checksum output = SKIP in the harness).

---

The csmith N32 test suite is essentially clean. To increase pass count further, the skip rate needs to be reduced — most skips are either cbmc-detected infinite loops (not fixable) or tests that exercise unimplemented instructions that terminate early (no checksum). Profiling which instructions cause early termination would identify the next targets.

## Longer-term Work

1. FP instructions (dmtc1, c.lt.d, add.d) — appear rarely in N32 code; currently skipped by csmith `--no-float` flag
2. TLB: pass-through VA→PA currently, not functionally correct
3. Exception vectors: detected but not dispatched
4. SGI IP22 machine model: MC + HPC3 stubs only; need more peripherals for IRIX boot
5. PROM: SGI Indy PROM binary needed for `--indy` mode
