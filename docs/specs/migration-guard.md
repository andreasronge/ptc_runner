# Migration Guard - Implementation Hints

Compile-time enforcement for [Cleanup Requirements](./message-history-optimization-requirements.md#cleanup-requirements).

## Purpose

Prevents old code from lingering after migration phases. Uncomment guards as phases begin—compilation fails until cleanup is done.

## Location

`lib/ptc_runner/migration_guard.ex`

## Usage

```elixir
defmodule PtcRunner.MigrationGuard do
  @moduledoc false

  # Uncomment when starting Phase 2
  # assert_field_deleted(PtcRunner.Step, :trace, "CLN-001")

  # Uncomment when starting Phase 3
  # assert_module_deleted(PtcRunner.Prompt, "CLN-002")
  # CLN-004 DONE: SubAgent.Prompt renamed to SubAgent.SystemPrompt
  # assert_module_deleted(PtcRunner.SubAgent.Template, "CLN-005")
  # assert_module_deleted(PtcRunner.Lisp.Prompts, "CLN-006")

  # Uncomment when starting Phase 4
  # assert_field_deleted(PtcRunner.SubAgent, :prompt, "CLN-007")

  defmacrop assert_module_deleted(module, cln_id) do
    quote do
      case Code.ensure_compiled(unquote(module)) do
        {:module, _} ->
          raise CompileError,
            description: "#{unquote(cln_id)}: #{unquote(module)} must be deleted"
        {:error, _} ->
          :ok
      end
    end
  end

  defmacrop assert_field_deleted(module, field, cln_id) do
    quote bind_quoted: [module: module, field: field, cln_id: cln_id] do
      if function_exported?(module, :__struct__, 0) do
        if Map.has_key?(module.__struct__(), field) do
          raise CompileError,
            description: "#{cln_id}: #{module}.#{field} must be deleted"
        end
      end
    end
  end
end
```

## Workflow

1. **Start phase** → Uncomment relevant guards
2. **Compilation fails** → Guards enforce cleanup
3. **Delete old code** → Compilation passes
4. **Phase complete** → Guards remain uncommented (documentation)

## Notes

- Guards are commented by default (no enforcement until phase starts)
- Once uncommented, guards stay uncommented permanently
- Failed compilation message includes CLN-* ID for traceability
