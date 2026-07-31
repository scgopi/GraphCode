// The session side of the relay A/B benchmark — a stand-in for a TUI agent.
//
// Behaves the way `claude` does from the relay's point of view: puts its tty in
// raw mode, ignores SIGWINCH, reads commands from stdin, and answers on stdout.
// Driven by ptybench (see ptybench.c) either directly on a PTY (the Ghostty-app
// shape) or through `zmx attach` (the graphcode shape); the identical workload on
// both sides is what isolates the relay's contribution.
//
// Protocol (all replies are @-sigil markers so ptybench can find them in a noisy
// stream that may also contain shell prompts and command echo):
//   ping <seq>              -> "@P<seq>#"
//   blast <bytes>           -> <bytes> of filler, then "@D#"
//   burst <n> <size> <us>   -> n bursts of <size> bytes every <us> microseconds,
//                              each ending "@E<i>#"; pings are still answered
//                              between bursts (a TUI answers input mid-redraw)
//   fragstat                -> "@F <reads> <seqs> <splits>#" — how many stdin
//                              read() chunks arrived, how many complete SGR mouse
//                              sequences they contained, and how many chunks ended
//                              mid-sequence (the "0;60M in the composer" class)
//   quit                    -> exit 0

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static long reads_count = 0;
static long seqs_count = 0;
static long splits_count = 0;
static int in_escape = 0;  // carries SGR-parse state across read() boundaries

static void write_all(const char *buf, size_t len) {
  while (len > 0) {
    ssize_t n = write(STDOUT_FILENO, buf, len);
    if (n < 0) {
      if (errno == EINTR || errno == EAGAIN) continue;
      _exit(1);
    }
    buf += n;
    len -= (size_t)n;
  }
}

static void writef(const char *fmt, ...) {
  char buf[256];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  if (n > 0) write_all(buf, (size_t)n);
}

// 256-byte lines of filler — plain text with regular newlines, so the zmx
// daemon's ghostty-vt pass does ordinary grid work rather than degenerate
// single-line appends.
static void write_filler(size_t bytes) {
  static char line[256];
  memset(line, 'x', sizeof line - 1);
  line[sizeof line - 1] = '\n';
  while (bytes > 0) {
    size_t n = bytes < sizeof line ? bytes : sizeof line;
    write_all(line, n);
    bytes -= n;
  }
}

// Tracks SGR mouse sequences (ESC [ < ... M/m) across chunk boundaries and
// counts chunks that end mid-sequence — fragmentation the app-side coalescing
// was built to paper over.
static void scan_chunk(const char *buf, ssize_t n) {
  reads_count++;
  for (ssize_t i = 0; i < n; i++) {
    char c = buf[i];
    if (!in_escape) {
      if (c == 0x1b) in_escape = 1;
    } else if (c == 'M' || c == 'm') {
      in_escape = 0;
      seqs_count++;
    }
  }
  if (in_escape) splits_count++;
}

static void handle_line(char *line);

// Command bytes accumulate here; escape sequences are counted by scan_chunk and
// stripped before line parsing so a mouse report never corrupts a command.
static char cmdbuf[512];
static size_t cmdlen = 0;

static void feed(const char *buf, ssize_t n) {
  static int skip_escape = 0;
  for (ssize_t i = 0; i < n; i++) {
    char c = buf[i];
    if (skip_escape) {
      if (c == 'M' || c == 'm') skip_escape = 0;
      continue;
    }
    if (c == 0x1b) {
      skip_escape = 1;
      continue;
    }
    if (c == '\n' || c == '\r') {
      if (cmdlen > 0) {
        cmdbuf[cmdlen] = '\0';
        cmdlen = 0;
        handle_line(cmdbuf);
      }
      continue;
    }
    if (cmdlen < sizeof cmdbuf - 1) cmdbuf[cmdlen++] = c;
  }
}

// Drains whatever is waiting on stdin without blocking — how pings get answered
// between bursts, mid-"redraw", the way a TUI event loop would.
static void drain_stdin(int block_ms) {
  struct pollfd pfd = {.fd = STDIN_FILENO, .events = POLLIN};
  for (;;) {
    int r = poll(&pfd, 1, block_ms);
    if (r <= 0) return;
    char buf[4096];
    ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
    if (n <= 0) {
      if (n < 0 && (errno == EAGAIN || errno == EINTR)) return;
      _exit(0);  // EOF: relay went away
    }
    scan_chunk(buf, n);
    feed(buf, n);
    block_ms = 0;  // first read may block; the rest of the backlog must not
  }
}

static void handle_line(char *line) {
  long a = 0, b = 0, c = 0;
  if (sscanf(line, "ping %ld", &a) == 1) {
    writef("@P%ld#\n", a);
  } else if (sscanf(line, "blast %ld", &a) == 1) {
    write_filler((size_t)a);
    writef("@D#\n");
  } else if (sscanf(line, "burst %ld %ld %ld", &a, &b, &c) == 3) {
    struct timespec interval = {.tv_sec = c / 1000000,
                                .tv_nsec = (c % 1000000) * 1000};
    for (long i = 0; i < a; i++) {
      writef("@B%ld#\n", i);
      write_filler((size_t)b);
      writef("@E%ld#\n", i);
      drain_stdin(0);
      nanosleep(&interval, NULL);
    }
    writef("@Z#\n");
  } else if (strcmp(line, "fragstat") == 0) {
    writef("@F %ld %ld %ld#\n", reads_count, seqs_count, splits_count);
  } else if (strcmp(line, "quit") == 0) {
    _exit(0);
  }
}

int main(void) {
  signal(SIGWINCH, SIG_IGN);
  if (isatty(STDIN_FILENO)) {
    struct termios t;
    tcgetattr(STDIN_FILENO, &t);
    cfmakeraw(&t);
    tcsetattr(STDIN_FILENO, TCSANOW, &t);
  }
  writef("@R#\n");
  for (;;) drain_stdin(-1);
}
