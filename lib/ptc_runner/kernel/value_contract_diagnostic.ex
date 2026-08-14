defmodule PtcRunner.Kernel.ValueContractDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.CommandContractAuthority
  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.ValueContract

  @spec classify(ValueContract.t(), term()) ::
          {:ok, map()} | {:error, :invalid_contract_classification}
  def classify(%ValueContract{} = contract, value) do
    {classification, evidence} = ValueContract.classify_with_evidence(contract, value)

    case CommandContractAuthority.new(evidence) do
      {:ok, authority} ->
        {:ok,
         classification
         |> Map.put(:contract_authority, authority)
         |> authorize_violation_paths(authority)}

      {:error, :invalid_contract_classification} = error ->
        error
    end
  end

  def classify(_contract, _value), do: {:error, :invalid_contract_classification}

  @spec diagnostic_parts(CommandSource.t() | nil, map()) ::
          {CommandSource.t() | nil, CommandPath.t() | nil}
  def diagnostic_parts(
        %CommandSource{} = source,
        %{contract_authority: authority} = classification
      ) do
    case CommandSource.with_contract(source, authority) do
      {:ok, bound_source} -> {bound_source, first_violation_path(classification, authority)}
      {:error, :invalid_command_source} -> {source, nil}
    end
  end

  def diagnostic_parts(%CommandSource{} = source, _classification), do: {source, nil}
  def diagnostic_parts(nil, _classification), do: {nil, nil}

  defp authorize_violation_paths(classification, authority) do
    Map.update(classification, :violations, [], fn violations ->
      Enum.flat_map(violations, fn
        %{segments: segments} = violation ->
          case CommandPath.contract(authority, segments) do
            {:ok, path} -> [violation |> Map.delete(:segments) |> Map.put(:path, path)]
            {:error, :invalid_command_path} -> []
          end

        _invalid ->
          []
      end)
    end)
  end

  defp first_violation_path(%{violations: violations}, authority) when is_list(violations) do
    paths = Enum.flat_map(violations, &violation_paths(&1, authority))

    Enum.find(paths, &(&1.segments != [])) || List.first(paths)
  end

  defp first_violation_path(_classification, _authority), do: nil

  defp violation_paths(
         %{path: %CommandPath{} = parent, missing_required: [name | _rest]},
         authority
       )
       when is_binary(name) do
    case CommandPath.contract(authority, parent.segments ++ [{:property, name}]) do
      {:ok, missing_path} -> [missing_path]
      {:error, :invalid_command_path} -> [parent]
    end
  end

  defp violation_paths(%{path: %CommandPath{} = path}, _authority), do: [path]
  defp violation_paths(_violation, _authority), do: []
end
