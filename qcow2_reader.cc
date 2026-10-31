#include "qcow2_reader.hh"
#include <cstdio>
#include <cstring>
#include <unistd.h>

/* qcow2 header layout (all big-endian), common to v2 and v3.  We read the fields
 * by explicit offset rather than a packed struct so there's no alignment/padding
 * question and the endianness swap is in one place. */
enum {
  QC_MAGIC                = 0x514649fbu,   /* "QFI\xfb" */
  OFF_MAGIC               = 0x00,
  OFF_VERSION             = 0x04,
  OFF_BACKING_FILE_OFFSET = 0x08,
  OFF_BACKING_FILE_SIZE   = 0x10,
  OFF_CLUSTER_BITS        = 0x14,
  OFF_SIZE                = 0x18,
  OFF_CRYPT_METHOD        = 0x20,
  OFF_L1_SIZE             = 0x24,
  OFF_L1_TABLE_OFFSET     = 0x28,
  OFF_INCOMPAT_FEATURES   = 0x48,          /* v3 only */
};

/* incompatible feature bits we must honour (v3) */
enum {
  INCOMPAT_EXTERNAL_DATA = 1u << 2,        /* guest data lives in another file */
  INCOMPAT_EXTENDED_L2   = 1u << 4,        /* 16-byte L2 entries (we assume 8) */
  INCOMPAT_KNOWN_MASK    = (1u << 0) | (1u << 1) | (1u << 2) | (1u << 3) | (1u << 4),
};

/* L1/L2 entry masks (QCOW2 spec): the cluster host offset is bits [9:55]. */
static const uint64_t OFFSET_MASK   = 0x00fffffffffffe00ull;
static const uint64_t L2E_COMPRESSED = 1ull << 62;
static const uint64_t L2E_ZERO       = 1ull << 0;   /* v3 "all zeroes" std cluster */

bool qcow2_reader::is_magic(const uint8_t *first4) {
  return first4[0] == 0x51 && first4[1] == 0x46 && first4[2] == 0x49 && first4[3] == 0xfb;
}

/* read a big-endian 64-bit word from the image at byte offset `off` */
bool qcow2_reader::read_be64(uint64_t off, uint64_t *out) {
  uint8_t b[8];
  if(pread(fd, b, 8, (off_t)off) != 8) {
    return false;
  }
  *out = ((uint64_t)b[0] << 56) | ((uint64_t)b[1] << 48) | ((uint64_t)b[2] << 40) |
         ((uint64_t)b[3] << 32) | ((uint64_t)b[4] << 24) | ((uint64_t)b[5] << 16) |
         ((uint64_t)b[6] << 8)  |  (uint64_t)b[7];
  return true;
}

