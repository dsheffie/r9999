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
LDFLAGS := -T henry_arcs.ld -nostdlib -G 0 -static

# Override RAM base/size here if desired, e.g.:
#   make ARCS_DEFS="-DARCS_RAM_SIZE=0x10000000"
ARCS_DEFS ?=

.PHONY: all clean
all: henry_arcs.bin henry_arcs.dis

henry_arcs.o: henry_arcs.S henry_arcs.ld ../tests/common/sim.h
	$(CC) $(ASFLAGS) $(ARCS_DEFS) -x assembler-with-cpp -c henry_arcs.S -o $@

henry_arcs.elf: henry_arcs.o henry_arcs.ld
	$(LD) $(LDFLAGS) henry_arcs.o -o $@

henry_arcs.bin: henry_arcs.elf
	$(OBJCOPY) -O binary $< $@

henry_arcs.dis: henry_arcs.elf
	$(OBJDUMP) -d $< > $@

clean:
	rm -f henry_arcs.o henry_arcs.elf henry_arcs.bin henry_arcs.dis
