#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#if defined(__linux__)
#include <sys/syscall.h>
#include <sys/prctl.h>
#endif

/* Reference implementation of the PtcRunner MCP stdio launcher contract. */

#define BOOT_VERSION 1U
#define MAX_FRAME_BYTES (1024U * 1024U)
#define MAX_PENDING_BYTES (1024U * 1024U)
#define MAX_ARGUMENTS 256U
#define MAX_ENVIRONMENT 256U
#define MAX_CONFIG_STRING (128U * 1024U)
#define IO_CHUNK_BYTES 8192U
#define MIN_FINAL_KILL_WAIT_MS 1000U
#define SHA256_BYTES 32U
#define SHA256_BLOCK_BYTES 64U

enum shutdown_phase {
  PHASE_RUNNING = 0,
  PHASE_FLUSH_WAIT = 1,
  PHASE_EOF_WAIT = 2,
  PHASE_TERM_WAIT = 3,
  PHASE_KILL_WAIT = 4
};

enum finish_reason {
  FINISH_SERVER_EXIT = 0,
  FINISH_CLOSE = 1,
  FINISH_OWNER_EOF = 2,
  FINISH_LAUNCHER_SIGNAL = 3,
  FINISH_PROTOCOL_ERROR = 4,
  FINISH_TERMINATION_TIMEOUT = 5
};

enum startup_result {
  STARTUP_READY = 0,
  STARTUP_FAILED = 1,
  STARTUP_OWNER_EOF = 2,
  STARTUP_TIMEOUT = 3
};

struct cursor {
  const uint8_t *bytes;
  size_t length;
  size_t offset;
};

struct launcher_config {
  char *executable;
  char *cwd;
  int executable_fd;
  int cwd_fd;
  dev_t executable_device;
  ino_t executable_inode;
  uint8_t executable_sha256[SHA256_BYTES];
  char **argv;
  size_t argc;
  char **envp;
  size_t envc;
  uint32_t grace_ms;
  uint32_t start_timeout_ms;
  uint64_t stderr_limit;
};

struct byte_queue {
  uint8_t bytes[MAX_PENDING_BYTES];
  size_t offset;
  size_t length;
  uint64_t ack_id;
  bool ack_pending;
};

struct sha256_context {
  uint32_t state[8];
  uint64_t bytes;
  uint8_t block[SHA256_BLOCK_BYTES];
  size_t block_length;
};

static volatile sig_atomic_t launcher_signal = 0;

static int publish_directory_noreplace(const char *staging,
                                       const char *target) {
  int result;

#if defined(__linux__)
#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1U << 0U)
#endif
#if defined(SYS_renameat2)
  result = (int)syscall(SYS_renameat2, AT_FDCWD, staging, AT_FDCWD, target,
                        RENAME_NOREPLACE);
#else
  errno = ENOSYS;
  result = -1;
#endif
#elif defined(__APPLE__)
  result = renamex_np(staging, target, RENAME_EXCL);
#else
  errno = ENOSYS;
  result = -1;
#endif

  if (result == 0) {
    return 0;
  }

  if (errno == EEXIST || errno == ENOTEMPTY) {
    return 73;
  }

  if (errno == ENOSYS || errno == EOPNOTSUPP || errno == EXDEV ||
      errno == EINVAL) {
    return 74;
  }

  return 75;
}

static const uint32_t sha256_constants[64] = {
    0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU,
    0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U, 0xd807aa98U, 0x12835b01U,
    0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U,
    0xc19bf174U, 0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
    0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU, 0x983e5152U,
    0xa831c66dU, 0xb00327c8U, 0xbf597fc7U, 0xc6e00bf3U, 0xd5a79147U,
    0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU,
    0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
    0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U, 0xd192e819U,
    0xd6990624U, 0xf40e3585U, 0x106aa070U, 0x19a4c116U, 0x1e376c08U,
    0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU,
    0x682e6ff3U, 0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
    0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U};

static void record_signal(int signal_number) { launcher_signal = signal_number; }

static uint32_t read_u32_be(const uint8_t *bytes) {
  return ((uint32_t)bytes[0] << 24U) | ((uint32_t)bytes[1] << 16U) |
         ((uint32_t)bytes[2] << 8U) | (uint32_t)bytes[3];
}

static uint64_t read_u64_be(const uint8_t *bytes) {
  uint64_t value = 0;
  size_t index;

  for (index = 0; index < 8; index++) {
    value = (value << 8U) | (uint64_t)bytes[index];
  }

  return value;
}

static void write_u32_be(uint8_t *bytes, uint32_t value) {
  bytes[0] = (uint8_t)(value >> 24U);
  bytes[1] = (uint8_t)(value >> 16U);
  bytes[2] = (uint8_t)(value >> 8U);
  bytes[3] = (uint8_t)value;
}

static void write_u64_be(uint8_t *bytes, uint64_t value) {
  size_t index;

  for (index = 0; index < 8; index++) {
    bytes[7U - index] = (uint8_t)value;
    value >>= 8U;
  }
}

static uint32_t rotate_right(uint32_t value, unsigned int bits) {
  return (value >> bits) | (value << (32U - bits));
}

static void sha256_transform(struct sha256_context *context,
                             const uint8_t block[SHA256_BLOCK_BYTES]) {
  uint32_t schedule[64];
  uint32_t a;
  uint32_t b;
  uint32_t c;
  uint32_t d;
  uint32_t e;
  uint32_t f;
  uint32_t g;
  uint32_t h;
  size_t index;

  for (index = 0; index < 16U; index++) {
    size_t offset = index * 4U;
    schedule[index] = ((uint32_t)block[offset] << 24U) |
                      ((uint32_t)block[offset + 1U] << 16U) |
                      ((uint32_t)block[offset + 2U] << 8U) |
                      (uint32_t)block[offset + 3U];
  }

  for (index = 16U; index < 64U; index++) {
    uint32_t previous = schedule[index - 15U];
    uint32_t before_previous = schedule[index - 2U];
    uint32_t sigma0 = rotate_right(previous, 7U) ^
                      rotate_right(previous, 18U) ^ (previous >> 3U);
    uint32_t sigma1 = rotate_right(before_previous, 17U) ^
                      rotate_right(before_previous, 19U) ^
                      (before_previous >> 10U);
    schedule[index] = schedule[index - 16U] + sigma0 +
                      schedule[index - 7U] + sigma1;
  }

  a = context->state[0];
  b = context->state[1];
  c = context->state[2];
  d = context->state[3];
  e = context->state[4];
  f = context->state[5];
  g = context->state[6];
  h = context->state[7];

  for (index = 0; index < 64U; index++) {
    uint32_t sum1 =
        rotate_right(e, 6U) ^ rotate_right(e, 11U) ^ rotate_right(e, 25U);
    uint32_t choice = (e & f) ^ ((~e) & g);
    uint32_t temporary1 =
        h + sum1 + choice + sha256_constants[index] + schedule[index];
    uint32_t sum0 =
        rotate_right(a, 2U) ^ rotate_right(a, 13U) ^ rotate_right(a, 22U);
    uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
    uint32_t temporary2 = sum0 + majority;

    h = g;
    g = f;
    f = e;
    e = d + temporary1;
    d = c;
    c = b;
    b = a;
    a = temporary1 + temporary2;
  }

  context->state[0] += a;
  context->state[1] += b;
  context->state[2] += c;
  context->state[3] += d;
  context->state[4] += e;
  context->state[5] += f;
  context->state[6] += g;
  context->state[7] += h;
}

