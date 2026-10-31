#ifndef __sgi_scsi__
#define __sgi_scsi__

#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>
#include <unordered_map>

struct state_t;
class qcow2_reader;
class chd_reader;

/*
 * Fused WD33C93A SCSI controller + single disk target (behavioral model).
 *
 * On IP22 the CPU programs the WD33C93 through two byte ports in the HPC3 HD0
 * window: SASR (0x44003, the indirect register-select pointer) and SCMD
 * (0x44007, the data port for the selected register; auto-increments the
 * pointer).  The HPC3 SCSI-DMA channel moves the data phase byte-at-a-time via
 * dma_r()/dma_w().
 *
 * We collapse the SCSI bus + disk target into one model (no arbitration /
 * REQ-ACK microstates -- MAME needs those for a general bus, we have one disk).
 * Control is an explicit data-phase state machine (see phase_t): a
 * Select-And-Transfer (0x08/0x09) decodes the CDB, runs the data phase against
 * the disk image, and completes with WD33C93 SCSI Status 0x16 + INTRQ.  Command
 * set validated against a live IRIX 6.5 MAME boot trace.  Writes go to an
 * in-memory COW overlay so the backing image is never modified.
 */
class sgi_scsi {
public:
  /* Externally-visible control FSM (the data phase the HPC3 DMA interacts with). */
  enum phase_t { PH_IDLE, PH_DATA_IN, PH_DATA_OUT };
private:
  state_t *s;
  int      fd = -1;                 /* raw disk image (read-only, or O_RDWR if direct_write) */
  qcow2_reader *qcow = nullptr;     /* non-null when the image is qcow2 (read-only, under the overlay) */
  chd_reader   *chd  = nullptr;     /* non-null when the image is a MAME CHD (read-only, under the overlay) */
  bool     direct_write = false;    /* --disk-write: writes go straight to the image, no COW */
  uint64_t nblocks = 0;             /* 512-byte block count */
  uint8_t  regs[0x20] = {0};        /* WD33C93 register file 0x00..0x1f */
  uint8_t  sasr = 0;                /* indirect register pointer */
  phase_t  phase = PH_IDLE;         /* data-phase state */
  std::vector<uint8_t> buf;         /* current data-in / data-out buffer */
  size_t   pos = 0;                 /* DMA cursor into buf */
  bool     drq = false;             /* DRQ: data available (in) / needed (out) */
  bool     intrq = false;           /* INTRQ pending (command complete) */
  uint64_t wr_lba = 0;              /* pending WRITE target (drained from buf) */
  uint8_t  sense[18] = {0};         /* REQUEST SENSE fixed-format data */
  uint8_t  tgt_status = 0;          /* target STATUS byte -> WD33C93 reg 0x0f after a transfer */
  /* Select-with-ATN (0x06) + Transfer Info: the step-by-step path the Linux wd33c93
   * driver uses for every target's first command (IRIX uses only the fused 0x08).
   * The target walks MESSAGE OUT -> (MESSAGE IN reject of an SDTR) -> COMMAND ->
   * DATA (by DMA, through a level-2 0x08 with Command Phase 0x45) or STATUS ->
   * MESSAGE IN, one interrupt per phase; message/CDB/status bytes move through
   * the data register (reg 0x19) by PIO. */
  enum tphase_t { TP_NONE, TP_MSG_OUT, TP_COMMAND, TP_DATA, TP_STATUS, TP_MSG_IN };
  tphase_t tphase = TP_NONE;        /* target bus phase while connected by 0x06 */
  std::vector<uint8_t> pio;         /* bytes moved by the current Transfer Info */
  size_t   pio_need = 0;            /* Transfer Info byte count */
  size_t   pio_pos = 0;             /* bytes the CPU has read of pio (target -> CPU) */
  bool     pio_dbr = false;         /* data register ready for the CPU (PIO, not DMA) */
  bool     pio_in = false;          /* PIO direction: target -> CPU */
  std::vector<uint8_t> msg_in;      /* MESSAGE IN bytes still to send, one per Negate ACK */
  bool     msg_done = false;        /* msg_in is COMMAND COMPLETE: disconnect after it */
  uint8_t  pending_st = 0;          /* next interrupt, raised when Status is read */
  bool     decoding_atn = false;    /* decode_cdb() from the 0x06 path: arm nothing */
  bool     atn_nodata = false;      /* ... and the command has no data phase */
  std::unordered_map<uint64_t, std::vector<uint8_t>> overlay; /* COW writes */
  std::string delta_path;           /* optional sidecar persisting the overlay */

  void load_delta();                /* populate overlay from delta_path if present */
  void block_read(uint64_t lba, uint8_t *dst);     /* 512 bytes */
  void block_write(uint64_t lba, const uint8_t *src);
  void exec_command(uint8_t cc);    /* a WD33C93 command was written to reg 0x18 */
  void select_and_transfer();       /* decode CDB -> arm data phase / complete */
  bool select_timeout();            /* no device at the destination ID: post 0x42 */
  void decode_cdb();                /* regs[WD_CDB..] -> data phase / no data */
  void raise_int(uint8_t st, uint8_t phs);   /* post a WD33C93 interrupt */
  void select_atn();                /* 0x06 */
  void transfer_info(bool sbt);     /* 0x20 (0xa0 single byte) while connected by 0x06 */
  void negate_ack();                /* 0x03 */
  void pio_done();                  /* the current Transfer Info moved its last byte */
  void begin_data_in(const uint8_t *p, size_t n);  /* -> PH_DATA_IN */
  void begin_data_out(size_t n);                   /* -> PH_DATA_OUT */
  void finish();                    /* data phase drained -> status + INTRQ */
  void complete(uint8_t scsi_status);
public:
  sgi_scsi(state_t *s, const std::string &disk_path, const std::string &delta_path = "",
           bool direct_write = false);
  ~sgi_scsi();
  bool ok() const { return fd >= 0; }

  /* Persist the in-memory COW overlay to delta_path (write-back so the SGIindex
   * and other writes survive across runs while the backing image stays pristine).
   * Called post-loop on clean exit and on SIGUSR2. No-op without --disk-delta. */
  void flush_delta() const;

  /* CPU PIO to the WD33C93 indirect register file (port 0 = SASR, 1 = SCMD). */
  void    pio_w(uint32_t port, uint8_t v);
  uint8_t pio_r(uint32_t port);

  /* HPC3 SCSI-DMA channel data byte port. */
  uint8_t dma_r();                  /* device -> memory */
  void    dma_w(uint8_t v);         /* memory -> device */

  void reset();
  bool drq_pending()   const { return drq; }
  bool intrq_pending() const { return intrq; }
  /* device bytes still pending in the data buffer (undrained read / unfilled write) */
  size_t residual() const {
    return (phase == PH_DATA_IN || phase == PH_DATA_OUT) ? buf.size() - pos : 0;
  }
  /* HPC3 DMA chain hit EOX before the data phase finished (chunked transfer):
   * post a transfer-paused interrupt; IRIX resumes via a fresh SEL_ATN_XFER. */
  void pause_transfer();
};

#endif
