defmodule PtcRunner.Kernel.PrivateDiagnostic do
  @moduledoc """
  Diagnostic projection policy for analysis sessions whose results are private.

  A session over private records may not forward evaluator-produced message
  text: that text can quote a captured record, and a host may route diagnostics
  somewhere the result itself never goes. It may still tell the operator what
  went wrong, because the fault often describes nothing but the operator's own
  submitted source — or, for a narrower class, nothing that evaluation could
  yet have captured.

  Two admission rules apply, both **rebuild-or-bound, never raw forward** of
  untrusted evaluator prose outside their footing:

  1. **Source-derived structured detail** (today `:unbound_var`). A message is
     rebuilt only when every name appears verbatim in the submitted source.
     Every other byte is a literal in this module.

  2. **Pre-execution kinds.** Parse, analyze, symbol-limit, compile-budget, and
     tool-resolution faults are produced before the first capability call, so
     no captured record has entered the evaluation. Their evaluator message is
     admitted only when `details.capability_activity?` is not `true`, and only
     after a byte/UTF-8 bound at this boundary. The kind allowlist is the
     durable contract; the activity flag is the enforcement that keeps the
     footing true if a kind later gains a post-capability producer.

  `details` is evaluator output and is treated as untrusted: it selects among
  fixed shapes, it never carries provenance. Anything outside those rules
  collapses to `redacted_message/0`.
  """

  @redacted "private evaluation failed; diagnostic withheld by the private result policy"
  @max_names 32
  @max_name_bytes 128
  @max_pre_execution_message_bytes 4_096

  # Kinds whose constructors run in parse/analyze/compile or the pre-execution
  # tool guard. Runtime cousins such as `:arity_error` stay outside this set.
  @pre_execution_kinds [
    :parse_error,
    :invalid_arity,
    :invalid_form,
    :symbol_limit_exceeded,
    :compile_timeout,
    :compile_memory_exceeded,
    :unknown_tool,
    :private_tool_unauthorized,
    :unknown_namespace
  ]

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

  def project(kind, details, _source)
      when kind in @pre_execution_kinds and is_map(details) do
    if capability_idle?(details) do
      admit_pre_execution_message(details)
    else
      {@redacted, true}
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

  # Explicit `true` means a capability ran in this evaluation: the pre-execution
  # footing no longer holds, even if the kind is still on the allowlist. Absent
  # or `false` keeps the admit path open for compile-time Steps that never set
  # the flag and for `release_failure/5`, which always records it.
  defp capability_idle?(%{capability_activity?: true}), do: false
  defp capability_idle?(_details), do: true

  defp admit_pre_execution_message(details) do
    case Map.get(details, :message) do
      message when is_binary(message) and message != "" ->
        if String.valid?(message) do
          {clip_utf8(message, @max_pre_execution_message_bytes), false}
        else
          {@redacted, true}
        end

      _other ->
        {@redacted, true}
    end
  end

  defp clip_utf8(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp clip_utf8(value, max_bytes) do
    value
    |> binary_part(0, max_bytes)
    |> trim_invalid_suffix()
  end

  defp trim_invalid_suffix(value) do
    if String.valid?(value),
      do: value,
      else: trim_invalid_suffix(binary_part(value, 0, byte_size(value) - 1))
  end
end
