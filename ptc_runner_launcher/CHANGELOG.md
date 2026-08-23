# Changelog

## [0.1.0] - 2026-08-23

### Added

- Added atomic no-replace directory publication for the shared initializer on
  macOS and Linux.
- Added the version 1 MCP stdio launcher protocol and macOS/Linux reference
  implementation.
- Added a cross-platform lifecycle, backpressure, environment, and descriptor
  conformance suite.
- Added mandatory-checksum precompiled artifacts for ARM64 and x86-64 macOS
  and GNU/Linux, with tested source fallback.
- Bound protocol-v1 startup to the caller's frozen server-executable SHA-256.
- Narrowed the macOS path-replacement window for a native executable to the
  check-then-exec call pair by re-reading the canonical path immediately before
  `execve`, instead of leaving the whole identity hash — which scales with the
  executable — exposed. An interpreted `#!` target is opened once more by its
  interpreter, which no launcher check covers.
- Added a group-resident watchdog so a launcher destroyed without running its
  own teardown — `SIGKILL`, or a host that tears the process down — still
  retires the server process group instead of leaving it reparented and
  running.
- Added tag-only release automation that executes each artifact and assembles
  the verified companion Hex package with signed build provenance.
- Added a protected publication path that uploads the exact verified package
  tarball without rebuilding it after checking both build and release
  attestations.

[0.1.0]: https://github.com/andreasronge/ptc_runner/releases/tag/ptc_runner_launcher-v0.1.0
