PRIV_DIR := $(MIX_APP_PATH)/priv
LAUNCHER := $(PRIV_DIR)/ptc_runner_launcher
SOURCE := c_src/ptc_runner_launcher.c

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
PLATFORM_CPPFLAGS := -D_DARWIN_C_SOURCE
else ifeq ($(UNAME_S),Linux)
PLATFORM_CPPFLAGS := -D_GNU_SOURCE
else
$(error ptc_runner_launcher supports only macOS and Linux)
endif

.PHONY: all clean

all: $(LAUNCHER)

$(LAUNCHER): $(SOURCE) Makefile
	mkdir -p "$(PRIV_DIR)"
	$(CC) $(CPPFLAGS) $(PLATFORM_CPPFLAGS) $(CFLAGS) -O2 -std=c11 \
		-Wall -Wextra -Werror -Wpedantic -o "$(LAUNCHER)" "$(SOURCE)"
	chmod 0755 "$(LAUNCHER)"

clean:
	rm -f "$(LAUNCHER)"
