/* sgi_ps2.cc -- IP22 8042 PS/2 controller + AT keyboard + PS/2 mouse (see header). */
#include <fcntl.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include "sgi_ps2.hh"
#include "sgi_newport.hh"
#include "interpret.hh"

static const bool g_ps2_log = getenv("PS2_LOG") != nullptr;

/* key name -> {set 1, set 2, set 3} make codes; ext = E0-prefixed in sets 1/2 */
struct key_code_t {
  const char *name;
  uint8_t s1, s2, s3;
  bool ext;
};
static const key_code_t g_keys[] = {
  {"a", 0x1e, 0x1c, 0x1c, false}, {"b", 0x30, 0x32, 0x32, false}, {"c", 0x2e, 0x21, 0x21, false},
  {"d", 0x20, 0x23, 0x23, false}, {"e", 0x12, 0x24, 0x24, false}, {"f", 0x21, 0x2b, 0x2b, false},
  {"g", 0x22, 0x34, 0x34, false}, {"h", 0x23, 0x33, 0x33, false}, {"i", 0x17, 0x43, 0x43, false},
  {"j", 0x24, 0x3b, 0x3b, false}, {"k", 0x25, 0x42, 0x42, false}, {"l", 0x26, 0x4b, 0x4b, false},
  {"m", 0x32, 0x3a, 0x3a, false}, {"n", 0x31, 0x31, 0x31, false}, {"o", 0x18, 0x44, 0x44, false},
  {"p", 0x19, 0x4d, 0x4d, false}, {"q", 0x10, 0x15, 0x15, false}, {"r", 0x13, 0x2d, 0x2d, false},
  {"s", 0x1f, 0x1b, 0x1b, false}, {"t", 0x14, 0x2c, 0x2c, false}, {"u", 0x16, 0x3c, 0x3c, false},
  {"v", 0x2f, 0x2a, 0x2a, false}, {"w", 0x11, 0x1d, 0x1d, false}, {"x", 0x2d, 0x22, 0x22, false},
  {"y", 0x15, 0x35, 0x35, false}, {"z", 0x2c, 0x1a, 0x1a, false},
  {"1", 0x02, 0x16, 0x16, false}, {"2", 0x03, 0x1e, 0x1e, false}, {"3", 0x04, 0x26, 0x26, false},
  {"4", 0x05, 0x25, 0x25, false}, {"5", 0x06, 0x2e, 0x2e, false}, {"6", 0x07, 0x36, 0x36, false},
  {"7", 0x08, 0x3d, 0x3d, false}, {"8", 0x09, 0x3e, 0x3e, false}, {"9", 0x0a, 0x46, 0x46, false},
  {"0", 0x0b, 0x45, 0x45, false},
  {"-", 0x0c, 0x4e, 0x4e, false}, {"=", 0x0d, 0x55, 0x55, false}, {"[", 0x1a, 0x54, 0x54, false},
  {"]", 0x1b, 0x5b, 0x5b, false}, {"\\", 0x2b, 0x5d, 0x5c, false}, {";", 0x27, 0x4c, 0x4c, false},
  {"'", 0x28, 0x52, 0x52, false}, {"`", 0x29, 0x0e, 0x0e, false}, {",", 0x33, 0x41, 0x41, false},
  {".", 0x34, 0x49, 0x49, false}, {"/", 0x35, 0x4a, 0x4a, false},
  {"esc", 0x01, 0x76, 0x08, false}, {"backspace", 0x0e, 0x66, 0x66, false}, {"tab", 0x0f, 0x0d, 0x0d, false},
  {"enter", 0x1c, 0x5a, 0x5a, false}, {"space", 0x39, 0x29, 0x29, false}, {"capslock", 0x3a, 0x58, 0x14, false},
  {"shift", 0x2a, 0x12, 0x12, false}, {"rshift", 0x36, 0x59, 0x59, false},
  {"ctrl", 0x1d, 0x14, 0x11, false}, {"alt", 0x38, 0x11, 0x19, false},
  {"f1", 0x3b, 0x05, 0x07, false}, {"f2", 0x3c, 0x06, 0x0f, false}, {"f3", 0x3d, 0x04, 0x17, false},
  {"f4", 0x3e, 0x0c, 0x1f, false}, {"f5", 0x3f, 0x03, 0x27, false}, {"f6", 0x40, 0x0b, 0x2f, false},
  {"f7", 0x41, 0x83, 0x37, false}, {"f8", 0x42, 0x0a, 0x3f, false}, {"f9", 0x43, 0x01, 0x47, false},
  {"f10", 0x44, 0x09, 0x4f, false}, {"f11", 0x57, 0x78, 0x56, false}, {"f12", 0x58, 0x07, 0x5e, false},
  {"up", 0x48, 0x75, 0x63, true}, {"down", 0x50, 0x72, 0x60, true},
  {"left", 0x4b, 0x6b, 0x61, true}, {"right", 0x4d, 0x74, 0x6a, true},
  {"home", 0x47, 0x6c, 0x6e, true}, {"end", 0x4f, 0x69, 0x65, true},
  {"pgup", 0x49, 0x7d, 0x6f, true}, {"pgdn", 0x51, 0x7a, 0x6d, true},
  {"insert", 0x52, 0x70, 0x67, true}, {"delete", 0x53, 0x71, 0x64, true},
};

