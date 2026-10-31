#include "sgi_scsi.hh"
#include "qcow2_reader.hh"
#include "chd_reader.hh"
#include "interpret.hh"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

static const bool scsi_verbose = getenv("SCSIDBG") != nullptr;
/* AUX-status polls are spammy, so only the first few are logged by default;
 * SCSIAUXMAX raises the cap when diffing the full PIO stream against another
 * implementation. */
static const char *scsi_auxmax_env = getenv("SCSIAUXMAX");
static const int scsi_auxmax = scsi_auxmax_env ? atoi(scsi_auxmax_env) : 12;
#define SPRINTF(...) do { if(scsi_verbose) fprintf(stderr, __VA_ARGS__); } while(0)

/* WD33C93 register file indices */
enum { WD_OWN_ID=0x00, WD_CONTROL=0x01, WD_CDB=0x03, WD_TARGET_LUN=0x0f,
       WD_COMMAND_PHASE=0x10, WD_XFER_CNT_MSB=0x12, WD_DEST_ID=0x15,
       WD_SOURCE_ID=0x16, WD_SCSI_STATUS=0x17, WD_COMMAND=0x18,
       WD_DATA=0x19, WD_AUX_STATUS=0x1f };
/* Auxiliary status bits */
enum { AUX_DBR=0x01, AUX_CIP=0x10, AUX_BSY=0x20, AUX_LCI=0x40, AUX_INT=0x80 };
/* WD33C93 commands (low 7 bits of reg 0x18) */
enum { CMD_RESET=0x00, CMD_NEGATE_ACK=0x03, CMD_SEL_ATN=0x06, CMD_SEL_ATN_XFER=0x08, CMD_SEL_XFER=0x09,
       CMD_XFER_INFO=0x20 };
/* SCSI Status completion codes (reg 0x17) */
enum { ST_RESET=0x00, ST_SELECT_TRANSFER_SUCCESS=0x16, ST_SELECTION_TIMEOUT=0x42 };
/* Step-by-step (0x06) interrupts: SELECT, MESSAGE IN paused on ACK, DISCONNECT, and a
 * target Service Request in a bus phase (0x88 | phase) */
enum { ST_SELECT=0x11, ST_XFER_DONE=0x18, ST_MSGIN_ACK=0x20, ST_DISC=0x85, ST_SRV_REQ=0x88 };
enum { BPH_DATA_OUT=0, BPH_DATA_IN=1, BPH_COMMAND=2, BPH_STATUS=3, BPH_MSG_OUT=6, BPH_MSG_IN=7 };
/* SCSI messages the 0x06 path speaks */
enum { MSG_COMMAND_COMPLETE=0x00, MSG_EXTENDED=0x01, MSG_SDTR=0x01 };
/* The single emulated disk lives at this SCSI target ID (SGI Indy system disk =
 * ID 1; IRIX roots on /hw/scsi_ctlr/0/target/1/...). Selecting any other ID
 * times out so the bus scan reports one drive, not one per target. */
static const uint8_t DISK_TARGET = 1;

