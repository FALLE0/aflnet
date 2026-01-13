/*
  AFLNet helper: execute one network testcase under afl-showmap / afl-cmin.

  Rationale:
  afl-cmin expects a target binary that consumes one testcase and exits.
  AFLNet targets are typically servers; this wrapper starts the server, replays
  one message sequence from stdin to the server (as a client), then terminates
  the server and exits.

  Intended usage (example):

    afl-cmin -i in -o out -- \
      ./aflnet-exec -N tcp://127.0.0.1/8554 -D 10000 -K -- \
      ./testOnDemandRTSPServer 8554

  Notes:
  - Testcase format is AFLNet's packet sequence format: repeated [u32 size][bytes].
  - This binary is not required to be AFL-instrumented as long as the server is;
    but afl-cmin performs a string-based instrumentation check. We embed the
    magic string to satisfy that check.
*/

#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "alloc-inl.h"
#include "aflnet.h"

/* afl-cmin checks for this substring to decide if a binary is instrumented. */
static const char* afl_shm_magic = "__AFL_SHM_ID";

typedef enum {
  INPUT_AUTO = 0,
  INPUT_LEN  = 1, /* [u32 size][bytes]... */
  INPUT_RAW  = 2  /* raw stream, split using extract_requests_* */
} input_mode_t;

static region_t* (*extract_requests_fn)(unsigned char* buf, unsigned int buf_size,
                                        unsigned int* region_count_ref) = NULL;

static void usage(const char* argv0) {

  fprintf(stderr,
      "Usage: %s -N (tcp|udp)://IP/PORT [options] -- server [args...]\n\n"
      "Reads one testcase from stdin, starts the server, replays the\n"
      "testcase to the server, then terminates the server and exits.\n"
      "Designed to be run under afl-showmap / afl-cmin.\n\n"
          "Required:\n"
          "  -N netinfo   Server address, e.g., tcp://127.0.0.1/8554\n\n"
          "Options:\n"
      "  -P proto     Protocol (RTSP, FTP, DNS, ...). Required for raw mode\n"
      "  -I mode      Input mode: auto|raw|len (default: auto)\n"
          "  -D usec      Wait time before connecting (default: 10000)\n"
          "  -K           Terminate server gracefully (SIGTERM)\n"
      "  -W ms        Poll timeout in ms (default: 1)\n"
      "  -w usec      Socket send/recv timeout in usec (default: 1000)\n"
      "  -M bytes     Max stdin size to read (default: 16777216)\n\n",
          argv0);

}

static int select_protocol(const char* proto) {

  if (!strcmp(proto, "RTSP")) extract_requests_fn = &extract_requests_rtsp;
  else if (!strcmp(proto, "FTP")) extract_requests_fn = &extract_requests_ftp;
  else if (!strcmp(proto, "MQTT")) extract_requests_fn = &extract_requests_mqtt;
  else if (!strcmp(proto, "DNS")) extract_requests_fn = &extract_requests_dns;
  else if (!strcmp(proto, "DTLS12")) extract_requests_fn = &extract_requests_dtls12;
  else if (!strcmp(proto, "DICOM")) extract_requests_fn = &extract_requests_dicom;
  else if (!strcmp(proto, "SMTP")) extract_requests_fn = &extract_requests_smtp;
  else if (!strcmp(proto, "SSH")) extract_requests_fn = &extract_requests_ssh;
  else if (!strcmp(proto, "TLS")) extract_requests_fn = &extract_requests_tls;
  else if (!strcmp(proto, "SIP")) extract_requests_fn = &extract_requests_sip;
  else if (!strcmp(proto, "HTTP")) extract_requests_fn = &extract_requests_http;
  else if (!strcmp(proto, "IPP")) extract_requests_fn = &extract_requests_ipp;
  else if (!strcmp(proto, "TFTP")) extract_requests_fn = &extract_requests_tftp;
  else if (!strcmp(proto, "DHCP")) extract_requests_fn = &extract_requests_dhcp;
  else if (!strcmp(proto, "SNTP")) extract_requests_fn = &extract_requests_SNTP;
  else if (!strcmp(proto, "NTP")) extract_requests_fn = &extract_requests_NTP;
  else if (!strcmp(proto, "SNMP")) extract_requests_fn = &extract_requests_SNMP;
  else return -1;

  return 0;

}

