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

  V1 recognizes exactly the `"upstream:<server>/<tool>"` backing id shape —
  the only shape the compiler infers and the only one explicit prelude
  metadata is expected to use in V1. `<server>` must be a configured upstream;
  `<tool>` must be present in that upstream's tool list (mirroring
  `PtcRunner.Upstream.CallTool` configured-tool checks). When an upstream's
  tool list is not yet materialized (lazy MCP transports report `nil` tools),
  the specific tool cannot be checked and the requirement passes on the
  configured server alone, matching `tool/call` dispatch behavior. Any
  unrecognized `requires` id shape fails attachment.
  """

  alias PtcRunner.Lisp.Prelude
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
  `requires` against `runtime`.

  Returns `{:ok, %PtcRunner.Lisp.Prelude{}}` on success.

  Returns `{:error, %ValidationError{}}` when:

    * the source fails compile-time validation (any compile reason), or
    * attach-time `requires` validation fails (`:prelude_attach_failed`).

  Raises `ArgumentError` for genuine programmer misuse: a value that is
  neither a `%PtcRunner.Lisp.Prelude{}` nor prelude source (binary).
  """
  @spec attach(Prelude.t() | String.t(), runtime()) ::
          {:ok, Prelude.t()} | {:error, ValidationError.t()}
  def attach(%Prelude{} = prelude, runtime) do
    with :ok <- validate_requires(prelude, runtime) do
      {:ok, prelude}
    end
  end

  def attach(source, runtime) when is_binary(source) do
    with {:ok, prelude} <- Compiler.compile(source) do
      attach(prelude, runtime)
    end
  end

  def attach(other, _runtime) do
    raise ArgumentError,
          "prelude must be a %PtcRunner.Lisp.Prelude{} artifact or prelude source string, got: " <>
            inspect(other, limit: 5)
  end

  @doc """
  Validates every public export's `requires` against the selected upstream
  `runtime`.

  Returns `:ok` when all required backing operations are provided by the
  runtime (or when there are no `requires` to check — e.g. dynamic-backed
  exports). Returns `{:error, %ValidationError{reason: :prelude_attach_failed}}`
  naming the first missing operation and the export that needs it.

  `runtime` may be `nil` (no upstream runtime selected); any upstream-backed
  requirement then fails.
  """
  @spec validate_requires(Prelude.t(), runtime()) :: :ok | {:error, ValidationError.t()}
  def validate_requires(%Prelude{exports: exports}, runtime) do
    Enum.reduce_while(exports, :ok, fn %Export{} = export, :ok ->
      case validate_export(export, runtime) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # ============================================================
  # Per-export validation
  # ============================================================

  defp validate_export(%Export{requires: requires} = export, runtime) do
    Enum.reduce_while(requires, :ok, fn required, :ok ->
      case validate_required(required, export, runtime) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Recognized backing id: "upstream:<server>/<tool>".
  defp validate_required(required, export, runtime) when is_binary(required) do
    case parse_upstream_ref(required) do
      {:ok, server, tool} ->
        check_upstream_op(server, tool, required, export, runtime)

      :error ->
        {:error,
         attach_error(
           "export `#{export.ref}` declares an unrecognized backing requirement " <>
             "`#{required}`; V1 only supports `upstream:<server>/<tool>` backing ids",
           export
         )}
    end
  end

  defp validate_required(required, export, _runtime) do
    {:error,
     attach_error(
       "export `#{export.ref}` declares a non-string backing requirement " <>
         "#{inspect(required, limit: 3)}",
       export
     )}
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

  # No runtime selected: any upstream-backed requirement is unmet.
  defp check_upstream_op(_server, _tool, required, export, nil) do
    {:error,
     attach_error(
       "export `#{export.ref}` requires upstream operation `#{required}`, " <>
         "but no upstream runtime is configured for this run",
       export
     )}
  end

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