static const key_code_t *find_key(const std::string &n) {
  for(const auto &k : g_keys) {
    if(n == k.name) {
      return &k;
    }
  }
  return nullptr;
}

sgi_ps2::sgi_ps2(state_t *s) : s(s) {
  static const char *g_script = getenv("NEWPORT_INPUT");
  if(g_script) {
    load_script(g_script);
  }
  static const char *g_fifo = getenv("NEWPORT_INPUT_FIFO");
  if(g_fifo) {
    /* O_NONBLOCK so open() does not wait for a writer; our own (unused) writer keeps
     * the pipe from reading as EOF between commands */
    fifo_fd = ::open(g_fifo, O_RDONLY | O_NONBLOCK);
    fifo_keepalive = ::open(g_fifo, O_WRONLY | O_NONBLOCK);
    if(fifo_fd < 0) {
      fprintf(stderr, "[ps2] cannot open input fifo %s (create it with mkfifo)\n", g_fifo);
    }
    else {
      fprintf(stderr, "[ps2] live input fifo %s\n", g_fifo);
    }
  }
}

/* move the next queued byte into the output buffer (keyboard first) */
void sgi_ps2::refill() {
  if(obf) {
    return;
  }
  if(!ctl_q.empty()) {
    /* the 8042's own replies reach the output buffer even with both ports disabled
     * (Linux reads the command byte back right after disabling them) */
    out = ctl_q.front();
    ctl_q.pop_front();
    obf = true;
    aux_obf = false;
  }
  else if(!kbd_q.empty() && !(ccb & 0x10)) {
    out = kbd_q.front();
    kbd_q.pop_front();
    obf = true;
    aux_obf = false;
  }
  else if(!aux_q.empty() && !(ccb & 0x20)) {
    out = aux_q.front();
    aux_q.pop_front();
    obf = true;
    aux_obf = true;
  }
  if(obf && irq()) {
    s->irq_poke = true;
  }
}

uint8_t sgi_ps2::read(bool cmd_port) {
  if(cmd_port) {
    /* status: OBF, SYS(2), last write was a command(3), not inhibited(4), AUXB(5) */
    return (obf ? 0x01 : 0) | 0x04 | (last_was_cmd ? 0x08 : 0) | 0x10 | (aux_obf ? 0x20 : 0);
  }
  const uint8_t v = out;
  obf = false;
  aux_obf = false;
  refill();
  if(g_ps2_log) {
    fprintf(stderr, "[ps2] icnt=%llu data -> %02x\n", (unsigned long long)s->icnt, v);
  }
  return v;
}

void sgi_ps2::write(bool cmd_port, uint8_t v) {
  if(g_ps2_log) {
    fprintf(stderr, "[ps2] icnt=%llu %s <- %02x\n", (unsigned long long)s->icnt, cmd_port ? "cmd" : "data", v);
  }
  last_was_cmd = cmd_port;
  if(cmd_port) {
    ctl_cmd(v);
    refill();
    return;
  }
  const uint8_t pc = pending_cmd;
  pending_cmd = 0;
  switch(pc)
    {
    case 0x60: ccb = v; break;                 /* write command byte */
    case 0xd1: break;                          /* write output port: ignored */
    case 0xd2: kbd_q.push_back(v); break;      /* write kbd output buffer */
    case 0xd3: aux_q.push_back(v); break;      /* write aux output buffer */
    case 0xd4: aux_cmd(v); break;              /* to the mouse */
    default: kbd_cmd(v); break;                /* to the keyboard */
    }
  refill();
}