static int parse_input_mode(const char* s, input_mode_t* out) {

  if (!strcmp(s, "auto")) {
    *out = INPUT_AUTO;
    return 0;
  }

  if (!strcmp(s, "raw")) {
    *out = INPUT_RAW;
    return 0;
  }

  if (!strcmp(s, "len")) {
    *out = INPUT_LEN;
    return 0;
  }

  return -1;

}

static unsigned char* read_all_stdin(size_t max_bytes, unsigned int* out_len) {

  size_t cap = 4096;
  size_t len = 0;
  unsigned char* buf = ck_alloc(cap);

  for (;;) {
    if (len == cap) {
      size_t new_cap = cap * 2;
      if (new_cap > max_bytes) new_cap = max_bytes;
      if (new_cap <= cap) {
        ck_free(buf);
        return NULL;
      }
      cap = new_cap;
      buf = ck_realloc(buf, cap);
    }

    ssize_t r = read(STDIN_FILENO, buf + len, cap - len);
    if (r == 0) break;
    if (r < 0) {
      ck_free(buf);
      return NULL;
    }
    len += (size_t)r;
    if (len > max_bytes) {
      ck_free(buf);
      return NULL;
    }
  }

  *out_len = (unsigned int)len;
  return buf;

}

static int looks_like_len_prefixed(const unsigned char* buf, unsigned int len) {

  if (len < sizeof(uint32_t)) return 0;

  unsigned int off = 0;
  unsigned int packets = 0;

  while (off + sizeof(uint32_t) <= len) {
    uint32_t sz = 0;
    memcpy(&sz, buf + off, sizeof(uint32_t));
    off += (unsigned int)sizeof(uint32_t);

    if (sz == 0) continue;
    if (sz > (1024U * 1024U * 64U)) return 0;
    if (off + sz > len) return 0;
    off += sz;
    packets++;
  }

  return (off == len) && (packets > 0);

}

static int parse_netinfo(const char* s, int* use_udp, char** ip_out, int* port_out) {

  /* Expected: tcp://127.0.0.1/8554 or udp://... */
  const char* tcp = "tcp://";
  const char* udp = "udp://";

  const char* p = NULL;
  if (!strncmp(s, tcp, strlen(tcp))) {
    *use_udp = 0;
    p = s + strlen(tcp);
  } else if (!strncmp(s, udp, strlen(udp))) {
    *use_udp = 1;
    p = s + strlen(udp);
  } else {
    return -1;
  }

  const char* slash = strrchr(p, '/');
  if (!slash || slash == p || !slash[1]) return -1;

  size_t ip_len = (size_t)(slash - p);
  char* ip = ck_alloc(ip_len + 1);
  memcpy(ip, p, ip_len);
  ip[ip_len] = 0;

  char* endptr = NULL;
  long port = strtol(slash + 1, &endptr, 10);
  if (!endptr || *endptr != 0 || port <= 0 || port > 65535) {
    ck_free(ip);
    return -1;
  }

  *ip_out = ip;
  *port_out = (int)port;
  return 0;

}

static int kill_and_wait(pid_t pid, int graceful) {

  if (pid <= 0) return 0;

  int status = 0;

  kill(pid, graceful ? SIGTERM : SIGKILL);

  /* Wait up to ~1s for graceful shutdown, then SIGKILL. */
  for (int i = 0; i < 100; i++) {
    pid_t r = waitpid(pid, &status, WNOHANG);
    if (r == pid) return status;
    usleep(10000);
  }

  kill(pid, SIGKILL);
  waitpid(pid, &status, 0);
  return status;

}

static int replay_len_prefixed(int sockfd, struct timeval timeout, unsigned int poll_timeout_ms,
                               const unsigned char* buf, unsigned int len) {

  unsigned int off = 0;
  while (off + sizeof(uint32_t) <= len) {

    uint32_t sz = 0;
    memcpy(&sz, buf + off, sizeof(uint32_t));
    off += (unsigned int)sizeof(uint32_t);

    if (sz == 0) continue;
    if (off + sz > len) return -1;

    char* response_buf = NULL;
    unsigned int response_buf_size = 0;
    (void)net_recv(sockfd, timeout, poll_timeout_ms, &response_buf, &response_buf_size);

    int n = net_send(sockfd, timeout, (char*)(buf + off), sz);
    if (response_buf) ck_free(response_buf);
    response_buf = NULL;
    response_buf_size = 0;

    if (n != (int)sz) return -1;

    (void)net_recv(sockfd, timeout, poll_timeout_ms, &response_buf, &response_buf_size);
    if (response_buf) ck_free(response_buf);

    off += sz;

  }

  return 0;

}

