/* Test-only read interposition. The shipped launcher has no race hook. */
#include <unistd.h>

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

    if (rename(PTC_RACE_IMPOSTOR, PTC_RACE_TARGET) != 0) {
      _exit(125);
    }
    replaced = true;
    marker = open(PTC_RACE_MARKER, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (marker < 0 || write(marker, "during-hash", 11) != 11) {
      _exit(125);
    }
    (void)close(marker);
  }

  return result;
}