static void sha256_init(struct sha256_context *context) {
  static const uint32_t initial_state[8] = {
      0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
      0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U};

  memcpy(context->state, initial_state, sizeof(initial_state));
  context->bytes = 0;
  context->block_length = 0;
}

static void sha256_update(struct sha256_context *context,
                          const uint8_t *bytes, size_t length) {
  size_t offset = 0;

  context->bytes += (uint64_t)length;

  while (offset < length) {
    size_t available = SHA256_BLOCK_BYTES - context->block_length;
    size_t remaining = length - offset;
    size_t copied = remaining < available ? remaining : available;

    memcpy(context->block + context->block_length, bytes + offset, copied);
    context->block_length += copied;
    offset += copied;

    if (context->block_length == SHA256_BLOCK_BYTES) {
      sha256_transform(context, context->block);
      context->block_length = 0;
    }
  }
}

static void sha256_final(struct sha256_context *context,
                         uint8_t digest[SHA256_BYTES]) {
  uint64_t bit_length = context->bytes * 8U;
  size_t index;

  context->block[context->block_length++] = 0x80U;

  if (context->block_length > 56U) {
    memset(context->block + context->block_length, 0,
           SHA256_BLOCK_BYTES - context->block_length);
    sha256_transform(context, context->block);
    context->block_length = 0;
  }

  memset(context->block + context->block_length, 0,
         56U - context->block_length);
  write_u64_be(context->block + 56U, bit_length);
  sha256_transform(context, context->block);

  for (index = 0; index < 8U; index++) {
    write_u32_be(digest + index * 4U, context->state[index]);
  }
}

static bool sha256_fd(int fd, uint8_t digest[SHA256_BYTES]) {
  struct sha256_context context;
  uint8_t buffer[IO_CHUNK_BYTES];

  sha256_init(&context);

  for (;;) {
    ssize_t count = read(fd, buffer, sizeof(buffer));

    if (count > 0) {
      sha256_update(&context, buffer, (size_t)count);
    } else if (count == 0) {
      sha256_final(&context, digest);
      return true;
    } else if (errno != EINTR) {
      return false;
    }
  }
}

static bool read_exact(int fd, uint8_t *buffer, size_t length) {
  size_t offset = 0;

  while (offset < length) {
    ssize_t count = read(fd, buffer + offset, length - offset);

    if (count > 0) {
      offset += (size_t)count;
    } else if (count == 0) {
      return false;
    } else if (errno != EINTR) {
      return false;
    }
  }

  return true;
}

static bool write_exact(int fd, const uint8_t *buffer, size_t length) {
  size_t offset = 0;

  while (offset < length) {
    ssize_t count = write(fd, buffer + offset, length - offset);

    if (count > 0) {
      offset += (size_t)count;
    } else if (count < 0 && errno == EINTR) {
      continue;
    } else {
      return false;
    }
  }

  return true;
}

static bool emit_frame(uint8_t type, const uint8_t *body, size_t body_length) {
  uint8_t header[5];

  if (body_length > UINT32_MAX - 1U) {
    return false;
  }

  write_u32_be(header, (uint32_t)body_length + 1U);
  header[4] = type;

  return write_exact(STDOUT_FILENO, header, sizeof(header)) &&
         (body_length == 0 || write_exact(STDOUT_FILENO, body, body_length));
}

static bool cursor_take(struct cursor *cursor, size_t length,
                        const uint8_t **value) {
  if (length > cursor->length - cursor->offset) {
    return false;
  }

  *value = cursor->bytes + cursor->offset;
  cursor->offset += length;
  return true;
}

static bool cursor_u8(struct cursor *cursor, uint8_t *value) {
  const uint8_t *bytes;

  if (!cursor_take(cursor, 1, &bytes)) {
    return false;
  }

  *value = bytes[0];
  return true;
}

static bool cursor_u32(struct cursor *cursor, uint32_t *value) {
  const uint8_t *bytes;

  if (!cursor_take(cursor, 4, &bytes)) {
    return false;
  }

  *value = read_u32_be(bytes);
  return true;
}

static bool cursor_u64(struct cursor *cursor, uint64_t *value) {
  const uint8_t *bytes;

  if (!cursor_take(cursor, 8, &bytes)) {
    return false;
  }

  *value = read_u64_be(bytes);
  return true;
}

static bool valid_utf8(const uint8_t *bytes, size_t length) {
  size_t index = 0;

  while (index < length) {
    uint8_t first = bytes[index++];
    uint32_t codepoint;
    size_t continuation;
    uint32_t minimum;
    size_t offset;

    if (first <= 0x7FU) {
      if (first == 0) {
        return false;
      }
      continue;
    }

    if (first >= 0xC2U && first <= 0xDFU) {
      continuation = 1;
      codepoint = first & 0x1FU;
      minimum = 0x80U;
    } else if (first >= 0xE0U && first <= 0xEFU) {
      continuation = 2;
      codepoint = first & 0x0FU;
      minimum = 0x800U;
    } else if (first >= 0xF0U && first <= 0xF4U) {
      continuation = 3;
      codepoint = first & 0x07U;
      minimum = 0x10000U;
    } else {
      return false;
    }

    if (continuation > length - index) {
      return false;
    }

    for (offset = 0; offset < continuation; offset++) {
      uint8_t next = bytes[index++];

      if ((next & 0xC0U) != 0x80U) {
        return false;
      }

      codepoint = (codepoint << 6U) | (uint32_t)(next & 0x3FU);
    }

    if (codepoint < minimum || codepoint > 0x10FFFFU ||
        (codepoint >= 0xD800U && codepoint <= 0xDFFFU)) {
      return false;
    }
  }

  return true;
}

static bool cursor_string(struct cursor *cursor, char **value) {
  uint32_t length;
  const uint8_t *bytes;
  char *copy;

  if (!cursor_u32(cursor, &length) || length > MAX_CONFIG_STRING ||
      !cursor_take(cursor, length, &bytes) || !valid_utf8(bytes, length)) {
    return false;
  }

  copy = malloc((size_t)length + 1U);
  if (copy == NULL) {
    return false;
  }

  memcpy(copy, bytes, length);
  copy[length] = '\0';
  *value = copy;
  return true;
}

static bool valid_env_name(const char *name) {
  size_t index;

  if (name[0] == '\0' ||
      !((name[0] >= 'A' && name[0] <= 'Z') ||
        (name[0] >= 'a' && name[0] <= 'z') || name[0] == '_')) {
    return false;
  }

  for (index = 1; name[index] != '\0'; index++) {
    char character = name[index];

    if (!((character >= 'A' && character <= 'Z') ||
          (character >= 'a' && character <= 'z') ||
          (character >= '0' && character <= '9') || character == '_')) {
      return false;
    }
  }

  return true;
}

