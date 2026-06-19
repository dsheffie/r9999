REPO   := ../..
HELLO  := $(REPO)/hello
SIM    := $(REPO)/ooo_core
CSMITH := ../csmith

CC  := mips-linux-gnu-gcc
BM_FLAGS := -mxgot -ffreestanding -O1 -mips3 -mno-branch-likely -mabi=n32 -mno-abicalls

SRCS := ext_irq_test.c \
        $(CSMITH)/start_csmith.S \
        $(CSMITH)/baremetal_support.c \
        $(HELLO)/printf.c \
        $(HELLO)/arith64.c

ext_irq_test.elf: $(SRCS)
	$(CC) $(BM_FLAGS) -I$(HELLO) -w -nostdlib \
	    $(CSMITH)/start_csmith.S \
	    $(CSMITH)/baremetal_support.c \
	    $(HELLO)/printf.c \
	    $(HELLO)/arith64.c \
	    ext_irq_test.c \
	    -T $(HELLO)/baremetal.ld -Wl,-melf32btsmipn32 -o $@

# Inject ip2 (held from cycle 0; gated by IM[2] until main() enables it).
# --checker false: the interpreter doesn't model the injected IRQ.
run: ext_irq_test.elf
	R9999_ASSERT_IP=2 R9999_ASSERT_CYCLE=0 $(SIM) --file $< --checker false 2>&1

dis: ext_irq_test.elf
	mips-linux-gnu-objdump -d $< > ext_irq_test.dis

clean:
	rm -f ext_irq_test.elf ext_irq_test.dis
