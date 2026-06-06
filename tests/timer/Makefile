REPO   := ../..
HELLO  := $(REPO)/hello
SIM    := $(REPO)/ooo_core
CSMITH := ../csmith

CC  := mips-linux-gnu-gcc
BM_FLAGS := -mxgot -ffreestanding -O1 -mips3 -mno-branch-likely -mabi=n32 -mno-abicalls

SRCS := timer_test.c \
        $(CSMITH)/start_csmith.S \
        $(CSMITH)/baremetal_support.c \
        $(HELLO)/printf.c \
        $(HELLO)/arith64.c

timer_test.elf: $(SRCS)
	$(CC) $(BM_FLAGS) -I$(HELLO) -w -nostdlib \
	    $(CSMITH)/start_csmith.S \
	    $(CSMITH)/baremetal_support.c \
	    $(HELLO)/printf.c \
	    $(HELLO)/arith64.c \
	    timer_test.c \
	    -T $(HELLO)/baremetal.ld -Wl,-melf32btsmipn32 -o $@

run: timer_test.elf
	$(SIM) --file $< --checker true 2>&1

dis: timer_test.elf
	mips-linux-gnu-objdump -d $< > timer_test.dis

clean:
	rm -f timer_test.elf timer_test.dis
