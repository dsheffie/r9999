CROSS   := mips-linux-gnu
CC      := $(CROSS)-gcc
LD      := $(CROSS)-ld
OBJDUMP := $(CROSS)-objdump

COMMON  := ../common
R       := ../..

# full MIPS IV (madd4, indexed FP) -- the RTL does NOT implement all of it, so
# this runs on the interpreter alone (iss_mips4), not on ooo_core
ARCH    := -march=mips4 -mabi=32 -mfp32 -EB -ffp-contract=off -fno-math-errno
NOABI   := -mno-abicalls -fno-pic -G 0
CFLAGS  := $(ARCH) $(NOABI) -O2 -nostdlib -nostartfiles -ffreestanding -I$(COMMON) -Wall
LDFLAGS := -T $(COMMON)/link.ld -nostdlib -G 0 -static

ISS_SRC := iss_main.cc $(R)/interpret.cc $(R)/loadelf.cc $(R)/sparse_mem.cc $(R)/helper.cc $(R)/disassemble.cc

.PHONY: all clean run

all: iss_mips4 mips4.elf mips4.dis

iss_mips4: $(ISS_SRC) $(R)/interpret.hh
	g++ -std=c++14 -O2 -DISS_FULL_MIPS4 -I$(R) $(ISS_SRC) -o $@ -lcapstone

$(COMMON)/crt0.o: $(COMMON)/crt0.S $(COMMON)/sim.h
	$(CC) -march=mips3 -mabi=32 -EB $(NOABI) -nostdlib -I$(COMMON) -c $< -o $@

mips4.o: mips4.c $(COMMON)/sim.h
	$(CC) $(CFLAGS) -c $< -o $@

mips4.elf: mips4.o $(COMMON)/crt0.o $(COMMON)/link.ld
	$(LD) $(LDFLAGS) $(COMMON)/crt0.o mips4.o -o $@

mips4.dis: mips4.elf
	$(OBJDUMP) -d $< > $@

run: iss_mips4 mips4.elf
	./iss_mips4 mips4.elf

clean:
	rm -f *.o mips4.elf mips4.dis iss_mips4
