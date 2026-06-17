# Makefile for R4000 bare-metal test programs
# Target: big-endian MIPS-III ELF32 for the r9999 simulator

CROSS   := mips-linux-gnu
CC      := $(CROSS)-gcc
AS      := $(CROSS)-as
LD      := $(CROSS)-ld
OBJDUMP := $(CROSS)-objdump
OBJCOPY := $(CROSS)-objcopy

COMMON  := common
SIM     := ../ooo_core

# Flags common to C and assembly
ARCH    := -march=mips3 -mabi=32 -EB
NOABI   := -mno-abicalls -fno-pic -G 0

CFLAGS  := $(ARCH) $(NOABI) -O1 -nostdlib -nostartfiles -I$(COMMON) \
           -Wall -Wno-unused-function
ASFLAGS := $(ARCH) $(NOABI) -I$(COMMON)
LDFLAGS := -T $(COMMON)/link.ld -nostdlib -G 0 -static

STARTUP := $(COMMON)/crt0.o

# All test binaries
TESTS := hello/hello.elf \
         cp0/test_cp0.elf \
         tlb/test_tlb.elf \
         dside_tlb/test_dside_tlb.elf \
         except/test_except.elf \
         except/test_overflow.elf \
         except/test_traps.elf \
         atomic/test_atomic.elf \
         unaligned/test_unaligned.elf \
         xtlb/test_xtlb64.elf \
         xtlb/test_xtlb32.elf \
         xtlb/test_xtlb_nested.elf \
         xtlb/test_eret.elf \
         xtlb/test_cache.elf \
         xtlb/test_prid.elf \
         cache/test_smc_hit.elf \
         cache/test_smc_index.elf \
         cache/test_inval_nowb.elf \
         cache/test_cache_priv.elf \
         cache/test_flush_full.elf \
         cache/test_flush_l2_full.elf \
         cache/test_l2_evict.elf \
         cache/test_uc_wb_alias.elf \
         devregs/test_devregs.elf \
         addr64/test_badvaddr.elf

DISASMS := $(TESTS:.elf=.dis)

.PHONY: all clean run-hello run-cp0 run-tlb run-dside-tlb run-except run-unaligned run-xtlb run-cache run-overflow run-traps run-atomic run-fpu

all: $(STARTUP) $(TESTS) $(DISASMS)

$(COMMON)/crt0.o: $(COMMON)/crt0.S $(COMMON)/sim.h
	$(CC) $(CFLAGS) -c $< -o $@

# -----------------------------------------------------------------------
# hello world
# -----------------------------------------------------------------------
hello/hello.elf: hello/hello.c $(STARTUP) $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -c hello/hello.c -o hello/hello.o
	$(LD) $(LDFLAGS) $(STARTUP) hello/hello.o -o $@

# -----------------------------------------------------------------------
# IRIX-boot device-register check (run via the Henry SoC harness for the
# RTL device models: henry_tb --kernel devregs/test_devregs.elf)
# -----------------------------------------------------------------------
devregs/test_devregs.elf: devregs/test_devregs.c $(STARTUP) $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -c devregs/test_devregs.c -o devregs/test_devregs.o
	$(LD) $(LDFLAGS) $(STARTUP) devregs/test_devregs.o -o $@

# -----------------------------------------------------------------------
# BadVAddr-on-64-bit-store regression (self-contained, own vectors, no crt0).
# Reproduces the IRIX-boot blocker: sdl/sd/sdr to a 64-bit kseg2 address must
# report BadVAddr = the store EA.  Run on the RTL via henry_tb, or co-sim:
#   ooo_core --file addr64/test_badvaddr.elf -c 1
# -----------------------------------------------------------------------
addr64/test_badvaddr.elf: addr64/test_badvaddr.S $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c addr64/test_badvaddr.S -o addr64/test_badvaddr.o
	$(LD) $(LDFLAGS) addr64/test_badvaddr.o -o $@

