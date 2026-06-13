#!/usr/bin/env python3
"""
gen_mips_test.py -- seeded random MIPS-III instruction generator for r9999.

Emits a bare-metal .S (builds with the tests/ Makefile pattern; crt0 jal's main).
Programs are VALID, FAULT-FREE, and TERMINATING so the sim's built-in interpreter
co-sim (ooo_core -c 1) can validate retire-by-retire:

  * runs entirely in 64-bit mode (Status.KX set in the preamble): every 32- and
    64-bit op is legal on EVERY control-flow path, so a branch can never reach a
    64-bit op with the wrong mode (the static-mode-tracking trap).
  * register pool only writes safe GPRs ($2..$24); $0/$sp/$ra/$k0/$k1 untouched.
  * memory ops mask the effective address into a zeroed BSS scratch buffer
    (64-bit kseg0 addressing), so they never fault.
  * branches are FORWARD-only with explicit (non-branch) delay slots, and branch
    targets only land on UNIT STARTS -- never inside a multi-instruction macro
    (mem mask / div / hazard), which would skip a safety step.
  * div/divu force a nonzero divisor; only non-trapping arithmetic is used
    (addu/daddu/... never add/dadd) so there are no integer-overflow traps.
  * the "hazard" unit toggles Status.KX off->on then runs a 64-bit op right after
    the re-enable (the mtc0 -> 64-bit-op restart-on-commit case) -- atomically,
    so the brief 32-bit window never exposes a 64-bit op.

Usage:
  ./gen_mips_test.py --seed 1 --n 256 --out rt_0001     # writes rt_0001.S
  make rt_0001.elf rt_0001.mips                          # build (.mips = ELF)
  ../../ooo_core -f rt_0001.elf -c 1 --maxicnt 5000000   # co-sim check
"""
import argparse, random

# ---- register allocation -------------------------------------------------
POOL   = list(range(2, 25))   # $2..$24 : random read/write
AT     = 1                    # address / macro temp (.set noat)
GP     = 28                   # holds the KX-clear mask
T9     = 25                   # putchar marker reg
SB     = 30                   # scratch-buffer base (sign-extended kseg0)
BUFSZ  = 1024                 # scratch bytes
OFFMASK = (BUFSZ - 16) & ~7   # 8-aligned offset, with headroom for unaligned dword access

def rd():  return random.choice(POOL)              # dest (pool only)
def rs():  return random.choice(POOL + [0])        # source (may be $0)
def s16(): return random.randint(-32768, 32767)
def u16(): return random.randint(0, 65535)
def sa():  return random.randint(0, 31)

# FP register pool: EVEN registers only -- gas under `.set mips3` rejects odd FP
# regs ("float register should be even", its FR=0 assumption).  The RTL/checker
# are flat FR=1 (32x64b), so even-only still exercises moves/ld/st/rename fully;
# the odd-reg / double-aliasing FR=1 edge would need raw .word encodings (later).
FPP    = list(range(0, 32, 2))                     # $f0,$f2,...,$f30
def frd(): return random.choice(FPP)               # FP register

# ---- instruction menus (edit to match what the core implements) ----------
ALU_R  = ["addu", "subu", "and", "or", "xor", "nor", "slt", "sltu"]
ALU_I  = ["addiu", "andi", "ori", "xori", "slti", "sltiu"]
SHIFTV = ["sllv", "srlv", "srav"]
SHIFTI = ["sll", "srl", "sra"]
D_ALU_R  = ["daddu", "dsubu"]                       # 64-bit (legal: always KX)
D_ALU_I  = ["daddiu"]
D_SHIFTV = ["dsllv", "dsrlv", "dsrav"]
D_SHIFTI = ["dsll", "dsrl", "dsra", "dsll32", "dsrl32", "dsra32"]
MEM_LD  = ["lb", "lbu", "lh", "lhu", "lw", "lwu", "ld"]   # aligned (EA is 8-aligned)
MEM_ST  = ["sb", "sh", "sw", "sd"]
MEM_UNW = ["lwl", "lwr", "swl", "swr"]                    # unaligned word  (off 0..3)
MEM_UND = ["ldl", "ldr", "sdl", "sdr"]                    # unaligned dword (off 0..7)
FP_LD   = ["lwc1", "ldc1"]                                # FP load  (word / dword); 8-aligned EA
FP_ST   = ["swc1", "sdc1"]                                # FP store (word / dword); 8-aligned EA

