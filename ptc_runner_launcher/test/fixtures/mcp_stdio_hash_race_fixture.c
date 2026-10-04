/* Test-only read interposition. The shipped launcher has no race hook. */
#include <unistd.h>
#if defined(PTC_TEST_PATH_EXEC) && defined(__linux__)
/* Exercise the descriptor-unavailable path on Linux, using its open flags. */
#include <sys/stat.h>
#include <fcntl.h>
#undef __linux__
#define O_EXEC O_RDONLY
#define O_SEARCH O_RDONLY
/* The unsupported publication fallback has unused path arguments. */
#pragma GCC diagnostic ignored "-Wunused-parameter"
#endif

static ssize_t race_read(int fd, void *buffer, size_t count);
#define read race_read
#include "../../c_src/ptc_runner_launcher.c"
#undef read

static ssize_t race_read(int fd, void *buffer, size_t count) {
  static bool replaced = false;
  struct stat opened;
  struct stat target;
  ssize_t result = read(fd, buffer, count);

  /* Bootstrap and watchdog reads use pipes. Only the executable's regular
   * file descriptor can match here, after its first bytes have been read and
   * before sha256_fd consumes them or reaches the final identity check. */
  if (!replaced && result > 0 && fstat(fd, &opened) == 0 &&
      S_ISREG(opened.st_mode) && stat(PTC_RACE_TARGET, &target) == 0 &&
      opened.st_dev == target.st_dev && opened.st_ino == target.st_ino) {
    int marker;

#if defined(PTC_RACE_IN_PLACE)
    int replacement = open(PTC_RACE_IMPOSTOR, O_RDONLY);
    int destination = open(PTC_RACE_TARGET, O_WRONLY | O_TRUNC);
    char bytes[8192];
    ssize_t length = read(replacement, bytes, sizeof(bytes));
    struct timespec times[2];
#if defined(__APPLE__)
    times[0] = target.st_atimespec;
    times[1] = target.st_mtimespec;
#else
    times[0] = target.st_atim;
    times[1] = target.st_mtim;
#endif
    if (replacement < 0 || destination < 0 || length <= 0 ||
        write(destination, bytes, (size_t)length) != length ||
        futimens(destination, times) != 0) {
      _exit(125);
    }
    (void)close(replacement);
    (void)close(destination);
#else
    if (rename(PTC_RACE_IMPOSTOR, PTC_RACE_TARGET) != 0) {
      _exit(125);
    }
#endif
    replaced = true;
    marker = open(PTC_RACE_MARKER, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (marker < 0 || write(marker, "during-hash", 11) != 11) {
      _exit(125);
    }
    (void)close(marker);
  }

  return result;
}
