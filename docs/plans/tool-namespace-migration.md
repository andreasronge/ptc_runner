# Plan: Unified Namespace Migration

## Goal

Replace `ctx/` namespace with proper `tool/` and `data/` namespaces in PTC-Lisp.

**Current state (confusing):**
- `ctx/key` → data access (Lisp syntax)
- `(ctx/tool args)` → tool call (Lisp syntax)
- `data/key` → display only (not valid Lisp)
- `tool/func()` → display only (not valid Lisp)

**Target state (clear):**
- `data/key` → data access
- `(tool/func args)` → tool call
- `ctx/` → removed entirely

This creates parallel namespaces:
| Namespace | Purpose | Syntax |
|-----------|---------|--------|
| `tool/` | Call tools | `(tool/search {:query "foo"})` |
| `data/` | Access input data | `data/user_id` |
| `user/` | User definitions | `my-var` (bare symbol, unchanged) |

## Phase 1: Core Interpreter

### 1.1 AST Type Definition
**File:** `lib/ptc_runner/lisp/core_ast.ex`

Changes:
```elixir
# Rename for tool calls (~line 56)
| {:ctx_call, atom(), [t()]}
# becomes:
| {:tool_call, atom(), [t()]}

# Rename for data access (~line 52)
| {:ctx, atom()}
# becomes:
| {:data, atom()}

# REMOVE dead code (~line 54)
| {:builtin_call, String.t(), t()}  # DELETE - never used
```

### 1.2 Analyzer
**File:** `lib/ptc_runner/lisp/analyze.ex`

Changes:

1. **Replace `ctx/` data access with `data/`** (~line 100):
```elixir
# Change from:
defp do_analyze({:ns_symbol, :ctx, key}, _tail?), do: {:ok, {:ctx, key}}
# To:
defp do_analyze({:ns_symbol, :data, key}, _tail?), do: {:ok, {:data, key}}
```

2. **Replace `ctx/` tool dispatch with `tool/`** (~line 194):
```elixir
# Change from:
defp dispatch_list_form({:ns_symbol, :ctx, tool_name}, rest, _list, tail?),
  do: analyze_ctx_call(tool_name, rest, tail?)
# To:
defp dispatch_list_form({:ns_symbol, :tool, tool_name}, rest, _list, tail?),
  do: analyze_tool_call(tool_name, rest, tail?)
```

3. **Rename analysis function** (~line 820):
```elixir
# Rename: analyze_ctx_call -> analyze_tool_call
# Update AST node:
{:ok, {:tool_call, tool_name, args}}
```

4. **Update error message** (~line 1048):
```elixir
{:error, {:invalid_form, "unknown namespace #{ns}/. Use tool/ for tools, data/ for input data"}}
```

5. **Remove deprecated `(call "tool" args)` form** (lines 181-186):
```elixir
# DELETE the entire analyze_call function and its dispatch
```

### 1.3 Evaluator
**File:** `lib/ptc_runner/lisp/eval.ex`

Changes:

1. **Update data access** (~lines 171-174):
```elixir
# Change from:
defp do_eval({:ctx, key}, %EvalContext{ctx: ctx} = eval_ctx) do
# To:
defp do_eval({:data, key}, %EvalContext{ctx: ctx} = eval_ctx) do
```

2. **Update tool invocation** (~line 520):
```elixir
# Change from:
defp do_eval({:ctx_call, tool_name, arg_asts}, ...
# To:
defp do_eval({:tool_call, tool_name, arg_asts}, ...
```

3. **Remove dead code** (~lines 510-518):
```elixir
# DELETE the entire builtin_call handler - it's never used
defp do_eval({:builtin_call, ...}, ...) do ... end
```

4. **Update comment** (~line 520):
```elixir
# Change: "Tool invocation via ctx namespace"
# To: "Tool invocation via tool/ namespace"
```

## Phase 2: System Prompts

### 2.1 Data Inventory
**File:** `lib/ptc_runner/sub_agent/system_prompt/data_inventory.ex`

