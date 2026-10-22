# Makefile -- build the Henry SoC's synthetic ARCS/FSBL firmware blob.
#
# Produces henry_arcs.bin: an FSBL @ kseg1 0xBFC00000 (the CPU reset vector) that
# copies the SPB/romvec to RAM @ 0xA0001000 and jumps to the kernel.  ONE blob
# boots BOTH IP22 Linux (-> /init) and IRIX 6.5 (-> banner); the driver/TB patches
# the kernel-entry slot @0xBFC00008 per kernel.  See henry_arcs.S / henry_arcs.ld.
# Run via the boot scripts with --start-pc 0xbfc00000.

CROSS   := mips-linux-gnu
CC      := $(CROSS)-gcc
LD      := $(CROSS)-ld
OBJCOPY := $(CROSS)-objcopy
OBJDUMP := $(CROSS)-objdump

# 32-bit ARC ABI, MIPS-III, big-endian, freestanding.
ASFLAGS := -march=mips3 -mabi=32 -EB -mno-abicalls -fno-pic -G 0 \
           -nostdlib -ffreestanding -I../tests/common
# C is compiled the same way; the FSBL sets up a stack before calling into it.
CFLAGS  := -march=mips3 -mabi=32 -EB -mno-abicalls -fno-pic -G 0 \
           -nostdlib -ffreestanding -O2 -Wall -I../tests/common
LDFLAGS := -T henry_arcs.ld -nostdlib -G 0 -static

# Override RAM base/size here if desired, e.g.:
#   make ARCS_DEFS="-DARCS_RAM_SIZE=0x10000000"
ARCS_DEFS ?=

.PHONY: all clean verify analyze
all: henry_arcs.bin henry_arcs.dis

# Static analysis (GCC -fanalyzer) + bounded model checking (CBMC) of the C firmware.
# Memory safety / overflow / conversion of the loops, table indexing, and the ARCS
# stubs' handling of kernel-controlled inputs.  (Hardware MMIO effects and the FIFO
# busy-wait's termination are outside a pure-software model's scope.)
CBMC      ?= cbmc
CBMCFLAGS := -I../tests/common --bounds-check --conversion-check \
             --unsigned-overflow-check --signed-overflow-check --div-by-zero-check
analyze:
	$(CC) $(CFLAGS) $(ARCS_DEFS) -Wextra -Wconversion -Wshadow -fanalyzer -c henry_fw.c      -o /dev/null
	$(CC) $(CFLAGS) $(ARCS_DEFS) -Wextra -Wconversion -Wshadow -fanalyzer -c henry_newport.c -o /dev/null
verify: analyze
	$(CBMC) henry_newport.c --function newport_init $(CBMCFLAGS) --unwind 1100 --unwinding-assertions
	$(CBMC) henry_fw.c cbmc_harness.c --function harness_getenv $(CBMCFLAGS) --unwind 12 --unwinding-assertions
	$(CBMC) henry_fw.c cbmc_harness.c --function harness_write  $(CBMCFLAGS) --unwind 12

henry_arcs.o: henry_arcs.S henry_arcs.ld ../tests/common/sim.h
	$(CC) $(ASFLAGS) $(ARCS_DEFS) -x assembler-with-cpp -c henry_arcs.S -o $@

henry_fw.o: henry_fw.c ../tests/common/sim.h
	$(CC) $(CFLAGS) $(ARCS_DEFS) -c henry_fw.c -o $@

henry_newport.o: henry_newport.c ../tests/common/sim.h
	$(CC) $(CFLAGS) $(ARCS_DEFS) -c henry_newport.c -o $@

henry_arcs.elf: henry_arcs.o henry_fw.o henry_newport.o henry_arcs.ld
	$(LD) $(LDFLAGS) henry_arcs.o henry_fw.o henry_newport.o -o $@

henry_arcs.bin: henry_arcs.elf
	$(OBJCOPY) -O binary $< $@

henry_arcs.dis: henry_arcs.elf
	$(OBJDUMP) -d $< > $@

clean:
	rm -f henry_arcs.o henry_fw.o henry_newport.o henry_arcs.elf henry_arcs.bin henry_arcs.dis
