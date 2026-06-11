defmodule PtcRunner.Lisp.Prelude.Attach do
  @moduledoc """
  Attach-time validation for a compiled deployment prelude (Capability
  Prelude V1, plan §3 / §6A).

  Prelude validation is split in two phases:

    * **compile-time** (`PtcRunner.Lisp.Prelude.Compiler`) checks source
      syntax, `(ns ...)` directives, reserved-namespace declarations,
      duplicate refs, visibility, and arity/signature metadata — facts that
      do NOT depend on a selected runtime. It also infers each export's
      `requires` backing ids from literal `(tool/call {:server "x" :tool
      "y" ...})` patterns. Dynamic server/tool values yield `:unknown` effect
      and no requires.

    * **attach-time** (this module) checks each public export's `requires`
      against the SELECTED upstream runtime BEFORE user code is analyzed. If a
      public export requires an upstream operation that is not configured or
      not present on the selected runtime, attachment fails — naming the
      missing operation — so a run never starts against a prelude whose
      backing operations are unavailable.

  This split lets a single compiled prelude artifact be reused across runs
  while still failing fast when the selected runtime cannot back it.

  ## Where the attach hook lives

  `attach/2` is the seam P2 wires at the TOP of `PtcRunner.Lisp.run` (and the
  SubAgent / REPL surfaces), before parsing/analyzing user code. The `prelude:`
  option may be either a compiled `%PtcRunner.Lisp.Prelude{}` artifact or raw
  prelude source (a binary), which `attach/2` compiles first. On success it
  yields the compiled artifact for the analyzer/evaluator path; on failure it
  yields a `%PtcRunner.Lisp.Prelude.ValidationError{}` that the call site maps
  to `{:error, %PtcRunner.Step{fail: %{reason: :prelude_attach_failed}}}`.

  Genuine programmer misuse (passing a value that is neither a prelude
  artifact nor source) raises `ArgumentError`; a missing/ungranted upstream op
  is a recoverable `{:error, ...}`, never a raise.

  ## Requires id format

  Two backing id shapes are recognized:

    * `"upstream:<server>/<tool>"` — validated against the selected upstream
      runtime. `<server>` must be a configured upstream; `<tool>` must be
      present in that upstream's tool list (mirroring
      `PtcRunner.Upstream.CallTool` configured-tool checks). When an upstream's
      tool list is not yet materialized (lazy MCP transports report `nil`
      tools), the specific tool cannot be checked and the requirement passes on
      the configured server alone. When **no** upstream runtime is configured
      for the run, upstream requirements are *skipped* (there is no runtime to
      check; the granted `(tool/call ...)` closure plus `check_undefined_tools`
      still guard the actual surface) — preserving direct-`Lisp.run`-with-stub
      use.

    * `"tool:<name>"` — validated against the run's granted `tools:` map (a
      host-bound typed-tool capability). Fails closed when the host did not
      grant a tool of that name. This is checked regardless of whether an
      upstream runtime is configured.

  Any other `requires` id shape fails attachment (fail-closed).
  """

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.AttachContext
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Lisp.Prelude.Export
  alias PtcRunner.Lisp.Prelude.ValidationError
  alias PtcRunner.Upstream.Runtime

  @typedoc """
  A selected upstream runtime handle (a `%PtcRunner.Upstream.Runtime{}`
  struct, a pid, or a registered name), or `nil` when no upstream runtime is
  configured for the run. Mirrors the handle shapes
  `PtcRunner.Upstream.Runtime.upstream/2` accepts.
  """
  @type runtime :: struct() | pid() | atom() | nil

  @doc """
  Resolves `prelude_or_source` to a compiled artifact, then validates its
  `requires` against the attach `context` (`%PtcRunner.Lisp.Prelude.AttachContext{}`,
  bundling the upstream runtime and the granted `tools:` map).

  Returns `{:ok, %PtcRunner.Lisp.Prelude{}}` on success.

  Returns `{:error, %ValidationError{}}` when:

    * the source fails compile-time validation (any compile reason), or
    * attach-time `requires` validation fails (`:prelude_attach_failed`).

  Raises `ArgumentError` for genuine programmer misuse: a value that is
  neither a `%PtcRunner.Lisp.Prelude{}` nor prelude source (binary).
  """
  @spec attach(Prelude.t() | String.t(), AttachContext.t()) ::
          {:ok, Prelude.t()} | {:error, ValidationError.t()}
  def attach(%Prelude{} = prelude, %AttachContext{} = context) do
    with :ok <- validate_requires(prelude, context) do
      {:ok, prelude}
    end
  end

  def attach(source, %AttachContext{} = context) when is_binary(source) do
    with {:ok, prelude} <- Compiler.compile(source) do
      attach(prelude, context)
    end
  end

  def attach(other, %AttachContext{}) do
    raise ArgumentError,
          "prelude must be a %PtcRunner.Lisp.Prelude{} artifact or prelude source string, got: " <>
            inspect(other, limit: 5)
  end

  @doc """
  Validates every public export's `requires` against the attach `context`.

  Returns `:ok` when all required backing operations are provided (or when
  there are no `requires` to check — e.g. dynamic-backed exports). Returns
  `{:error, %ValidationError{reason: :prelude_attach_failed}}` naming the first
  missing operation and the export that needs it.
  """
  @spec validate_requires(Prelude.t(), AttachContext.t()) ::
          :ok | {:error, ValidationError.t()}
  def validate_requires(%Prelude{exports: exports}, %AttachContext{} = context) do
    Enum.reduce_while(exports, :ok, fn %Export{} = export, :ok ->
      case validate_export(export, context) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # ============================================================
  # Per-export validation
  # ============================================================

  defp validate_export(%Export{requires: requires} = export, context) do
    Enum.reduce_while(requires, :ok, fn required, :ok ->
      case validate_required(required, export, context) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Dispatch by backing id shape: "tool:<name>" (granted-tools check),
  # "upstream:<server>/<tool>" (runtime check), else fail closed.
  defp validate_required("tool:" <> name, export, context) when name != "" do
    check_tool_grant(name, export, context)
  end

  defp validate_required(required, export, %AttachContext{runtime: runtime})
       when is_binary(required) do
    case parse_upstream_ref(required) do
      {:ok, server, tool} ->
        check_upstream_op(server, tool, required, export, runtime)

      :error ->
        {:error,
         attach_error(
           "export `#{export.ref}` declares an unrecognized backing requirement " <>
             "`#{required}`; supported shapes are `upstream:<server>/<tool>` and `tool:<name>`",
           export
         )}
    end
  end

  defp validate_required(required, export, _context) do
    {:error,
     attach_error(
       "export `#{export.ref}` declares a non-string backing requirement " <>
         "#{inspect(required, limit: 3)}",
       export
     )}
  end

  # "tool:<name>" — satisfied by a granted typed tool of that name; fail closed
  # otherwise (a recoverable attach error, NOT a later unknown-tool crash).
  defp check_tool_grant(name, export, %AttachContext{} = context) do
    if AttachContext.grants_tool?(context, name) do
      :ok
    else
      {:error,
       attach_error(
         "export `#{export.ref}` requires granted tool `#{name}`, " <>
           "but the host did not grant a tool of that name for this run",
         export
       )}
    end
  end

  # "upstream:server/tool" -> {:ok, server, tool}. The tool segment is split on
  # the FIRST slash after the "upstream:" prefix; server names contain no
  # slashes, but tool names are taken verbatim (they may themselves not, in
  # V1, contain slashes either, but we keep the remainder intact).
  defp parse_upstream_ref("upstream:" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [server, tool] when server != "" and tool != "" -> {:ok, server, tool}
      _ -> :error
    end
  end

  defp parse_upstream_ref(_), do: :error

  # No runtime selected: there is no runtime to validate an upstream requirement
  # against, so skip it. The `(tool/call ...)` closure the host granted plus the
  # analyzer's `check_undefined_tools` still guard the actual tool surface; this
  # preserves direct `Lisp.run` with a stub `tools:` map and no configured
  # runtime. `tool:<name>` requirements are still checked (handled earlier).
  defp check_upstream_op(_server, _tool, _required, _export, nil), do: :ok

  defp check_upstream_op(server, tool, required, export, runtime) do
    case Runtime.upstream(runtime, server) do
      nil ->
        {:error,
         attach_error(
           "export `#{export.ref}` requires upstream operation `#{required}`, " <>
             "but upstream server `#{server}` is not configured for this run",
           export
         )}

      %{tools: nil} ->
        # Lazy transport: tool list not materialized. Mirror CallTool's
        # configured-tool check, which allows the call when tools are nil.
        :ok

      %{tools: tools} when is_list(tools) ->
        if Enum.any?(tools, &(Map.get(&1, "name") == tool)) do
          :ok
        else
          {:error,
           attach_error(
             "export `#{export.ref}` requires upstream operation `#{required}`, " <>
               "but tool `#{tool}` is not present on upstream server `#{server}`",
             export
           )}
        end
    end
  end

  defp attach_error(message, %Export{ref: ref, namespace: namespace}) do
    ValidationError.new(:prelude_attach_failed, message, namespace: namespace, ref: ref)
  end
end