# -----------------------------------------------------------------------
# CP0 register access test
# -----------------------------------------------------------------------
cp0/test_cp0.elf: cp0/test_cp0.S $(STARTUP) $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c cp0/test_cp0.S -o cp0/test_cp0.o
	$(LD) $(LDFLAGS) $(STARTUP) cp0/test_cp0.o -o $@

# -----------------------------------------------------------------------
# TLB instruction test (TLBWI / TLBR / TLBP)
# -----------------------------------------------------------------------
tlb/test_tlb.elf: tlb/test_tlb.S $(STARTUP) $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c tlb/test_tlb.S -o tlb/test_tlb.o
	$(LD) $(LDFLAGS) $(STARTUP) tlb/test_tlb.o -o $@

# -----------------------------------------------------------------------
# Exception / ERET test (self-contained: own vectors, no crt0)
# -----------------------------------------------------------------------
except/test_except.elf: except/test_except.S $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c except/test_except.S -o except/test_except.o
	$(LD) $(LDFLAGS) except/test_except.o -o $@

except/test_overflow.elf: except/test_overflow.S $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c except/test_overflow.S -o except/test_overflow.o
	$(LD) $(LDFLAGS) except/test_overflow.o -o $@

atomic/test_atomic.elf: atomic/test_atomic.S $(STARTUP) $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c atomic/test_atomic.S -o atomic/test_atomic.o
	$(LD) $(LDFLAGS) $(STARTUP) atomic/test_atomic.o -o $@

atomic/test_ll_intervening.elf: atomic/test_ll_intervening.S $(STARTUP) $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c atomic/test_ll_intervening.S -o atomic/test_ll_intervening.o
	$(LD) $(LDFLAGS) $(STARTUP) atomic/test_ll_intervening.o -o $@

except/test_traps.elf: except/test_traps.S $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c except/test_traps.S -o except/test_traps.o
	$(LD) $(LDFLAGS) except/test_traps.o -o $@

# -----------------------------------------------------------------------
# Unaligned load test (lwl / lwr)
# -----------------------------------------------------------------------
unaligned/test_unaligned.elf: unaligned/test_unaligned.c $(STARTUP) $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -c unaligned/test_unaligned.c -o unaligned/test_unaligned.o
	$(LD) $(LDFLAGS) $(STARTUP) unaligned/test_unaligned.o -o $@

# -----------------------------------------------------------------------
# TLB-refill vs XTLB-refill vector test (self-contained: no crt0, own vectors)
#   64-bit variant faults in 64-bit mode -> must take the XTLB vector (0x080)
#   32-bit variant faults in 32-bit mode -> must take the TLB  vector (0x000)
# -----------------------------------------------------------------------
xtlb/test_xtlb64.elf: xtlb/test_xtlb.S $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -DMODE64 -x assembler-with-cpp -c xtlb/test_xtlb.S -o xtlb/test_xtlb64.o
	$(LD) $(LDFLAGS) xtlb/test_xtlb64.o -o $@

xtlb/test_xtlb32.elf: xtlb/test_xtlb.S $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c xtlb/test_xtlb.S -o xtlb/test_xtlb32.o
	$(LD) $(LDFLAGS) xtlb/test_xtlb32.o -o $@

# Nested refill: EXL already set -> must fall through to the general vector.
xtlb/test_xtlb_nested.elf: xtlb/test_xtlb.S $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -DMODE_NESTED -x assembler-with-cpp -c xtlb/test_xtlb.S -o xtlb/test_xtlb_nested.o
	$(LD) $(LDFLAGS) xtlb/test_xtlb_nested.o -o $@

# EXL-based exception/ERET round trip (exception sets EXL; ERET clears it).
xtlb/test_eret.elf: xtlb/test_eret.S $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c xtlb/test_eret.S -o xtlb/test_eret.o
	$(LD) $(LDFLAGS) xtlb/test_eret.o -o $@

# CACHE instruction decoded as NOP (must not trap).
xtlb/test_cache.elf: xtlb/test_cache.S $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c xtlb/test_cache.S -o xtlb/test_cache.o
	$(LD) $(LDFLAGS) xtlb/test_cache.o -o $@

