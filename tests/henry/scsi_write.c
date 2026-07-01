/*
 * scsi_write.c -- bare-metal round-trip test of the DMA controller's WRITE path.
 *
 * WRITE(10) a known pattern to a scratch LBA (the engine reads mem[BP] -> disk_wr
 * beats -> TB captures -> block_write to the disk overlay), then READ(10) it back
 * into a different buffer and compare.  Exercises engine S_W_MEM/S_W_DISK + the TB
 * beat-capture path, and proves the round trip is byte-exact.  Writes hit the TB's
 * in-memory overlay only, so the real disk image is untouched.
 *
 * Run: henry_tb --kernel scsi_write.elf --arcs henry_arcs.bin --start-pc 0xbfc00000 \
 *               --disk irix65-clean.img --maxcyc 800000
 */
#include "henry_io.h"

#define SASR (*(volatile unsigned char *)0xbfbc0003u)
#define SCMD (*(volatile unsigned char *)0xbfbc0007u)
#define HPC_NBDP (*(volatile unsigned int *)0xbfb90004u)
#define HPC_BC   (*(volatile unsigned int *)0xbfb91000u)
#define HPC_CTRL (*(volatile unsigned int *)0xbfb91004u)

#define DESC ((volatile unsigned int *)0xa9000000u)   /* phys 0x09000000 */
#define DESC_PHYS 0x09000000u
#define WBUF ((volatile unsigned int *)0xa9002000u)   /* phys 0x09002000 */
#define WBUF_PHYS 0x09002000u
#define RBUF ((volatile unsigned int *)0xa9003000u)   /* phys 0x09003000 */
#define RBUF_PHYS 0x09003000u

static void wd(unsigned idx, unsigned val) { SASR = (unsigned char)idx; SCMD = (unsigned char)val; }
static void clear_intrq(void) { SASR = 0x17u; (void)SCMD; }     /* read SCSI Status clears INTRQ */
static void wait_intrq(void)  { while (!(SASR & 0x80u)) { } }

/* one 512-byte transfer: program the descriptor + CDB(10) and ring the doorbell */
static void xfer(unsigned op, unsigned lba, unsigned bp_phys, unsigned to_dev)
{
    DESC[0] = bp_phys; DESC[1] = 0x80000000u | 512u; DESC[2] = 0u; DESC[3] = 0u;
    HPC_NBDP = DESC_PHYS;
    HPC_BC   = 0x80000000u | 512u;
    HPC_CTRL = to_dev ? 0x14u : 0x10u;            /* ACTIVE | (bit2 DIR for WRITE) */
    wd(0x15, 1u); wd(0x0f, 0u);                   /* dest=1, lun=0 */
    wd(0x03, op);                                 /* CDB[0] = READ10/WRITE10 */
    wd(0x04, 0u);
    wd(0x05, (lba >> 24) & 0xff); wd(0x06, (lba >> 16) & 0xff);
    wd(0x07, (lba >> 8) & 0xff);  wd(0x08, lba & 0xff);   /* LBA (BE) */
    wd(0x09, 0u);
    wd(0x0a, 0u); wd(0x0b, 1u);                   /* 1 block */
    wd(0x0c, 0u);
    wd(0x18, 0x08u);                              /* SEL_ATN_XFER -> doorbell */
}

int main(void)
{
    unsigned i, bad = 0, lba = 1000u;

    for (i = 0; i < 128; i++) WBUF[i] = 0xc0de0000u | i;   /* pattern to write */
    for (i = 0; i < 128; i++) RBUF[i] = 0x5e5e5e5eu;       /* sentinel the read-back */

    xfer(0x2au, lba, WBUF_PHYS, 1u);   /* WRITE(10) */
    wait_intrq();
    clear_intrq();

    xfer(0x28u, lba, RBUF_PHYS, 0u);   /* READ(10) it back */
    wait_intrq();

    for (i = 0; i < 128; i++) if (RBUF[i] != (0xc0de0000u | i)) bad++;
    puts_("scsi_write: rbuf[0]="); puthex32(RBUF[0]); puts_(" bad="); puthex32(bad); putch('\n');
    if (bad == 0) puts_("scsi_write: PASS (round-trip write+read byte-exact)\n");
    else          puts_("scsi_write: FAIL\n");
    sim_halt();
    return 0;
}
