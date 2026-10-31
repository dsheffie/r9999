#ifndef __sparse_mem_hh__
#define __sparse_mem_hh__

#include <cstdlib>
#include <cassert>
#include <cstring>
#include <cstdint>


#include <map>

#include "sim_bitvec.hh"
#include "helper.hh"

#ifndef unlikely
#define unlikely(x)    __builtin_expect(!!(x), 0)
#endif

class sparse_mem {
public:
  static const uint64_t pgsize = 4096;
  static const uint64_t sz = 1UL<<32;
  uint8_t *mem = nullptr;
  /* IP22 System Memory Alias: the low 512 KB of the physical map mirrors the base
   * of main DRAM at 0x08000000, so kseg0 exception vectors (PA 0x0/0x180) and the
   * SPB/romvec staged at PA 0x1000 reach the DRAM the kernel sees at 0x08000000.
   * OFF by default (ooo_core randgen is flat, self-consistent); the henry_tb golden
   * ISS enables it so it reads the real handler, matching the RTL MC + interp_mips. */
  bool route_devices = false;
  /* the base of main memory the alias mirrors: 0x08000000 on IP22, 0x20000000 on IP28
   * (ooo_core --ip28 sets it on the checker ISS, as top.cc's ip28_mem_pa does for the RTL) */
  uint64_t alias_base = 0x08000000UL;
  inline uint64_t mc_alias(uint64_t pa) const {
    return (pa < 0x00080000UL) ? (pa + alias_base) : pa;
  }
public:
  sparse_mem();
  ~sparse_mem();
  void clear();

  uint8_t * operator[](uint64_t addr) {
    return &mem[addr];
  }
  uint8_t * operator+(uint64_t disp) {
    return (*this)[disp];
  }
  bool compare(const sparse_mem &other, bool verbose = false) {
    bool error = false;
    for(uint64_t b = 0; b < sz; ++b) {
      if(mem[b] != other.mem[b]) {
	error = true;
	if(verbose) {
	  std::cout << "byte " << std::hex << b
		    << " differs "
		    << static_cast<int>(mem[b])
		    << " vs "
		    << static_cast<int>(other.mem[b])
		    << std::dec
		    << "\n";
	}
      }
    }
    return error;
  }
  uint8_t *get_raw_ptr(uint64_t byte_addr) {
    byte_addr &= ((1UL<<32) - 1);
    if(route_devices) byte_addr = mc_alias(byte_addr);
    return mem+byte_addr;
  }
  /* indysim's read-only DMA accessor (the device models use it); r9999 has no decode
   * cache to keep coherent, so it is get_raw_ptr */
  uint8_t *peek_raw_ptr(uint64_t byte_addr) {
    return get_raw_ptr(byte_addr);
  }
  template <typename T>
  T get(uint64_t byte_addr) {
    if(route_devices) byte_addr = mc_alias(byte_addr);
    assert(byte_addr < 1UL<<32);
    return *reinterpret_cast<T*>(mem+byte_addr);
  }
  template<typename T>
  void set(uint64_t byte_addr, T v) {
    //static_assert(sizeof(T) != 8);
    if(route_devices) byte_addr = mc_alias(byte_addr);
    assert(byte_addr < 1UL<<32);
    *reinterpret_cast<T*>(mem+byte_addr) = v;
  }
  uint64_t bytes_allocated() const {
    return sz;
  }
};



#endif
