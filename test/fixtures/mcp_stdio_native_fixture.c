#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;

static void print_variable(const char *name) {
  const char *value = getenv(name);
  (void)printf("%s=%s\n", name, value == NULL ? "unset" : value);
}

static void print_environment_names(void) {
  char **entry;

  for (entry = environ; *entry != NULL; entry++) {
    const char *separator = strchr(*entry, '=');
    const unsigned char *cursor;

    if (separator != NULL) {
      (void)fputs("ENV_HEX=", stdout);
      for (cursor = (const unsigned char *)*entry;
           cursor < (const unsigned char *)separator; cursor++) {
        (void)printf("%02X", *cursor);
      }
      (void)fputc('\n', stdout);
    }
  }

  (void)fputs("ENV_END\n", stdout);
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "environment") == 0) {
    print_variable("HOME");
    print_variable("LOGNAME");
    print_variable("PATH");
    print_variable("SHELL");
    print_variable("TERM");
    print_variable("USER");
    print_variable("PTC_UNSAFE_CHILD_ENV");
    print_variable("PTC_SECOND_UNSAFE_ENV");
    print_environment_names();
    return 0;
  }

  (void)fputs("native-fixture\n", stdout);
  return 0;
}