sgi_scsi::sgi_scsi(state_t *s, const std::string &disk_path, const std::string &delta_path,
                   bool direct_write)
  : s(s), direct_write(direct_write), delta_path(delta_path) {
  /* --disk-write: open O_RDWR and let block_write() land straight in the image
   * (like the FPGA's real disk) so IRIX reconfigure/state persists. Mutually
   * exclusive with the COW delta -- ignore delta_path in this mode. */
  if(direct_write and !delta_path.empty()) {
    fprintf(stderr, "sgi_scsi: --disk-write overrides --disk-delta (direct writes, no COW)\n");
    this->delta_path.clear();
  }
  fd = disk_path.empty() ? -1 : open(disk_path.c_str(), direct_write ? O_RDWR : O_RDONLY);
  if(fd >= 0) {
    /* qcow2 or MAME CHD? peek the magic; if so, parse it and size the disk from
     * the image's virtual size.  Both readers are read-only -- writes go through
     * the COW overlay / --disk-delta like a read-only raw image -- so --disk-write
     * is rejected.  CHD's magic is 8 bytes ("MComprHD"); qcow2's is the first 4. */
    uint8_t magic[8];
    ssize_t mg = pread(fd, magic, 8, 0);
    if(mg == 8 && chd_reader::is_magic(magic)) {
      chd = new chd_reader();
      if(chd->open(fd)) {
        nblocks = chd->virtual_size() / 512;
        if(this->direct_write) {
          fprintf(stderr, "sgi_scsi: --disk-write is not supported on a CHD image; "
                          "writes go to the in-memory overlay (use --disk-delta to persist)\n");
          this->direct_write = false;
          direct_write = false;
        }
      } else {
        fprintf(stderr, "sgi_scsi: '%s' is a CHD but unsupported -- modeling an empty bus\n",
                disk_path.c_str());
        delete chd; chd = nullptr;
        close(fd); fd = -1;
      }
    } else if(mg >= 4 && qcow2_reader::is_magic(magic)) {
      qcow = new qcow2_reader();
      if(qcow->open(fd)) {
        nblocks = qcow->virtual_size() / 512;
        if(this->direct_write) {
          fprintf(stderr, "sgi_scsi: --disk-write is not supported on a qcow2 image; "
                          "writes go to the in-memory overlay (use --disk-delta to persist)\n");
          this->direct_write = false;   /* member: block_write() uses the COW overlay */
          direct_write = false;         /* parameter: keep this ctor's own diagnostics honest */
        }
      } else {
        fprintf(stderr, "sgi_scsi: '%s' is qcow2 but unsupported -- modeling an empty bus\n",
                disk_path.c_str());
        delete qcow; qcow = nullptr;
        close(fd); fd = -1;
      }
    } else {
      struct stat st;
      if(fstat(fd, &st) == 0)
        nblocks = (uint64_t)st.st_size / 512;
    }
  } else if(!disk_path.empty()) {
    fprintf(stderr, "sgi_scsi: cannot open disk image '%s'%s -- modeling an empty bus\n",
            disk_path.c_str(), direct_write ? " for read/write (--disk-write)" : "");
  }
  /* The WD33C93 controller is always present (a real Indy always has it).  With no
   * media (fd < 0 -- no --disk, or an unopenable image) the bus is simply empty and
   * every SELECT times out; the controller still resets and answers its registers,
   * which is what lets a diskless Linux boot clear the driver's reset + target probe
   * instead of hanging on ASR_INT. */
  sense[0] = 0x70; sense[7] = 0x0a;   /* fixed-format REQUEST SENSE: NO SENSE */
  reset();
  if(fd >= 0) {
    SPRINTF("sgi_scsi: '%s' = %llu blocks (%llu MB)%s\n", disk_path.c_str(),
            (unsigned long long)nblocks, (unsigned long long)(nblocks/2048),
            direct_write ? " [DIRECT WRITE]" : "");
    if(direct_write) {
      fprintf(stderr, "sgi_scsi: DIRECT WRITE to '%s' -- the image WILL be modified in place\n",
              disk_path.c_str());
    }
    if(!this->delta_path.empty()) load_delta();
  }
}

/* delta sidecar format: 8-byte magic "IMDELTA1" then repeated records of
 * { uint64_t lba; uint8_t block[512]; } in host byte order (host-local cache). */
static const char DELTA_MAGIC[8] = {'I','M','D','E','L','T','A','1'};

void sgi_scsi::load_delta() {
  FILE *f = fopen(delta_path.c_str(), "rb");
  if(!f) return;                         /* no prior delta -> start from the image */
  char magic[8];
  if(fread(magic, 1, 8, f) != 8 || memcmp(magic, DELTA_MAGIC, 8) != 0) {
    fprintf(stderr, "sgi_scsi: ignoring delta '%s' (bad magic)\n", delta_path.c_str());
    fclose(f);
    return;
  }
  uint64_t lba; std::vector<uint8_t> blk(512); size_t n = 0;
  while(fread(&lba, sizeof(lba), 1, f) == 1 && fread(blk.data(), 1, 512, f) == 512) {
    overlay[lba] = blk; n++;
  }
  fclose(f);
  fprintf(stderr, "sgi_scsi: loaded %zu delta blocks from '%s'\n", n, delta_path.c_str());
}

void sgi_scsi::flush_delta() const {
  if(delta_path.empty()) return;
  FILE *f = fopen(delta_path.c_str(), "wb");
  if(!f) { fprintf(stderr, "sgi_scsi: cannot write delta '%s'\n", delta_path.c_str()); return; }
  fwrite(DELTA_MAGIC, 1, 8, f);
  for(const auto &kv : overlay) {
    uint64_t lba = kv.first;
    fwrite(&lba, sizeof(lba), 1, f);
    fwrite(kv.second.data(), 1, 512, f);
  }
  fclose(f);
  fprintf(stderr, "sgi_scsi: wrote %zu delta blocks to '%s'\n", overlay.size(), delta_path.c_str());
}

