# Makefile -- build the synthetic ARCS firmware blob for the r9999 simulator.
#
# Produces arcs_fw.bin: a flat image (SPB + romvec + stubs + data) linked at
# kseg1 0xA0001000, loaded by the simulator at physical 0x1000.  See arcs_fw.S.

CROSS   := mips-linux-gnu
CC      := $(CROSS)-gcc
LD      := $(CROSS)-ld
OBJCOPY := $(CROSS)-objcopy
OBJDUMP := $(CROSS)-objdump

# 32-bit ARC ABI, MIPS-III, big-endian, freestanding.
ASFLAGS := -march=mips3 -mabi=32 -EB -mno-abicalls -fno-pic -G 0 \
           -nostdlib -ffreestanding -I../tests/common
LDFLAGS := -T arcs.ld -nostdlib -G 0 -static

# Override RAM base/size here if desired, e.g.:
#   make ARCS_DEFS="-DARCS_RAM_SIZE=0x10000000"
ARCS_DEFS ?=

.PHONY: all clean
all: arcs_fw.bin arcs_fw.dis arcs_irix.bin arcs_irix.dis arcs_linux.bin arcs_linux.dis

arcs_fw.o: arcs_fw.S arcs.ld ../tests/common/sim.h
	$(CC) $(ASFLAGS) $(ARCS_DEFS) -x assembler-with-cpp -c arcs_fw.S -o $@

arcs_fw.elf: arcs_fw.o arcs.ld
	$(LD) $(LDFLAGS) arcs_fw.o -o $@

arcs_fw.bin: arcs_fw.elf
	$(OBJCOPY) -O binary $< $@

arcs_fw.dis: arcs_fw.elf
	$(OBJDUMP) -d $< > $@

arcs_irix.o: arcs_irix.S arcs.ld ../tests/common/sim.h
	$(CC) $(ASFLAGS) $(ARCS_DEFS) -x assembler-with-cpp -c arcs_irix.S -o $@

arcs_irix.elf: arcs_irix.o arcs.ld
	$(LD) $(LDFLAGS) arcs_irix.o -o $@

arcs_irix.bin: arcs_irix.elf
	$(OBJCOPY) -O binary $< $@

arcs_irix.dis: arcs_irix.elf
	$(OBJDUMP) -d $< > $@

clean:
	rm -f arcs_fw.o arcs_fw.elf arcs_fw.bin arcs_fw.dis \
	      arcs_irix.o arcs_irix.elf arcs_irix.bin arcs_irix.dis \
	      arcs_linux.o arcs_linux.elf arcs_linux.bin arcs_linux.dis

arcs_linux.o: arcs_linux.S arcs_linux.ld ../tests/common/sim.h
	$(CC) $(ASFLAGS) $(ARCS_DEFS) -x assembler-with-cpp -c arcs_linux.S -o $@

arcs_linux.elf: arcs_linux.o arcs_linux.ld
	$(LD) -T arcs_linux.ld -nostdlib -G 0 -static arcs_linux.o -o $@

arcs_linux.bin: arcs_linux.elf
	$(OBJCOPY) -O binary $< $@

arcs_linux.dis: arcs_linux.elf
	$(OBJDUMP) -d $< > $@
