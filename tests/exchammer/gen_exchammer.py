#!/usr/bin/env python3
"""
gen_exchammer.py -- seeded random "exception hammer" for r9999: a stream of normal code
(ALU, branches, cached loads/stores, L1-missing loads) with loads/stores that FAULT mixed
in, so every exception flushes a pipeline full of younger in-flight memory ops.

Targets the L1D per-ROB/colour bookkeeping across flushes (the silicon EXCEPTION_DRAIN
hang after a TLB-miss load).  Self-contained: own _start and BEV=0 vectors (no crt0).

Fault kinds (rates are knobs):
  * TLB refill: loads/stores to a mapped kuseg window (VA 0x00400000, --map-pages pages,
    identity-offset onto PA 0x00200000).  The refill handler (0x000) maps the faulting page
    pair with tlbwi at a SOFTWARE round-robin index ($28): deterministic, so the RTL and the
    ISS evict the same entries and the co-sim checker stays in lockstep (tlbwr would not --
    the RTL's Random decrements per retire, not per cycle).  The faulting op then re-executes.
  * AdEL/AdES: misaligned lw/sw to the cached buffer; the general handler (0x180) skips the
    instruction (EPC += 4).  Faulting ops are never placed in delay slots.
Normal code: ALU/shift/mult, forward branches (delay slots are always safe ALU ops), loads
and stores to a 4 KB L1-resident buffer and a 64 KB L1-missing buffer.

Usage:
  ./gen_exchammer.py --seed 1 --units 400 --iters 50 --out eh_0001     # writes eh_0001.S
  make -C .. exchammer/eh_0001.elf
  ../../ooo_core -f exchammer/eh_0001.elf -c 1 --maxicnt 20000000      # expect DONE
"""
import argparse, random

POOL = list(range(2, 25))      # $2..$24 random read/write
AT = 1                         # address temp (.set noat)
LOOP = 25                      # iteration counter
TLBI = 28                      # software TLB-replacement index (handler only)
NEAR = 30                      # 4 KB cached buffer base (kseg0)
MAPB = 31                      # mapped kuseg window base (0x00400000)
FAR_OFF = 0x1000               # far (L1-missing) buffer = NEAR + 4K .. +68K
N_TLB = 48

def rd(): return random.choice(POOL)
def rs(): return random.choice(POOL + [0])
def s16(): return random.randint(-32768, 32767)

ALU_R = ["addu", "subu", "and", "or", "xor", "nor", "slt", "sltu"]
ALU_I = ["addiu", "andi", "ori", "xori", "slti", "sltiu"]
SHI = ["sll", "srl", "sra"]