bool qcow2_reader::open(int fd_) {
  fd = fd_;
  uint8_t hdr[0x50];
  if(pread(fd, hdr, sizeof(hdr), 0) != (ssize_t)sizeof(hdr)) {
    fprintf(stderr, "qcow2: short read on header\n");
    return false;
  }
  auto be32 = [&](int o) -> uint32_t {
    return ((uint32_t)hdr[o] << 24) | ((uint32_t)hdr[o+1] << 16) |
           ((uint32_t)hdr[o+2] << 8) | (uint32_t)hdr[o+3];
  };
  auto be64 = [&](int o) -> uint64_t {
    return ((uint64_t)be32(o) << 32) | (uint64_t)be32(o + 4);
  };

  if(be32(OFF_MAGIC) != QC_MAGIC) {
    fprintf(stderr, "qcow2: bad magic\n");
    return false;
  }
  uint32_t version = be32(OFF_VERSION);
  if(version != 2 && version != 3) {
    fprintf(stderr, "qcow2: unsupported version %u (need 2 or 3)\n", version);
    return false;
  }
  if(be32(OFF_CRYPT_METHOD) != 0) {
    fprintf(stderr, "qcow2: encrypted images are not supported\n");
    return false;
  }
  if(be64(OFF_BACKING_FILE_OFFSET) != 0 || be32(OFF_BACKING_FILE_SIZE) != 0) {
    fprintf(stderr, "qcow2: backing-file chains are not supported "
                    "(flatten with: qemu-img convert -O qcow2 in.qcow2 out.qcow2)\n");
    return false;
  }
  if(version >= 3) {
    uint64_t incompat = be64(OFF_INCOMPAT_FEATURES);
    if(incompat & INCOMPAT_EXTERNAL_DATA) {
      fprintf(stderr, "qcow2: external data files are not supported\n");
      return false;
    }
    if(incompat & INCOMPAT_EXTENDED_L2) {
      fprintf(stderr, "qcow2: extended L2 entries are not supported\n");
      return false;
    }
    if(incompat & ~(uint64_t)INCOMPAT_KNOWN_MASK) {
      fprintf(stderr, "qcow2: unknown incompatible feature bits 0x%llx\n",
              (unsigned long long)(incompat & ~(uint64_t)INCOMPAT_KNOWN_MASK));
      return false;
    }
  }

  cluster_bits = be32(OFF_CLUSTER_BITS);
  if(cluster_bits < 9 || cluster_bits > 30) {
    fprintf(stderr, "qcow2: implausible cluster_bits %u\n", cluster_bits);
    return false;
  }
  cluster_size = 1ull << cluster_bits;
  l2_bits = cluster_bits - 3;            /* 8 bytes per L2 entry */
  v_size = be64(OFF_SIZE);
  l1_size = be32(OFF_L1_SIZE);
  uint64_t l1_off = be64(OFF_L1_TABLE_OFFSET);

  /* load the active L1 table into memory (tiny: one entry maps cluster_size*2^l2_bits
   * of guest space, e.g. 512 MiB with 64 KiB clusters, so a 20 GiB disk is ~40 words) */
  l1.resize(l1_size);
  for(uint32_t i = 0; i < l1_size; i++) {
    if(!read_be64(l1_off + (uint64_t)i * 8, &l1[i])) {
      fprintf(stderr, "qcow2: short read on L1 table\n");
      return false;
    }
  }
  return true;
}

void qcow2_reader::read_block(uint64_t lba, uint8_t *dst) {
  const uint64_t guest_off = lba * 512;
  if(guest_off >= v_size) {
    memset(dst, 0, 512);
    return;
  }
  const uint64_t off_in_cluster = guest_off & (cluster_size - 1);
  const uint64_t cluster_idx    = guest_off >> cluster_bits;
  const uint64_t l1_index       = cluster_idx >> l2_bits;
  const uint64_t l2_index       = cluster_idx & ((1ull << l2_bits) - 1);

  if(l1_index >= l1_size) {                 /* beyond the mapped range -> hole */
    memset(dst, 0, 512);
    return;
  }
  const uint64_t l2_off = l1[l1_index] & OFFSET_MASK;
  if(l2_off == 0) {                         /* unallocated L2 table -> hole */
    memset(dst, 0, 512);
    return;
  }
  uint64_t l2e;
  if(!read_be64(l2_off + l2_index * 8, &l2e)) {
    memset(dst, 0, 512);
    return;
  }
  if(l2e & L2E_COMPRESSED) {                /* -c image: unsupported, zero-fill once-warned */
    if(!warned_compressed) {
      fprintf(stderr, "qcow2: compressed cluster encountered -- not supported; "
                      "reconvert without -c (qemu-img convert -O qcow2 ...)\n");
      warned_compressed = true;
    }
    memset(dst, 0, 512);
    return;
  }
  const uint64_t host_off = l2e & OFFSET_MASK;
  if((l2e & L2E_ZERO) || host_off == 0) {   /* zero cluster / unallocated -> hole */
    memset(dst, 0, 512);
    return;
  }
  if(pread(fd, dst, 512, (off_t)(host_off + off_in_cluster)) != 512) {
    memset(dst, 0, 512);
  }
}