# PRId reads the R4000-family value and is read-only.
xtlb/test_prid.elf: xtlb/test_prid.S $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c xtlb/test_prid.S -o xtlb/test_prid.o
	$(LD) $(LDFLAGS) xtlb/test_prid.o -o $@

# -----------------------------------------------------------------------
# CACHE instruction coherence tests (tests/cache/)
#   smc_*  : self-modifying-code coherence -- co-sim safe (interp is coherent)
#   inval_nowb : D-Hit-Invalidate no-writeback -- RTL self-check ONLY (-c 0)
# -----------------------------------------------------------------------
cache/test_smc_hit.elf: cache/test_smc_hit.S $(STARTUP) $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c cache/test_smc_hit.S -o cache/test_smc_hit.o
	$(LD) $(LDFLAGS) $(STARTUP) cache/test_smc_hit.o -o $@

cache/test_smc_index.elf: cache/test_smc_index.S $(STARTUP) $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c cache/test_smc_index.S -o cache/test_smc_index.o
	$(LD) $(LDFLAGS) $(STARTUP) cache/test_smc_index.o -o $@

cache/test_inval_nowb.elf: cache/test_inval_nowb.S $(STARTUP) $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c cache/test_inval_nowb.S -o cache/test_inval_nowb.o
	$(LD) $(LDFLAGS) $(STARTUP) cache/test_inval_nowb.o -o $@

# user-mode CACHE -> CpU. Self-contained (own vectors, no crt0), RTL-only.
cache/test_cache_priv.elf: cache/test_cache_priv.S $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c cache/test_cache_priv.S -o cache/test_cache_priv.o
	$(LD) $(LDFLAGS) cache/test_cache_priv.o -o $@

cache/test_flush_full.elf: cache/test_flush_full.S $(STARTUP) $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c cache/test_flush_full.S -o cache/test_flush_full.o
	$(LD) $(LDFLAGS) $(STARTUP) cache/test_flush_full.o -o $@

cache/test_flush_l2_full.elf: cache/test_flush_l2_full.S $(STARTUP) $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c cache/test_flush_l2_full.S -o cache/test_flush_l2_full.o
	$(LD) $(LDFLAGS) $(STARTUP) cache/test_flush_l2_full.o -o $@

cache/test_l2_evict.elf: cache/test_l2_evict.S $(STARTUP) $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c cache/test_l2_evict.S -o cache/test_l2_evict.o
	$(LD) $(LDFLAGS) $(STARTUP) cache/test_l2_evict.o -o $@

cache/test_uc_wb_alias.elf: cache/test_uc_wb_alias.S $(STARTUP) $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c cache/test_uc_wb_alias.S -o cache/test_uc_wb_alias.o
	$(LD) $(LDFLAGS) $(STARTUP) cache/test_uc_wb_alias.o -o $@

# Code-coherence tests run under the co-sim checker (RTL must match the
# coherent interpreter). inval_nowb is RTL-only (-c 0): the coherent interp
# cannot model dirty-discard, so it is NOT checker-compatible.
# NB: the binary lives at ../ooo_core relative to this dir; after `cd ..` it is
# ./ooo_core (the pre-existing run-* targets above use ../ooo_core post-cd and
# are broken -- run the sim from r9999/ by hand or via this target).
run-cache: cache/test_smc_hit.elf cache/test_smc_index.elf cache/test_inval_nowb.elf
	@echo "== SMC Hit-form (expect PASS; red = 'does not match') =="
	cd .. && ./ooo_core --file tests/cache/test_smc_hit.elf --checker true 2>&1 | grep -iE "PASS|FAIL|does not match"
	@echo "== SMC Index-form (expect PASS; red = 'does not match') =="
	cd .. && ./ooo_core --file tests/cache/test_smc_index.elf --checker true 2>&1 | grep -iE "PASS|FAIL|does not match"
	@echo "== D-Hit-Inval no-WB, RTL-only (expect PASS) =="
	cd .. && ./ooo_core --file tests/cache/test_inval_nowb.elf -c 0 2>&1 | grep -iE "PASS|FAIL|does not match"
	@echo "== user-mode CACHE -> CpU, RTL-only (expect PASS) =="
	cd .. && ./ooo_core --file tests/cache/test_cache_priv.elf -c 0 2>&1 | grep -iE "PASS|FAIL|does not match"

