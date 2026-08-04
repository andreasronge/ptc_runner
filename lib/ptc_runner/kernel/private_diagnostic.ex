defmodule PtcRunner.Kernel.PrivateDiagnostic do
  @moduledoc """
  Diagnostic projection policy for analysis sessions whose results are private.

  A session over private records may not forward evaluator-produced message
  text: that text can quote a captured record, and a host may route diagnostics
  somewhere the result itself never goes. It may still tell the operator what
  went wrong, because the fault often describes nothing but the operator's own
  submitted source.

  Such a message is therefore **rebuilt, never forwarded**. A message is
  produced only for a fault kind that carries structured, source-derived
  detail, and every name in it must appear verbatim in the submitted source.
  Every other byte is a literal in this module. Anything outside that
  allowlist — and any detail whose shape is not exactly what the allowlist
  expects — collapses to `redacted_message/0`.

  `details` is evaluator output and is treated as untrusted: it selects among
  fixed shapes, it never carries provenance.
  """

  @redacted "private evaluation failed; diagnostic withheld by the private result policy"
  @max_names 32
  @max_name_bytes 128

  alias PtcRunner.Lisp.Eval.Helpers

  @doc "The fixed message used whenever no source-derived message can be rebuilt."
  @spec redacted_message() :: binary()
  def redacted_message, do: @redacted

  @doc """
  Projects one private-session diagnostic as `{message, redacted?}`.

  `redacted?` is true when anything the evaluator reported was withheld,
  including a name dropped because it is absent from `source`. A partially
  rebuilt message also says so in its own text, so a consumer that renders the
  message alone still cannot mistake a short list for the whole cause.
  """
  @spec project(term(), term(), term()) :: {binary(), boolean()}
  def project(:unbound_var, %{unbound_names: names}, source) when is_binary(source) do
    case admitted_names(names, source) do
      {[], _dropped?} -> {@redacted, true}
      {admitted, dropped?} -> {unbound_var_message(admitted, dropped?), dropped?}
    end
  end

  def project(_kind, _details, _source), do: {@redacted, true}

  # Walks at most the rendering bound and refuses anything that is not a proper
  # list of that shape, so an oversized or malformed detail costs nothing and
  # fails closed rather than raising inside the session owner.
  defp admitted_names(names, source) do
    case take_names(names, @max_names, []) do
      {:ok, candidates, overflow?} ->
        admitted = Enum.filter(candidates, &admitted_name?(&1, source))
        {admitted, overflow? or length(admitted) != length(candidates)}

      :error ->
        {[], true}
    end
  end

  defp take_names([], _remaining, taken), do: {:ok, Enum.reverse(taken), false}
  defp take_names([_name | _rest], 0, taken), do: {:ok, Enum.reverse(taken), true}

  defp take_names([name | rest], remaining, taken),
    do: take_names(rest, remaining - 1, [name | taken])

  defp take_names(_names, _remaining, _taken), do: :error

  defp admitted_name?(name, source) do
    is_binary(name) and String.valid?(name) and name != "" and
      byte_size(name) <= @max_name_bytes and String.contains?(source, name)
  end

  defp unbound_var_message(names, dropped?) do
    label = if length(names) == 1, do: "Undefined variable", else: "Undefined variables"
    "#{label}: #{Enum.join(names, ", ")}#{hint_suffix(names)}#{omission_suffix(dropped?)}"
  end

  defp omission_suffix(false), do: ""

  defp omission_suffix(true),
    do: " (further names withheld by the private result policy)"

  defp hint_suffix(names) do
    case Helpers.definition_only_hint(names) do
      nil -> ""
      hint -> ". Hint: #{hint}"
    end
  end
end
