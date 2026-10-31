#ifndef __SGI_NEWPORT_HH__
#define __SGI_NEWPORT_HH__

#include <cstdint>
#include <cstddef>
#include <vector>
#include <unordered_map>

struct state_t;
class newport_sdl;

/* SGI Newport (XL8/XL24) graphics: REX3 raster engine at GIO graphics-slot offset
 * 0xf0000 (PA 0x1f0f0000-0x1f0f1fff), plus the chips behind its Display Control
 * Bus -- VC2 (timing/cursor/DID tables), XMAP9 (mode table), CMAP (palette), the
 * Bt445 RAMDAC gamma LUT -- and the RB2 framebuffer.  A condensed port of MAME's
 * src/devices/bus/gio64/newport.cpp (BSD-3-Clause, Ryan Holtz): same register
 * semantics, all draws complete instantly, FIFOs are always empty.  The host
 * framebuffer is presented by newport_sdl (if built with SDL) and/or dumped as a
 * PPM (NEWPORT_PPM=<path>). */
class sgi_newport {
public:
  uint64_t display_gen() const { return disp_gen; }   /* see disp_gen */
  /* the guest's hardware cursor (VC2): image spans [cursor_x-31, cursor_x] */
  void cursor_pos(int &x, int &y) const { x = vc2.cursor_x; y = vc2.cursor_y; }
  static const uint32_t BASE = 0x1f0f0000u;
  static const uint32_t SIZE = 0x2000u;
  static const uint32_t FB_W = 1280 + 64;     /* RB2 line pitch (pixels) */
  static const uint32_t FB_H = 1024 + 64;
  static const uint32_t DISP_W = 1280;
  static const uint32_t DISP_H = 1024;

  sgi_newport(state_t *s);
  ~sgi_newport();
  /* offs = pa - BASE; values are in guest memory order (the cpu load/store path
   * byte-swaps), like the other device models. */
  uint64_t read(uint32_t offs, size_t sz);
  void write(uint32_t offs, uint64_t v, size_t sz);
  void vblank(uint64_t icnt);
  /* INT3 local1 RETRACE (0x80) level, cleared by a REX3 STATUS read */
  uint8_t local1_bits() const { return vrint_line ? 0x80 : 0x00; }
  /* render the visible 1280x1024 frame as 0x00RRGGBB */
  void render(uint32_t *dst);
  void dump_ppm(const char *path);
  void attach_display(newport_sdl *d) { disp = d; }
  /* NEWPORT_TRACE=<file>: binary trace of every board access, GO command and MC
   * graphics-DMA transfer; one packed 24-byte trace_rec_t each (see sgi_newport.cc) */
  static void trace_dma(uint64_t icnt, bool to_host, uint32_t gio, uint32_t bytes);
  void set_in_dma(bool on) { in_dma = on; }

