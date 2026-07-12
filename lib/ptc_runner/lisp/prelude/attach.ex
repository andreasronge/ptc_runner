defmodule PtcRunner.Lisp.Prelude.Attach do
  @moduledoc """
  Resolves a compiled or source deployment prelude and validates every
  `tool:<name>` requirement against the host-granted tools map before user
  code is analyzed. Unknown requirement shapes fail closed.
  """

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.AttachContext
  alias PtcRunner.Lisp.Prelude.Bundle
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Lisp.Prelude.Export
  alias PtcRunner.Lisp.Prelude.ValidationError

  @doc """
  Resolves `prelude_or_source` to a compiled artifact, then validates its
  `requires` against the attach `context` (`%PtcRunner.Lisp.Prelude.AttachContext{}`,
  containing the granted `tools:` map).

  Returns `{:ok, %PtcRunner.Lisp.Prelude{}}` on success.

  Returns `{:error, %ValidationError{}}` when:

    * the source fails compile-time validation (any compile reason), or
    * attach-time `requires` validation fails (`:prelude_attach_failed`).

  Raises `ArgumentError` for genuine programmer misuse: a value that is neither
  a `%PtcRunner.Lisp.Prelude{}`, prelude source (binary), nor a list of
  source-bearing prelude selection maps.
  """
  @spec attach(Prelude.t() | String.t() | [Bundle.selection()], AttachContext.t()) ::
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

  def attach(selections, %AttachContext{} = context) when is_list(selections) do
    with {:ok, prelude} <- Bundle.compile(selections) do
      attach(prelude, context)
    end
  end

  def attach(other, %AttachContext{}) do
    raise ArgumentError,
          "prelude must be a %PtcRunner.Lisp.Prelude{} artifact, prelude source string, " <>
            "or a list of source-bearing prelude selection maps, got: " <>
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

  # Only host-granted `tool:<name>` requirements are supported.
  defp validate_required("tool:" <> name, export, context) when name != "" do
    check_tool_grant(name, export, context)
  end

  # Historical source metadata may still describe an external provider binding.
  # Provider availability is now validated by Kernel environment assembly, not
  # by the neutral Lisp evaluator.
  defp validate_required("upstream:" <> _provider_ref, _export, %AttachContext{}), do: :ok

  defp validate_required(required, export, %AttachContext{}) when is_binary(required) do
    {:error,
     attach_error(
       "export `#{export.ref}` declares an unrecognized backing requirement " <>
         "`#{required}`; the supported shape is `tool:<name>`",
       export
     )}
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

  defp attach_error(message, %Export{ref: ref, namespace: namespace}) do
    ValidationError.new(:prelude_attach_failed, message, namespace: namespace, ref: ref)
  end
end