class Gen:
    def __init__(self, a):
        self.a, self.L, self.lab = a, [], 0

    def label(self):
        self.lab += 1
        return "L%d" % self.lab

    def e(self, s):
        self.L.append("    " + s)

    def alu_text(self):
        k = random.random()
        if k < 0.45:
            return "%s $%d, $%d, $%d" % (random.choice(ALU_R), rd(), rs(), rs())
        if k < 0.8:
            return "%s $%d, $%d, %d" % (random.choice(ALU_I), rd(), rs(),
                                         s16() if True else 0)
        return "%s $%d, $%d, %d" % (random.choice(SHI), rd(), rs(), random.randint(0, 31))

    def alu(self):
        t = self.alu_text()
        if t.split()[0] in ("andi", "ori", "xori"):          # zero-extended immediates
            op, rest = t.split(" ", 1)
            a, b, imm = rest.split(", ")
            t = "%s %s, %s, %d" % (op, a, b, random.randint(0, 65535))
        self.e(t)

    def mem_near(self, store=None):
        off = random.randint(0, 0xff8) & ~7
        store = random.random() < 0.4 if store is None else store
        if store:
            self.e("%s $%d, %d($%d)" % (random.choice(["sw", "sh", "sb"]), rs(), off, NEAR))
        else:
            self.e("%s $%d, %d($%d)" % (random.choice(["lw", "lhu", "lbu", "lb"]), rd(), off, NEAR))

    def mem_far(self):
        # index = (reg & 0xfff8) -> 64 KB window: misses L1, mostly hits L2
        self.e("andi $%d, $%d, 0xfff8" % (AT, rs()))
        self.e("addu $%d, $%d, $%d" % (AT, AT, NEAR))
        if random.random() < 0.3:
            self.e("sw $%d, %d($%d)" % (rs(), FAR_OFF, AT))
        else:
            self.e("lw $%d, %d($%d)" % (rd(), FAR_OFF, AT))

    def fault_tlb(self):
        # page = reg & (map_pages-1); mapped VA = MAPB + page*4K + small offset
        self.e("andi $%d, $%d, %d" % (AT, rs(), self.a.map_pages - 1))
        self.e("sll $%d, $%d, 12" % (AT, AT))
        self.e("addu $%d, $%d, $%d" % (AT, AT, MAPB))
        off = random.randint(0, 0xff0) & ~7
        if random.random() < 0.3:
            self.e("sw $%d, %d($%d)" % (rs(), off, AT))
        else:
            self.e("lw $%d, %d($%d)" % (rd(), off, AT))

    def fault_ade(self):
        off = (random.randint(0, 0xff0) & ~7) + random.choice([1, 2, 3])
        if random.random() < 0.3:
            self.e("sw $%d, %d($%d)" % (rs(), off, NEAR))
        else:
            self.e("lw $%d, %d($%d)" % (rd(), off, NEAR))

    def branch(self):
        l = self.label()
        op = random.choice(["beq", "bne"]) if random.random() < 0.5 else random.choice(["blez", "bgtz", "bltz", "bgez"])
        if op in ("beq", "bne"):
            self.e("%s $%d, $%d, %s" % (op, rs(), rs(), l))
        else:
            self.e("%s $%d, %s" % (op, rs(), l))
        self.e(self.alu_text_safe())               # delay slot: never faults
        for _ in range(random.randint(0, 3)):      # skipped-or-not body
            self.unit(allow_branch=False)
        self.L.append("%s:" % l)

    def alu_text_safe(self):
        t = self.alu_text()
        op = t.split()[0]
        if op in ("andi", "ori", "xori"):
            a, b, _ = t.split(" ", 1)[1].split(", ")
            return "%s %s, %s, %d" % (op, a, b, random.randint(0, 65535))
        return t

    def unit(self, allow_branch=True):
        a, x = self.a, random.random()
        c = a.p_tlb
        if x < c:
            return self.fault_tlb()
        c += a.p_ade
        if x < c:
            return self.fault_ade()
        c += 0.25
        if x < c:
            return self.mem_near()
        c += 0.12
        if x < c:
            return self.mem_far()
        c += 0.10
        if x < c and allow_branch:
            return self.branch()
        c += 0.03
        if x < c:
            self.e("multu $%d, $%d" % (rs(), rs()))
            self.e("mflo $%d" % rd())
            return
        self.alu()

    def render(self):
        a = self.a
        H = []
        H.append("/* gen_exchammer.py --seed %d --units %d --iters %d --map-pages %d --p-tlb %.3f --p-ade %.3f */"
                 % (a.seed, a.units, a.iters, a.map_pages, a.p_tlb, a.p_ade))
        H += ['#include "sim.h"', "    .set mips3", "    .set noreorder", "    .set noat", ""]
        H += ["    .macro HALT", "    li $26, 0xBFD00000", "    li $27, 1", "    sw $27, 0($26)",
              "1:  b 1b", "    nop", "    .endm", ""]
        H += ["    .section .except_vec, \"ax\"",
              "    .org 0x000                 /* TLB refill: map the faulting page pair */",
              "    mfc0 $26, $8               /* BadVAddr */",
              "    srl  $26, $26, 13",
              "    sll  $26, $26, 13          /* even-page VA of the pair */",
              "    lui  $27, 0x0040",
              "    subu $26, $26, $27         /* offset in the window */",
              "    lui  $27, 0x0020",
              "    addu $26, $26, $27         /* PA = 0x00200000 + offset */",
              "    srl  $26, $26, 12",
              "    sll  $26, $26, 6",
              "    ori  $26, $26, 0x1f        /* C=3 D V G */",
              "    mtc0 $26, $2               /* EntryLo0 */",
              "    addiu $26, $26, 0x40       /* next PFN */",
              "    mtc0 $26, $3               /* EntryLo1 */",
              "    mtc0 $0, $5                /* PageMask 4K */",
              "    mtc0 $%d, $0               /* Index = software round-robin */" % TLBI,
              "    addiu $%d, $%d, 1" % (TLBI, TLBI),
              "    sltiu $27, $%d, %d" % (TLBI, N_TLB),
              "    movz_emul:",
              "    bne  $27, $0, 1f",
              "    nop",
              "    move $%d, $0" % TLBI,
              "1:  tlbwi",
              "    eret",
              "    nop",
              "    .org 0x180                 /* general: skip AdEL/AdES, else fail */",
              "    mfc0 $26, $13",
              "    andi $26, $26, 0x7c",
              "    addiu $26, $26, -(4<<2)",
              "    beq  $26, $0, 2f           /* AdEL */",
              "    addiu $26, $26, -(1<<2)",
              "    beq  $26, $0, 2f           /* AdES */",
              "    nop",
              "    SIMCON_PUTLIT('X')",
              "    SIMCON_PUTLIT('\\n')",
              "    HALT",
              "2:  mfc0 $26, $14",
              "    addiu $26, $26, 4",
              "    mtc0 $26, $14",
              "    eret",
              "    nop", ""]
        H += ["    .section .text.startup, \"ax\"", "    .globl _start", "_start:",
              "    mtc0 $0, $12               /* Status: kernel, EXL=0, BEV=0, 32-bit */",
              "    mtc0 $0, $6                /* Wired = 0 */",
              "    mtc0 $0, $10               /* EntryHi ASID 0 */",
              "    move $%d, $0" % TLBI,
              "    li $%d, 0x80100000" % NEAR,
              "    li $%d, 0x00400000" % MAPB,
              "    li $%d, %d" % (LOOP, a.iters)]
        for r in POOL:
            H.append("    li $%d, %d" % (r, random.randint(-1 << 15, (1 << 15) - 1) * 4))
        H += ["iter:"]
        body = self.L
        H += body
        H += ["    addiu $%d, $%d, -1" % (LOOP, LOOP),
              "    bne $%d, $0, iter" % LOOP,
              "    nop",
              "    SIMCON_PUTLIT('D')", "    SIMCON_PUTLIT('O')", "    SIMCON_PUTLIT('N')",
              "    SIMCON_PUTLIT('E')", "    SIMCON_PUTLIT('\\n')",
              "    HALT"]
        return "\n".join(H).replace("    movz_emul:\n", "") + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--units", type=int, default=400, help="random units in the loop body")
    ap.add_argument("--iters", type=int, default=50, help="loop iterations")
    ap.add_argument("--map-pages", type=int, default=256, help="mapped window pages (power of 2; > 96 to miss the 48-pair TLB)")
    ap.add_argument("--p-tlb", type=float, default=0.06, help="fraction of units that are TLB-faulting mapped accesses")
    ap.add_argument("--p-ade", type=float, default=0.03, help="fraction of units that are misaligned (AdEL/AdES)")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    assert a.map_pages & (a.map_pages - 1) == 0 and a.map_pages <= 4096
    random.seed(a.seed)
    g = Gen(a)
    for _ in range(a.units):
        g.unit()
    open(a.out + ".S", "w").write(g.render())


if __name__ == "__main__":
    main()
