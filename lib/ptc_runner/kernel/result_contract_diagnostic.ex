defmodule PtcRunner.Kernel.ResultContractDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.CommandContractAuthority
  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.CommandSource

  @constraints [
    :additionalProperties,
    :boolean_schema,
    :const,
    :enum,
    :format,
    :json_value,
    :maximum,
    :maxItems,
    :maxLength,
    :minimum,
    :minItems,
    :minLength,
    :required,
    :type
  ]
  @constraint_names Enum.map(@constraints, &Atom.to_string/1)
  @turn_pattern "(?:[1-9]|[1-9][0-9]|1[01][0-9]|12[0-8])"
  @constraint_pattern "(?:" <> Enum.join(@constraint_names, "|") <> ")"
  @prefix "agent could not satisfy the result contract within "
  @middle " turns; last candidate violated "
  @max_message_bytes byte_size(@prefix) + 3 + byte_size(@middle) +
                       (@constraint_names |> Enum.map(&byte_size/1) |> Enum.max())

  @doc false
  @spec retain_details(term()) :: {:ok, map()} | :error
  def retain_details(
        %{
          agent_turns: turns,
          constraint: constraint,
          contract_authority: %CommandContractAuthority{} = authority,
          violations: violations
        } = details
      )
      when turns in 1..128 and constraint in @constraints and is_list(violations) do
    with true <- CommandContractAuthority.valid?(authority),
         true <- valid_contract_source?(Map.get(details, :contract_source)),
         {:ok, retained_violations} <- retain_violations(violations, constraint, authority) do
      retained = %{
        agent_turns: turns,
        constraint: constraint,
        contract_authority: authority,
        violations: retained_violations
      }

      {:ok, maybe_put_source(retained, Map.get(details, :contract_source))}
    else
      _invalid -> :error
    end
  end

  def retain_details(_details), do: :error

  # The retained runtime details deliberately carry `CommandContractAuthority`
  # and `CommandPath` structs: they are what makes the diagnostic
  # authenticated at the error boundary. Neither is a JSON inspection value,
  # so publishing them verbatim poisons the sink and replaces the real
  # `result_contract_failed` outcome with `inspection_sink_error` — losing
  # exactly the evidence a failed run needs. Project only the inspection copy:
  # drop the internal attestation and render each already-authorized path as a
  # JSON Pointer. The runtime error keeps its structs unchanged.
  @doc false
  @spec inspection_details(term()) :: {:ok, map()} | :error
  def inspection_details(details) do
    with {:ok, retained} <- retain_details(details) do
      {:ok,
       retained
       |> Map.delete(:contract_authority)
       |> Map.put(:violations, Enum.map(retained.violations, &inspection_violation/1))}
    end
  end

  @doc false
  @spec retain_phase_details(term()) :: {:ok, map()} | :error
  def retain_phase_details(
        %{
          completion: :invalid_return,
          phase_index: 1,
          mission: mission,
          contract: contract,
          max_turns: turns,
          constraint: constraint,
          contract_authority: %CommandContractAuthority{} = authority,
          violations: violations
        } = details
      )
      when is_binary(mission) and is_binary(contract) and turns in 1..128 and
             constraint in @constraints and is_list(violations) do
    with true <- identifier?(mission),
         true <- identifier?(contract),
         true <- CommandContractAuthority.valid?(authority),
         true <- valid_phase_contract_source?(Map.get(details, :contract_source)),
         {:ok, retained_violations} <- retain_violations(violations, constraint, authority) do
      retained = %{
        completion: :invalid_return,
        phase_index: 1,
        mission: mission,
        contract: contract,
        max_turns: turns,
        constraint: constraint,
        contract_authority: authority,
        violations: retained_violations
      }

      {:ok, maybe_put_source(retained, Map.get(details, :contract_source))}
    else
      _invalid -> :error
    end
  end

  def retain_phase_details(_details), do: :error

  @doc false
  @spec phase_inspection_details(term()) :: {:ok, map()} | :error
  def phase_inspection_details(details) do
    with {:ok, retained} <- retain_phase_details(details) do
      {:ok,
       retained
       |> Map.delete(:contract_authority)
       |> Map.put(:violations, Enum.map(retained.violations, &inspection_violation/1))}
    end
  end

  @doc false
  @spec message(term(), term()) :: {:ok, binary()} | :error
  def message(turns, constraint) when turns in 1..128 and constraint in @constraints,
    do: {:ok, @prefix <> Integer.to_string(turns) <> @middle <> Atom.to_string(constraint)}

  def message(_turns, _constraint), do: :error

  @doc false
  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message) do
    Enum.any?(1..128, fn turns ->
      Enum.any?(@constraints, fn constraint -> message(turns, constraint) == {:ok, message} end)
    end)
  end

  def valid_message?(_message), do: false

  @doc false
  @spec message_schema(binary()) :: map()
  def message_schema(fallback) when is_binary(fallback) do
    %{
      "oneOf" => [
        %{"const" => fallback},
        %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => @max_message_bytes,
          "pattern" =>
            "^agent could not satisfy the result contract within #{@turn_pattern} turns; last candidate violated #{@constraint_pattern}$(?![\\s\\S])"
        }
      ]
    }
  end

  defp retain_violations([], :json_value, _authority), do: {:ok, []}

  defp retain_violations([violation], constraint, authority) do
    case violation do
      %{kind: ^constraint, path: %CommandPath{authority: {:contract, ^authority}} = path} = item ->
        if CommandPath.valid?(path) do
          {:ok, [Map.take(item, [:kind, :path, :missing_required])]}
        else
          :error
        end

      _invalid ->
        :error
    end
  end

  defp retain_violations(_violations, _constraint, _authority), do: :error

  # `retain_violations/3` already proved the path valid, so `to_pointer/1`
  # cannot raise here.
  defp inspection_violation(%{kind: kind, path: %CommandPath{} = path} = violation) do
    violation
    |> Map.take([:missing_required])
    |> Map.merge(%{kind: kind, path: CommandPath.to_pointer(path)})
  end

  defp valid_contract_source?(nil), do: true

  defp valid_contract_source?(source) when is_binary(source),
    do: match?({:ok, _source}, CommandSource.new(:result_contract, source))

  defp valid_contract_source?(_source), do: false

  defp valid_phase_contract_source?(nil), do: true

  defp valid_phase_contract_source?(source) when is_binary(source),
    do: match?({:ok, _source}, CommandSource.new(:phase_return_contract, source))

  defp valid_phase_contract_source?(_source), do: false

  defp identifier?(value),
    do:
      byte_size(value) in 1..128 and
        Regex.match?(~r/\A[a-z][a-z0-9._-]*\z/, value)

  defp maybe_put_source(details, source) when is_binary(source),
    do: Map.put(details, :contract_source, source)

  defp maybe_put_source(details, _source), do: details
end