static int replay_raw_split(int sockfd, struct timeval timeout, unsigned int poll_timeout_ms,
                            const unsigned char* buf, unsigned int len) {

  if (!extract_requests_fn) return -1;

  unsigned int region_count = 0;
  region_t* regions = (*extract_requests_fn)((unsigned char*)buf, len, &region_count);
  if (!regions || !region_count) {
    if (regions) ck_free(regions);
    return -1;
  }

  for (unsigned int i = 0; i < region_count; i++) {

    int start = regions[i].start_byte;
    int end = regions[i].end_byte;

    if (start < 0) start = 0;
    if (end < start) continue;
    if ((unsigned int)start >= len) continue;
    if ((unsigned int)end >= len) end = (int)len - 1;

    unsigned int msg_len = (unsigned int)(end - start + 1);
    if (!msg_len) continue;

    char* response_buf = NULL;
    unsigned int response_buf_size = 0;
    (void)net_recv(sockfd, timeout, poll_timeout_ms, &response_buf, &response_buf_size);

    int n = net_send(sockfd, timeout, (char*)(buf + start), msg_len);
    if (response_buf) ck_free(response_buf);
    response_buf = NULL;
    response_buf_size = 0;

    if (n != (int)msg_len) {
      ck_free(regions);
      return -1;
    }

    (void)net_recv(sockfd, timeout, poll_timeout_ms, &response_buf, &response_buf_size);
    if (response_buf) ck_free(response_buf);

  }

  ck_free(regions);
  return 0;

}