  /* per-GO draw capture (NEWPORT_DRAWCAP=<file>, zstd-compressed record stream; format
   * in sgi_newport.cc) and the hooks the per-GO replayer (tools/np_goreplay) uses */
  struct rb_snap_t {
    uint32_t global_mask, write_mask;
    uint8_t blend, fast_clear, plane_enable, draw_depth, logicop, src_shift, dest_aux, pad;
  };
  struct touch_t {
    uint32_t addr;          /* word index, bit 31 = cidaux buffer */
    uint32_t old_v, new_v;
  };
  static size_t rex_size();
  void get_state(uint8_t *rex_out, rb_snap_t *rb_out) const;
  void set_state(const uint8_t *rex_in, const rb_snap_t &rb_in);
  void run_go() { do_command(); }
  /* pre-decoded packet prototype (tools/np_pack, tools/np_packplay): the decoded REX3
   * state as words, the RB2 control state, and a hook called as each GO starts */
  uint32_t *rex_words() { return reinterpret_cast<uint32_t *>(&rex); }
  void set_rb(const rb_snap_t &r);
  static void (*go_hook)(sgi_newport *np);
  uint32_t *fb_word(uint32_t addr) { return ((addr >> 31) ? rb.cidaux : rb.rgbci) + (addr & 0x7fffffffu); }
  uint64_t last_go_pixels() const { return go_pixels; }
  /* touch tracking: every framebuffer word read or written, first-touch pre-image */
  void touch_begin() { touching = true; touched.clear(); touched_idx.clear(); }
  const std::vector<touch_t> &touch_end();
private:
  struct xmap9_t {
    uint32_t config = 0, revision = 0, cursor_cmap = 0, popup_cmap = 0, mode_idx = 0;
    uint32_t mode[0x20] = {0};
    uint32_t read(uint32_t r);
    void write(uint32_t r, uint32_t d);
  };
  struct cmap_t {
    uint32_t status = 8, revision = 0;
    uint16_t idx = 0;
    uint32_t *pal = nullptr;   /* 0x10000 entries, 0x00RRGGBB */
    uint32_t read(uint32_t r);
    void write(uint32_t r, uint32_t d);
  };
  struct vc2_t {
    uint16_t vid_entry = 0, cursor_entry = 0, cursor_x = 0, cursor_y = 0, cur_cursor_x = 0;
    uint16_t did_entry = 0, scanline_len = 0, ram_addr = 0, vt_frame_ptr = 0, vt_line_ptr = 0;
    uint16_t vt_line_run = 0, vt_line_count = 0, cursor_table_ptr = 0, work_cursor_y = 0;
    uint16_t did_frame_ptr = 0, did_line_ptr = 0, display_ctrl = 0, config = 0;
    uint8_t reg_idx = 0;
    uint16_t *ram = nullptr;   /* 0x8000 words */
    int readout_y0 = 0, readout_y1 = 0;
    bool cursor_on = false;
    uint32_t read(uint32_t r);
    void write(uint32_t r, uint32_t d, uint32_t mask);
    void update_screen_size();
    uint8_t cursor_pixel(int x, int y);
  };
  struct rex3_t {
    uint32_t draw_mode0, draw_mode1;
    bool color_host, rwpacked, rwdouble, blend_back;
    uint8_t plane_enable, plane_depth, hostdepth, sfactor, dfactor;
    uint32_t host_shift, ls_mode, ls_pattern, ls_pattern_saved, z_pattern;
    uint32_t color_back, color_vram, alpha_ref, setup, step_z;
    int32_t x_start, y_start, x_end, y_end;
    int16_t x_start_frac, y_start_frac, x_end_frac, y_end_frac, x_save;
    uint32_t xy_move;
    int16_t x_move, y_move;
    uint32_t bres_d, bres_s1, bres_octant_inc1, bres_round_inc2, bres_e1, bres_s2;
    uint32_t a_weight0, a_weight1, x_start_f, y_start_f, x_end_f, y_end_f;
    int16_t x_start_i, y_start_i, x_end_i, y_end_i;
    uint32_t xy_start_i, xy_end_i, x_start_end_i;
    uint32_t color_red, color_alpha, color_green, color_blue;
    uint32_t curr_red, curr_alpha, curr_green, curr_blue;
    int32_t slope_red, slope_alpha, slope_green, slope_blue;
    uint32_t write_mask, color_i, zero_overflow;
    uint64_t host_dataport;
    uint32_t dcb_mode, dcb_reg_select, dcb_slave_select, dcb_data_msw, dcb_data_lsw, dcb_mask;
    uint32_t smask_x[5], smask_y[5];
    uint32_t top_scanline, xy_window;
    int16_t x_window, y_window;
    uint32_t clip_mode, config, status;
  };
  /* RB2 framebuffer state, derived from draw_mode1 / write_mask */
  struct rb2_t {
    uint32_t global_mask = 0xff, write_mask = 0;
    bool blend = false, fast_clear = false;
    uint8_t plane_enable = 0, draw_depth = 0, logicop = 0, src_shift = 0;
    uint32_t *rgbci = nullptr, *cidaux = nullptr, *dest = nullptr, *ptr = nullptr;
  };

