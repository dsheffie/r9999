CROSS   := mips-linux-gnu
CC      := $(CROSS)-gcc
LD      := $(CROSS)-ld
OBJDUMP := $(CROSS)-objdump

COMMON  := ../common
SIM     := ../../ooo_core

# MIPS III + the MIPS IV conditional moves and indexed FP loads/stores: needs an ooo_core
# built with ENABLE_MIPS4; no madd.fmt/branch-likely
ARCH    := -march=mips4 -mabi=32 -mfp32 -EB -mno-branch-likely -mno-madd4 -mlxc1-sxc1
NOABI   := -mno-abicalls -fno-pic -G 0
CFLAGS  := $(ARCH) $(NOABI) -O2 -nostdlib -nostartfiles -ffreestanding -I$(COMMON) -Wall
LDFLAGS := -T $(COMMON)/link.ld -nostdlib -G 0 -static

STARTUP := $(COMMON)/crt0.o

.PHONY: all clean run

all: idxfp.elf idxfp.dis

$(STARTUP): $(COMMON)/crt0.S $(COMMON)/sim.h
	$(CC) -march=mips3 -mabi=32 -EB $(NOABI) -nostdlib -I$(COMMON) -c $< -o $@

%.o: %.c $(COMMON)/sim.h
	$(CC) $(CFLAGS) -c $< -o $@

%.o: %.S $(COMMON)/sim.h
	$(CC) $(CFLAGS) -c $< -o $@

idxfp.elf: idxfp.o edges.o $(STARTUP) $(COMMON)/link.ld
	$(LD) $(LDFLAGS) $(STARTUP) idxfp.o edges.o -o $@

idxfp.dis: idxfp.elf
	$(OBJDUMP) -d $< > $@

run: idxfp.elf
	cd ../.. && $(SIM) -f tests/idxfp/idxfp.elf -c 1

clean:
	rm -f *.o idxfp.elf idxfp.dis