static int open_executable(const char *path) {
#if defined(__linux__)
  return open(path, O_RDONLY | O_CLOEXEC);
#else
  return open(path, O_EXEC | O_CLOEXEC);
#endif
}

static int open_working_directory(const char *path) {
#if defined(__linux__)
  return open(path, O_PATH | O_DIRECTORY | O_CLOEXEC);
#else
  return open(path, O_SEARCH | O_CLOEXEC);
#endif
}

static void free_config(struct launcher_config *config) {
  size_t index;

  free(config->executable);
  free(config->cwd);
  if (config->executable_fd >= 0) {
    (void)close(config->executable_fd);
  }
  if (config->cwd_fd >= 0) {
    (void)close(config->cwd_fd);
  }

  if (config->argv != NULL) {
    for (index = 0; index < config->argc + 1U; index++) {
      free(config->argv[index]);
    }
    free(config->argv);
  }

  if (config->envp != NULL) {
    for (index = 0; index < config->envc; index++) {
      free(config->envp[index]);
    }
    free(config->envp);
  }

  memset(config, 0, sizeof(*config));
  config->executable_fd = -1;
  config->cwd_fd = -1;
}

static bool parse_config(const uint8_t *bytes, size_t length,
                         struct launcher_config *config) {
  struct cursor cursor = {.bytes = bytes, .length = length, .offset = 0};
  uint8_t version;
  uint32_t argc;
  uint32_t envc;
  size_t index;
  char *raw_executable = NULL;
  char *raw_cwd = NULL;
  const uint8_t *executable_sha256 = NULL;

  memset(config, 0, sizeof(*config));
  config->executable_fd = -1;
  config->cwd_fd = -1;

  if (!cursor_u8(&cursor, &version) || version != BOOT_VERSION ||
      !cursor_u32(&cursor, &config->grace_ms) || config->grace_ms < 1U ||
      config->grace_ms > 5000U ||
      !cursor_u32(&cursor, &config->start_timeout_ms) ||
      config->start_timeout_ms < 1U || config->start_timeout_ms > 60000U ||
      !cursor_u64(&cursor, &config->stderr_limit) ||
      config->stderr_limit > MAX_FRAME_BYTES ||
      !cursor_take(&cursor, SHA256_BYTES, &executable_sha256) ||
      !cursor_string(&cursor, &raw_executable) ||
      !cursor_string(&cursor, &raw_cwd) || !cursor_u32(&cursor, &argc) ||
      argc > MAX_ARGUMENTS) {
    free(raw_executable);
    free(raw_cwd);
    return false;
  }

  memcpy(config->executable_sha256, executable_sha256, SHA256_BYTES);

  config->argc = argc;
  config->argv = calloc((size_t)argc + 2U, sizeof(char *));
  if (config->argv == NULL) {
    free(raw_executable);
    free(raw_cwd);
    return false;
  }

  for (index = 0; index < argc; index++) {
    if (!cursor_string(&cursor, &config->argv[index + 1U])) {
      free(raw_executable);
      free(raw_cwd);
      free_config(config);
      return false;
    }
  }

  if (!cursor_u32(&cursor, &envc) || envc > MAX_ENVIRONMENT) {
    free(raw_executable);
    free(raw_cwd);
    free_config(config);
    return false;
  }

  config->envc = envc;
  config->envp = calloc((size_t)envc + 1U, sizeof(char *));
  if (config->envp == NULL) {
    free(raw_executable);
    free(raw_cwd);
    free_config(config);
    return false;
  }

  for (index = 0; index < envc; index++) {
    char *name = NULL;
    char *value = NULL;
    size_t assignment_length;

    if (!cursor_string(&cursor, &name) || !cursor_string(&cursor, &value) ||
        !valid_env_name(name)) {
      free(name);
      free(value);
      free(raw_executable);
      free(raw_cwd);
      free_config(config);
      return false;
    }

    assignment_length = strlen(name) + strlen(value) + 2U;
    config->envp[index] = malloc(assignment_length);
    if (config->envp[index] == NULL) {
      free(name);
      free(value);
      free(raw_executable);
      free(raw_cwd);
      free_config(config);
      return false;
    }

    (void)snprintf(config->envp[index], assignment_length, "%s=%s", name,
                   value);
    free(name);
    free(value);
  }

  if (cursor.offset != cursor.length || raw_executable[0] != '/' ||
      raw_cwd[0] != '/') {
    free(raw_executable);
    free(raw_cwd);
    free_config(config);
    return false;
  }

  config->argv[0] = strdup(raw_executable);
  if (config->argv[0] == NULL) {
    free(raw_executable);
    free(raw_cwd);
    free_config(config);
    return false;
  }

  config->executable = raw_executable;
  config->cwd = raw_cwd;
  return true;
}

static bool resolve_config_paths(struct launcher_config *config) {
  char *canonical_executable = realpath(config->executable, NULL);
  char *canonical_cwd = realpath(config->cwd, NULL);
  int readable_executable_fd = -1;
  struct stat executable_stat;
  struct stat readable_executable_stat;
  struct stat cwd_stat;
  uint8_t executable_sha256[SHA256_BYTES];
  bool valid = false;

  if (canonical_executable != NULL) {
    config->executable_fd = open_executable(canonical_executable);
#if defined(__linux__)
    readable_executable_fd = config->executable_fd;
#else
    readable_executable_fd = open(canonical_executable, O_RDONLY | O_CLOEXEC);
#endif
  }
  if (canonical_cwd != NULL) {
    config->cwd_fd = open_working_directory(canonical_cwd);
  }

  if (canonical_executable != NULL && canonical_cwd != NULL &&
      config->executable_fd >= 0 && readable_executable_fd >= 0 &&
      config->cwd_fd >= 0 &&
      fstat(config->executable_fd, &executable_stat) == 0 &&
      fstat(readable_executable_fd, &readable_executable_stat) == 0 &&
      S_ISREG(executable_stat.st_mode) &&
      executable_stat.st_dev == readable_executable_stat.st_dev &&
      executable_stat.st_ino == readable_executable_stat.st_ino &&
      access(canonical_executable, X_OK) == 0 &&
      fstat(config->cwd_fd, &cwd_stat) == 0 && S_ISDIR(cwd_stat.st_mode) &&
      sha256_fd(readable_executable_fd, executable_sha256) &&
      memcmp(executable_sha256, config->executable_sha256, SHA256_BYTES) == 0) {
    config->executable_device = executable_stat.st_dev;
    config->executable_inode = executable_stat.st_ino;
    valid = true;
  }

  if (readable_executable_fd >= 0 &&
      readable_executable_fd != config->executable_fd) {
    (void)close(readable_executable_fd);
  }

  if (!valid) {
    free(canonical_executable);
    free(canonical_cwd);
    return false;
  }

  free(config->executable);
  free(config->cwd);
  config->executable = canonical_executable;
  config->cwd = canonical_cwd;
  return true;
}

