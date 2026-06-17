# Bare-metal R4000 mode-hazard / delay-slot TDD tests (kseg0).
# build: make ; run on sim: ../../ooo_core -f <name>.elf  (markers via mtc0 $7)
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
TESTS   := test64 test64b test64c test64d dslot_j dslot_bne wirepda_pfn wirepda_xlate
all: $(addsuffix .elf,$(TESTS))
$(STARTUP): $(COMMON)/crt0.S $(COMMON)/sim.h
	$(CC) $(CFLAGS) -c $< -o $@
%.o: %.S $(COMMON)/sim.h
	$(CC) $(CFLAGS) -c $< -o $@
%.elf: %.o $(STARTUP) $(COMMON)/link.ld
	$(LD) $(LDFLAGS) $(STARTUP) $< -o $@
clean:
	rm -f *.o *.elf *.dis