sgi_scsi::~sgi_scsi() { delete qcow; delete chd; if(fd >= 0) close(fd); }

void sgi_scsi::reset() {
  SPRINTF("sgi_scsi: reset() called @icnt=%llu (intrq->false)\n", (unsigned long long)s->icnt);
  sasr = 0; pos = 0; drq = false; intrq = false; phase = PH_IDLE;
  buf.clear();
  regs[WD_AUX_STATUS] = 0;
  tphase = TP_NONE; pio.clear(); pio_need = 0; pio_dbr = false; pending_st = 0;
}

void sgi_scsi::block_read(uint64_t lba, uint8_t *dst) {
  auto it = overlay.find(lba);            /* COW: written blocks win */
  if(it != overlay.end()) { memcpy(dst, it->second.data(), 512); return; }
  if(lba >= nblocks) { memset(dst, 0, 512); return; }
  if(qcow) { qcow->read_block(lba, dst); return; }   /* qcow2 backing (read-only) */
  if(chd)  { chd->read_block(lba, dst);  return; }   /* MAME CHD backing (read-only) */
  ssize_t n = pread(fd, dst, 512, (off_t)(lba * 512));
  if(n != 512) memset(dst, 0, 512);
}

void sgi_scsi::block_write(uint64_t lba, const uint8_t *src) {
  if(direct_write) {                      /* --disk-write: straight to the image, no COW */
    if(lba < nblocks) {
      ssize_t n = pwrite(fd, src, 512, (off_t)(lba * 512));
      (void)n;
    }
    return;
  }
  auto &v = overlay[lba];                 /* COW: never touch the backing image */
  v.assign(src, src + 512);
}

/* ---- data-phase FSM transitions ------------------------------------------ */

void sgi_scsi::begin_data_in(const uint8_t *p, size_t n) {
  buf.assign(p, p + n);
  pos = 0;
  if(n == 0) { finish(); return; }
  phase = PH_DATA_IN; drq = true;
}

void sgi_scsi::begin_data_out(size_t n) {
  buf.assign(n, 0);
  pos = 0;
  if(n == 0) { finish(); return; }
  phase = PH_DATA_OUT; drq = true;
}

void sgi_scsi::finish() {
  if(decoding_atn) {                     /* 0x06 path: no data phase -> STATUS next */
    phase = PH_IDLE; drq = false; atn_nodata = true;
    return;
  }
  /* drain side-effects for data-out, then post completion status + INTRQ */
  if(phase == PH_DATA_OUT && regs[WD_CDB] == 0x2a) {      /* WRITE(10) -> overlay */
    size_t blocks = buf.size() / 512;
    for(size_t i = 0; i < blocks; i++)
      block_write(wr_lba + i, buf.data() + i * 512);
    { /* SCSIWDUMP=<file>: append every written block as {uint64 lba (LE), 512 bytes},
       * the same format as the board driver's, to diff guest writes block by block */
      static FILE *g_wd = getenv("SCSIWDUMP") ? fopen(getenv("SCSIWDUMP"), "wb") : nullptr;
      if(g_wd) {
        for(size_t i = 0; i < blocks; i++) {
          uint64_t l = wr_lba + i;
          fwrite(&l, 8, 1, g_wd);
          fwrite(buf.data() + i * 512, 512, 1, g_wd);
        }
        fflush(g_wd);
      }
    }
    if(getenv("SCSIHASH")) {                 /* golden per-WRITE payload hash (vs FPGA) */
      uint64_t h = 1469598103934665603ULL;
      for(size_t i = 0; i < buf.size(); i++) { h ^= buf[i]; h *= 1099511628211ULL; }
      fprintf(stderr, "[scsiwhash] op=2a lba=%llu nblk=%zu bytes=%zu hash=%016llx\n",
              (unsigned long long)wr_lba, blocks, buf.size(), (unsigned long long)h);
    }
  }
  phase = PH_IDLE; drq = false;
  complete(ST_SELECT_TRANSFER_SUCCESS);
}

