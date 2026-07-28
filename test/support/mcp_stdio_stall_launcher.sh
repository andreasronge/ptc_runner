#!/bin/sh

# Consume the private bootstrap without ever completing the launcher handshake.
while IFS= read -r _line; do
  :
done