static bool load_bootstrap(struct launcher_config *config) {
  uint8_t header[4];
  uint32_t length;
  uint8_t *payload;
  bool valid;

  if (!read_exact(STDIN_FILENO, header, sizeof(header))) {
    return false;
  }

  length = read_u32_be(header);
  if (length < 2U || length > MAX_FRAME_BYTES) {
    return false;
  }

  payload = malloc(length);
  if (payload == NULL || !read_exact(STDIN_FILENO, payload, length)) {
    free(payload);
    return false;
  }

  valid = payload[0] == 'B' && parse_config(payload + 1U, length - 1U, config);
  free(payload);
  return valid;
}

static bool owner_connected(void) {
  struct pollfd descriptor = {
      .fd = STDIN_FILENO, .events = POLLHUP, .revents = 0};
  int result;

  if (launcher_signal != 0) {
    return false;
  }

  do {
    result = poll(&descriptor, 1, 0);
  } while (result < 0 && errno == EINTR);

  return result >= 0 &&
         (descriptor.revents & (POLLHUP | POLLERR | POLLNVAL)) == 0;
}

static bool make_pipe(int descriptors[2]) {
  if (pipe(descriptors) != 0) {
    return false;
  }

  return true;
}

static bool close_on_exec(int fd) {
  int flags = fcntl(fd, F_GETFD);
  return flags >= 0 && fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0;
}

static bool nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL);
  return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

static void close_if_open(int *fd) {
  if (*fd >= 0) {
    (void)close(*fd);
    *fd = -1;
  }
}

static int64_t monotonic_ms(void) {
  struct timespec now;

  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
    return 0;
  }

  return (int64_t)now.tv_sec * 1000LL + (int64_t)now.tv_nsec / 1000000LL;
}

static bool process_group_alive(pid_t process_group) {
  if (kill(-process_group, 0) == 0) {
    return true;
  }

  return errno == EPERM;
}

static void signal_process_group(pid_t process_group, int signal_number) {
  if (process_group > 0) {
    (void)kill(-process_group, signal_number);
  }
}

/*
 * Observe the leader without releasing its PID. The PID is also the process
 * group identifier, so reaping it before the last group signal would permit
 * PID reuse to redirect a later negative-PID kill at an unrelated group.
 */
static bool child_has_exited(pid_t child_pid) {
  siginfo_t info;
  int result;

  memset(&info, 0, sizeof(info));
  do {
    result = waitid(P_PID, (id_t)child_pid, &info,
                    WEXITED | WNOHANG | WNOWAIT);
  } while (result != 0 && errno == EINTR);

  return result == 0 && info.si_pid == child_pid;
}

static bool reap_child(pid_t child_pid, int *child_status) {
  pid_t waited;

  do {
    waited = waitpid(child_pid, child_status, WNOHANG);
  } while (waited < 0 && errno == EINTR);

  return waited == child_pid;
}

/*
 * Retire descendants that outlived the leader. `process_group_alive` probes
 * the group with kill(2), which still succeeds for un-reaped zombies, so a
 * killed group only becomes observably empty once every member's status has
 * been collected. Orphaned descendants are reparented away from the leader,
 * so the launcher declares itself a child subreaper on Linux and adopts them
 * instead. macOS has no subreaper interface, but launchd reaps orphans
 * promptly, so the group empties there without launcher involvement.
 *
 * Only safe once the leader has been reaped: before that, an untargeted wait
 * could consume the leader's status and release its PID while group-directed
 * signals are still outstanding.
 */
static void reap_orphaned_descendants(void) {
  for (;;) {
    pid_t waited = waitpid(-1, NULL, WNOHANG);

    if (waited > 0) {
      continue;
    }
    if (waited < 0 && errno == EINTR) {
      continue;
    }

    return;
  }
}

static void request_child_subreaper(void) {
#if defined(__linux__)
  (void)prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0);
#endif
}

/*
 * Lifeline watchdog.
 *
 * Every launcher teardown path retires the server process group, but a
 * launcher destroyed without running any of its own code -- SIGKILL, or a host
 * that tears the process down -- runs none of them. Closing the server's stdin
 * is then the only backstop, and a server that never reads stdin never
 * observes it, so the group is reparented and survives.
 *
 * The watchdog is a second child forked before any other descriptor exists. It
 * holds the read end of a private lifeline pipe whose write end only the
 * launcher retains, and leaves the launcher's session so a signal aimed at the
 * launcher's own group cannot take it along. Losing that write end without an
 * explicit stand-down means the launcher died while its group was still live.
 *
 * It then sends exactly one round of signals. Once the launcher is gone the
 * leader is reparented and reaped, releasing its PID, and the PID is also the
 * group identifier -- so a TERM-then-KILL escalation could point its second
 * signal at an unrelated group that reused the number. A single SIGKILL keeps
 * that exposure to the interval between the launcher's death and this wake-up.
 * The direct kill covers the window before the leader reaches `setsid`, where
 * no group of its own exists yet; `terminate_starting_child` pairs them for
 * the same reason.
 */
static int lifeline_watchdog(int lifeline_fd) {
  struct sigaction ignored;
  uint8_t identifier[4];
  uint8_t stand_down;
  pid_t process_group;
  ssize_t count;

  (void)setsid();
  (void)close(STDIN_FILENO);
  (void)close(STDOUT_FILENO);
  (void)close(STDERR_FILENO);

  memset(&ignored, 0, sizeof(ignored));
  ignored.sa_handler = SIG_IGN;
  (void)sigemptyset(&ignored.sa_mask);
  (void)sigaction(SIGTERM, &ignored, NULL);
  (void)sigaction(SIGINT, &ignored, NULL);
  (void)sigaction(SIGHUP, &ignored, NULL);

  if (!read_exact(lifeline_fd, identifier, sizeof(identifier))) {
    return 0;
  }

  process_group = (pid_t)read_u32_be(identifier);

  do {
    count = read(lifeline_fd, &stand_down, sizeof(stand_down));
  } while (count < 0 && errno == EINTR);

  if (count > 0) {
    return 0;
  }

  signal_process_group(process_group, SIGKILL);
  (void)kill(process_group, SIGKILL);
  return 0;
}

static bool start_lifeline_watchdog(int *lifeline_fd) {
  int lifeline[2] = {-1, -1};
  pid_t watchdog_pid;

  if (!make_pipe(lifeline)) {
    return false;
  }

  /*
   * The server inherits the write end across `fork` and must not carry it past
   * `execve`: a lifeline the server itself holds open never reports the
   * launcher's death.
   */
  if (!close_on_exec(lifeline[1])) {
    close_if_open(&lifeline[0]);
    close_if_open(&lifeline[1]);
    return false;
  }

  watchdog_pid = fork();
  if (watchdog_pid < 0) {
    close_if_open(&lifeline[0]);
    close_if_open(&lifeline[1]);
    return false;
  }

  if (watchdog_pid == 0) {
    (void)close(lifeline[1]);
    _exit(lifeline_watchdog(lifeline[0]));
  }

  (void)close(lifeline[0]);
  *lifeline_fd = lifeline[1];
  return true;
}

