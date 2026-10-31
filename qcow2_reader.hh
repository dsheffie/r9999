#ifndef __QCOW2_READER_HH__
#define __QCOW2_READER_HH__

#include <cstdint>
#include <cstddef>
#include <vector>

/*
 * Minimal read-only QCOW2 (v2/v3) backing reader.
 *
 * The transport win over a sparse raw image is that a qcow2's holes live in the
 * *format* (unallocated L1/L2 entries + the v3 all-zeroes bit), not in the host
 * filesystem -- so a dumb byte-for-byte copy (cp, Blob, HTTP range) preserves
 * sparseness without any FS/tool cooperation.  We only need to READ the active
 * L1 mapping: writes in the sim go to sgi_scsi's COW overlay / --disk-delta, so
 * the qcow2 base stays pristine and we never allocate a cluster.
 *
 * Supported: unallocated clusters, the v3 zero cluster, and normal uncompressed
 * clusters.  NOT supported (open() fails with a clear stderr message): encryption,
 * a backing-file chain, external data files, extended L2 entries, and compressed
 * (-c) clusters.  Convert such an image with:
 *   qemu-img convert -O qcow2 in.img out.qcow2   (no -c; sparse, uncompressed)
 */
class qcow2_reader {
public:
  qcow2_reader() = default;

  /* Parse the qcow2 header + L1 table on an already-open fd (owned by the caller).
   * Returns true on a supported image; false (with a stderr reason) otherwise.
   * Only call when the file's first 4 bytes are the qcow2 magic (see is_magic). */
  bool open(int fd);
  static bool is_magic(const uint8_t *first4);

  uint64_t virtual_size() const { return v_size; }   /* guest disk size in bytes */

  /* Read exactly 512 bytes of the guest image at block `lba`; holes read as zero.
   * A 512-byte block never straddles a cluster boundary (cluster_size is a power
   * of two >= 512), so each maps to a single L2 lookup. */
  void read_block(uint64_t lba, uint8_t *dst);

private:
  int fd = -1;
  uint32_t cluster_bits = 0;
  uint64_t cluster_size = 0;
  uint64_t v_size = 0;
  uint32_t l1_size = 0;
  uint32_t l2_bits = 0;              /* log2(entries per L2 table) = cluster_bits - 3 */
  std::vector<uint64_t> l1;          /* active L1 table, host byte order */
  bool warned_compressed = false;    /* one-shot: hit an unexpected compressed cluster */

  bool read_be64(uint64_t off, uint64_t *out);
};

#endif