The output already uses `ctx/` format. Change to `data/`:

```elixir
# Line 77 - change:
"| `ctx/#{key_str}` | ..."
# To:
"| `data/#{key_str}` | ..."
```

Update docstrings (~lines 35, 37).

### 2.2 Tools Prompt
**File:** `lib/ptc_runner/sub_agent/system_prompt/tools.ex`

**NOT previously updated!** Change all `ctx/` to `tool/`:

```elixir
# Line 122:
"ctx/#{name}#{display_sig}"  →  "tool/#{name}#{display_sig}"

# Line 167 (comment):
"(ctx/search {:query ...})"  →  "(tool/search {:query ...})"

# Line 211:
"(ctx/#{name})"  →  "(tool/#{name})"

# Line 215:
"(ctx/#{name} {#{args}})"  →  "(tool/#{name} {#{args}})"
```

## Phase 3: Tests

**IMPORTANT:** Do NOT blindly find/replace `ctx` - this would break Elixir internals like `eval_ctx`, `EvalContext`, `ctx` variable names.

**Safe approach:** Only replace in these patterns:
- `ctx/` in string literals (Lisp source code)
- `:ctx` as namespace atom
- `{:ctx_call, ...}` AST nodes
- `{:ctx, ...}` AST nodes (data access)

### Test files to update:

| File | Change Type |
|------|-------------|
| `test/ptc_runner/lisp/analyze_operations_test.exs` | `:ctx` → `:tool`, `:ctx_call` → `:tool_call` |
| `test/ptc_runner/lisp/analyze_conditional_bindings_test.exs` | `{:ctx_call, ...}` → `{:tool_call, ...}` |
| `test/ptc_runner/lisp/def_test.exs` | `ctx/` → `tool/` or `data/` in Lisp source |
| `test/ptc_runner/lisp/eval_apply_test.exs` | `:ctx_call` → `:tool_call` |
| `test/ptc_runner/lisp/pmap_test.exs` | `:ctx_call` → `:tool_call` |
| `test/ptc_runner/lisp/e2e_test.exs` | `ctx/` → `tool/` in Lisp source |
| `test/ptc_runner/lisp/lisp_options_test.exs` | `ctx/` → `tool/` or `data/` in Lisp source |
| `test/ptc_runner/lisp/integration/*.exs` | `ctx/` → `tool/` or `data/` in Lisp source |
| `test/ptc_runner/lisp/parser_test.exs` | `:ctx` → `:tool` or `:data` |
| `test/ptc_runner/lisp/formatter_test.exs` | `ctx/` → `data/` |
| `test/ptc_runner/sub_agent/**/*.exs` | `ctx/` → `tool/` or `data/` |

## Phase 4: Documentation

### 4.1 PTC-Lisp Specification
**File:** `docs/ptc-lisp-specification.md`

Major updates:
- Section 9 "Context Access" → "Namespaces"
- Replace all `ctx/` examples
- Update namespace table
- Update extension table

### 4.2 Guides
**Files:**
- `docs/guides/subagent-getting-started.md`
- `docs/guides/subagent-advanced.md`
- `docs/signature-syntax.md`

Update all examples.

## Execution Order

1. **Phase 1** - Core interpreter (all changes together)
2. **Phase 3** - Tests (same commit to keep green)
3. **Phase 2** - System prompts
4. **Phase 4** - Documentation

## Verification

After each phase:
```bash
mix format --check-formatted && mix compile --warnings-as-errors && mix test
```

## Summary

| Category | Files | Key Changes |
|----------|-------|-------------|
| Core Interpreter | 3 | AST rename, analyzer, eval |
| System Prompts | 2 | `ctx/` → `tool/` and `data/` |
| Tests | 20+ | Lisp source + AST assertions |
| Documentation | 5+ | Examples |

## Out of Scope (Future Work)

- `user/` namespace for explicit user variable access
- Reserved namespace validation
- Better error for tool references without calling
