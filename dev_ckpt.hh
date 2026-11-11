#ifndef __DEV_CKPT_HH__
#define __DEV_CKPT_HH__
/* Device-state serialization for full-system checkpoints (saveState.cc writes it,
 * indysim --restore and r9999 ooo_core --checkpoint read it).  ONE field list per
 * device (its ckpt() method) serves both directions, so save and load cannot drift.
 * The SAME file and the SAME ckpt() bodies are copied into r9999 (whose device
 * models are a fork of these): a field one fork has and the other lacks is not
 * serialized and keeps its constructor default.  Host byte order, no padding. */
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <vector>
#include <unordered_map>

class ckpt_io {
  FILE *fp;
public:
  const bool saving;
  ckpt_io(FILE *fp, bool saving) : fp(fp), saving(saving) {}
  void bytes(void *p, size_t n) {
    const size_t r = saving ? fwrite(p, 1, n, fp) : fread(p, 1, n, fp);
    if(r != n) {
      fprintf(stderr, "ckpt_io: short %s (%zu of %zu bytes)\n", saving ? "write" : "read", r, n);
      exit(1);
    }
  }
  /* any trivially-copyable scalar, enum, array or struct */
  template <typename T> void io(T &x) {
    bytes(&x, sizeof(T));
  }
  void io(std::vector<uint8_t> &v) {
    uint64_t n = v.size();
    io(n);
    v.resize(n);
    if(n) {
      bytes(v.data(), n);
    }
  }
  void io(std::deque<std::vector<uint8_t>> &q) {
    uint64_t n = q.size();
    io(n);
    q.resize(n);
    for(auto &v : q) {
      io(v);
    }
  }
  void io(std::unordered_map<uint64_t, std::vector<uint8_t>> &m) {
    uint64_t n = m.size();
    io(n);
    if(saving) {
      for(auto &kv : m) {
        uint64_t k = kv.first;
        io(k);
        io(kv.second);
      }
    }
    else {
      m.clear();
      for(uint64_t i = 0; i < n; i++) {
        uint64_t k = 0;
        io(k);
        io(m[k]);
      }
    }
  }
  /* a section marker: catches a save/load field-list mismatch at the device it occurs in */
  void tag(uint32_t t) {
    uint32_t x = t;
    io(x);
    if(x != t) {
      fprintf(stderr, "ckpt_io: device section tag %08x, expected %08x (field lists differ?)\n", x, t);
      exit(1);
    }
  }
};

#endif
