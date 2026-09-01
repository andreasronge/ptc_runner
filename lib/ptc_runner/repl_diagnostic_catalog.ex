defmodule PtcRunner.ReplDiagnosticCatalog do
  @moduledoc """
  Closed public diagnostics for REPL-only preparation and evaluation.

  These rows are separate from `PtcRunner.Kernel.DiagnosticCatalog` (command
  envelope phases) and `PtcRunner.ProfileDiagnosticCatalog` (private analysis).
  Unknown reasons are never promoted to public vocabulary.
  """

  @rows [
    %{
      code: :inspect_only_unavailable,
      message: "this inspect-only session cannot use Kernel, provider, or capability routes",
      description:
        "An expression crossed into a Kernel, provider, or capability route that inspect-only mode does not install."
    }
  ]

  @by_code Map.new(@rows, &{&1.code, &1})

  @spec rows() :: [map()]
  def rows, do: @rows

  @spec classify(term()) :: {:ok, map()} | {:error, :unknown_repl_diagnostic}
  def classify(reason) when is_atom(reason), do: fetch(reason)
  def classify({reason, _details}) when is_atom(reason), do: fetch(reason)
  def classify(_reason), do: {:error, :unknown_repl_diagnostic}

  @spec classify!(term()) :: map()
  def classify!(reason) do
    case classify(reason) do
      {:ok, diagnostic} ->
        diagnostic

      {:error, :unknown_repl_diagnostic} ->
        raise ArgumentError, "unknown REPL diagnostic: #{inspect(reason)}"
    end
  end

  defp fetch(code) do
    case Map.fetch(@by_code, code) do
      {:ok, diagnostic} -> {:ok, diagnostic}
      :error -> {:error, :unknown_repl_diagnostic}
    end
  end
end
