REPO   := ../..
HELLO  := $(REPO)/hello
SIM    := $(REPO)/ooo_core
CSMITH := ../csmith

CC  := mips-linux-gnu-gcc
BM_FLAGS := -mxgot -ffreestanding -O1 -mips3 -mno-branch-likely -mabi=n32 -mno-abicalls

SRCS := sw_irq_test.c \
        $(CSMITH)/start_csmith.S \
        $(CSMITH)/baremetal_support.c \
        $(HELLO)/printf.c \
        $(HELLO)/arith64.c

sw_irq_test.elf: $(SRCS)
	$(CC) $(BM_FLAGS) -I$(HELLO) -w -nostdlib \
	    $(CSMITH)/start_csmith.S \
	    $(CSMITH)/baremetal_support.c \
	    $(HELLO)/printf.c \
	    $(HELLO)/arith64.c \
	    sw_irq_test.c \
	    -T $(HELLO)/baremetal.ld -Wl,-melf32btsmipn32 -o $@

# Software interrupts are program-raised (mtc0 Cause), no TB inject needed.
run: sw_irq_test.elf
	$(SIM) --file $< --checker false 2>&1

dis: sw_irq_test.elf
	mips-linux-gnu-objdump -d $< > sw_irq_test.dis

clean:
	rm -f sw_irq_test.elf sw_irq_test.dis