void sgi_ps2::ctl_cmd(uint8_t v) {
  switch(v)
    {
    case 0x20: ctl_q.push_back(ccb); break;    /* read command byte */
    case 0x60: case 0xd1: case 0xd2: case 0xd3: case 0xd4:
      pending_cmd = v;
      break;
    case 0xa7: ccb |= 0x20; break;             /* disable aux */
    case 0xa8: ccb &= ~0x20; break;            /* enable aux */
    case 0xa9: ctl_q.push_back(0x00); break;   /* aux interface test: ok */
    case 0xaa: ctl_q.push_back(0x55); break;   /* controller self test: ok */
    case 0xab: ctl_q.push_back(0x00); break;   /* kbd interface test: ok */
    case 0xad: ccb |= 0x10; break;             /* disable kbd */
    case 0xae: ccb &= ~0x10; break;            /* enable kbd */
    case 0xc0: ctl_q.push_back(0x00); break;   /* read input port */
    case 0xd0: ctl_q.push_back(0x01); break;   /* read output port */
    default: break;                            /* 0xfe reset pulse etc.: ignored */
    }
}

void sgi_ps2::kbd_cmd(uint8_t v) {
  const uint8_t arg_of = kbd_pending;
  kbd_pending = 0;
  if(arg_of != 0 && v < 0xed) {                /* argument byte of the previous command */
    if(arg_of == 0xf0) {
      if(v == 0) {
        kbd_q.push_back(0xfa);
        kbd_q.push_back(scan_set);
        return;
      }
      scan_set = v;
      if(g_ps2_log) {
        fprintf(stderr, "[ps2] keyboard scan code set %u\n", scan_set);
      }
    }
    if(arg_of == 0xfb || arg_of == 0xfc || arg_of == 0xfd) {
      kbd_pending = arg_of;                    /* set-3 per-key lists run until a command */
    }
    kbd_q.push_back(0xfa);
    return;
  }
  switch(v)
    {
    case 0xff:                                 /* reset: ack + BAT passed */
      scan_set = 2;
      kbd_enabled = true;
      kbd_q.push_back(0xfa);
      kbd_q.push_back(0xaa);
      break;
    case 0xf2:                                 /* identify: MF2 keyboard */
      kbd_q.push_back(0xfa);
      kbd_q.push_back(0xab);
      kbd_q.push_back(0x83);
      break;
    case 0xee: kbd_q.push_back(0xee); break;   /* echo */
    case 0xf4: kbd_enabled = true; kbd_q.push_back(0xfa); break;
    case 0xf5: kbd_enabled = false; kbd_q.push_back(0xfa); break;
    case 0xf6: kbd_enabled = true; kbd_q.push_back(0xfa); break;
    case 0xed: case 0xf0: case 0xf3: case 0xfb: case 0xfc: case 0xfd:
      kbd_pending = v;                         /* LEDs/scan set/typematic/set-3 key modes */
      kbd_q.push_back(0xfa);
      break;
    default:                                   /* f7-fa set-3 global modes, fe resend */
      kbd_q.push_back(0xfa);
      break;
    }
}

void sgi_ps2::aux_cmd(uint8_t v) {
  if(aux_pending != 0) {                       /* argument (sample rate / resolution) */
    aux_pending = 0;
    aux_q.push_back(0xfa);
    return;
  }
  switch(v)
    {
    case 0xff:                                 /* reset: ack, BAT passed, id 0 */
      aux_enabled = false;
      aux_q.push_back(0xfa);
      aux_q.push_back(0xaa);
      aux_q.push_back(0x00);
      break;
    case 0xf2:                                 /* identify: standard mouse */
      aux_q.push_back(0xfa);
      aux_q.push_back(0x00);
      break;
    case 0xf3: case 0xe8:
      aux_pending = v;
      aux_q.push_back(0xfa);
      break;
    case 0xf4: aux_enabled = true; aux_q.push_back(0xfa); break;
    case 0xf5: aux_enabled = false; aux_q.push_back(0xfa); break;
    case 0xf6: aux_enabled = false; aux_q.push_back(0xfa); break;
    case 0xe9:                                 /* status: stream, buttons, res 2, rate 100 */
      aux_q.push_back(0xfa);
      aux_q.push_back((aux_enabled ? 0x20 : 0) | (mouse_buttons & 7));
      aux_q.push_back(0x02);
      aux_q.push_back(0x64);
      break;
    case 0xeb:                                 /* read data: one empty packet */
      aux_q.push_back(0xfa);
      aux_q.push_back(0x08 | (mouse_buttons & 7));
      aux_q.push_back(0x00);
      aux_q.push_back(0x00);
      break;
    default:                                   /* e6/e7 scaling, ea stream, f0 remote, ... */
      aux_q.push_back(0xfa);
      break;
    }
}

