#ifndef __SGI_PS2_HH__
#define __SGI_PS2_HH__

#include <cstdint>
#include <cstddef>
#include <deque>
#include <string>
#include <vector>

struct state_t;

/* IP22 PS/2 keyboard + mouse: the 8042-compatible controller in IOC2 (data at
 * IOC2 reg 0x10, status/command at 0x11 -> HPC offsets 0x59843/0x59847), with an
 * AT keyboard on the primary port and a PS/2 mouse on the aux port.  A high-level
 * model of the controller command set and both devices' command sets (MAME
 * models the 8042 microcontroller itself; behaviour here follows the IBM spec).
 * The controller interrupt is IOC2 mappable bit 0x10.
 *
 * Host input arrives through key()/mouse() (SDL, or a NEWPORT_INPUT script) and
 * is paced out one event per service() call (each Newport vertical retrace). */
class sgi_ps2 {
public:
  sgi_ps2(state_t *s);
  uint8_t read(bool cmd_port);
  void write(bool cmd_port, uint8_t v);
  bool irq() const {
    return obf && (aux_obf ? (ccb & 0x02) : (ccb & 0x01));
  }
  /* host input; name is a key name from the scan-code table ("a", "enter", ...) */
  bool key(const std::string &name, bool down);
  void mouse(int dx, int dy, uint8_t buttons);
  /* no mouse motion waiting to reach (or be read by) the guest */
  bool aux_idle() const { return host_aux.empty() && aux_q.empty(); }
  /* called once per vertical retrace: run the input script, move one queued event */
  void service(uint64_t icnt);
  uint8_t buttons() const { return mouse_buttons; }
private:
  state_t *s;
  /* controller */
  uint8_t ccb = 0x45;             /* command byte: kbd irq, sys, translate */
  uint8_t pending_cmd = 0;        /* controller command waiting for its data byte */
  bool obf = false, aux_obf = false;
  uint8_t out = 0;
  bool last_was_cmd = false;
  std::deque<uint8_t> kbd_q, aux_q;
  std::deque<uint8_t> ctl_q;       /* controller command replies: not gated by the port disables */
  /* keyboard */
  uint8_t kbd_pending = 0;        /* keyboard command waiting for its argument */
  bool kbd_enabled = true;
  uint8_t scan_set = 2;
  /* mouse */
  uint8_t aux_pending = 0;
  bool aux_enabled = false;       /* stream reporting (0xF4) */
  uint8_t mouse_buttons = 0;
  /* host events not yet handed to the device queues */
  std::deque<std::vector<uint8_t>> host_kbd;
  std::deque<std::vector<uint8_t>> host_aux;
  /* input script (NEWPORT_INPUT=<file>) */
  struct script_line_t {
    std::string op, arg;
  };
  std::vector<script_line_t> script;
  size_t script_pc = 0;
  uint64_t script_wait_until = 0;
  void load_script(const char *path);
  void run_script(uint64_t icnt);
  /* NEWPORT_INPUT_FIFO=<path>: the same script commands, fed live through a named
   * pipe (e.g. echo "type ls" > path) and appended to the script as they arrive */
  int fifo_fd = -1, fifo_keepalive = -1;
  std::string fifo_buf;
  void add_script_line(const std::string &ln);
  void poll_fifo();
  void type_text(const std::string &t);

  void refill();
  void kbd_cmd(uint8_t v);
  void aux_cmd(uint8_t v);
  void ctl_cmd(uint8_t v);
};

#endif