void sgi_scsi::complete(uint8_t scsi_status) {
  regs[WD_SCSI_STATUS]   = scsi_status;
  /* After Select-and-Transfer the WD33C93 leaves the target STATUS byte in reg
   * 0x0f (Target LUN). IRIX reads it to tell GOOD (0x00) from CHECK CONDITION
   * (0x02). We must write it -- otherwise IRIX reads back the LUN it programmed
   * and mistakes lun>=2 for a CHECK CONDITION (an INQUIRY/REQUEST-SENSE loop). */
  regs[WD_TARGET_LUN]    = tgt_status;
  regs[WD_COMMAND_PHASE] = 0x60;          /* command complete */
  /* The WD33C93 decrements its 24-bit Transfer Count (regs 0x12-0x14) as bytes
   * move; at completion it has counted down to 0. We transfer exactly the
   * programmed amount, so post a zero residual -- otherwise the sgiwd93 driver
   * reads the leftover programmed count as a short transfer and sets b_error on
   * the buffer, which makes xfs_read_file bail (chunkread -> b_error -> ENOEXEC). */
  regs[0x12] = regs[0x13] = regs[0x14] = 0;
  regs[WD_AUX_STATUS]   &= ~(AUX_CIP | AUX_BSY);
  regs[WD_AUX_STATUS]   |= AUX_INT;
  intrq = true; s->irq_poke = true;
  tphase = TP_NONE;                      /* a Select-and-Transfer ends any 0x06 connection */
  SPRINTF("sgi_scsi: complete status=0x%02x\n", scsi_status);
  { static const bool g_si = getenv("SCSIICNT") != nullptr;
    if(g_si) fprintf(stderr, "[scsi-icnt] %llu\n", (unsigned long long)s->icnt); }
}

/* ---- command decode ------------------------------------------------------ */

void sgi_scsi::pause_transfer() {
  /* The HPC3 DMA descriptor chain ended (EOX) before this data phase finished:
   * IRIX deliberately programmed the WD33C93 transfer count for fewer bytes than
   * the SCSI command's full length (a chunked/scatter transfer). The real
   * WD33C93 raises an interrupt when its transfer count hits zero, leaving the
   * data phase active; IRIX then reprograms the DMA and re-issues SEL_ATN_XFER to
   * move the rest (see the resume path in select_and_transfer). Status/phase
   * codes match the validated iris WD33C93 model (ST_UNEX_SDATA on a data-in
   * read / ST_UNEX_RDATA on a data-out write). buf + pos are preserved. */
  drq = false;                            /* no data movement until resumed */
  regs[WD_SCSI_STATUS]   = (phase == PH_DATA_OUT) ? 0x48 : 0x49;
  regs[WD_COMMAND_PHASE] = 0x46;          /* transfer count exhausted */
  regs[0x12] = regs[0x13] = regs[0x14] = 0;  /* WD33C93 count counted down to 0 at the chunk boundary */
  regs[WD_AUX_STATUS]   &= ~(AUX_CIP | AUX_BSY);
  regs[WD_AUX_STATUS]   |= AUX_INT;
  intrq = true; s->irq_poke = true;
  SPRINTF("sgi_scsi: %s paused at %zu/%zu (chunked) -> INTRQ\n",
          phase == PH_DATA_OUT ? "data-out" : "data-in", pos, buf.size());
}

void sgi_scsi::select_and_transfer() {
  /* Resume a chunked transfer paused at a DMA EOX boundary: IRIX has
   * reprogrammed the DMA channel for the remaining bytes and re-issued
   * SEL_ATN_XFER. Continue the data phase from pos -- do NOT re-decode the CDB
   * (the HPC3 DMA pump after this command write moves the rest). */
  if((phase == PH_DATA_IN || phase == PH_DATA_OUT) && pos > 0 && pos < buf.size()) {
    SPRINTF("sgi_scsi: %s resume from %zu/%zu\n",
            phase == PH_DATA_OUT ? "data-out" : "data-in", pos, buf.size());
    regs[WD_AUX_STATUS] |= (AUX_CIP | AUX_BSY);
    drq = true;
    return;
  }

  /* Only one device on the bus, at DISK_TARGET (and only when media is attached).
   * Selecting any other target ID -- or any target at all on an empty bus (fd < 0,
   * no --disk) -- gets a selection timeout (no device responded): command-phase
   * DISCONNECTED + status SELECTION_TIMEOUT + INTRQ.  This matches the iris WD33C93
   * model; without it the fused model answered as a disk for every target and
   * IRIX's hinv reported 7 drives (one per probed ID). */
  if(select_timeout()) {
    return;
  }
  regs[WD_AUX_STATUS] |= (AUX_CIP | AUX_BSY);
  decode_cdb();
}

