defmodule PtcRunner.Kernel.ComponentOverrideDiagnostic do
  @moduledoc """
  Closed messages for a refused component-override descriptor.

  Three verification mistakes, a confined-source refusal, and a schema
  violation previously collapsed to one catalog sentence with no path. Each
  verification rule now names the descriptor field it broke; the path is the
  schema-authorized pointer to that field. Rejected hash values, candidate
  bytes, and the descriptor's filesystem path never cross this boundary:
  `source.name` stays the logical document role `component-override.json`.
  """

  alias PtcRunner.Kernel.ComponentOverride

  @reasons [
    {:override_base_hash_mismatch, "base_source_hash",
     "base_source_hash does not match the installed source"},
    {:override_source_hash_mismatch, "source_hash",
     "source_hash does not match the candidate bytes"},
    {:override_component_not_selected, "component_id",
     "component_id is not a selected component"},
    {:invalid_override_source, "path", "path is not a usable candidate source"}
  ]

  @messages Map.new(@reasons, fn {reason, _field, message} -> {reason, message} end)
  @paths Map.new(@reasons, fn {reason, field, _message} ->
           {reason, [{:property, field}]}
         end)

  if Enum.any?(@paths, fn {_reason, [{:property, field}]} ->
       not Map.has_key?(ComponentOverride.schema()["properties"], field)
     end) do
    raise "component override diagnostic fields drifted from the descriptor schema"
  end

  @type reason ::
          :override_base_hash_mismatch
          | :override_source_hash_mismatch
          | :override_component_not_selected
          | :invalid_override_source

  @doc "Renders one verification rule as its fixed message, or declines so the catalog literal stands."
  @spec message(term()) :: {:ok, binary()} | :error
  def message(reason) when is_map_key(@messages, reason), do: {:ok, Map.fetch!(@messages, reason)}
  def message(_reason), do: :error

  @doc false
  @spec path(term()) :: [PtcRunner.Kernel.CommandPath.segment()] | nil
  def path(reason) when is_map_key(@paths, reason), do: Map.fetch!(@paths, reason)
  def path(_reason), do: nil

  @doc false
  @spec valid_message?(term()) :: boolean()
  # ex_dna:disable-for-next-line — closed override vocabulary, independent of contract-schema messages
  def valid_message?(message) when is_binary(message), do: message in messages()
  def valid_message?(_message), do: false

  @doc false
  @spec messages() :: [binary()]
  def messages, do: @messages |> Map.values() |> Enum.sort()

  @doc false
  @spec message_schema(binary()) :: map()
  def message_schema(fallback) when is_binary(fallback),
    do: %{"enum" => Enum.sort([fallback | messages()])}

  @doc false
  @spec reasons() :: [reason()]
  def reasons, do: @reasons |> Enum.map(&elem(&1, 0)) |> Enum.sort()
end