static void arm_lifeline(int lifeline_fd, pid_t process_group) {
  uint8_t identifier[4];

  write_u32_be(identifier, (uint32_t)process_group);
  (void)write_exact(lifeline_fd, identifier, sizeof(identifier));
}

/*
 * The watchdog's group-directed SIGKILL is only sound while the leader's PID is
 * still pinned by an uncollected status, so standing the watchdog down belongs
 * to releasing that PID rather than to exiting. Every caller has already
 * SIGKILLed the group and reaps immediately afterwards.
 */
static void disarm_lifeline(int *lifeline_fd) {
  static const uint8_t stand_down = 1U;

  if (*lifeline_fd >= 0) {
    (void)write_exact(*lifeline_fd, &stand_down, sizeof(stand_down));
    (void)close(*lifeline_fd);
    *lifeline_fd = -1;
  }
}

static void queue_compact(struct byte_queue *queue) {
  if (queue->offset > 0 && queue->length > 0) {
    memmove(queue->bytes, queue->bytes + queue->offset, queue->length);
  }

  queue->offset = 0;
}

static bool queue_append(struct byte_queue *queue, const uint8_t *bytes,
                         size_t length) {
  if (length > MAX_PENDING_BYTES - queue->length) {
    return false;
  }

  if (queue->offset + queue->length + length > MAX_PENDING_BYTES) {
    queue_compact(queue);
  }

  memcpy(queue->bytes + queue->offset + queue->length, bytes, length);
  queue->length += length;
  return true;
}

static bool acknowledge_pending(struct byte_queue *queue) {
  uint8_t ack[8];

  if (!queue->ack_pending || queue->length > 0) {
    return true;
  }

  write_u64_be(ack, queue->ack_id);
  queue->ack_pending = false;
  return emit_frame('A', ack, sizeof(ack));
}

static void begin_eof_wait(enum shutdown_phase *phase, int *child_stdin,
                           uint32_t grace_ms, int64_t *deadline) {
  close_if_open(child_stdin);
  *phase = PHASE_EOF_WAIT;
  *deadline = monotonic_ms() + (int64_t)grace_ms;
}

static void begin_shutdown(enum shutdown_phase *phase,
                           enum finish_reason *finish_reason,
                           enum finish_reason requested_reason,
                           struct byte_queue *pending, int *child_stdin,
                           uint32_t grace_ms, int64_t *deadline) {
  if (*phase != PHASE_RUNNING) {
    return;
  }

  *finish_reason = requested_reason;

  if (requested_reason != FINISH_CLOSE) {
    pending->length = 0;
    pending->ack_pending = false;
    begin_eof_wait(phase, child_stdin, grace_ms, deadline);
  } else if (pending->length == 0) {
    begin_eof_wait(phase, child_stdin, grace_ms, deadline);
  } else {
    *phase = PHASE_FLUSH_WAIT;
    *deadline = monotonic_ms() + (int64_t)grace_ms;
  }
}

static void handle_child_stdin_failure(
    pid_t child_pid, bool *child_exited, bool *child_stdin_failed,
    enum shutdown_phase *phase, enum finish_reason *finish_reason,
    struct byte_queue *pending, int *child_stdin, uint32_t grace_ms,
    int64_t *deadline) {
  enum finish_reason reason = FINISH_PROTOCOL_ERROR;

  if (!*child_exited) {
    if (child_has_exited(child_pid)) {
      *child_exited = true;
      reason = FINISH_SERVER_EXIT;
    } else {
      *child_stdin_failed = true;
    }
  } else {
    reason = FINISH_SERVER_EXIT;
  }

  begin_shutdown(phase, finish_reason, reason, pending, child_stdin, grace_ms,
                 deadline);
}

static bool consume_input_frames(
    uint8_t *input, size_t *input_length, struct byte_queue *pending,
    bool *stdout_ack_pending,
    enum shutdown_phase *phase, enum finish_reason *finish_reason,
    int *child_stdin, uint32_t grace_ms, int64_t *deadline) {
  size_t consumed = 0;

  while (*input_length - consumed >= 4U) {
    uint32_t frame_length = read_u32_be(input + consumed);

    if (frame_length < 1U || frame_length > MAX_FRAME_BYTES) {
      begin_shutdown(phase, finish_reason, FINISH_PROTOCOL_ERROR, pending,
                     child_stdin, grace_ms, deadline);
      return false;
    }

    if (*input_length - consumed < (size_t)frame_length + 4U) {
      break;
    }

    if (input[consumed + 4U] == 'D' && *phase == PHASE_RUNNING) {
      uint64_t ack_id;

      if (frame_length < 9U) {
        begin_shutdown(phase, finish_reason, FINISH_PROTOCOL_ERROR, pending,
                       child_stdin, grace_ms, deadline);
        return false;
      }

      if (pending->ack_pending) {
        begin_shutdown(phase, finish_reason, FINISH_PROTOCOL_ERROR, pending,
                       child_stdin, grace_ms, deadline);
        return false;
      }

      ack_id = read_u64_be(input + consumed + 5U);

      if (!queue_append(pending, input + consumed + 13U,
                        (size_t)frame_length - 9U)) {
        break;
      }

      pending->ack_id = ack_id;
      pending->ack_pending = true;

      if (!acknowledge_pending(pending)) {
        begin_shutdown(phase, finish_reason, FINISH_OWNER_EOF, pending,
                       child_stdin, grace_ms, deadline);
        return false;
      }
    } else if (input[consumed + 4U] == 'K' && frame_length == 1U &&
               *stdout_ack_pending) {
      *stdout_ack_pending = false;
    } else if (input[consumed + 4U] == 'C' && frame_length == 1U) {
      begin_shutdown(phase, finish_reason, FINISH_CLOSE, pending, child_stdin,
                     grace_ms, deadline);
    } else {
      begin_shutdown(phase, finish_reason, FINISH_PROTOCOL_ERROR, pending,
                     child_stdin, grace_ms, deadline);
      return false;
    }

    consumed += (size_t)frame_length + 4U;
  }

  if (consumed > 0) {
    memmove(input, input + consumed, *input_length - consumed);
    *input_length -= consumed;
  }

  return true;
}

static bool emit_stderr(const uint8_t *bytes, size_t length,
                        uint64_t stderr_limit, uint64_t *stderr_emitted,
                        bool *stderr_truncated) {
  size_t allowed = 0;

  if (*stderr_emitted < stderr_limit) {
    uint64_t remaining = stderr_limit - *stderr_emitted;
    allowed = length < remaining ? length : (size_t)remaining;
  }

  if (allowed > 0 && !emit_frame('E', bytes, allowed)) {
    return false;
  }

  *stderr_emitted += allowed;

  if (allowed < length && !*stderr_truncated) {
    *stderr_truncated = true;
    if (!emit_frame('T', NULL, 0)) {
      return false;
    }
  }

  return true;
}

