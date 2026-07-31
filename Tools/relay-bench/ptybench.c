// The terminal side of the relay A/B benchmark — a stand-in for the app's
// Ghostty surface.
//
// Spawns its argv on a PTY (via forkpty) and drives the workload (workload.c)
// through it. Run it two ways and diff the numbers:
//
//   ptybench ./workload                          # bare PTY — the Ghostty-app shape
//   ptybench zmx attach <name> ./workload        # through the relay — the graphcode shape
//
// Scenarios, in order:
//   1. idle RTT        — 300 pings, one at a time. Input-path latency floor.
//   2. throughput      — 20MB blast, time to drain. Output-path bandwidth.
//   3. RTT under load  — 300 bursts of 64KB at 60Hz (a TUI redrawing) with a
//                        ping every 20ms. The scroll scenario: input latency
//                        while the output path is busy. Burst-end arrival times
//                        double as the pacing-jitter measurement.
//   4. fragmentation   — 2000 SGR wheel reports written one write() apiece;
//                        the workload reports how many arrived split across
//                        read() boundaries.
//
// Output: one JSON object on stdout. Everything else (spawn noise, shell
// prompts, zmx snapshot bytes) is scanned only for @-sigil markers and
// otherwise discarded.

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <util.h>

static int master = -1;
static pid_t child = -1;

static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void write_master(const char *buf, size_t len) {
  while (len > 0) {
    ssize_t n = write(master, buf, len);
    if (n < 0) {
      if (errno == EINTR || errno == EAGAIN) continue;
      fprintf(stderr, "write to pty failed: %s\n", strerror(errno));
      exit(1);
    }
    buf += n;
    len -= (size_t)n;
  }
}

static void sendf(const char *fmt, ...) {
  char buf[256];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  if (n > 0) write_master(buf, (size_t)n);
}

// --- marker scanning ---------------------------------------------------------
// The output stream is noise + markers. Markers are "@<kind><payload>#" and
// never span more than 63 bytes, so a 64-byte carry across reads suffices.

typedef void (*marker_fn)(char kind, const char *payload, uint64_t at_ns);

static char carry[64];
static size_t carry_len = 0;
static uint64_t bytes_seen = 0;
static uint64_t reads_seen = 0;

static void scan(const char *buf, ssize_t n, marker_fn fn) {
  uint64_t at = now_ns();
  bytes_seen += (uint64_t)n;
  reads_seen++;
  char joined[sizeof carry + 4096];
  memcpy(joined, carry, carry_len);
  memcpy(joined + carry_len, buf, (size_t)n);
  size_t len = carry_len + (size_t)n;

  size_t consumed = 0;
  for (size_t i = 0; i < len; i++) {
    if (joined[i] != '@') continue;
    size_t j = i + 1;
    while (j < len && j - i < 60 && joined[j] != '#') j++;
    if (j >= len) break;  // marker may continue in the next read
    if (joined[j] == '#' && j > i + 1) {
      char payload[64];
      size_t plen = j - i - 2;
      memcpy(payload, joined + i + 2, plen);
      payload[plen] = '\0';
      fn(joined[i + 1], payload, at);
      consumed = j + 1;
      i = j;
    }
  }
  if (consumed < len) {
    size_t rest = len - consumed;
    if (rest > sizeof carry) rest = sizeof carry;  // markers never this long
    memcpy(carry, joined + len - rest, rest);
    carry_len = rest;
  } else {
    carry_len = 0;
  }
}

// Reads until `until` returns nonzero or the deadline passes. Returns 0 on
// deadline, 1 otherwise.
static int (*pump_until)(void);
static int pump(marker_fn fn, int (*until)(void), int timeout_ms) {
  uint64_t deadline = now_ns() + (uint64_t)timeout_ms * 1000000ull;
  while (!until()) {
    int64_t left_ms = (int64_t)(deadline - now_ns()) / 1000000;
    if (left_ms <= 0) return 0;
    struct pollfd pfd = {.fd = master, .events = POLLIN};
    int r = poll(&pfd, 1, (int)(left_ms < 50 ? left_ms : 50));
    if (r <= 0) continue;
    char buf[4096];
    ssize_t n = read(master, buf, sizeof buf);
    if (n <= 0) {
      if (n < 0 && (errno == EAGAIN || errno == EINTR)) continue;
      fprintf(stderr, "pty closed while waiting\n");
      exit(1);
    }
    scan(buf, n, fn);
  }
  return 1;
}

