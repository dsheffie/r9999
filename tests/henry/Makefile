# Makefile -- Henry-SoC bare-metal tests booted via the henry_arcs FSBL.
#
# Build:  make
# Deploy: scp hello.elf root@fpga.local:~/mips/
# Run on board:
#   mips-axi -f hello.elf --sgi true --arcs henry_arcs.bin --start-pc 0xbfc00000
# (the FSBL bring-up runs, then jumps to the test's e_entry; output is the
#  CP0-$7 console drained by the driver.)

CROSS   := mips-linux-gnu-
CC      := $(CROSS)gcc
LD      := $(CROSS)ld
OBJCOPY := $(CROSS)objcopy

ARCH    := -march=mips3 -mabi=32 -EB
CFLAGS  := $(ARCH) -mno-abicalls -fno-pic -G 0 -O2 -ffreestanding -nostdlib \
           -nostartfiles -fno-builtin -Wall -Wextra
LDFLAGS := -T henry.ld -nostdlib -G 0 -static

CRT0    := henry_crt0.o

TESTS   := hello.elf contest.elf fp_capacity.elf

all: $(TESTS)

henry_crt0.o: henry_crt0.S
	$(CC) $(CFLAGS) -x assembler-with-cpp -c $< -o $@

%.o: %.c henry_io.h
	$(CC) $(CFLAGS) -c $< -o $@

irqvec.o: irqvec.S
	$(CC) $(CFLAGS) -x assembler-with-cpp -c $< -o $@

# contest links the IP2 handler at 0x80000180 via henry_irq.ld
contest.elf: contest.o irqvec.o $(CRT0) henry_irq.ld
	$(LD) -T henry_irq.ld -nostdlib -G 0 -static $(CRT0) contest.o irqvec.o -o $@
	$(CROSS)objdump -d $@ > contest.dis

%.elf: %.o $(CRT0) henry.ld
	$(LD) $(LDFLAGS) $(CRT0) $< -o $@
	$(CROSS)objdump -d $@ > $(@:.elf=.dis)

clean:
	rm -f *.o *.elf *.dis

.PHONY: all clean