  state_t *s;
  newport_sdl *disp = nullptr;
  rex3_t rex;
  rb2_t rb;
  xmap9_t xmap[2];
  cmap_t cmap[2];
  vc2_t vc2;
  uint32_t lut_r[256], lut_g[256], lut_b[256];
  uint8_t lut_idx = 0;
  bool vrint_line = false;
  uint64_t next_vblank = 0;
  uint64_t vblank_period = 0;
  uint64_t nframes = 0;
  /* bumped on every guest/DMA write to the board (REX3, DCB: cmap/xmap/vc2 cursor)
   * and on state restore: the display can only change when this moves */
  uint64_t disp_gen = 0;
  uint32_t backbusy_reads = 0;   /* STATUS reads until an absent-slave DCB access clears BACKBUSY */
  bool in_dma = false;            /* accesses come from the MC graphics DMA engine */
  uint64_t go_pixels = 0;         /* pixels produced by the stepper (trace) */
  bool touching = false;
  std::vector<touch_t> touched;
  std::unordered_map<uint32_t, uint32_t> touched_idx;
  void touch_note(const uint32_t *p);
  void drawcap_checksum();

  uint64_t rex3_r(uint32_t line, bool hi, bool lo);
  void rex3_w(uint32_t line, uint64_t data, uint64_t mask, bool hi, bool lo);
  void dcb_write(uint32_t data);
  uint32_t dcb_read();
  /* rb2 */
  void rb_set_flags(uint32_t mode1);
  void rb_set_addr(uint32_t a) { rb.ptr = &rb.dest[a]; }
  uint32_t rb_read() {
    if(touching) {
      touch_note(rb.ptr);
    }
    return *rb.ptr >> rb.src_shift;
  }
  void rb_write(uint32_t v);
  /* the bits a plane target owns in its buffer word: RB2 aux per byte is CID [1:0],
   * popup [3:2], CID [5:4], popup [7:6], overlay bytes [15:8] and [23:16].  A popup
   * write is replicated across lanes like any 8-bit write, so without this its copies
   * land in the overlay byte (a black overlay bar over a window). */
  uint32_t plane_mask() const {
    switch(rb.plane_enable)
      {
      case 4: return 0x00ffff00u;
      case 5: return 0x000000ccu;
      case 6: return 0x00000033u;
      default: return 0x00ffffffu;
      }
  }
  void rb_store(uint32_t v) {
    if(touching) {
      touch_note(rb.ptr);
    }
    const uint32_t m = rb.write_mask & rb.global_mask & plane_mask();
    *rb.ptr = (*rb.ptr & ~m) | (v & m);
  }
  /* rex3 drawing */
  void write_x_start(int32_t v);
  void write_y_start(int32_t v);
  void write_x_end(int32_t v);
  void write_y_end(int32_t v);
  bool clip_pass(int16_t x, int16_t y);
  void output_pixel(int16_t x, int16_t y, uint32_t color);
  void blend_pixel(uint32_t src);
  void iterate_shade();
  uint32_t default_color(uint32_t src);
  uint32_t host_color();
  uint32_t rgb_color(int16_t x, int16_t y);
  uint32_t rgb_from(uint32_t cr, uint32_t cg, uint32_t cb, uint32_t ca, int16_t x, int16_t y);
  bool span_fast(int16_t &start_x, int16_t y, int16_t prim_end_x, int16_t end_x, bool stop_on_x, uint32_t pattern,
                 bool opaque, bool shade, bool rgbmode, bool fastclear, uint32_t color);
  uint32_t convert_depth(uint32_t c, uint8_t from, uint8_t to);
  void do_setup();
  void do_fline(uint32_t color);
  void do_iline(uint32_t color);
  uint32_t do_pixel_read();
  uint64_t do_pixel_word_read();
  void do_command();
  void do_command_timed();
  void do_command_body(uint8_t opcode, uint8_t adrmode);
  void span_or_block(bool block);
  void scr2scr();
};

#ifdef NP_PROF
/* replay-tool profiling ticks (cntvct_el0 / TSC); see sgi_newport.cc */
static inline uint64_t np_ticks() {
#if defined(__aarch64__)
  uint64_t v;
  asm volatile("isb; mrs %0, cntvct_el0" : "=r"(v));
  return v;
#else
  return __builtin_ia32_rdtsc();
#endif
}
extern uint64_t g_np_prof_cmd, g_np_prof_pix, g_np_prof_rows;
#endif

/* out of line: the per-instruction check is just icnt >= s->gfx_next_icnt */
void newport_retrace(state_t *s) __attribute__((noinline));

#endif
