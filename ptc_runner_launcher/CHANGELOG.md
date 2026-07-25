# Changelog

## Unreleased

### Added

- Added the version 1 MCP stdio launcher protocol and macOS/Linux reference
  implementation.
- Added a cross-platform lifecycle, backpressure, environment, and descriptor
  conformance suite.
- Added mandatory-checksum precompiled artifacts for Apple Silicon macOS and
  x86-64 GNU/Linux, with tested source fallback.
- Added tag-only release automation that executes each artifact and assembles
  the verified companion Hex package with signed build provenance.
- Added a protected publication path that uploads the exact verified package
  tarball without rebuilding it after checking both build and release
  attestations.