# -----------------------------------------------------------------------
# FP (COP1) directed tests — run under the co-sim checker (RTL must match
# the interpreter).  Each prints 'P' on the functional self-check; a co-sim
# divergence prints 'does not match'.
# -----------------------------------------------------------------------
fpu/%.elf: fpu/%.S $(STARTUP) $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c fpu/$*.S -o fpu/$*.o
	$(LD) $(LDFLAGS) $(STARTUP) fpu/$*.o -o $@

run-fpu: fpu/fp_move.elf fpu/fp_load.elf fpu/fp_store.elf fpu/fp_sext.elf fpu/fp_cfc1.elf fpu/fp_dmove.elf fpu/fp_dldst.elf
	@for t in fp_move fp_load fp_store fp_sext fp_cfc1 fp_dmove fp_dldst; do \
	  echo "== fpu/$$t (co-sim; expect 'P' and no 'does not match') =="; \
	  ( cd .. && ./ooo_core --file tests/fpu/$$t.elf --checker true 2>&1 \
	      | grep -iE "does not match|FAIL" ) || echo "  ok (no divergence)"; \
	done

# -----------------------------------------------------------------------
# Generic disassembly rule
# -----------------------------------------------------------------------
%.dis: %.elf
	$(OBJDUMP) -d $< > $@

# -----------------------------------------------------------------------
# Run targets (require ooo_core to be built in parent dir)
# -----------------------------------------------------------------------
run-hello: hello/hello.elf
	cd .. && $(SIM) --file tests/$< --checker true 2>&1

run-cp0: cp0/test_cp0.elf
	cd .. && $(SIM) --file tests/$< --checker true 2>&1

run-tlb: tlb/test_tlb.elf
	cd .. && $(SIM) --file tests/$< -c 0 2>&1

# -----------------------------------------------------------------------
# D-side TLB translation test
# -----------------------------------------------------------------------
dside_tlb/test_dside_tlb.elf: dside_tlb/test_dside_tlb.S $(STARTUP) $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c dside_tlb/test_dside_tlb.S -o dside_tlb/test_dside_tlb.o
	$(LD) $(LDFLAGS) $(STARTUP) dside_tlb/test_dside_tlb.o -o $@

run-dside-tlb: dside_tlb/test_dside_tlb.elf
	cd .. && $(SIM) --file tests/$< --checker true 2>&1

run-except: except/test_except.elf
	cd .. && $(SIM) --file tests/$< -c 0 2>&1

run-overflow: except/test_overflow.elf
	@echo "== add/addi/sub signed overflow, self-check (expect P) =="
	cd .. && $(SIM) --file tests/except/test_overflow.elf -c 0 2>&1 | grep -aoE '[PF]' | head -1
	@echo "== same under co-sim (expect no 'does not match') =="
	cd .. && $(SIM) --file tests/except/test_overflow.elf --checker true 2>&1 | grep -i 'does not match' || echo "  ok (no divergence)"

run-traps: except/test_traps.elf
	@echo "== traps + branch-and-link, self-check (expect P) =="
	cd .. && $(SIM) --file tests/except/test_traps.elf -c 0 2>&1 | grep -aoE '[PF]' | head -1
	@echo "== same under co-sim (expect no 'does not match') =="
	cd .. && $(SIM) --file tests/except/test_traps.elf --checker true 2>&1 | grep -i 'does not match' || echo "  ok (no divergence)"

run-atomic: atomic/test_atomic.elf
	@echo "== LL/SC + LLD/SCD round-trip, self-check (expect P) =="
	cd .. && $(SIM) --file tests/atomic/test_atomic.elf -c 0 2>&1 | grep -aoE '[PF]' | head -1
	@echo "== same under co-sim (expect no 'does not match') =="
	cd .. && $(SIM) --file tests/atomic/test_atomic.elf --checker true 2>&1 | grep -i 'does not match' || echo "  ok (no divergence)"

