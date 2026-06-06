CROSS   := mips-linux-gnu
CC      := $(CROSS)-gcc
LD      := $(CROSS)-ld
OBJDUMP := $(CROSS)-objdump

COMMON  := ../common
SIM     := ../../ooo_core

ARCH    := -march=mips3 -mabi=32 -EB
NOABI   := -mno-abicalls -fno-pic -G 0
CFLAGS  := $(ARCH) $(NOABI) -O1 -nostdlib -nostartfiles -I$(COMMON) -Wall
LDFLAGS := -T $(COMMON)/link.ld -nostdlib -G 0 -static

STARTUP := $(COMMON)/crt0.o

.PHONY: all clean run

all: hello.elf hello.dis

$(STARTUP): $(COMMON)/crt0.S $(COMMON)/sim.h
	$(CC) $(CFLAGS) -c $< -o $@

hello.o: hello.c $(COMMON)/sim.h
	$(CC) $(CFLAGS) -c $< -o $@

hello.elf: hello.o $(STARTUP) $(COMMON)/link.ld
	$(LD) $(LDFLAGS) $(STARTUP) hello.o -o $@

hello.dis: hello.elf
	$(OBJDUMP) -d $< > $@

run: hello.elf
	cd ../.. && $(SIM) -f tests/hello/hello.elf -c 0

clean:
	rm -f hello.o hello.elf hello.dis
