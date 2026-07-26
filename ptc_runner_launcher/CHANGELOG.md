# Changelog

## Unreleased

### Added

- Added the version 1 MCP stdio launcher protocol and macOS/Linux reference
  implementation.
- Added a cross-platform lifecycle, backpressure, environment, and descriptor
  conformance suite.
- Added mandatory-checksum precompiled artifacts for ARM64 and x86-64 macOS
  and GNU/Linux, with tested source fallback.
- Bound protocol-v1 startup to the caller's frozen server-executable SHA-256.
- Added tag-only release automation that executes each artifact and assembles
  the verified companion Hex package with signed build provenance.
- Added a protected publication path that uploads the exact verified package
  tarball without rebuilding it after checking both build and release
  attestations.