run-atomic-intervening: atomic/test_ll_intervening.elf
	@echo "== LL/SC intervening load/store breaks the link (expect P) =="
	cd .. && $(SIM) --file tests/atomic/test_ll_intervening.elf -c 0 2>&1 | grep -aoE '[PF]' | head -1
	@echo "== same under co-sim (expect no 'does not match') =="
	cd .. && $(SIM) --file tests/atomic/test_ll_intervening.elf --checker true 2>&1 | grep -i 'does not match' || echo "  ok (no divergence)"

run-unaligned: unaligned/test_unaligned.elf
	cd .. && $(SIM) --file tests/$< --checker true 2>&1

run-xtlb: xtlb/test_xtlb64.elf xtlb/test_xtlb32.elf xtlb/test_xtlb_nested.elf
	@echo "== 64-bit refill (expect VEC=XTLB) =="
	cd .. && $(SIM) --file tests/xtlb/test_xtlb64.elf -c 0 2>&1 | grep -E "VEC=|NO"
	@echo "== 32-bit refill (expect VEC=TLB) =="
	cd .. && $(SIM) --file tests/xtlb/test_xtlb32.elf -c 0 2>&1 | grep -E "VEC=|NO"
	@echo "== nested refill, EXL=1 (expect VEC=GEN) =="
	cd .. && $(SIM) --file tests/xtlb/test_xtlb_nested.elf -c 0 2>&1 | grep -E "VEC=|NO"
	@echo "== exception/ERET round trip (expect H1 R0) =="
	cd .. && $(SIM) --file tests/xtlb/test_eret.elf -c 0 2>&1 | grep -E "H|R"
	@echo "== CACHE decoded as NOP (expect CACHE-OK) =="
	cd .. && $(SIM) --file tests/xtlb/test_cache.elf -c 0 2>&1 | grep -E "CACHE"
	@echo "== PRId read-only R4000 value (expect PRID-OK) =="
	cd .. && $(SIM) --file tests/xtlb/test_prid.elf -c 0 2>&1 | grep -E "PRID"

run-all: run-hello run-cp0 run-tlb run-dside-tlb run-except run-unaligned

clean:
	rm -f $(COMMON)/crt0.o \
	      hello/hello.o hello/hello.elf hello/hello.dis \
	      cp0/test_cp0.o cp0/test_cp0.elf cp0/test_cp0.dis \
	      tlb/test_tlb.o tlb/test_tlb.elf tlb/test_tlb.dis \
	      dside_tlb/test_dside_tlb.o dside_tlb/test_dside_tlb.elf dside_tlb/test_dside_tlb.dis \
	      except/test_except.o except/test_except.elf except/test_except.dis \
	      unaligned/test_unaligned.o unaligned/test_unaligned.elf unaligned/test_unaligned.dis

atomic/test_ll_tight.elf: atomic/test_ll_tight.S $(STARTUP) $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c atomic/test_ll_tight.S -o atomic/test_ll_tight.o
	$(LD) $(LDFLAGS) $(STARTUP) atomic/test_ll_tight.o -o $@

atomic/test_ll_chain.elf: atomic/test_ll_chain.S $(STARTUP) $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c atomic/test_ll_chain.S -o atomic/test_ll_chain.o
	$(LD) $(LDFLAGS) $(STARTUP) atomic/test_ll_chain.o -o $@

atomic/test_ll_fwd.elf: atomic/test_ll_fwd.S $(STARTUP) $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c atomic/test_ll_fwd.S -o atomic/test_ll_fwd.o
	$(LD) $(LDFLAGS) $(STARTUP) atomic/test_ll_fwd.o -o $@

except/test_nested_epc.elf: except/test_nested_epc.S $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c except/test_nested_epc.S -o except/test_nested_epc.o
	$(LD) $(LDFLAGS) except/test_nested_epc.o -o $@