bool sgi_scsi::select_timeout() {
  if(fd >= 0 && (regs[WD_DEST_ID] & 7) == DISK_TARGET) {
    return false;
  }
  regs[WD_AUX_STATUS]   &= ~(AUX_CIP | AUX_BSY);
  regs[WD_AUX_STATUS]   |= AUX_INT;
  regs[WD_SCSI_STATUS]   = ST_SELECTION_TIMEOUT;
  regs[WD_COMMAND_PHASE] = 0x00;          /* DISCONNECTED: no device selected */
  intrq = true; s->irq_poke = true;
  SPRINTF("sgi_scsi: select target %u -> no device (selection timeout)\n",
          regs[WD_DEST_ID] & 7);
  return true;
}

void sgi_scsi::decode_cdb() {
  const uint8_t *cdb = &regs[WD_CDB];
  const uint8_t op = cdb[0];
  uint8_t lun = regs[WD_TARGET_LUN] & 7;   /* capture before complete() overwrites 0x0f */
  SPRINTF("sgi_scsi: icnt=%llu CDB %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x dest=%u lun=%u\n",
          (unsigned long long)s->icnt,
          cdb[0],cdb[1],cdb[2],cdb[3],cdb[4],cdb[5],cdb[6],cdb[7],cdb[8],cdb[9],
          regs[WD_DEST_ID]&7, lun);

  tgt_status = 0x00;                        /* GOOD unless we set CHECK below */

  /* Only LUN 0 exists. For any other LUN, return CHECK CONDITION with sense
   * key ILLEGAL REQUEST / ASC 0x25 (LOGICAL UNIT NOT SUPPORTED) and no data, so
   * the probe records "no device" and stops instead of looping. REQUEST SENSE
   * itself must still succeed so IRIX can read that sense. */
  if(lun != 0 && op != 0x03) {
    sense[0] = 0x70; sense[2] = 0x05; sense[7] = 0x0a; sense[12] = 0x25; sense[13] = 0x00;
    tgt_status = 0x02;                      /* CHECK CONDITION */
    finish();
    return;
  }

  switch(op) {
  case 0x00:   /* TEST UNIT READY  */
  case 0x1b:   /* START STOP UNIT  */
    finish();
    break;

  case 0x12: { /* INQUIRY */
    uint8_t inq[36] = {0};
    inq[0] = 0x00;            /* direct-access disk */
    inq[1] = 0x00;            /* not removable */
    inq[2] = 0x02;            /* SCSI-2 */
    inq[3] = 0x02;            /* response data format */
    inq[4] = 31;              /* additional length */
    memcpy(inq + 8,  "SGI     ", 8);
    memcpy(inq + 16, "interp_mips disk", 16);
    memcpy(inq + 32, "1.0 ", 4);
    size_t alloc = cdb[4];
    begin_data_in(inq, alloc < sizeof(inq) ? alloc : sizeof(inq));
    break;
  }

  case 0x03: { /* REQUEST SENSE */
    size_t alloc = cdb[4];
    begin_data_in(sense, alloc < sizeof(sense) ? alloc : sizeof(sense));
    break;
  }

  case 0x25: { /* READ CAPACITY(10) */
    uint8_t cap[8];
    uint32_t last = (nblocks ? (uint32_t)(nblocks - 1) : 0);
    cap[0]=last>>24; cap[1]=last>>16; cap[2]=last>>8; cap[3]=last;  /* last LBA, BE */
    cap[4]=0; cap[5]=0; cap[6]=2; cap[7]=0;                         /* block size 512, BE */
    begin_data_in(cap, sizeof(cap));
    break;
  }

  case 0x1a: { /* MODE SENSE(6) - minimal valid mode-parameter header */
    uint8_t ms[4] = {3, 0, 0, 0};   /* mode data len, medium type, dev-spec, blk-desc len */
    size_t alloc = cdb[4];
    begin_data_in(ms, alloc < sizeof(ms) ? alloc : sizeof(ms));
    break;
  }

  case 0x15: { /* MODE SELECT(6) - data-out, consume + succeed */
    begin_data_out(cdb[4]);
    break;
  }

  case 0x28: { /* READ(10) */
    uint64_t lba = ((uint64_t)cdb[2]<<24)|((uint64_t)cdb[3]<<16)|((uint64_t)cdb[4]<<8)|cdb[5];
    uint32_t len = ((uint32_t)cdb[7]<<8)|cdb[8];          /* blocks */
    buf.assign((size_t)len * 512, 0);
    for(uint32_t i = 0; i < len; i++)
      block_read(lba + i, buf.data() + (size_t)i * 512);
    if(getenv("SCSIHASH")) {                 /* golden per-READ payload hash (vs FPGA) */
      uint64_t h = 1469598103934665603ULL;
      for(size_t i = 0; i < buf.size(); i++) { h ^= buf[i]; h *= 1099511628211ULL; }
      fprintf(stderr, "[scsihash] op=28 lba=%llu nblk=%u bytes=%zu hash=%016llx\n",
              (unsigned long long)lba, len, buf.size(), (unsigned long long)h);
    }
    pos = 0;
    if(len == 0) { finish(); break; }
    phase = PH_DATA_IN; drq = true;
    break;
  }

  case 0x2a: { /* WRITE(10) - data-out into COW overlay */
    uint64_t lba = ((uint64_t)cdb[2]<<24)|((uint64_t)cdb[3]<<16)|((uint64_t)cdb[4]<<8)|cdb[5];
    uint32_t len = ((uint32_t)cdb[7]<<8)|cdb[8];
    wr_lba = lba;
    begin_data_out((size_t)len * 512);
    break;
  }

  default:
    SPRINTF("sgi_scsi: UNHANDLED CDB opcode 0x%02x -> success/no-data\n", op);
    finish();
    break;
  }
}

