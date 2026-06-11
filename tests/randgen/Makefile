CROSS   := mips-linux-gnu
CC      := $(CROSS)-gcc
LD      := $(CROSS)-ld
OBJDUMP := $(CROSS)-objdump
COMMON  := ../common
ARCH    := -march=mips3 -mabi=32 -EB
NOABI   := -mno-abicalls -fno-pic -G 0
CFLAGS  := $(ARCH) $(NOABI) -O1 -nostdlib -nostartfiles -I$(COMMON) -Wall
LDFLAGS := -T $(COMMON)/link.ld -nostdlib -G 0 -static
STARTUP := $(COMMON)/crt0.o

.PRECIOUS: %.o %.elf
.SECONDARY:

$(STARTUP): $(COMMON)/crt0.S $(COMMON)/sim.h
	$(CC) $(CFLAGS) -c $< -o $@

%.o: %.S $(COMMON)/sim.h
	$(CC) $(CFLAGS) -c $< -o $@

%.elf: %.o $(STARTUP) $(COMMON)/link.ld
	$(LD) $(LDFLAGS) $(STARTUP) $*.o -o $@

%.mips: %.elf            # a .mips file is just the ELF (FPGA loader reads ELF)
	cp $< $@

%.dis: %.elf
	$(OBJDUMP) -d $< > $@

clean:
	rm -f *.o *.elf *.mips *.dis
