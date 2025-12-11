# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2025-12-11

### Added

- **PTC-Lisp DSL**: Introduced a Lisp-based DSL as a first-class language for LLM interactions, with full parser and evaluator support.
- **Enhanced Evaluations**: Improved testing infrastructure with `Mix` tasks for multi-model evaluations, detailed markdown reporting, and `ModelRegistry`.
- **Clojure Compliance**: Added integration with Babashka to verify PTC-Lisp semantics against real Clojure, ensuring strict alignment.
- **LLM-Friendly Semantics**: Extended the language with flexible key access (string/keyword interoperability) and type coercions to better handle LLM-generated output.
- **Language Extensions**: Added support for set literals, function parameter destructuring, and property-based testing for safety.

### Fixed

- **Workflow Improvements**: Hardened GitHub workflows for PM and Code Review with better prompting and safety checks.
- **Semantic Fixes**: Aligned `update-vals`, `sort-by`, and destructuring behaviors strictly with Clojure specifications.
- **Documentation**: Comprehensive updates to guides, README, and API docs to reflect the new Lisp DSL and migration paths.

## [0.2.0] - 2025-12-05

### Added

- Introspection operations (`keys`, `typeof`) for exploring data structure
- New operations: `sort_by`, `min_by`, `max_by` for better data manipulation
- `PtcRunner.Json.format_error/1` for LLM-friendly error messages
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
