# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.0] - 2026-01-30

### Added

**Language**

- `for` (minimal) list comprehension
- String functions: `grep`, `grep-n`, `.indexOf`, `.lastIndexOf`
- Collection functions: `extract`, `extract-int`, `pairs`, `combinations`, `mapcat`, `butlast`, `take-last`, `drop-last`, `partition-all`
- Aggregators: `sum`, `avg`, `quot`
- Reader literals: `##Inf`, `##-Inf`, `##NaN`

**SubAgent**

- `return_retries` for validation recovery with compression support
- `:self` sentinel for recursive agents
- `memory_strategy :rollback` for recoverable memory limit errors
- Budget introspection and callback for RLM patterns
- Last expression as return value on budget exhaustion
- `llm_query` builtin integrated into system prompts and tool normalization
- Auto-set `return_retries` for agents with tools during compile

**LLM-as-Tool Composition**

- `LLMTool` with `response_template` mode for typed LLM output
- Transparent tool unwrapping and input validation

**Tracing & Observability**

- `TraceLog` + `Analyzer` for structured SubAgent tracing
- Hierarchical tracing for nested SubAgents
- Chrome DevTools trace export
- HTML trace viewer
- Post-sandbox tool telemetry with span correlation

**Utilities**

- `PtcRunner.Chunker` for text chunking
- Configurable `pmap_timeout` for LLM-backed tools

### Changed

- Refactored SubAgent loop from recursive to iterative driver loop
- Extracted chaining, validation, and prompt modules into focused files

### Fixed

- Propagate `max_heap` option to Lisp.run and child agents
- Handle tool call positional args error gracefully
- Support `apply` with maps and variadic `max-by`/`min-by`

## [0.5.2] - 2026-01-23

### Added