#if !defined(__linux__)
/*
 * Descriptor exec is unavailable on macOS -- `fexecve` is undeclared and
 * execing `/dev/fd/N` fails with ENOTSUP for O_EXEC and EACCES for O_RDONLY --
 * so the identity that is hashed and the identity that is executed can only be
 * connected through the path. Re-reading the path here narrows the replacement
 * window from "the whole hash", which a rename against a 64 MiB target wins by
 * three hundred milliseconds, to this call pair. The hashed descriptor is
 * still open, so the inode number it reports cannot have been recycled by a
 * different file underneath the comparison.
 */
static bool executable_identity_unchanged(const struct launcher_config *config) {
  struct stat current;

  return stat(config->executable, &current) == 0 && S_ISREG(current.st_mode) &&
         current.st_dev == config->executable_device &&
         current.st_ino == config->executable_inode;
}
#endif

static int child_main(struct launcher_config *config,
                      const int child_stdin[2], const int child_stdout[2],
                      const int child_stderr[2], const int exec_status[2]) {
  struct sigaction default_action;
  int exec_errno;

  (void)close(child_stdin[1]);
  (void)close(child_stdout[0]);
  (void)close(child_stderr[0]);
  (void)close(exec_status[0]);

  memset(&default_action, 0, sizeof(default_action));
  default_action.sa_handler = SIG_DFL;
  (void)sigemptyset(&default_action.sa_mask);

  if (sigaction(SIGPIPE, &default_action, NULL) != 0 || setsid() < 0 ||
      !resolve_config_paths(config) || fchdir(config->cwd_fd) != 0 ||
      dup2(child_stdin[0], STDIN_FILENO) < 0 ||
      dup2(child_stdout[1], STDOUT_FILENO) < 0 ||
      dup2(child_stderr[1], STDERR_FILENO) < 0) {
    exec_errno = errno;
    (void)write_exact(exec_status[1], (const uint8_t *)&exec_errno,
                      sizeof(exec_errno));
    return 126;
  }

  (void)close(child_stdin[0]);
  (void)close(child_stdout[1]);
  (void)close(child_stderr[1]);
  (void)close(config->cwd_fd);

#if defined(__linux__)
  fexecve(config->executable_fd, config->argv, config->envp);
  exec_errno = errno;

  /*
   * Linux implements script fexecve through /proc/self/fd. A close-on-exec
   * descriptor makes the interpreter handoff fail with ENOENT, so retry
   * scripts with the descriptor intentionally inherited. Native executables
   * take the first path and do not inherit the descriptor.
   */
  if (exec_errno == ENOENT) {
    int descriptor_flags = fcntl(config->executable_fd, F_GETFD);

    if (descriptor_flags >= 0 &&
        fcntl(config->executable_fd, F_SETFD,
              descriptor_flags & ~FD_CLOEXEC) == 0) {
      fexecve(config->executable_fd, config->argv, config->envp);
      exec_errno = errno;
    }
  }
#else
  if (executable_identity_unchanged(config)) {
    execve(config->executable, config->argv, config->envp);
    exec_errno = errno;
  } else {
    exec_errno = EPERM;
  }
#endif
  (void)write_exact(exec_status[1], (const uint8_t *)&exec_errno,
                    sizeof(exec_errno));
  return 127;
}

static enum startup_result await_child_start(int exec_status_fd,
                                             uint32_t timeout_ms) {
  int64_t deadline = monotonic_ms() + (int64_t)timeout_ms;

  for (;;) {
    struct pollfd descriptors[2] = {
        {.fd = exec_status_fd, .events = POLLIN | POLLHUP, .revents = 0},
        {.fd = STDIN_FILENO, .events = POLLHUP, .revents = 0}};
    int64_t remaining = deadline - monotonic_ms();
    int poll_result;

    if (remaining <= 0) {
      return STARTUP_TIMEOUT;
    }

    poll_result = poll(descriptors, 2, (int)remaining);
    if (poll_result == 0) {
      return STARTUP_TIMEOUT;
    }
    if (poll_result < 0) {
      if (errno == EINTR) {
        continue;
      }
      return STARTUP_FAILED;
    }

    if ((descriptors[1].revents & (POLLHUP | POLLERR | POLLNVAL)) != 0) {
      return STARTUP_OWNER_EOF;
    }

    if ((descriptors[0].revents &
         (POLLIN | POLLHUP | POLLERR | POLLNVAL)) != 0) {
      int exec_errno = 0;
      ssize_t count;

      do {
        count = read(exec_status_fd, &exec_errno, sizeof(exec_errno));
      } while (count < 0 && errno == EINTR);

      return count == 0 ? STARTUP_READY : STARTUP_FAILED;
    }
  }
}

static void terminate_starting_child(pid_t child_pid, int *lifeline_fd) {
  int64_t deadline = monotonic_ms() + 1000LL;

  signal_process_group(child_pid, SIGKILL);
  (void)kill(child_pid, SIGKILL);
  disarm_lifeline(lifeline_fd);

  for (;;) {
    pid_t waited = waitpid(child_pid, NULL, WNOHANG);

    if (waited == child_pid || (waited < 0 && errno == ECHILD)) {
      return;
    }
    if (waited < 0 && errno != EINTR) {
      return;
    }
    if (monotonic_ms() >= deadline) {
      return;
    }

    (void)poll(NULL, 0, 10);
  }
}

static int finish_supervision(enum finish_reason reason, bool child_reaped,
                              int child_status, bool stderr_truncated) {
  uint8_t finish[6];
  int32_t exit_value = -1;

  if (child_reaped && WIFEXITED(child_status)) {
    exit_value = WEXITSTATUS(child_status);
  } else if (child_reaped && WIFSIGNALED(child_status)) {
    exit_value = -WTERMSIG(child_status);
  }

  finish[0] = (uint8_t)reason;
  write_u32_be(finish + 1U, (uint32_t)exit_value);
  finish[5] = stderr_truncated ? 1U : 0U;
  return emit_frame('X', finish, sizeof(finish)) ? 0 : 74;
}

