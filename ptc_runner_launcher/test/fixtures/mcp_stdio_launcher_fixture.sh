#!/bin/sh

case "$1" in
  basic)
    printf 'cwd=%s\n' "$(pwd)"
    printf 'home=%s\n' "${HOME-unset}"
    printf 'allowed=%s\n' "${PTC_ALLOWED-unset}"
    printf 'unsafe=%s\n' "${PTC_UNSAFE_CHILD_ENV-unset}"
    printf 'arg=%s\n' "$2"
    printf 'diagnostic-only\n' >&2

    while IFS= read -r line; do
      printf 'echo=%s\n' "$line"
    done
    ;;

  stderr)
    index=0
    while [ "$index" -lt 256 ]; do
      printf x >&2
      index=$((index + 1))
    done

    while IFS= read -r _line; do
      :
    done
    ;;

  stdout-flood)
    while :; do
      printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
    done
    ;;

  write-before-read)
    dd if=/dev/zero bs=65536 count=4 2>/dev/null
    dd of=/dev/null bs=65536 count=16 2>/dev/null
    printf 'after-read\n'
    ;;

  trailing-output)
    while IFS= read -r _line; do
      :
    done

    printf 'after-eof\n'
    ;;

  no-read)
    printf 'ready\n'
    trap '' TERM

    while :; do
      /bin/sleep 1
    done
    ;;

  slow-eof)
    marker="$2"
    trap 'printf term > "$marker"; exit 0' TERM
    printf 'ready\n'
    /bin/sleep 0.15
    bytes=$(/usr/bin/wc -c)
    printf 'bytes=%s' "$bytes" > "$marker"
    exit 0
    ;;

  exit-no-read)
    printf 'request rejected\n' >&2
    /bin/sleep 1
    exit 23
    ;;

  final-output)
    printf 'final output\n'
    exit 0
    ;;

  close-stdin)
    exec 0<&-
    printf 'stdin closed\n'
    trap '' TERM

    while :; do
      /bin/sleep 1
    done
    ;;

  sigpipe)
    kill -PIPE "$$"
    printf 'sigpipe-ignored\n'
    ;;

  tree)
    marker="$2"

    (
      trap 'printf term > "$marker"' TERM
      while :; do
        /bin/sleep 0.05
      done
    ) &

    descendant="$!"
    printf 'leader=%s\n' "$$"
    printf 'descendant=%s\n' "$descendant"
    trap '' TERM

    while :; do
      /bin/sleep 1
    done
    ;;

  deep-tree)
    marker="$2"

    (
      (
        trap 'printf term > "$marker"' TERM
        while :; do
          /bin/sleep 0.05
        done
      ) &

      leaf="$!"
      printf 'descendant=%s\n' "$leaf"
      wait "$leaf"
    ) &

    trap '' TERM
    while :; do
      /bin/sleep 0.05
    done
    ;;

  *)
    printf 'unknown fixture mode\n' >&2
    exit 64
    ;;
esac