/* ---- Select-with-ATN (0x06): one interrupt per bus phase --------------------- */

void sgi_scsi::raise_int(uint8_t st, uint8_t phs) {
  regs[WD_SCSI_STATUS]   = st;
  regs[WD_COMMAND_PHASE] = phs;
  regs[WD_AUX_STATUS]   &= ~(AUX_CIP | AUX_BSY);
  regs[WD_AUX_STATUS]   |= AUX_INT;
  intrq = true; s->irq_poke = true;
  SPRINTF("sgi_scsi: [atn] int status=%02x phase=%02x\n", st, phs);
}

void sgi_scsi::select_atn() {
  if(select_timeout()) {
    return;
  }
  /* Selected with ATN: the target answers ATN by asking for MESSAGE OUT, which the
   * chip reports once the driver has taken the SELECT interrupt (Status read). */
  tphase = TP_MSG_OUT;
  phase = PH_IDLE; drq = false; pos = 0; buf.clear();
  tgt_status = 0x00;
  raise_int(ST_SELECT, 0x10);
  pending_st = ST_SRV_REQ | BPH_MSG_OUT;
}

void sgi_scsi::transfer_info(bool sbt) {
  /* Transfer Info moves Transfer Count bytes (one in single-byte mode) in the
   * current bus phase; the data register carries them (DBR in AUX status). */
  pio.clear();
  pio_pos = 0;
  pio_need = sbt ? 1 : ((size_t)regs[0x12] << 16 | (size_t)regs[0x13] << 8 | regs[0x14]);
  switch(tphase)
    {
    case TP_MSG_OUT:
    case TP_COMMAND:
      pio_in = false;
      pio_dbr = pio_need != 0;
      break;
    case TP_STATUS:
      pio_in = true; pio.push_back(tgt_status); pio_dbr = true;
      break;
    case TP_MSG_IN:
      /* up to Transfer Count bytes of the pending message (the SGI PROM takes a 5-byte
       * SDTR in one go; Linux uses single-byte mode), then the chip stops with ACK held
       * (status 0x20) until Negate ACK */
      pio_in = true;
      pio.assign(msg_in.begin(), msg_in.begin() + std::min(pio_need, msg_in.size()));
      if(pio.empty()) {
        pio.push_back(MSG_COMMAND_COMPLETE);
      }
      pio_need = pio.size();
      pio_dbr = true;
      break;
    default:
      /* a PIO data phase: sgiwd93 always uses DMA (level-2 0x08), so not modeled */
      fprintf(stderr, "sgi_scsi: Transfer Info in bus phase %d not modeled\n", (int)tphase);
      pio_dbr = false;
      break;
    }
  if(pio_need == 0) {
    pio_done();
  }
}

/* the last byte of a Transfer Info moved: the target changes phase.  A phase change
 * that ends a Transfer Info is "transfer done" (0x18 | phase); "service request"
 * (0x88 | phase) is for one with no command in progress (after a selection or Negate
 * ACK).  Linux takes either, the SGI PROM only the former. */
