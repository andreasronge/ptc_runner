# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2025-12-05

### Added

- Introspection operations (`keys`, `typeof`) for exploring data structure
- New operations: `sort_by`, `min_by`, `max_by` for better data manipulation
- `PtcRunner.format_error/1` for LLM-friendly error messages
- Explore mode for schema discovery (see demo app)

## [0.1.0] - 2025-12-03

Initial release of PtcRunner - a BEAM-native Elixir library for Programmatic Tool Calling (PTC).

### Features

- JSON-based DSL for safe program execution
- Sandboxed interpreter with configurable timeout and memory limits
- Built-in operations: arithmetic, comparison, collection, string, and logic
- Tool registry for user-defined functions
- JSON Schema generation for LLM structured output
- Comprehensive validation with helpful error messages
