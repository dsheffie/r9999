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
         unaligned/test_unaligned.elf \
         xtlb/test_xtlb64.elf \
         xtlb/test_xtlb32.elf \
         xtlb/test_xtlb_nested.elf \
         xtlb/test_eret.elf

DISASMS := $(TESTS:.elf=.dis)

.PHONY: all clean run-hello run-cp0 run-tlb run-dside-tlb run-except run-unaligned run-xtlb

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
# Exception / ERET test
# -----------------------------------------------------------------------
except/test_except.elf: except/test_except.S $(STARTUP) $(COMMON)/sim.h $(COMMON)/link.ld
	$(CC) $(CFLAGS) -x assembler-with-cpp -c except/test_except.S -o except/test_except.o
	$(LD) $(LDFLAGS) $(STARTUP) except/test_except.o -o $@

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
	cd .. && $(SIM) --file tests/$< --checker true 2>&1

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

run-all: run-hello run-cp0 run-tlb run-dside-tlb run-except run-unaligned

clean:
	rm -f $(COMMON)/crt0.o \
	      hello/hello.o hello/hello.elf hello/hello.dis \
	      cp0/test_cp0.o cp0/test_cp0.elf cp0/test_cp0.dis \
	      tlb/test_tlb.o tlb/test_tlb.elf tlb/test_tlb.dis \
	      dside_tlb/test_dside_tlb.o dside_tlb/test_dside_tlb.elf dside_tlb/test_dside_tlb.dis \
	      except/test_except.o except/test_except.elf except/test_except.dis \
	      unaligned/test_unaligned.o unaligned/test_unaligned.elf unaligned/test_unaligned.dis