void sgi_scsi::pio_done() {
  pio_dbr = false;
  switch(tphase)
    {
    case TP_MSG_OUT: {
      /* IDENTIFY, optionally followed by an SDTR (1, 3, 1, period, offset).  Answer
       * with an SDTR of our own -- the asked-for period, offset 0, i.e. asynchronous.
       * A MESSAGE REJECT would also mean async to Linux, but the SGI PROM and IRIX
       * call a rejected SDTR a "SYNC negotiation error" and reset the bus. */
      const bool sdtr = pio.size() >= 5 && pio[1] == MSG_EXTENDED && pio[3] == MSG_SDTR;
      if(sdtr) {
        tphase = TP_MSG_IN;
        msg_in = {MSG_EXTENDED, 3, MSG_SDTR, pio[4], 0};
        msg_done = false;
        raise_int(ST_XFER_DONE | BPH_MSG_IN, 0x20);
      }
      else {
        tphase = TP_COMMAND;
        raise_int(ST_XFER_DONE | BPH_COMMAND, 0x20);
      }
      break;
    }
    case TP_COMMAND: {
      /* the CDB arrived by PIO: decode it as the fused path would, but arm nothing --
       * the data phase starts when the driver issues a level-2 0x08 (phase 0x45) */
      for(size_t i = 0; i < pio.size() && i < 12; i++) {
        regs[WD_CDB + i] = pio[i];
      }
      SPRINTF("sgi_scsi: [atn] CDB by PIO (%zu bytes)\n", pio.size());
      decoding_atn = true; atn_nodata = false;
      decode_cdb();
      decoding_atn = false;
      drq = false;
      if(atn_nodata) {
        tphase = TP_STATUS;
        raise_int(ST_XFER_DONE | BPH_STATUS, 0x30);
      }
      else {
        tphase = TP_DATA;
        raise_int(ST_XFER_DONE | (phase == PH_DATA_OUT ? BPH_DATA_OUT : BPH_DATA_IN), 0x30);
      }
      break;
    }
    case TP_STATUS:
      /* status byte taken: the target goes to MESSAGE IN with COMMAND COMPLETE (the
       * driver then finishes with a level-2 0x08, Command Phase 0x50) */
      tphase = TP_MSG_IN;
      msg_in = {MSG_COMMAND_COMPLETE};
      msg_done = true;
      raise_int(ST_XFER_DONE | BPH_MSG_IN, 0x40);
      break;
    case TP_MSG_IN:
      /* message byte taken, ACK held until Negate ACK */
      raise_int(ST_MSGIN_ACK, 0x50);
      break;
    default:
      break;
    }
}

void sgi_scsi::negate_ack() {
  if(tphase != TP_MSG_IN) {
    return;
  }
  /* the bytes the last Transfer Info delivered are consumed */
  msg_in.erase(msg_in.begin(), msg_in.begin() + std::min(pio.size(), msg_in.size()));
  if(!msg_in.empty()) {                /* more of a multi-byte message (the SDTR) */
    raise_int(ST_SRV_REQ | BPH_MSG_IN, 0x20);
  }
  else if(!msg_done) {                 /* the SDTR reply is done: on to COMMAND */
    tphase = TP_COMMAND;
    raise_int(ST_SRV_REQ | BPH_COMMAND, 0x20);
  }
  else {                               /* COMMAND COMPLETE: the target disconnects */
    tphase = TP_NONE;
    raise_int(ST_DISC, 0x60);
  }
}

void sgi_scsi::exec_command(uint8_t cc) {
  switch(cc) {
  case CMD_RESET: {
    reset();
    /* WD33C93 reset status: 0x01 = "reset, advanced features enabled" (OWN_ID
     * EAF bit 0x08 set), else 0x00. wd93resetdone reads Status to confirm the
     * post-reset mode; returning 0x00 when the driver enabled EAF wedges it. */
    bool eaf = (regs[WD_OWN_ID] & 0x08) != 0;
    regs[WD_SCSI_STATUS] = eaf ? 0x01 : ST_RESET;
    regs[WD_AUX_STATUS] |= AUX_INT;
    intrq = true; s->irq_poke = true;
    SPRINTF("sgi_scsi: CMD_RESET own_id=%02x eaf=%d -> status=%02x @icnt=%llu\n",
            regs[WD_OWN_ID], (int)eaf, regs[WD_SCSI_STATUS], (unsigned long long)s->icnt);
    break;
  }
  case CMD_SEL_ATN_XFER:
  case CMD_SEL_XFER:
    if(tphase == TP_DATA && regs[WD_COMMAND_PHASE] == 0x45) {
      /* level-2 continuation of a 0x06 command (Linux transfer_bytes): run the data
       * phase decode_cdb() prepared by DMA; finish() completes it as 0x16 / 0x60 */
      SPRINTF("sgi_scsi: [atn] level-2 data phase (%zu bytes)\n", buf.size());
      regs[WD_AUX_STATUS] |= (AUX_CIP | AUX_BSY);
      drq = true;
    }
    else if(tphase == TP_MSG_IN && regs[WD_COMMAND_PHASE] == 0x50) {
      /* level-2 finish after the status byte: message in + disconnect -> 0x16 / 0x60 */
      phase = PH_IDLE; drq = false;
      complete(ST_SELECT_TRANSFER_SUCCESS);
    }
    else {
      select_and_transfer();
    }
    break;
  case CMD_SEL_ATN:
    select_atn();
    break;
  case CMD_NEGATE_ACK:
    negate_ack();
    break;
  case CMD_XFER_INFO:
    /* Transfer Info: the 0x06 path's PIO phases; otherwise (the fused path) the
     * data phase is already armed by the prior command */
    if(tphase != TP_NONE) {
      transfer_info(false);
    }
    break;
  default:
    SPRINTF("sgi_scsi: unhandled WD33C93 command 0x%02x\n", cc);
    break;
  }
}