// --- stats -------------------------------------------------------------------

static int cmp_u64(const void *a, const void *b) {
  uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
  return x < y ? -1 : x > y ? 1 : 0;
}

static void print_dist(const char *name, uint64_t *v, size_t n) {
  if (n == 0) {
    printf("  \"%s\": null", name);
    return;
  }
  qsort(v, n, sizeof *v, cmp_u64);
  double p50 = (double)v[n / 2] / 1e6;
  double p90 = (double)v[(size_t)((double)n * 0.90)] / 1e6;
  double p99 = (double)v[(size_t)((double)n * 0.99) < n ? (size_t)((double)n * 0.99) : n - 1] / 1e6;
  double max = (double)v[n - 1] / 1e6;
  printf("  \"%s\": {\"n\": %zu, \"p50_ms\": %.3f, \"p90_ms\": %.3f, \"p99_ms\": %.3f, \"max_ms\": %.3f}",
         name, n, p50, p90, p99, max);
}

// --- scenario state ----------------------------------------------------------

#define MAX_PINGS 1024
#define MAX_BURSTS 512

static uint64_t ping_sent[MAX_PINGS];
static uint64_t ping_rtt[MAX_PINGS];
static int pong_flag[MAX_PINGS];
static uint64_t burst_end_at[MAX_BURSTS];
static int last_pong = -1;
static int got_ready = 0, got_done = 0, got_burst_fin = 0;
static long frag_reads = -1, frag_seqs = -1, frag_splits = -1;
static int got_frag = 0;

static void on_marker(char kind, const char *payload, uint64_t at) {
  switch (kind) {
    case 'R': got_ready = 1; break;
    case 'D': got_done = 1; break;
    case 'Z': got_burst_fin = 1; break;
    case 'P': {
      int seq = atoi(payload);
      if (seq >= 0 && seq < MAX_PINGS && !pong_flag[seq]) {
        pong_flag[seq] = 1;
        ping_rtt[seq] = at - ping_sent[seq];
        last_pong = seq;
      }
      break;
    }
    case 'E': {
      int i = atoi(payload);
      if (i >= 0 && i < MAX_BURSTS) burst_end_at[i] = at;
      break;
    }
    case 'F':
      sscanf(payload, " %ld %ld %ld", &frag_reads, &frag_seqs, &frag_splits);
      got_frag = 1;
      break;
    default: break;
  }
}

