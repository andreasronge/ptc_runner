# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2025-12-02

### Added

- Initial release of PtcRunner: BEAM-native Elixir library for Programmatic Tool Calling (PTC)
- JSON DSL with 33 fixed operations for safe, sandboxed execution
- Resource limits: configurable timeout (default 1s) and memory (default 10MB)
- Execution metrics: duration and memory usage tracking for every call
- Structured error handling optimized for LLM retry loops
- Integration support for LLM clients (e.g., ReqLLM) with structured output mode

#### Data Operations
- `literal` - Return a constant value
- `var` - Access a variable
- `load` - Load data from context
- `let` - Bind a value to a variable

#### Collection Operations
- `pipe` - Chain operations sequentially
- `filter` - Keep items matching a condition
- `reject` - Remove items matching a condition
- `map` - Transform each item
- `select` - Extract specific fields
- `first` - Get the first item
- `last` - Get the last item
- `count` - Count items in a collection
- `nth` - Get the nth item

#### Aggregation Operations
- `sum` - Sum numeric values
- `avg` - Calculate average
- `min` - Find minimum value
- `max` - Find maximum value

#### Access Operations
- `get` - Access nested values

#### Comparison Operations
- `eq` - Equality check
- `neq` - Inequality check
- `gt` - Greater than
- `gte` - Greater than or equal
- `lt` - Less than
- `lte` - Less than or equal
- `contains` - String/list containment check

#### Logic Operations
- `and` - Logical AND
- `or` - Logical OR
- `not` - Logical NOT
- `if` - Conditional execution

#### Tool Operations
- `call` - Invoke a user-defined tool

#### Combine Operations
- `merge` - Combine objects
- `concat` - Concatenate sequences
- `zip` - Combine sequences element-wise

### Documentation

- Comprehensive architecture documentation with DSL specification and API reference
- Research notes on PTC approaches and design decisions
- Development and testing guidelines for contributors
- Planning and issue review guidelines
- PR review guidelines with severity classification

### Project Structure

- Four-layer architecture: Parser → Validator → Interpreter → Tool Registry
- Isolated BEAM process execution with resource limits
- Tool registration system for user-defined functions
- Context data support for multi-turn conversations
- Metrics collection for performance monitoring

[0.1.0]: https://github.com/andreasronge/ptc_runner/releases/tag/v0.1.0
