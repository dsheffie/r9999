#ifndef __CHD_READER_HH__
#define __CHD_READER_HH__

#include <cstdint>
#include <cstddef>
#include <cstdio>
#include <vector>

/*
 * Minimal read-only MAME CHD (Compressed Hunks of Data) backing reader, wrapping
 * the vendored libchdr (see ./libchdr).  Like qcow2_reader it sits UNDER sgi_scsi
 * as a read-only base image: guest writes land in sgi_scsi's COW overlay, so the
 * CHD file is never modified and we only ever read hunks.  libchdr decodes every
 * hard-disk codec (none / zlib / lzma / zstd / huffman), so an uncompressed CHD
 * and a compressed one both work -- the exact codec is the CHD's business.
 *
 * Only call open() when the first 8 bytes are the CHD magic (see is_magic).
 */
struct _chd_file;   /* opaque libchdr handle; chd.h does `typedef struct _chd_file chd_file` */

class chd_reader {
public:
  chd_reader() = default;
  ~chd_reader();

  /* Open an already-open fd (owned by the caller: we dup() it for libchdr and
   * close only our own dup).  Returns true on a supported image; false (with a
   * stderr reason) otherwise. */
  bool open(int fd);
  static bool is_magic(const uint8_t *first8);        /* "MComprHD" */

  uint64_t virtual_size() const { return v_size; }    /* guest disk size in bytes */

  /* Read exactly 512 bytes of the guest image at block `lba`; reads past the end
   * come back zero.  A 512-byte block never straddles a hunk (hunkbytes is a
   * multiple of 512), so each maps to a single hunk + offset. */
  void read_block(uint64_t lba, uint8_t *dst);

private:
  struct _chd_file *chd = nullptr;    /* libchdr chd_file* (opaque here) */
  FILE *fp = nullptr;                 /* our dup'd FILE*; libchdr is a non-owner */
  uint64_t v_size = 0;
  uint32_t hunkbytes = 0;
  uint32_t secs_per_hunk = 0;
  uint64_t total_hunks = 0;
  uint64_t cached_hunk = ~0ULL;       /* which hunk hunkbuf currently holds */
  std::vector<uint8_t> hunkbuf;
};

#endif
