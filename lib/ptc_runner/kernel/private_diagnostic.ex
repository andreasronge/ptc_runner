defmodule PtcRunner.Kernel.PrivateDiagnostic do
  @moduledoc """
  Diagnostic projection policy for analysis sessions whose results are private.

  A session over private records may not forward evaluator-produced message
  text: that text can quote a captured record, and a host may route diagnostics
  somewhere the result itself never goes. It may still tell the operator what
  went wrong, because the fault often describes nothing but the operator's own
  submitted source — or, for a narrower class, nothing private that this
  evaluation itself captured.

  Three admission rules apply, all **rebuild-or-bound, never raw forward** of
  untrusted evaluator prose outside their footing:

  1. **Source-derived structured detail** (today `:unbound_var`). A message is
     rebuilt only when every name appears verbatim in the submitted source.
     Every other byte is a literal in this module.

  2. **Allowlisted compile/analyze kinds with no capability activity.** Several
     of these kinds (`:invalid_arity`, `:invalid_form`, `:unknown_tool`,
     `:private_tool_unauthorized`) also have runtime constructors. Admission
     therefore requires `details.capability_activity? == false` — measured for
     this evaluation — and a byte/UTF-8 bound at this boundary. The allowlist
     names which kinds may be considered; the activity flag is the load-bearing
     gate. Messages are a function of the submitted source, prelude surface, and
     installed tool names, not of values read from private records.

  3. **Code-owned structured selectors with no capability activity.** The
     private prelude boundary may replace an evaluator message with a closed
     `:safe_diagnostic` shape. This module admits only exact selector shapes it
     knows and emits only fixed literals. The current selector explains that
     `analysis/counters` expects a named-argument map and uses `run_id` in its
     remediation example; arbitrary `:invalid_tool_args` messages never enter
     the kind allowlist above.

  `details` is evaluator output and remains untrusted even when it contains a
  code-owned selector: it can only select among exact fixed shapes and never
  contributes rendered bytes. Anything outside those rules collapses to
  `redacted_message/0`.
  """

  @redacted "private evaluation failed; diagnostic withheld by the private result policy"
  @max_names 32
  @max_name_bytes 128
  @max_pre_execution_message_bytes 4_096
  @truncation_suffix " (further text withheld by the private result policy)"

  # Kinds whose primary constructors run in parse/analyze/compile or the
  # pre-execution tool guard. Some also have runtime producers; those stay
  # redacted unless `capability_activity?` is explicitly false. Runtime-only
  # cousins such as `:arity_error` stay outside this set.
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
  alias PtcRunner.Utf8

  @doc "The fixed message used whenever no source-derived message can be rebuilt."
  @spec redacted_message() :: binary()
  def redacted_message, do: @redacted

  @doc """
  Projects one private-session diagnostic as `{message, redacted?}`.

  `redacted?` is true when anything the evaluator reported was withheld,
  including a name dropped because it is absent from `source`, or a
  pre-execution message clipped at the admission bound. A partially rebuilt or
  clipped message also says so in its own text, so a consumer that renders the
  message alone still cannot mistake a short list for the whole cause.
  """
  @spec project(term(), term(), term()) :: {binary(), boolean()}
  def project(:unbound_var, %{unbound_names: names}, source) when is_binary(source) do
    case admitted_names(names, source) do
      {[], _dropped?} -> {@redacted, true}
      {admitted, dropped?} -> {unbound_var_message(admitted, dropped?), dropped?}
    end
  end

  def project(
        :invalid_tool_args,
        %{
          capability_activity?: false,
          safe_diagnostic:
            %{
              kind: :prelude_named_argument_map,
              ref: "analysis/counters",
              example_key: "run_id"
            } = diagnostic
        },
        _source
      )
      when map_size(diagnostic) == 3 do
    {~s(analysis/counters: expected one named argument map, for example {"run_id" value}; positional arguments are not accepted),
     false}
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

  # Require an explicit idle measurement. `release_failure/5` always records the
  # flag; an absent key means the shape is not what this rule expects, so fail
  # closed rather than forward evaluator text.
  defp capability_idle?(%{capability_activity?: false}), do: true
  defp capability_idle?(_details), do: false

  defp admit_pre_execution_message(details) do
    case Map.get(details, :message) do
      message when is_binary(message) ->
        if admissible_message?(message) do
          bound_pre_execution_message(message)
        else
          {@redacted, true}
        end

      _other ->
        {@redacted, true}
    end
  end

  defp admissible_message?(message) do
    String.valid?(message) and String.trim(message) != ""
  end

  defp bound_pre_execution_message(message) do
    if byte_size(message) <= @max_pre_execution_message_bytes do
      {message, false}
    else
      body_budget = max(@max_pre_execution_message_bytes - byte_size(@truncation_suffix), 1)
      {Utf8.truncate(message, body_budget) <> @truncation_suffix, true}
    end
  end
end