/* ---------------- host input ---------------- */
bool sgi_ps2::key(const std::string &name, bool down) {
  const key_code_t *k = find_key(name);
  if(k == nullptr) {
    return false;
  }
  std::vector<uint8_t> b;
  const bool xlate = (ccb & 0x40) != 0 && scan_set == 2;
  if(scan_set == 3 && !xlate) {
    if(!down) {
      b.push_back(0xf0);
    }
    b.push_back(k->s3);
  }
  else if(xlate || scan_set == 1) {            /* controller translates to set 1 */
    if(k->ext) {
      b.push_back(0xe0);
    }
    b.push_back(down ? k->s1 : (uint8_t)(k->s1 | 0x80));
  }
  else {
    if(k->ext) {
      b.push_back(0xe0);
    }
    if(!down) {
      b.push_back(0xf0);
    }
    b.push_back(k->s2);
  }
  host_kbd.push_back(b);
  return true;
}

void sgi_ps2::mouse(int dx, int dy, uint8_t buttons) {
  /* coalesce: motion with unchanged buttons folds into the newest packet not yet
   * handed to the guest, so a slow guest handler never builds a backlog -- the cursor
   * goes straight to where the host pointer is now instead of replaying the path */
  if((buttons & 7) == mouse_buttons && !host_aux.empty() && host_aux.back().size() == 3) {
    std::vector<uint8_t> &q = host_aux.back();
    const int qx = (q[0] & 0x10) ? (int)q[1] - 256 : (int)q[1];
    const int qy = -((q[0] & 0x20) ? (int)q[2] - 256 : (int)q[2]);   /* back to host +y down */
    if((q[0] & 7) == mouse_buttons && qx + dx >= -255 && qx + dx <= 255 && qy + dy >= -255 && qy + dy <= 255) {
      const int px = qx + dx, my = -(qy + dy);
      q[0] = (uint8_t)(0x08 | mouse_buttons | (px < 0 ? 0x10 : 0) | (my < 0 ? 0x20 : 0));
      q[1] = (uint8_t)px;
      q[2] = (uint8_t)my;
      return;
    }
  }
  mouse_buttons = buttons & 7;
  do {                                         /* split into packets of at most +-255 */
    const int px = dx > 255 ? 255 : (dx < -255 ? -255 : dx);
    const int py = dy > 255 ? 255 : (dy < -255 ? -255 : dy);
    dx -= px;
    dy -= py;
    const int my = -py;                        /* PS/2 +y is up; host +y is down */
    std::vector<uint8_t> b;
    b.push_back((uint8_t)(0x08 | mouse_buttons | (px < 0 ? 0x10 : 0) | (my < 0 ? 0x20 : 0)));
    b.push_back((uint8_t)px);
    b.push_back((uint8_t)my);
    host_aux.push_back(b);
  } while(dx != 0 || dy != 0);
}

void sgi_ps2::add_script_line(const std::string &ln) {
  if(ln.empty() || ln[0] == '#') {
    return;
  }
  const size_t sp = ln.find(' ');
  script_line_t l;
  l.op = ln.substr(0, sp);
  l.arg = (sp == std::string::npos) ? "" : ln.substr(sp + 1);
  script.push_back(l);
}

void sgi_ps2::poll_fifo() {
  char buf[4096];
  const ssize_t n = ::read(fifo_fd, buf, sizeof(buf));
  if(n <= 0) {
    return;
  }
  fifo_buf.append(buf, (size_t)n);
  size_t nl;
  while((nl = fifo_buf.find('\n')) != std::string::npos) {
    add_script_line(fifo_buf.substr(0, nl));
    fifo_buf.erase(0, nl + 1);
  }
}

void sgi_ps2::service(uint64_t icnt) {
  if(fifo_fd >= 0) {
    poll_fifo();
  }
  run_script(icnt);
  /* hand over one event per device per retrace, and only into an empty queue,
   * so the guest's interrupt handler keeps up and its own replies are not mixed */
  if(!host_kbd.empty() && kbd_q.empty() && kbd_enabled) {
    for(uint8_t c : host_kbd.front()) {
      kbd_q.push_back(c);
    }
    host_kbd.pop_front();
  }
  if(!host_aux.empty() && aux_q.empty()) {
    if(aux_enabled) {
      for(uint8_t c : host_aux.front()) {
        aux_q.push_back(c);
      }
    }
    host_aux.pop_front();
  }
  refill();
}

