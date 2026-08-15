defmodule PtcRunner.LLM.PreparedModel do
  @moduledoc """
  Immutable result of preparing a configured LLM selector.

  The value binds the adapter, original selector, adapter-owned request target,
  and catalog status. Hosts may pass it to `PtcRunner.LLM.callback/2` to avoid
  repeating adapter preparation; the target remains opaque to the host.
  """

  @statuses [:cataloged, :uncataloged, :unavailable]

  @enforce_keys [:adapter, :selector, :target, :catalog_status]
  defstruct @enforce_keys

  @type catalog_status :: :cataloged | :uncataloged | :unavailable
  @type t :: %__MODULE__{
          adapter: module(),
          selector: String.t(),
          target: term(),
          catalog_status: catalog_status()
        }

  @spec new(module(), String.t(), term(), catalog_status()) ::
          {:ok, t()} | {:error, :invalid_prepared_model}
  def new(adapter, selector, target, catalog_status)
      when is_atom(adapter) and is_binary(selector) and catalog_status in @statuses do
    if byte_size(selector) in 1..256 and String.valid?(selector) do
      {:ok,
       %__MODULE__{
         adapter: adapter,
         selector: selector,
         target: target,
         catalog_status: catalog_status
       }}
    else
      {:error, :invalid_prepared_model}
    end
  end

  def new(_adapter, _selector, _target, _catalog_status),
    do: {:error, :invalid_prepared_model}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = prepared) do
    Enum.sort(Map.keys(prepared)) ==
      Enum.sort([:__struct__, :adapter, :selector, :target, :catalog_status]) and
      is_atom(prepared.adapter) and is_binary(prepared.selector) and
      byte_size(prepared.selector) in 1..256 and String.valid?(prepared.selector) and
      prepared.catalog_status in @statuses
  end

  def valid?(_prepared), do: false
end