static int supervise(const struct launcher_config *config, pid_t child_pid,
                     int *lifeline_fd, int child_stdin, int child_stdout,
                     int child_stderr) {
  uint8_t input[MAX_FRAME_BYTES + 4U];
  size_t input_length = 0;
  struct byte_queue pending = {
      .offset = 0, .length = 0, .ack_id = 0, .ack_pending = false};
  enum shutdown_phase phase = PHASE_RUNNING;
  enum finish_reason finish_reason = FINISH_SERVER_EXIT;
  int64_t deadline = 0;
  uint64_t stderr_emitted = 0;
  bool stderr_truncated = false;
  bool child_exited = false;
  bool child_reaped = false;
  bool child_stdin_failed = false;
  int child_status = 0;
  bool stdout_eof = false;
  bool stdout_ack_pending = false;
  bool stderr_eof = false;

  if (!nonblocking(STDIN_FILENO) || !nonblocking(child_stdin) ||
      !nonblocking(child_stdout) || !nonblocking(child_stderr)) {
    terminate_starting_child(child_pid, lifeline_fd);
    return 70;
  }

  if (!emit_frame('R', NULL, 0)) {
    terminate_starting_child(child_pid, lifeline_fd);
    return 70;
  }

  for (;;) {
    struct pollfd descriptors[4];
    nfds_t descriptor_count = 0;
    int poll_timeout = 100;
    int64_t now = monotonic_ms();
    bool group_alive;
    size_t index;

    if (launcher_signal != 0 && phase < PHASE_TERM_WAIT) {
      finish_reason = FINISH_LAUNCHER_SIGNAL;
      pending.length = 0;
      pending.ack_pending = false;
      close_if_open(&child_stdin);
      signal_process_group(child_pid, SIGTERM);
      phase = PHASE_TERM_WAIT;
      deadline = now + (int64_t)config->grace_ms;
    }

    if (!child_exited && child_has_exited(child_pid)) {
      child_exited = true;
      if (child_stdin_failed && phase == PHASE_EOF_WAIT) {
        finish_reason = FINISH_SERVER_EXIT;
      }
      if (phase == PHASE_RUNNING) {
        begin_shutdown(&phase, &finish_reason, FINISH_SERVER_EXIT, &pending,
                       &child_stdin, config->grace_ms, &deadline);
        signal_process_group(child_pid, SIGTERM);
        phase = PHASE_TERM_WAIT;
        deadline = now + (int64_t)config->grace_ms;
      }
    }

    if (phase == PHASE_FLUSH_WAIT && deadline > 0 && now >= deadline) {
      pending.length = 0;
      pending.ack_pending = false;
      begin_eof_wait(&phase, &child_stdin, config->grace_ms, &deadline);
    } else if (phase == PHASE_EOF_WAIT && deadline > 0 && now >= deadline) {
      signal_process_group(child_pid, SIGTERM);
      phase = PHASE_TERM_WAIT;
      deadline = now + (int64_t)config->grace_ms;
    } else if (phase == PHASE_TERM_WAIT && now >= deadline) {
      uint32_t final_wait_ms =
          config->grace_ms > MIN_FINAL_KILL_WAIT_MS
              ? config->grace_ms
              : MIN_FINAL_KILL_WAIT_MS;
      signal_process_group(child_pid, SIGKILL);
      phase = PHASE_KILL_WAIT;
      deadline = now + (int64_t)final_wait_ms;
    } else if (phase == PHASE_KILL_WAIT && now >= deadline) {
      close_if_open(&child_stdout);
      close_if_open(&child_stderr);
      if (!child_reaped) {
        disarm_lifeline(lifeline_fd);
        child_reaped = reap_child(child_pid, &child_status);
      }
      return finish_supervision(FINISH_TERMINATION_TIMEOUT, child_reaped,
                                child_status, stderr_truncated);
    }

    /*
     * SIGKILL above is the final process-group signal. Only now may the leader
     * be reaped and its numeric PID released, and the lifeline watchdog stands
     * down with it because its own signal names the same number. Subsequent
     * loops merely observe whether any same-group descendants remain.
     */
    if (phase == PHASE_KILL_WAIT && child_exited && !child_reaped) {
      disarm_lifeline(lifeline_fd);
      child_reaped = reap_child(child_pid, &child_status);
    }

    if (phase == PHASE_KILL_WAIT && child_reaped) {
      reap_orphaned_descendants();
    }

    if (phase == PHASE_RUNNING && input_length > 0) {
      (void)consume_input_frames(
          input, &input_length, &pending, &stdout_ack_pending, &phase,
          &finish_reason, &child_stdin, config->grace_ms, &deadline);
    }

    /*
     * No group-directed signals occur after the leader is reaped in
     * PHASE_KILL_WAIT. It is therefore safe to probe the numeric PGID: reuse
     * can only cause a conservative timeout, never signal an unrelated group.
     */
    group_alive = process_group_alive(child_pid);
    if (phase != PHASE_RUNNING && child_reaped && !group_alive &&
        stdout_eof && stderr_eof) {
      return finish_supervision(finish_reason, child_reaped, child_status,
                                stderr_truncated);
    }

    if (phase != PHASE_RUNNING && deadline > 0) {
      int64_t remaining = deadline - now;
      if (remaining < 0) {
        remaining = 0;
      }
      if (remaining < poll_timeout) {
        poll_timeout = (int)remaining;
      }
    }

    if ((phase == PHASE_RUNNING || stdout_ack_pending) &&
        input_length < sizeof(input)) {
      descriptors[descriptor_count].fd = STDIN_FILENO;
      descriptors[descriptor_count].events = POLLIN | POLLHUP;
      descriptors[descriptor_count].revents = 0;
      descriptor_count++;
    }

    if (child_stdout >= 0 && !stdout_ack_pending) {
      descriptors[descriptor_count].fd = child_stdout;
      descriptors[descriptor_count].events = POLLIN | POLLHUP;
      descriptors[descriptor_count].revents = 0;
      descriptor_count++;
    }

    if (child_stderr >= 0) {
      descriptors[descriptor_count].fd = child_stderr;
      descriptors[descriptor_count].events = POLLIN | POLLHUP;
      descriptors[descriptor_count].revents = 0;
      descriptor_count++;
    }

    if (child_stdin >= 0 && pending.length > 0) {
      descriptors[descriptor_count].fd = child_stdin;
      descriptors[descriptor_count].events = POLLOUT | POLLHUP;
      descriptors[descriptor_count].revents = 0;
      descriptor_count++;
    }

    if (poll(descriptors, descriptor_count, poll_timeout) < 0) {
      if (errno == EINTR) {
        continue;
      }
      begin_shutdown(&phase, &finish_reason, FINISH_PROTOCOL_ERROR,
                     &pending, &child_stdin, config->grace_ms, &deadline);
      continue;
    }

    for (index = 0; index < descriptor_count; index++) {
      int fd = descriptors[index].fd;
      short events = descriptors[index].revents;

      if (events == 0) {
        continue;
      }

      if (fd == STDIN_FILENO && (events & (POLLIN | POLLHUP)) != 0) {
        ssize_t count =
            read(STDIN_FILENO, input + input_length,
                 sizeof(input) - input_length);

        if (count > 0) {
          input_length += (size_t)count;
          (void)consume_input_frames(
              input, &input_length, &pending, &stdout_ack_pending, &phase,
              &finish_reason, &child_stdin, config->grace_ms, &deadline);
        } else if (count == 0) {
          stdout_ack_pending = false;
          begin_shutdown(&phase, &finish_reason, FINISH_OWNER_EOF, &pending,
                         &child_stdin, config->grace_ms, &deadline);
        } else if (errno != EAGAIN && errno != EWOULDBLOCK &&
                   errno != EINTR) {
          stdout_ack_pending = false;
          begin_shutdown(&phase, &finish_reason, FINISH_OWNER_EOF, &pending,
                         &child_stdin, config->grace_ms, &deadline);
        }
      } else if (fd == child_stdout &&
                 (events & (POLLIN | POLLHUP)) != 0) {
        uint8_t chunk[IO_CHUNK_BYTES];
        ssize_t count = read(child_stdout, chunk, sizeof(chunk));

        if (count > 0) {
          if (!emit_frame('O', chunk, (size_t)count)) {
            begin_shutdown(&phase, &finish_reason, FINISH_OWNER_EOF,
                           &pending, &child_stdin, config->grace_ms,
                           &deadline);
            close_if_open(&child_stdout);
            stdout_eof = true;
          } else {
            stdout_ack_pending = true;
          }
        } else if (count == 0) {
          close_if_open(&child_stdout);
          stdout_eof = true;
        } else if (errno != EAGAIN && errno != EWOULDBLOCK &&
                   errno != EINTR) {
          close_if_open(&child_stdout);
          stdout_eof = true;
        }
      } else if (fd == child_stderr &&
                 (events & (POLLIN | POLLHUP)) != 0) {
        uint8_t chunk[IO_CHUNK_BYTES];
        ssize_t count = read(child_stderr, chunk, sizeof(chunk));

        if (count > 0) {
          if (!emit_stderr(chunk, (size_t)count, config->stderr_limit,
                           &stderr_emitted, &stderr_truncated)) {
            begin_shutdown(&phase, &finish_reason, FINISH_OWNER_EOF,
                           &pending, &child_stdin, config->grace_ms,
                           &deadline);
            close_if_open(&child_stderr);
            stderr_eof = true;
          }
        } else if (count == 0) {
          close_if_open(&child_stderr);
          stderr_eof = true;
        } else if (errno != EAGAIN && errno != EWOULDBLOCK &&
                   errno != EINTR) {
          close_if_open(&child_stderr);
          stderr_eof = true;
        }
      } else if (fd == child_stdin && (events & POLLOUT) != 0 &&
                 pending.length > 0) {
        ssize_t count =
            write(child_stdin, pending.bytes + pending.offset, pending.length);

        if (count > 0) {
          pending.offset += (size_t)count;
          pending.length -= (size_t)count;
          if (pending.length == 0) {
            pending.offset = 0;
            if (!acknowledge_pending(&pending)) {
              begin_shutdown(&phase, &finish_reason, FINISH_OWNER_EOF,
                             &pending, &child_stdin, config->grace_ms,
                             &deadline);
            }
            if (phase == PHASE_FLUSH_WAIT) {
              begin_eof_wait(&phase, &child_stdin, config->grace_ms, &deadline);
            }
          }
        } else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK &&
                   errno != EINTR) {
          handle_child_stdin_failure(
              child_pid, &child_exited, &child_stdin_failed,
              &phase, &finish_reason, &pending, &child_stdin, config->grace_ms,
              &deadline);
        }
      }

      if (fd == child_stdin && (events & (POLLERR | POLLHUP)) != 0) {
        handle_child_stdin_failure(
            child_pid, &child_exited, &child_stdin_failed,
            &phase, &finish_reason, &pending, &child_stdin, config->grace_ms,
            &deadline);
      }
    }

    if (phase == PHASE_FLUSH_WAIT && pending.length == 0) {
      begin_eof_wait(&phase, &child_stdin, config->grace_ms, &deadline);
    }
  }
}