/* ---- CPU PIO register file ------------------------------------------------ */

void sgi_scsi::pio_w(uint32_t port, uint8_t v) {
  SPRINTF("sgi_scsi: pio_w port=%u v=%02x (sasr=%02x)\n", port, v, sasr);
  if(port == 0) { sasr = v & 0x1f; return; }       /* SASR: set register pointer */
  /* SCMD: write the selected register */
  if(sasr == WD_COMMAND) {
    regs[WD_COMMAND] = v;
    if((v & 0x7f) == CMD_XFER_INFO && tphase != TP_NONE) {
      transfer_info((v & 0x80) != 0);   /* bit 7 = single-byte transfer */
    }
    else {
      exec_command(v & 0x7f);
    }
    return;
  }
  if(sasr == WD_DATA && pio_dbr && !pio_in) {       /* 0x06 path: a PIO byte out */
    pio.push_back(v);
    if(pio.size() >= pio_need) {
      pio_done();
    }
    return;                                         /* the data register does not advance */
  }
  regs[sasr] = v;
  sasr = (sasr + 1) & 0x1f;                         /* auto-increment */
}

uint8_t sgi_scsi::pio_r(uint32_t port) {
  if(port == 0) {                                   /* SASR read = aux status */
    uint8_t a = 0;
    if(intrq) a |= AUX_INT;
    if(drq || pio_dbr) a |= AUX_DBR;
    { static int auxlog = 0;
      if(scsi_verbose && auxlog < scsi_auxmax) {
        fprintf(stderr, "sgi_scsi: pio_r AUX -> %02x (intrq=%d) @icnt=%llu\n",
                a, (int)intrq, (unsigned long long)s->icnt); auxlog++; } }
    return a;
  }
  /* SCMD: read the selected register */
  if(sasr == WD_SCSI_STATUS) {                      /* reading status clears INTRQ */
    uint8_t st = regs[WD_SCSI_STATUS];
    intrq = false; regs[WD_AUX_STATUS] &= ~AUX_INT;
    SPRINTF("sgi_scsi: pio_r reg=%02x -> %02x\n", (unsigned)sasr, st);
    sasr = (sasr + 1) & 0x1f;
    if(pending_st) {                                /* 0x06: the next phase's request */
      const uint8_t p = pending_st;
      pending_st = 0;
      raise_int(p, 0x10);
    }
    return st;
  }
  if(sasr == WD_DATA && pio_dbr && pio_in) {        /* 0x06 path: a PIO byte in */
    const uint8_t b = (pio_pos < pio.size()) ? pio[pio_pos] : 0;
    pio_pos++;
    if(pio_pos >= pio.size()) {
      pio_done();
    }
    return b;                                       /* the data register does not advance */
  }
  uint8_t r = regs[sasr];
  SPRINTF("sgi_scsi: pio_r reg=%02x -> %02x\n", (unsigned)sasr, r);
  sasr = (sasr + 1) & 0x1f;
  return r;
}

/* ---- HPC3 DMA data byte port (driven by the data-phase FSM) --------------- */

uint8_t sgi_scsi::dma_r() {
  switch(phase) {
  case PH_DATA_IN: {
    if(pos >= buf.size()) return 0;
    uint8_t b = buf[pos++];
    if(pos >= buf.size()) finish();
    return b;
  }
  default:
    return 0;
  }
}

void sgi_scsi::dma_w(uint8_t v) {
  switch(phase) {
  case PH_DATA_OUT:
    if(pos >= buf.size()) return;
    buf[pos++] = v;
    if(pos >= buf.size()) finish();
    break;
  default:
    break;
  }
}