int main(int argc, char** argv) {

  (void)afl_shm_magic; /* keep referenced */

  unsigned int server_wait_usecs = 10000;
  unsigned int poll_timeout_ms = 1;
  unsigned int socket_timeout_usecs = 1000;
  size_t max_stdin_bytes = (size_t)(1024U * 1024U * 16U);
  int graceful_term = 0;

  input_mode_t input_mode = INPUT_AUTO;

  char* ip = NULL;
  int port = 0;
  int use_udp = 0;

  int opt;
  while ((opt = getopt(argc, argv, "+N:P:I:D:KW:w:M:p:s:")) != -1) {

    switch (opt) {
      case 'N':
        if (parse_netinfo(optarg, &use_udp, &ip, &port)) {
          usage(argv[0]);
          return 1;
        }
        break;
      case 'P':
        if (select_protocol(optarg)) {
          fprintf(stderr, "[aflnet-exec] Unsupported protocol: %s\n", optarg);
          return 1;
        }
        break;
      case 'I':
        if (parse_input_mode(optarg, &input_mode)) {
          fprintf(stderr, "[aflnet-exec] Bad -I mode (auto|raw|len): %s\n", optarg);
          return 1;
        }
        break;
      case 'D':
        server_wait_usecs = (unsigned int)strtoul(optarg, NULL, 10);
        break;
      case 'K':
        graceful_term = 1;
        break;
      case 'W':
        poll_timeout_ms = (unsigned int)strtoul(optarg, NULL, 10);
        break;
      case 'w':
        socket_timeout_usecs = (unsigned int)strtoul(optarg, NULL, 10);
        break;
      case 'M':
        max_stdin_bytes = (size_t)strtoull(optarg, NULL, 10);
        break;
      /* Backward compatible aliases. */
      case 'p':
        poll_timeout_ms = (unsigned int)strtoul(optarg, NULL, 10);
        break;
      case 's':
        socket_timeout_usecs = (unsigned int)strtoul(optarg, NULL, 10);
        break;
      default:
        usage(argv[0]);
        return 1;
    }

  }

  if (!ip || port == 0) {
    usage(argv[0]);
    return 1;
  }

  if (input_mode == INPUT_RAW && !extract_requests_fn) {
    fprintf(stderr, "[aflnet-exec] -I raw requires -P <protocol>\n");
    return 1;
  }

  if (optind >= argc || strcmp(argv[optind], "--") != 0) {
    usage(argv[0]);
    return 1;
  }
  optind++;

  if (optind >= argc) {
    usage(argv[0]);
    return 1;
  }

  char** server_argv = &argv[optind];

  unsigned int stdin_len = 0;
  unsigned char* stdin_buf = read_all_stdin(max_stdin_bytes, &stdin_len);
  if (!stdin_buf && max_stdin_bytes) {
    fprintf(stderr, "[aflnet-exec] Failed to read stdin or stdin exceeds -M\n");
    if (ip) ck_free(ip);
    return 1;
  }

  pid_t srv_pid = fork();
  if (srv_pid < 0) {
    PFATAL("fork() failed");
  }

  if (srv_pid == 0) {
    execvp(server_argv[0], server_argv);
    _exit(127);
  }

  usleep(server_wait_usecs);

  int sockfd = socket(AF_INET, use_udp ? SOCK_DGRAM : SOCK_STREAM, 0);
  if (sockfd < 0) {
    kill_and_wait(srv_pid, graceful_term);
    PFATAL("Cannot create a socket");
  }

  struct timeval timeout;
  timeout.tv_sec = 0;
  timeout.tv_usec = socket_timeout_usecs;

  setsockopt(sockfd, SOL_SOCKET, SO_SNDTIMEO, (char*)&timeout, sizeof(timeout));
  setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, (char*)&timeout, sizeof(timeout));

  struct sockaddr_in serv_addr;
  memset(&serv_addr, 0, sizeof(serv_addr));

  serv_addr.sin_family = AF_INET;
  serv_addr.sin_port = htons((uint16_t)port);

  if (inet_pton(AF_INET, ip, &serv_addr.sin_addr) != 1) {
    close(sockfd);
    kill_and_wait(srv_pid, graceful_term);
    fprintf(stderr, "[aflnet-exec] Bad IP: %s\n", ip);
    return 1;
  }

  /* Connect with retries (server startup jitter). */
  int connected = 0;
  for (int i = 0; i < 1000; i++) {
    if (connect(sockfd, (struct sockaddr*)&serv_addr, sizeof(serv_addr)) == 0) {
      connected = 1;
      break;
    }
    usleep(1000);
  }

  if (!connected) {
    close(sockfd);
    kill_and_wait(srv_pid, graceful_term);
    if (stdin_buf) ck_free(stdin_buf);
    return 1;
  }

  int replay_rc = 0;
  if (stdin_len == 0) {
    /* Nothing to replay: still keep behavior deterministic. */
    replay_rc = 0;
  } else {

    input_mode_t effective_mode = input_mode;
    if (effective_mode == INPUT_AUTO) {
      if (looks_like_len_prefixed(stdin_buf, stdin_len)) {
        effective_mode = INPUT_LEN;
      } else if (extract_requests_fn) {
        effective_mode = INPUT_RAW;
      } else {
        /* No protocol provided; fall back to single send. */
        effective_mode = INPUT_LEN;
      }
    }

    if (effective_mode == INPUT_LEN) {
      if (looks_like_len_prefixed(stdin_buf, stdin_len)) {
        replay_rc = replay_len_prefixed(sockfd, timeout, poll_timeout_ms, stdin_buf, stdin_len);
      } else {
        /* Not actually len-prefixed; treat as one packet. */
        char* response_buf = NULL;
        unsigned int response_buf_size = 0;
        (void)net_recv(sockfd, timeout, poll_timeout_ms, &response_buf, &response_buf_size);
        if (response_buf) ck_free(response_buf);

        int n = net_send(sockfd, timeout, (char*)stdin_buf, stdin_len);
        if (n != (int)stdin_len) replay_rc = 1;
      }
    } else {
      replay_rc = replay_raw_split(sockfd, timeout, poll_timeout_ms, stdin_buf, stdin_len);
    }
  }

  close(sockfd);
  if (stdin_buf) ck_free(stdin_buf);

  /* If the server already crashed, propagate that via a signal so afl-showmap
     and afl-cmin can treat it as a crash (-C). */
  int status = 0;
  pid_t w = waitpid(srv_pid, &status, WNOHANG);

  if (w == srv_pid) {
    if (WIFSIGNALED(status)) {
      kill(getpid(), WTERMSIG(status));
    }
  } else {
    (void)kill_and_wait(srv_pid, graceful_term);
  }

  if (ip) ck_free(ip);

  return replay_rc ? 1 : 0;

}