int main(int argc, char **argv) {
  struct launcher_config config;
  int child_stdin[2] = {-1, -1};
  int child_stdout[2] = {-1, -1};
  int child_stderr[2] = {-1, -1};
  int exec_status[2] = {-1, -1};
  int lifeline_fd = -1;
  pid_t child_pid;
  struct sigaction action;
  enum startup_result startup;
  int result;

  if (argc > 1) {
    if (argc == 4 &&
        strcmp(argv[1], "--publish-directory-noreplace") == 0) {
      return publish_directory_noreplace(argv[2], argv[3]);
    }

    return 64;
  }

  memset(&action, 0, sizeof(action));
  action.sa_handler = record_signal;
  (void)sigemptyset(&action.sa_mask);
  (void)sigaction(SIGTERM, &action, NULL);
  (void)sigaction(SIGINT, &action, NULL);
  (void)sigaction(SIGHUP, &action, NULL);
  (void)signal(SIGPIPE, SIG_IGN);
  request_child_subreaper();

  /*
   * Started before every other descriptor so no launcher death after this
   * point can leave a started server without an observer, and so the watchdog
   * inherits nothing it would have to close beyond the standard streams.
   */
  if (!start_lifeline_watchdog(&lifeline_fd)) {
    (void)emit_frame('F', NULL, 0);
    return 70;
  }

  if (!load_bootstrap(&config)) {
    (void)emit_frame('F', NULL, 0);
    return 64;
  }

  /*
   * Bootstrap path resolution happens in the child so the BEAM owner can
   * enforce its wall-clock startup deadline by closing the Port. The checks
   * below avoid starting after an already-observable owner disconnect; an
   * owner loss racing startup is handled by await_child_start/supervision and
   * bounded process-group cleanup.
   */
  if (!owner_connected()) {
    free_config(&config);
    return 69;
  }

  if (!make_pipe(child_stdin) || !make_pipe(child_stdout) ||
      !make_pipe(child_stderr) || !make_pipe(exec_status) ||
      !close_on_exec(exec_status[1])) {
    (void)emit_frame('F', NULL, 0);
    free_config(&config);
    return 70;
  }

  if (!owner_connected()) {
    close_if_open(&child_stdin[0]);
    close_if_open(&child_stdin[1]);
    close_if_open(&child_stdout[0]);
    close_if_open(&child_stdout[1]);
    close_if_open(&child_stderr[0]);
    close_if_open(&child_stderr[1]);
    close_if_open(&exec_status[0]);
    close_if_open(&exec_status[1]);
    free_config(&config);
    return 69;
  }

  child_pid = fork();
  if (child_pid < 0) {
    (void)emit_frame('F', NULL, 0);
    free_config(&config);
    return 70;
  }

  if (child_pid == 0) {
    int child_result =
        child_main(&config, child_stdin, child_stdout, child_stderr,
                   exec_status);
    _exit(child_result);
  }

  /*
   * The child becomes its own group leader in `setsid`, so before that call
   * the identifier still names the launcher's group; the watchdog kills the
   * PID directly as well to cover the gap.
   */
  arm_lifeline(lifeline_fd, child_pid);

  close_if_open(&child_stdin[0]);
  close_if_open(&child_stdout[1]);
  close_if_open(&child_stderr[1]);
  close_if_open(&exec_status[1]);

  startup = await_child_start(exec_status[0], config.start_timeout_ms);
  if (startup != STARTUP_READY) {
    close_if_open(&exec_status[0]);
    close_if_open(&child_stdin[1]);
    close_if_open(&child_stdout[0]);
    close_if_open(&child_stderr[0]);
    terminate_starting_child(child_pid, &lifeline_fd);
    if (startup != STARTUP_OWNER_EOF) {
      (void)emit_frame('F', NULL, 0);
    }
    free_config(&config);
    return 69;
  }

  close_if_open(&exec_status[0]);
  /*
   * Supervision stands the watchdog down as part of reaping the leader, and
   * every path that returns from here has done so. An exit that somehow left
   * it armed is the safe direction: the watchdog then retires a group the
   * launcher never confirmed dead.
   */
  result = supervise(&config, child_pid, &lifeline_fd, child_stdin[1],
                     child_stdout[0], child_stderr[0]);
  free_config(&config);
  return result;
}