/* ---------------- input script ----------------
 * NEWPORT_INPUT=<file>, one command per line ('#' comments):
 *   wait <n>          let n instructions pass
 *   until <icnt>      wait until the instruction count reaches icnt
 *   type <text>       type text (US layout; shift added as needed)
 *   key <name>        press and release a key (names as in g_keys)
 *   down|up <name>    press / release
 *   move <dx> <dy> [step]  relative mouse motion in pixels (+y down), one packet
 *                     per retrace of at most step px per axis (default 4)
 *   click <1|2|3>     press and release a mouse button (1 = left)
 *   press|release <1|2|3>  hold / let go of a button (moves in between drag)
 *   ppm <path>        dump the Newport display */
void sgi_ps2::load_script(const char *path) {
  std::ifstream in(path);
  if(!in) {
    fprintf(stderr, "[ps2] cannot read input script %s\n", path);
    return;
  }
  std::string ln;
  while(std::getline(in, ln)) {
    add_script_line(ln);
  }
  fprintf(stderr, "[ps2] input script %s: %zu commands\n", path, script.size());
}

void sgi_ps2::type_text(const std::string &t) {
  static const char *shifted_from = "~!@#$%^&*()_+{}|:\"<>?";
  static const char *shifted_to   = "`1234567890-=[]\\;',./";
  for(char c : t) {
    std::string name;
    bool shift = false;
    if(c >= 'A' && c <= 'Z') {
      name = std::string(1, (char)(c - 'A' + 'a'));
      shift = true;
    }
    else if(c == ' ') {
      name = "space";
    }
    else if(const char *p = strchr(shifted_from, c)) {
      name = std::string(1, shifted_to[p - shifted_from]);
      shift = true;
    }
    else {
      name = std::string(1, c);
    }
    if(shift) {
      key("shift", true);
    }
    if(!key(name, true)) {
      fprintf(stderr, "[ps2] script: no key for '%c'\n", c);
    }
    key(name, false);
    if(shift) {
      key("shift", false);
    }
  }
}

void sgi_ps2::run_script(uint64_t icnt) {
  while(script_pc < script.size() && icnt >= script_wait_until) {
    /* do not run ahead of the device queues: input stays in order with waits */
    if(!host_kbd.empty() || !host_aux.empty()) {
      return;
    }
    const script_line_t &l = script[script_pc++];
    if(g_ps2_log) {
      fprintf(stderr, "[ps2] icnt=%llu script: %s %s\n", (unsigned long long)icnt, l.op.c_str(), l.arg.c_str());
    }
    if(l.op == "wait") {
      script_wait_until = icnt + strtoull(l.arg.c_str(), nullptr, 0);
    }
    else if(l.op == "until") {
      script_wait_until = strtoull(l.arg.c_str(), nullptr, 0);
    }
    else if(l.op == "type") {
      type_text(l.arg);
    }
    else if(l.op == "key") {
      key(l.arg, true);
      key(l.arg, false);
    }
    else if(l.op == "down" || l.op == "up") {
      key(l.arg, l.op == "down");
    }
    else if(l.op == "move") {
      int dx = 0, dy = 0, step = 4;
      sscanf(l.arg.c_str(), "%d %d %d", &dx, &dy, &step);
      if(step < 1) {
        step = 1;
      }
      /* small steps stay under the X server's pointer-acceleration threshold */
      while(dx != 0 || dy != 0) {
        const int sx = dx > step ? step : (dx < -step ? -step : dx);
        const int sy = dy > step ? step : (dy < -step ? -step : dy);
        mouse(sx, sy, mouse_buttons);
        dx -= sx;
        dy -= sy;
      }
    }
    else if(l.op == "click" || l.op == "press" || l.op == "release") {
      static const uint8_t s_ps2_bit[4] = { 0x01, 0x01, 0x04, 0x02 };   /* 1=left 2=middle 3=right */
      const uint8_t b = s_ps2_bit[atoi(l.arg.c_str()) & 3];
      if(l.op != "release") {
        mouse(0, 0, mouse_buttons | b);
      }
      if(l.op != "press") {
        mouse(0, 0, mouse_buttons & ~b);
      }
    }
    else if(l.op == "ppm") {
      if(s->np) {
        s->np->dump_ppm(l.arg.c_str());
      }
    }
    else {
      fprintf(stderr, "[ps2] script: unknown command '%s'\n", l.op.c_str());
    }
  }
}