class Gen:
    def __init__(self, n):
        self.n = n
        self.body = []          # list of {labels:[...], text:str}
        self.pending = []        # [(label, min_idx)] branches awaiting a target
        self.lbl = 0

    def newlabel(self):
        self.lbl += 1
        return f".L{self.lbl}"

    # A branch target may only land on a UNIT START (never inside a mem/div/hazard
    # macro -- jumping past e.g. the address-mask would break a safety step).
    # Called once at the start of each top-level unit; returns the labels of any
    # pending branches whose target has now been reached, to put on this insn.
    def _start_unit(self):
        idx = len(self.body)
        here = [l for (l, m) in self.pending if m <= idx]
        self.pending = [(l, m) for (l, m) in self.pending if m > idx]
        return here

    def _emit(self, text, labels=None):
        self.body.append({"labels": labels or [], "text": text})

    # -- a single legal ALU instruction (allow64=False for delay slots) ----
    def alu(self, allow64=True):
        menu = [("r", ALU_R), ("i", ALU_I), ("v", SHIFTV), ("s", SHIFTI),
                ("lui", None)]
        if allow64:
            menu += [("dr", D_ALU_R), ("di", D_ALU_I),
                     ("dv", D_SHIFTV), ("ds", D_SHIFTI)]
        kind, ops = random.choice(menu)
        if kind in ("r", "dr", "v", "dv"):
            return f"{random.choice(ops)} ${rd()}, ${rs()}, ${rs()}"
        if kind == "i":
            o = random.choice(ALU_I)
            imm = u16() if o in ("andi", "ori", "xori") else s16()
            return f"{o} ${rd()}, ${rs()}, {imm}"
        if kind == "di":
            return f"daddiu ${rd()}, ${rs()}, {s16()}"
        if kind in ("s", "ds"):
            return f"{random.choice(ops)} ${rd()}, ${rs()}, {sa()}"
        return f"lui ${rd()}, {u16()}"              # lui

    # -- multiply / divide (raw; divisor forced nonzero) -------------------
    def muldiv(self, labs):
        a, b, dst = rs(), rs(), rd()
        if random.random() < 0.5:                   # multiply (32-bit hi/lo)
            op   = random.choice(["multu", "mult"])
            rdop = random.choice(["mfhi", "mflo"])
            # 32-bit mult/div require sign-extended (canonical) operands; a prior
            # 64-bit op may have left non-canonical upper bits -> sll $x,$x,0 fixes.
            lines = [f"sll ${a}, ${a}, 0", f"sll ${b}, ${b}, 0",
                     f"{op} ${a}, ${b}", f"{rdop} ${dst}"]
        else:                                       # divide (nonzero divisor)
            op   = random.choice(["divu", "div"])
            rdop = random.choice(["mflo", "mfhi"])
            lines = [f"sll ${a}, ${a}, 0",                            # canonical dividend
                     f"sll ${AT}, ${b}, 0", f"ori ${AT}, ${AT}, 1",   # canonical divisor, != 0
                     f"{op} $0, ${a}, ${AT}", f"{rdop} ${dst}"]       # raw, no trap
        for i, ln in enumerate(lines):
            self._emit(ln, labs if i == 0 else None)

    # -- memory: mask EA into the scratch buffer (64-bit kseg0) ------------
    def mem(self, labs):
        base = rs()
        lines = [f"andi ${AT}, ${base}, {OFFMASK}",   # 8-aligned offset
                 f"daddu ${AT}, ${SB}, ${AT}"]        # EA in scratch (64-bit)
        r = random.random()
        if r < 0.2:                                   # unaligned word
            op = random.choice(MEM_UNW); off = random.randint(0, 3)
            reg = rd() if op[0] == 'l' else rs()
            lines.append(f"{op} ${reg}, {off}(${AT})")
        elif r < 0.4:                                 # unaligned dword
            op = random.choice(MEM_UND); off = random.randint(0, 7)
            reg = rd() if op[0] == 'l' else rs()
            lines.append(f"{op} ${reg}, {off}(${AT})")
        elif r < 0.7:
            lines.append(f"{random.choice(MEM_LD)} ${rd()}, 0(${AT})")
        else:
            lines.append(f"{random.choice(MEM_ST)} ${rs()}, 0(${AT})")
        for i, ln in enumerate(lines):
            self._emit(ln, labs if i == 0 else None)

    # -- FP move / load / store (FR=1 flat regs; even-only so gas accepts) --
    #    moves are address-less; FP ld/st mask the EA into scratch like mem().
    #    The co-sim compares GPRs+memory, so mfc1 (-> GPR) and swc1/sdc1 (-> mem,
    #    read back by a later int load) are what actually get validated.
    def fp(self, labs):
        r = random.random()
        if r < 0.3:                                   # GPR -> FPR
            self._emit(f"mtc1 ${rs()}, $f{frd()}", labs)
        elif r < 0.6:                                 # FPR -> GPR (dst compared)
            self._emit(f"mfc1 ${rd()}, $f{frd()}", labs)
        else:                                         # FP load / store
            base = rs()
            lines = [f"andi ${AT}, ${base}, {OFFMASK}",   # 8-aligned offset
                     f"daddu ${AT}, ${SB}, ${AT}"]        # EA in scratch (64-bit)
            if r < 0.8:
                lines.append(f"{random.choice(FP_LD)} $f{frd()}, 0(${AT})")
            else:
                lines.append(f"{random.choice(FP_ST)} $f{frd()}, 0(${AT})")
            for i, ln in enumerate(lines):
                self._emit(ln, labs if i == 0 else None)

    # -- forward branch + delay slot ---------------------------------------
    def branch(self, labs):
        k = random.randint(0, 5)
        target = len(self.body) + 2 + k             # past branch + delay slot
        lbl = self.newlabel()
        self.pending.append((lbl, target))          # placed at next safe unit start
        r = random.random()
        if r < 0.45:
            self._emit(f"{random.choice(['beq','bne'])} ${rs()}, ${rs()}, {lbl}", labs)
        elif r < 0.85:
            op = random.choice(["blez", "bgtz", "bltz", "bgez"])
            self._emit(f"{op} ${rs()}, {lbl}", labs)
        else:
            self._emit(f"j {lbl}", labs)
        self._emit(self.alu(allow64=False))         # delay slot (safe, no branch)

    # -- mode-hazard stress: atomically toggle KX off then on, then run a
    #    64-bit op right after the re-enable (the mtc0 -> 64b-op restart case).
    #    Atomic (only the first insn is a branch target), so the brief 32-bit
    #    window never exposes a 64-bit op and KX is always set at unit edges.
    def hazard(self, labs):
        lines = [f"mfc0 ${AT}, $12",
                 f"and ${AT}, ${AT}, ${GP}",   # clear KX (-> 32-bit, momentarily)
                 f"mtc0 ${AT}, $12",
                 f"ori ${AT}, ${AT}, 0x80",    # set KX (-> 64-bit)
                 f"mtc0 ${AT}, $12",
                 ".word 0x000000c0"]           # ehb
        for _ in range(random.randint(1, 2)):  # 64-bit op(s) right after re-enable
            lines.append(self.alu())
        for i, ln in enumerate(lines):
            self._emit(ln, labs if i == 0 else None)

    def generate(self):
        while len(self.body) < self.n:
            labs = self._start_unit()               # labels for this unit start
            near_end = len(self.body) > self.n - 8
            choices = ["alu"] * 5 + ["mem"] * 3 + ["muldiv"] * 2 + ["hazard"] * 1 + ["fp"] * 3
            if not near_end:
                choices += ["branch"] * 3
            c = random.choice(choices)
            if   c == "alu":    self._emit(self.alu(), labs)
            elif c == "muldiv": self.muldiv(labs)
            elif c == "mem":    self.mem(labs)
            elif c == "fp":     self.fp(labs)
            elif c == "branch": self.branch(labs)
            elif c == "hazard": self.hazard(labs)
        # any branch target past the end lands on a final safe nop
        leftover = [l for (l, _) in self.pending]
        if leftover:
            self.body.append({"labels": leftover, "text": "nop"})

    def render(self, seed):
        L = []
        L.append(f"/* AUTO-GENERATED by gen_mips_test.py  seed={seed} n={self.n} */")
        L.append("    .set mips3")
        L.append("    .set noreorder")
        L.append("    .set noat")
        L.append("    .text")
        L.append("    .globl main")
        L.append("    .type  main, @function")
        L.append("main:")
        L.append(f"    mfc0  ${AT}, $12                 /* enter 64-bit mode */")
        L.append(f"    ori   ${AT}, ${AT}, 0x80         /* set Status.KX */")
        L.append(f"    mtc0  ${AT}, $12")
        L.append("    .word 0x000000c0                 /* ehb */")
        L.append(f"    lui   ${GP}, 0xffff             /* ${GP} = ~0x80 KX-clear mask */")
        L.append(f"    ori   ${GP}, ${GP}, 0xff7f")
        L.append(f"    la    ${SB}, randgen_scratch     /* scratch base */")
        L.append(f"    sll   ${SB}, ${SB}, 0            /* sign-extend to 64-bit kseg0 */")
        L.append("    multu $0, $0                     /* init hi/lo */")
        for r in POOL:                                 # deterministic reg init
            v = random.getrandbits(32)
            L.append(f"    lui   ${r}, 0x{(v>>16)&0xffff:04x}")
            L.append(f"    ori   ${r}, ${r}, 0x{v&0xffff:04x}")
        # FP regs are not reset in HW -> init every even FP reg deterministically
        # (mtc1 sign-extends bits[31:0]) so no mfc1/store ever reads an undefined reg.
        for fr in FPP:
            v = random.getrandbits(32)
            L.append(f"    lui   ${AT}, 0x{(v>>16)&0xffff:04x}")
            L.append(f"    ori   ${AT}, ${AT}, 0x{v&0xffff:04x}")
            L.append(f"    mtc1  ${AT}, $f{fr}")
        L.append("    /* ---- random body ---- */")
        for it in self.body:
            for lab in it["labels"]:
                L.append(f"{lab}:")
            L.append(f"    {it['text']}")
        L.append("    /* ---- epilogue: print DONE + halt ---- */")
        for ch in "DONE\n":
            L.append(f"    li    ${T9}, {ord(ch)}")
            L.append(f"    mtc0  ${T9}, $7")
        L.append("    break")
        L.append("    .size main, .-main")
        L.append("    .bss")
        L.append("    .align 3")
        L.append("randgen_scratch:")
        L.append(f"    .space {BUFSZ}")
        L.append("")
        return "\n".join(L)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--n", type=int, default=256, help="approx body instruction count")
    ap.add_argument("--out", default="rt", help="output prefix (writes <out>.S)")
    a = ap.parse_args()
    random.seed(a.seed)
    g = Gen(a.n)
    g.generate()
    with open(a.out + ".S", "w") as f:
        f.write(g.render(a.seed))
    print(f"wrote {a.out}.S  (seed={a.seed}, n={a.n})")

if __name__ == "__main__":
    main()
