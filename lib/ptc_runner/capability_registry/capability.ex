defmodule PtcRunner.CapabilityRegistry.Capability do
  @moduledoc """
  Abstract capability with multiple implementations.

  A Capability represents *what* can be done (the interface), while
  implementations represent *how* (concrete tools). This allows the
  registry to resolve the best implementation based on context.

  ## Example

      %Capability{
        id: "parse_csv",
        description: "Parse CSV text into structured data",
        canonical_signature: "(text :string) -> [{:map}]",
        implementations: ["parse_csv_v1", "parse_csv_v2", "parse_csv_eu"],
        default_impl: "parse_csv_v2"
      }

  """

  @type t :: %__MODULE__{
          id: String.t(),
          description: String.t() | nil,
          canonical_signature: String.t() | nil,
          implementations: [String.t()],
          default_impl: String.t() | nil
        }

  defstruct [
    :id,
    :description,
    :canonical_signature,
    :default_impl,
    implementations: []
  ]

  @doc """
  Creates a new capability.

  ## Examples

      iex> cap = PtcRunner.CapabilityRegistry.Capability.new(
      ...>   "parse_csv",
      ...>   description: "Parse CSV text into structured data",
      ...>   canonical_signature: "(text :string) -> [{:map}]"
      ...> )
      iex> cap.id
      "parse_csv"

  """
  @spec new(String.t(), keyword()) :: t()
  def new(id, opts \\ []) when is_binary(id) do
    %__MODULE__{
      id: id,
      description: Keyword.get(opts, :description),
      canonical_signature: Keyword.get(opts, :canonical_signature),
      implementations: Keyword.get(opts, :implementations, []),
      default_impl: Keyword.get(opts, :default_impl)
    }
  end

  @doc """
  Adds an implementation to the capability.

  Sets as default if it's the first implementation.
  """
  @spec add_implementation(t(), String.t()) :: t()
  def add_implementation(capability, impl_id) when is_binary(impl_id) do
    if impl_id in capability.implementations do
      capability
    else
      updated = %{capability | implementations: capability.implementations ++ [impl_id]}

      if capability.default_impl == nil do
        %{updated | default_impl: impl_id}
      else
        updated
      end
    end
  end

  @doc """
  Removes an implementation from the capability.

  Clears default_impl if the removed impl was the default.
  """
  @spec remove_implementation(t(), String.t()) :: t()
  def remove_implementation(capability, impl_id) do
    updated = %{
      capability
      | implementations: Enum.reject(capability.implementations, &(&1 == impl_id))
    }

    if capability.default_impl == impl_id do
      %{updated | default_impl: List.first(updated.implementations)}
    else
      updated
    end
  end

  @doc """
  Sets the default implementation.
  """
  @spec set_default(t(), String.t()) :: t()
  def set_default(capability, impl_id) when is_binary(impl_id) do
    if impl_id in capability.implementations do
      %{capability | default_impl: impl_id}
    else
      capability
    end
  end

  @doc """
  Converts to a JSON-serializable map.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = capability) do
    Map.from_struct(capability)
  end

  @doc """
  Creates from a JSON map.
  """
  @spec from_json(map()) :: {:ok, t()} | {:error, term()}
  def from_json(data) do
    {:ok,
     %__MODULE__{
       id: data["id"],
       description: data["description"],
       canonical_signature: data["canonical_signature"],
       implementations: data["implementations"] || [],
       default_impl: data["default_impl"]
     }}
  rescue
    e -> {:error, {:deserialization_failed, e}}
  end
end
