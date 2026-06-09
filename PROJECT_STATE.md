# R9999 MIPS-III OOO Simulator — Project State

**Last updated:** 2026-06-07

---

## Goal

Long-term: run a real OS on a simulated R4000-class MIPS. **Near-term active target: boot a stripped-down 64-bit MIPS Linux on the RTL only** (C++ checker disabled — the RTL's `tlb.sv` does real translation, so the interpreter's 1:1 `va2pa` is irrelevant for that path). Linux is chosen first because we can modify the source and build a minimal platform; IRIX 6.5 (closed source, SGI-specific HW/ARCS firmware) is a much-later "only when we're sure it'll work" aspiration. The csmith N32 corpus remains the ISA-validation backbone.

---

## Session 2026-06-07 — 64-bit TLB, exception model, Linux64 prep

All pushed to `main`:

| Commit | Summary |
|--------|---------|
| `fdcafe3` | 64-bit (R10000) TLB format: region `r[1:0]`, 27-bit VPN2 (VA[39:13]), 28-bit PFN (PA[39:12]), `PA_WIDTH` 32→40; `DMFC0`/`DMTC0` (rs=1/5); XContext (CP0 reg 20). Plus `--mapped64-data`/`--mapped64-insn` csmith variants (install TLB via DMTC0 in the 64-bit format, 1:1 mapping preserved). |
| `4a55121` | XTLB refill vector: a refill taken in 64-bit addressing mode vectors to `base\|0x080` (vs 32-bit `base\|0x000`); general exceptions `base\|0x180`. |
| `2335ceb` | EXL-based exception model: normal exceptions set `Status.EXL` (was wrongly setting `ERL`); ERET clears EXL with ERL precedence; EXL-gated refill vector (nested refill, EXL=1, → general vector). |
| `f0b46f5` | Fixed the `except` test: made self-contained (own vectors, no crt0) so the handler reaches `0x80000180` (crt0's `break` stubs had pushed it to `0x304`). |
| `6905e54` | CACHE (opcode 0x2f) decoded as NOP (RTL + interpreter). |
| `4c81611` | Read-only PRId (CP0 reg 15) = R4000 value; named `PRID_R4000/R4400/R10000` defines in `machine.vh`/`interpret.hh`/`sim.h`. |

**New self-contained test pattern** (`tests/xtlb/`, `tests/except/`): own vectors at exact BEV=0 offsets, no crt0, halt via the magic-halt register (store non-zero word to kseg1 `0xBFD00000` = PA `0x1FD00000`); build without crt0, run with `-c 0`. Tests: `test_xtlb64/32/_nested` (VEC=XTLB/TLB/GEN), `test_eret` (H1 R0), `test_cache` (CACHE-OK), `test_prid` (PRID-OK). `make run-xtlb` runs them all.

**Linux64 kernel bring-up — decided, not yet implemented:**
- Memory map: **hardcoded in the kernel** (`mach-r9999` platform, `prom_init` → `add_memory_region(0, SIZE)` + `CONFIG_CMDLINE`); sim passes nothing.
- Loader: **SGI-ROM-style raw blob, not ELF64** — model on `top.cc:427-451` (`--indy`): `memcpy` `objcopy -O binary vmlinux vmlinux.bin` into `s->mem.mem + (load_pa & 0x1fffffff)`, set PC = entry, `enable_checker=false`, no SGI MC/HPC. Pending sim work: a `--kernel <bin>` mode + `--kernel-load-pa`/`--kernel-entry` options.
- Addresses NOT finalized (proposed ckseg0: load PA `0x100000`, entry `0xffffffff80100000`). **PAUSED**: user researching Linux/MIPS boot + qemu-mips first.
- Console: CP0-reg-7 putchar works (no SGI devices needed); kseg1 pseudo-UART later for a real earlycon.

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
MFC0, MTC0, DMFC0, DMTC0, SYSCALL, BREAK, ERET, TLBWI, TLBWR, TLBR, TLBP, CACHE (NOP)
CP0 regs include EntryHi/Lo (64-bit format), Index/Random/Wired/PageMask, Context + XContext (reg 20), PRId (reg 15, read-only), Config (reg 16), Count/Compare, Status/Cause/EPC/BadVAddr.

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
| **FPGA: get the IP22 address map working** | High | Zynq UltraScale, `hdl/axi_is_the_worst_v1_0_M00_AXI.v` routes CPU physical → shared DRAM (`baseaddr + t_cpuaddr`). Need: (1) ARM-side loader (vmlinux.32 → baseaddr+0x08004000, arcs_fw.bin → baseaddr+0x1000, set resume_pc/sgi_mode/baseaddr/addrmask); (2) **ARM-side device emulation** replacing sgi_mc/sgi_hpc (seed MC MEMCFG/sysid at the device DRAM window +0x10000000, poll SCC console @ +0x10BD9837 and magic-halt @ +0x10D00000); (3) RTL decode cleanup in M00_AXI.v (RAM `{4'd0,cpuaddr[27:0]}` wraps 0x10000000+ onto low mem — cap RAM at 128MB or fix; make `t_cpuaddr` match `compute_mem_range_type`); (4) validate endianness (MEMCFG byte-swap). **Full write-up: `docs/fpga_address_map.html`.** |
| L1D miss-queue: "huh N should be inflight" | High | current kernel-boot blocker (appears after the MC/make_mask fixes); L1D inflight-tracking accounting |
| kseg1 pseudo-UART | Low | ARC console now works via the ARCS Write stub → CP0-r7 putchar; only needed for a real SCC `earlycon` |
| FPU stubs / Coproc-Unusable | Low | kernel currently built no-FPU; for FPU: stub cfc1 + CpU exception + FP emulator |

**Recent progress (2026-06-08):** 64-bit IP22 vmlinux.32 boots on the RTL via `--file vmlinux.32 -c 0 --arcs arcs/arcs_fw.bin` with **live console** ("Linux version… / ARCH: SGI-IP22 / CPU0 revision 00000400 (R4000SC) / MC: bank0 128M @ 08000000"). Fixed along the way: TNE, CACHE→NOP, PRId, EXL model, XTLB vector, ARCS firmware (`arcs/`), `sgi_mc` MEMCFG (wired into the `--arcs` path, decoupled from `--indy`), L1D `make_mask` missing MEM_SD/MEM_LD (full-mask bug), and refactored 64-bit load/store to `merge_cl64`/`select_cl64`. **Not yet committed** (per request). Physical address map + FPGA bring-up plan documented in `docs/fpga_address_map.html`.

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
2. TLB: **RTL now does real VA→PA translation** (tlb.sv, 64-bit format, refill/XTLB/general vectoring). The C++ **interpreter** still uses 1:1 `va2pa` — fine because Linux runs RTL-only; would need real translation only to re-enable the checker on a non-1:1 page table.
3. Exception vectors: **now dispatched** (EXL model; TLB-refill 0x000, XTLB 0x080, general 0x180, BEV-aware). ErrorEPC / true ERL-NMI-cache-error path intentionally deferred (not needed now).
4. SGI IP22 machine model: MC + HPC3 stubs only — only relevant to the eventual IRIX path, not Linux64.
5. PROM: SGI Indy PROM binary needed for `--indy` mode (IRIX path).

> Authoritative live status for the Linux64 effort: the "Session 2026-06-07" section above, and the auto-memory note `project_linux64_todo.md`.
