CROSS   := mips-linux-gnu
CC      := $(CROSS)-gcc
LD      := $(CROSS)-ld
OBJDUMP := $(CROSS)-objdump

COMMON  := ../common
SIM     := ../../ooo_core

# MIPS III + the MIPS IV conditional moves and indexed FP loads/stores + FP madd/recip/rsqrt: needs an ooo_core
# built with ENABLE_MIPS4; no branch-likely
ARCH    := -march=mips4 -mabi=32 -mfp32 -EB -mno-branch-likely -mno-madd4 -mlxc1-sxc1 -mmadd4 -ffp-contract=fast
NOABI   := -mno-abicalls -fno-pic -G 0
CFLAGS  := $(ARCH) $(NOABI) -O2 -nostdlib -nostartfiles -ffreestanding -I$(COMMON) -Wall
LDFLAGS := -T $(COMMON)/link.ld -nostdlib -G 0 -static

STARTUP := $(COMMON)/crt0.o

.PHONY: all clean run

all: mips4fp.elf mips4fp.dis

$(STARTUP): $(COMMON)/crt0.S $(COMMON)/sim.h
	$(CC) -march=mips3 -mabi=32 -EB $(NOABI) -nostdlib -I$(COMMON) -c $< -o $@

%.o: %.c $(COMMON)/sim.h
	$(CC) $(CFLAGS) -c $< -o $@

%.o: %.S $(COMMON)/sim.h
	$(CC) $(CFLAGS) -c $< -o $@

mips4fp.elf: mips4fp.o edges.o $(STARTUP) $(COMMON)/link.ld
	$(LD) $(LDFLAGS) $(STARTUP) mips4fp.o edges.o -o $@

mips4fp.dis: mips4fp.elf
	$(OBJDUMP) -d $< > $@

run: mips4fp.elf
	cd ../.. && $(SIM) -f tests/mips4fp/mips4fp.elf -c 1

clean:
	rm -f *.o mips4fp.elf mips4fp.dis