- **Mustache Templates** - Standalone `PtcRunner.Mustache` module for template rendering (#719)
- **Unified SubAgent API** - CompiledAgent support with `then/3` for chaining (#709)
- Support `timeout` and `max_heap` options in compiled agent execution
- Allow SubAgentTools in compiled agents
- JSON reports with failure traces for demo benchmarks
- Signature naming convention documentation (underscores vs hyphens)
- Improved signature documentation and error messages (#715)

### Fixed

- Normalize hyphenated keys to underscores at tool boundary (#706)
- Enforce named args and string keys at tool boundary
- Normalize keys in `has_keys` constraint for better prompt clarity
- Return error for non-scalar Mustache variable expansion
- Use string keys for JSON mode and add `max_turns` for compile
- Allow `timeout` option in string convenience form
- Fix report filename extraction for Bedrock model IDs

## [0.5.1] - 2026-01-18

### Added

- **JSON Output Mode** - SubAgents can now return structured JSON instead of PTC-Lisp
  - Add `output:` field to SubAgent struct for declaring JSON schema
  - Add `Signature.to_json_schema/1` for JSON schema generation
  - Add `LLMClient.generate_object/4` for structured output generation
  - Add `LLMClient.callback/1` for SubAgent integration
  - Support array types and improved validation UX
- Add `re-seq` regex function to PTC-Lisp for extracting all matches
- Add debug mission display and tool call statistics with Clojure format output

### Fixed

- Convert keyword-style tool args to map in Lisp interpreter

## [0.5.0] - 2026-01-16

### Breaking Changes

- Replace `ctx/` namespace with `data/` and `tool/` namespaces for clearer separation
- Remove `tool_catalog` field from SubAgent (use `tools` directly)

### Added

**Observability & Message History (v0.5 theme)**

- Add `Turn` struct for immutable per-turn execution history with tool calls, prints, and memory snapshots
- Add `SingleUserCoalesced` compression strategy for token-efficient multi-turn conversations
- Add `compression: true` option to enable message compression in SubAgent
- Add `collect_messages: true` option to capture full conversation history
- Enhance `print_trace/2` with new options: `view: :compressed`, `messages: true`, `raw: true`, `usage: true`
- Add compression statistics to debug output
- Add prompt caching support by splitting static/dynamic sections

**New Functions**

- Add `distinct-by` for unique items by key function
- Add `re-split` for regex-based string splitting
- Add `rem` function and fix `mod` to match Clojure semantics
- Add multi-arity `map` and `partition` functions
- Add list index support to `get-in`, `assoc`, `update`, and related functions
- Add context filtering via static analysis to reduce memory pressure

**Other**

- Add configurable println truncation limit (`max_print_length` option)
- Add hidden fields filtering from LLM-visible output (fields starting with `_`)
- Add configurable sample limits and smart println for char lists
- Improve float support in PTC-Lisp

### Fixed

- Multi-arity map with variadic builtins
- Propagate `max_print_length` into closures and pcalls
- Show map field names in tool signatures for LLM
- Handle nil values in `Debug.print_trace` options
- Support builtin tuples in `fnil` for Clojure compatibility
- Show explicit "No tools available" message in prompt

## [0.4.1] - 2026-01-09

### Added

- Add `juxt` function combinator for multi-criteria operations
- Add variadic function support with rest parameters `[a & rest]`
- Add `max-key` and `min-key` for variadic comparisons
- Add IEEE 754 special values: `##Inf`, `##-Inf`, `##NaN`
- Add `float_precision` option to SubAgent (default: 2 decimal places)
- Add `context_descriptions` for automatic data inventory in prompts
- Extend `reduce` to work on maps, sets, and strings
- Add variadic `update` and `update-in` (match Clojure semantics)
- Add `java.time.LocalDate/parse` for date handling

### Fixed

- Preserve memory state on parse/analysis errors (multi-turn recovery)
- Handle `return`/`fail` correctly in threading macros (`->`, `->>`)
- Make `return`/`fail` terminate execution immediately
- Restore caller environment after closure execution
- Improve error messages with actionable suggestions

## [0.4.0] - 2026-01-06

### Added

- Add SubAgent API for high-level agent definition with type-safe signatures, auto-chaining, and resource limits
- Add Tracer system for immutable recording and visualization of agent execution
- Implement loop and recur support for iterative computation in PTC-Lisp
- Add character literals and string-as-sequence support for more flexible data handling
- Add `pcalls` for parallel execution of heterogeneous thunks
- Add `pmap` for parallel map evaluation
- Support vector paths in collection extraction functions for nested data access
- Add Clojure namespace normalization to improve LLM resilience

### Fixed

- Correct argument order for sort-by function to match Clojure semantics
- Fix update-vals argument order to match Clojure 1.11
- Update supported functions list (add frequencies, add float and for)
- Improve multi-turn agent guidance and system prompts
- Add specific error messages for predicate functions
- Fix Clojure compatibility for destructuring, count, and empty?

## [0.3.4] - 2025-12-25

### Added

- Add seqable map support to filter, remove, and sort-by operations
- Add entries and identity functions to PTC-Lisp
- Add sandbox support to PtcRunner.Lisp for resource limits

### Fixed

- Replace length() comparisons with Enum.empty? alternative
- Update error handling to use error tuples instead of raised exceptions

## [0.3.3] - 2025-12-22

### Added

- Add `update` and `update-in` map bindings for transforming values with functions
- Add function-based key support to `*-by` operations for custom sorting and grouping
- Add spec validation system for PTC-Lisp with multi-line examples and section reporting
- Improve JSON DSL prompts for better LLM accuracy

### Fixed

- Fix JSON agent to retry on empty LLM responses
- Improve deterministic ordering in keys/vals output
- Align `assoc-in` and `update-in` with Clojure semantics for intermediate path creation
- Correct `update/3` semantics to pass nil to function for missing keys
- Fix zip and into operations to return vectors instead of tuples
- Handle empty and nil LLM responses gracefully in agent loop

## [0.3.2] - 2025-12-20

### Added

- Add format_error/1 for human-readable error messages

### Fixed

- Include ptc-lisp-llm-guide.md in hex package

## [0.3.1] - 2025-12-13

### Added

- Improve PTC-JSON system prompt for better LLM accuracy
- Add object operation to construct maps with evaluated values (#253) (#254) ([#254](https://github.com/andreasronge/ptc_runner/pull/254))
- Enhance Clojure validation to execute and compare results
- Add auto-generated report filenames and reports directory
- Add cross-dataset join test case and clean up old reports
- Add --show-prompt option to display system prompts
- Add arithmetic operations (add, sub, mul, div, round, pct) #255
- Add membership operations (in, filter_in) (#257) (#259) ([#259](https://github.com/andreasronge/ptc_runner/pull/259))
- Add implicit object literals for memory storage (#256) (#261) ([#261](https://github.com/andreasronge/ptc_runner/pull/261))

### Fixed

- Handle Map values in constraint errors and fix GenServer timeout
- Correct round operation documentation for precision constraints
- Improve LLM prompt with arithmetic ops and better examples
- Evaluate filter_in value when it's a DSL expression
- Add sort_by order:desc to LLM prompt

## [0.3.0] - 2025-12-11

### Added

- Add PTC-Lisp LLM generation benchmark (Phase 1)
- Improve generation and judge prompts for PTC-Lisp benchmark
- Improve benchmark with edge cases, better judge, and dry run output
- Add autonomous issue creation and GitHub Project integration to PM workflow
- Enhance PM workflow with tech debt priority and efficiency fixes
- Auto-trigger implementation on ready-for-implementation label
- Auto-trigger code review for PRs from claude/* branches
- Install git pre-commit hook in Claude workflow
- Create PtcRunner.Json public API and deprecate PtcRunner (#103) ([#103](https://github.com/andreasronge/ptc_runner/pull/103))
- Allow full Bash access in claude.yml workflow
- Implement PTC-Lisp parser infrastructure (Phase 1) - Closes #106 (#107) ([#107](https://github.com/andreasronge/ptc_runner/pull/107))
- Implement PTC-Lisp analyzer infrastructure (Phase 2) - Closes #108 (#109) ([#109](https://github.com/andreasronge/ptc_runner/pull/109))
- Implement PTC-Lisp eval infrastructure (Phase 1) - Closes #111 (#112) ([#112](https://github.com/andreasronge/ptc_runner/pull/112))
- Implement PtcRunner.Lisp entry point with memory contract - Closes #115 (#116) ([#116](https://github.com/andreasronge/ptc_runner/pull/116))
- Add hourly schedule trigger to PM workflow
- Add pre-computed phase status to PM workflow prompt
- Implement LispGenerators module with StreamData generators (#130) (#132) ([#132](https://github.com/andreasronge/ptc_runner/pull/132))
- Add property tests for evaluation safety and determinism (#133) (#134) ([#134](https://github.com/andreasronge/ptc_runner/pull/134))
- Add domain property tests for arithmetic, collections, types, and logic (#135) (#136) ([#136](https://github.com/andreasronge/ptc_runner/pull/136))
- Support flexible key access in where clause field accessors (#137) (#138) ([#138](https://github.com/andreasronge/ptc_runner/pull/138))
- Add Lisp.Schema module and extend Runtime with flexible key access (#139) ([#139](https://github.com/andreasronge/ptc_runner/pull/139))
- Add truncation hints to guide LLM query refinement
- Add PTC-Lisp CLI and enhance demo infrastructure
- Refactor PM workflow to use Epic Issue pattern
- Add LispTestRunner and improve multi-turn support
- Add file size analysis to PR review workflow
- Add #{...} set literal syntax support (Phase 1 of #164) (#166) ([#166](https://github.com/andreasronge/ptc_runner/pull/166))
- Add {:set, [t()]} to AST type specifications (#167) (#168) ([#168](https://github.com/andreasronge/ptc_runner/pull/168))
- Add set analysis support (Phase 3 of #164) (#170) ([#170](https://github.com/andreasronge/ptc_runner/pull/170))
- Add set evaluation support (Phase 4 of #164) (#172) ([#172](https://github.com/andreasronge/ptc_runner/pull/172))
- Add .env support and model selection for e2e tests
- Add flex_fetch/2 and flex_get_in/2 to Runtime module (#188) ([#188](https://github.com/andreasronge/ptc_runner/pull/188))
- Add update-vals for map value transformation
- Create TestRunner.Base with shared constraint/formatting functions (#197) ([#197](https://github.com/andreasronge/ptc_runner/pull/197))
- Create TestRunner.Report with markdown generation (#199) ([#199](https://github.com/andreasronge/ptc_runner/pull/199))
- Create TestRunner.TestCase with shared test definitions (#201) ([#201](https://github.com/andreasronge/ptc_runner/pull/201))
- Create CLIBase with shared CLI utilities (#203) ([#203](https://github.com/andreasronge/ptc_runner/pull/203))
- Set up demo test infrastructure (MockAgent, test config) - Closes #205 (#206) ([#206](https://github.com/andreasronge/ptc_runner/pull/206))
- Create JsonTestRunner with shared modules support
- Create JsonCLI module with test mode support (#217) ([#217](https://github.com/andreasronge/ptc_runner/pull/217))
- Add memory support to JSON Agent (#220) (#221) ([#221](https://github.com/andreasronge/ptc_runner/pull/221))
- Add agent injection to test runners for MockAgent testing (#222) (#223) ([#223](https://github.com/andreasronge/ptc_runner/pull/223))
- Add ModelRegistry and unify test cases (#227) ([#227](https://github.com/andreasronge/ptc_runner/pull/227))
- Add --runs=N option for running tests multiple times
- Add keyword/string type coercion to where clause comparisons (#232) (#233) ([#233](https://github.com/andreasronge/ptc_runner/pull/233))
- Align JSON DSL memory model with Lisp (#234)
- Add take, drop, and distinct operations to JSON DSL (#236) (#243) ([#243](https://github.com/andreasronge/ptc_runner/pull/243))
- Add enhanced stats to demo test runner report (#246) (#249) ([#249](https://github.com/andreasronge/ptc_runner/pull/249))

### Fixed

- Move PM prompt to command file to fix expression length limit
- Use Bash(gh:*) pattern for PM workflow
- Trigger PM workflow on claude-approved label too
- Re-trigger code review on sync for claude/* branches
- Use --force in precommit to catch stale .beam files
- Add spec document verification to code review prompt
- Include PR comments and review comments in claude.yml
- Add mkdir permission to claude.yml workflow
- Add explicit Claude CLI install to workaround action bug
- Add safety net to push unpushed commits in PR fix workflow
- Mark PTC-Lisp implementation checklist items as complete (#123) ([#123](https://github.com/andreasronge/ptc_runner/pull/123))
- Update README with PTC-Lisp announcement and API migration guidance
- Complete API migration in Integration with LLMs section
- Implement compile-time extraction for PTC-Lisp schema prompt (#144) ([#144](https://github.com/andreasronge/ptc_runner/pull/144))
- Configure StreamData to run 300 iterations in CI (#146) ([#146](https://github.com/andreasronge/ptc_runner/pull/146))
- Make issue review always update the issue body
- Add sequential destructuring pattern type to CoreAST (#149) ([#149](https://github.com/andreasronge/ptc_runner/pull/149))
- Extend analyze_pattern for vector destructuring patterns
- Complete PR #151 - Add fn parameter destructuring documentation and tests
- Complete PR #151 - Remove stale documentation and add insufficient elements test
- Complete PR #151 - Remove stale documentation and add insufficient elements test
- Add E2E test for group-by with destructuring (#153) ([#153](https://github.com/andreasronge/ptc_runner/pull/153))
- Add analyzer unit tests for fn parameter destructuring patterns (#155) ([#155](https://github.com/andreasronge/ptc_runner/pull/155))
- Add evaluator unit tests for fn parameter destructuring patterns (#157) ([#157](https://github.com/andreasronge/ptc_runner/pull/157))
- Update LLM guide map example to use fn destructuring syntax (#159) ([#159](https://github.com/andreasronge/ptc_runner/pull/159))
- Enable sort-by with comparator and builtin HOF arguments (#160) ([#160](https://github.com/andreasronge/ptc_runner/pull/160))
- Extend multi-arity support to get and get-in (#163) ([#163](https://github.com/andreasronge/ptc_runner/pull/163))
- Unify concurrency groups for Claude issue workflows
- Add MapSet-safe collection operations and set runtime support (#175) ([#175](https://github.com/andreasronge/ptc_runner/pull/175))
- Add set literal formatting support to formatter (Phase 6 of #164) (#178) ([#178](https://github.com/andreasronge/ptc_runner/pull/178))
- Add test coverage for remove, mapv, empty?, and count on sets (#181) ([#181](https://github.com/andreasronge/ptc_runner/pull/181))
- Split eval_test.exs into multiple focused test files (#182) ([#182](https://github.com/andreasronge/ptc_runner/pull/182))
- Extract shared dummy_tool test helper (#183) (#184) ([#184](https://github.com/andreasronge/ptc_runner/pull/184))
- Support string key parameters in Lisp runtime functions (#185) ([#185](https://github.com/andreasronge/ptc_runner/pull/185))
- Standardize OpenAI model to gpt-5.1-codex-mini
- Rename duplicate module name in integration_test.exs
- Wire all call sites to use flex_fetch/flex_get_in for string/atom key interop
- Add integration tests and update docs for flexible key access (Phase 3)
- Update docs for flexible key access implementation
- Add @doc annotation to flex_get for API consistency
- Update ptc-lisp-overview.md to reflect completed flex key access (#192) ([#192](https://github.com/andreasronge/ptc_runner/pull/192))
- Update format_error references to PtcRunner.Json.format_error
- Update CHANGELOG format_error reference
- Change update-vals argument order to match Clojure 1.11
- Remove duplicate incorrect update-vals signature from LLM guide
- Handle FunctionClauseError in builtins with descriptive type errors
- Handle FunctionClauseError in multi-arity functions and complete type error messages
- Delete old TestRunner module and update README references (#219) ([#219](https://github.com/andreasronge/ptc_runner/pull/219))
- Require closing keyword in PR body for auto-close
- Add --report option to Lisp CLI Options table
- Update demo CLI to use ModelRegistry.resolve pattern (#229) ([#229](https://github.com/andreasronge/ptc_runner/pull/229))
- Update guide.md to reflect new JSON DSL API signature
- Update guide.md and demo to use new 4-tuple return format
- Handle invalid map destructuring syntax gracefully in analyzer
- Improve error message for update-vals with swapped arguments
- Update JSON agent to use new memory model API (#235) (#241) ([#241](https://github.com/andreasronge/ptc_runner/pull/241))
- Filter nil opts in CLI to allow Keyword.get defaults
- Split transformation_test.exs into access_test.exs and collection_test.exs (#244) (#247) ([#247](https://github.com/andreasronge/ptc_runner/pull/247))
- Align PTC-Lisp semantics with Clojure specification (#245) (#248) ([#248](https://github.com/andreasronge/ptc_runner/pull/248))
- Resolve remaining Clojure conformance test failures (#250) ([#250](https://github.com/andreasronge/ptc_runner/pull/250))

## [0.2.0] - 2025-12-05

### Added

- Add introspection operations (keys, typeof) to DSL (#92) ([#92](https://github.com/andreasronge/ptc_runner/pull/92))
- Improve DSL consistency for better LLM program generation (#94) ([#94](https://github.com/andreasronge/ptc_runner/pull/94))
- Add explore mode for schema discovery (#97) ([#97](https://github.com/andreasronge/ptc_runner/pull/97))
- Enable async execution for test modules (#98) ([#98](https://github.com/andreasronge/ptc_runner/pull/98))
## [0.1.0] - 2025-12-03

### Added

- Add CI check to verify STATUS.md is updated in PRs
- Implement Phase 1 core interpreter with JSON parsing and sandbox execution (#10) ([#10](https://github.com/andreasronge/ptc_runner/pull/10))
- Add pre-implementation check for blockers in PM workflow
- Implement get operation for nested path access (fixes #17) (#18) ([#18](https://github.com/andreasronge/ptc_runner/pull/18))
- Implement comparison operations (neq, gt, gte, lt, lte) (#22) ([#22](https://github.com/andreasronge/ptc_runner/pull/22))
- Implement collection operations (first, last, nth, reject) (#26) (#27) ([#27](https://github.com/andreasronge/ptc_runner/pull/27))
- Implement contains, avg, min, max operations (#28)
- Implement let variable bindings for Phase 3 (#30) (#31) ([#31](https://github.com/andreasronge/ptc_runner/pull/31))
- Implement if conditional operation for Phase 3 (#32) (#33) ([#33](https://github.com/andreasronge/ptc_runner/pull/33))
- Implement boolean logic operations (and, or, not) for Phase 3 (#34) (#35) ([#35](https://github.com/andreasronge/ptc_runner/pull/35))
- Implement combine operations (merge, concat, zip) for Phase 3 (#37) ([#37](https://github.com/andreasronge/ptc_runner/pull/37))
- Implement call operation for tool invocation (#41) ([#41](https://github.com/andreasronge/ptc_runner/pull/41))
- Add Jaro-Winkler typo suggestions for unknown operations (#44) ([#44](https://github.com/andreasronge/ptc_runner/pull/44))
- Add ExDoc and Hex package metadata (#45) (#46) ([#46](https://github.com/andreasronge/ptc_runner/pull/46))
- Implement declarative schema module for DSL operations (#52) ([#52](https://github.com/andreasronge/ptc_runner/pull/52))
- [Phase 5] JSON Schema Generation (#50) (#55) ([#55](https://github.com/andreasronge/ptc_runner/pull/55))
- [Phase 5] E2E LLM Testing Infrastructure (#51) (#57) ([#57](https://github.com/andreasronge/ptc_runner/pull/57))
- Adopt program wrapper as canonical PTC format - Update to_json_schema/0 (#63) ([#63](https://github.com/andreasronge/ptc_runner/pull/63))
- Adopt program wrapper as canonical PTC format in parser (#58) (#64) ([#64](https://github.com/andreasronge/ptc_runner/pull/64))
- Add structured output support with generate_program_structured! for E2E tests (#65) (#67) ([#67](https://github.com/andreasronge/ptc_runner/pull/67))
- Validate tool function arities at registration time (#42) (#68) ([#68](https://github.com/andreasronge/ptc_runner/pull/68))
- Add interactive demo CLI for PTC with ReqLLM integration (#75) ([#75](https://github.com/andreasronge/ptc_runner/pull/75))
- Add to_prompt/0 for token-efficient LLM text mode (#80) ([#80](https://github.com/andreasronge/ptc_runner/pull/80))
- Add security gates and hardening to Claude workflows

### Fixed

- Add safety improvements to GitHub workflows
- PM workflow commits STATUS.md directly to main
- Avoid parallel PRs by including STATUS.md in implementation PR
- Simplify STATUS.md update rules to prevent merge conflicts
- Improve PM workflow action handling
- Trigger PM workflow when issue becomes ready-for-implementation
- Ensure git push happens immediately after commit in Claude workflow
- Use PAT in issue-review workflow to trigger PM workflow
- Optimize min_list and max_list performance and update avg docs
- Correct documentation for sum vs avg behavior with non-numeric values
- Use anyOf for nested expressions in LLM schema (#71) ([#71](https://github.com/andreasronge/ptc_runner/pull/71))
- Improve LLM schema descriptions and use Haiku 4.5 (#73) ([#73](https://github.com/andreasronge/ptc_runner/pull/73))
- Store last_result in Agent state to avoid regenerating random data (#79) ([#79](https://github.com/andreasronge/ptc_runner/pull/79))
- Add test_coverage configuration to exclude test support modules (#89) ([#89](https://github.com/andreasronge/ptc_runner/pull/89))
[0.6.0]: https://github.com/andreasronge/ptc_runner/compare/v0.5.2...v0.6.0
[0.5.2]: https://github.com/andreasronge/ptc_runner/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/andreasronge/ptc_runner/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/andreasronge/ptc_runner/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/andreasronge/ptc_runner/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/andreasronge/ptc_runner/compare/v0.3.4...v0.4.0
[0.3.4]: https://github.com/andreasronge/ptc_runner/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/andreasronge/ptc_runner/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/andreasronge/ptc_runner/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/andreasronge/ptc_runner/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/andreasronge/ptc_runner/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/andreasronge/ptc_runner/compare/v0.1.0...v0.2.0