static int until_ready(void) { return got_ready; }
static int until_done(void) { return got_done; }
static int until_burst_fin(void) { return got_burst_fin; }
static int until_frag(void) { return got_frag; }
static int expected_pong = -1;
static int until_pong(void) { return last_pong >= expected_pong; }

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <command...>\n", argv[0]);
    return 2;
  }
  struct winsize ws = {.ws_row = 60, .ws_col = 220};
  child = forkpty(&master, NULL, NULL, &ws);
  if (child < 0) {
    perror("forkpty");
    return 1;
  }
  if (child == 0) {
    execvp(argv[1], argv + 1);
    perror("execvp");
    _exit(127);
  }

  if (!pump(on_marker, until_ready, 15000)) {
    fprintf(stderr, "workload never reported ready\n");
    return 1;
  }
  // Let the spawn noise (prompt, command echo, zmx snapshot) finish.
  usleep(300000);

  // 1. idle RTT
  int n_idle = 300;
  for (int i = 0; i < n_idle; i++) {
    expected_pong = i;
    ping_sent[i] = now_ns();
    sendf("ping %d\n", i);
    if (!pump(on_marker, until_pong, 2000)) {
      fprintf(stderr, "ping %d lost\n", i);
      return 1;
    }
    usleep(2000);
  }

  // 2. throughput: 20MB
  const uint64_t blast_bytes = 20ull * 1024 * 1024;
  uint64_t bytes_before = bytes_seen;
  uint64_t t0 = now_ns();
  sendf("blast %llu\n", (unsigned long long)blast_bytes);
  if (!pump(on_marker, until_done, 120000)) {
    fprintf(stderr, "blast never finished\n");
    return 1;
  }
  double blast_secs = (double)(now_ns() - t0) / 1e9;
  double mb_moved = (double)(bytes_seen - bytes_before) / 1048576.0;

  // 3. RTT under 60Hz redraw load, ping every 20ms
  int first_load_ping = 500, n_load_pings = 0;
  sendf("burst 300 65536 16667\n");
  uint64_t next_ping = now_ns() + 20000000ull;
  while (!got_burst_fin) {
    if (now_ns() >= next_ping && first_load_ping + n_load_pings < MAX_PINGS) {
      int seq = first_load_ping + n_load_pings++;
      ping_sent[seq] = now_ns();
      sendf("ping %d\n", seq);
      next_ping += 20000000ull;
    }
    struct pollfd pfd = {.fd = master, .events = POLLIN};
    int r = poll(&pfd, 1, 5);
    if (r > 0) {
      char buf[4096];
      ssize_t n = read(master, buf, sizeof buf);
      if (n <= 0) {
        if (n < 0 && (errno == EAGAIN || errno == EINTR)) continue;
        fprintf(stderr, "pty closed during burst\n");
        return 1;
      }
      scan(buf, n, on_marker);
    }
  }
  // Give stragglers a moment.
  pump(on_marker, until_burst_fin, 1000);

  // 4. input fragmentation: 2000 wheel reports, one write() each
  for (int i = 0; i < 2000; i++) {
    char seq[32];
    int len = snprintf(seq, sizeof seq, "\x1b[<%d;%d;%dM", 64 + (i & 1),
                       10 + (i % 80), 20 + (i % 40));
    write_master(seq, (size_t)len);
    usleep(500);
  }
  sendf("fragstat\n");
  if (!pump(on_marker, until_frag, 5000)) {
    fprintf(stderr, "no fragstat reply\n");
    return 1;
  }

  sendf("quit\n");

  // --- report ---
  uint64_t idle[MAX_PINGS], load[MAX_PINGS];
  size_t n_idle_ok = 0, n_load_ok = 0;
  for (int i = 0; i < n_idle; i++)
    if (pong_flag[i]) idle[n_idle_ok++] = ping_rtt[i];
  for (int i = 0; i < n_load_pings; i++)
    if (pong_flag[first_load_ping + i]) load[n_load_ok++] = ping_rtt[first_load_ping + i];

  // Burst pacing: inter-arrival gaps of burst-end markers vs the 16.667ms ideal.
  uint64_t gaps[MAX_BURSTS];
  size_t n_gaps = 0;
  int late_gaps = 0;
  for (int i = 1; i < 300; i++) {
    if (burst_end_at[i] && burst_end_at[i - 1]) {
      uint64_t gap = burst_end_at[i] - burst_end_at[i - 1];
      gaps[n_gaps++] = gap;
      if (gap > 25000000ull) late_gaps++;  // >25ms between 60Hz frames = felt hitch
    }
  }

  printf("{\n");
  print_dist("idle_rtt", idle, n_idle_ok);
  printf(",\n");
  print_dist("loaded_rtt", load, n_load_ok);
  printf(",\n");
  print_dist("burst_gap", gaps, n_gaps);
  printf(",\n  \"late_gaps_over_25ms\": %d", late_gaps);
  printf(",\n  \"throughput_mb_s\": %.1f", mb_moved / blast_secs);
  printf(",\n  \"blast_mb\": %.1f", mb_moved);
  printf(",\n  \"client_reads\": %llu, \"client_bytes\": %llu",
         (unsigned long long)reads_seen, (unsigned long long)bytes_seen);
  printf(",\n  \"frag\": {\"reads\": %ld, \"seqs\": %ld, \"splits\": %ld}\n",
         frag_reads, frag_seqs, frag_splits);
  printf("}\n");

  kill(child, SIGKILL);
  waitpid(child, NULL, 0);
  return 0;
}
