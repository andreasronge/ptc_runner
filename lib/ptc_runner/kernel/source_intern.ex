defmodule PtcRunner.Kernel.SourceIntern do
  @moduledoc """
  Interns exact source binaries by qualified SHA-256 during package preparation.

  Identical bytes reuse one BEAM binary across workflow and mission catalogs.
  A hash collision with different bytes fails closed rather than aliasing two
  sources together.
  """

  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.ComponentOverride

  @enforce_keys [:entries]
  defstruct [:entries]

  @type t :: %__MODULE__{entries: %{binary() => binary()}}

  @doc "Returns an empty intern table."
  @spec new() :: t()
  def new, do: %__MODULE__{entries: %{}}

  @doc """
  Interns `source` and returns the canonical binary for that qualified hash.

  When the hash is new, `source` itself becomes the interned binary. When it
  already maps to equal bytes, the previously interned binary is returned so
  catalogs share one refc binary. Distinct bytes under the same hash fail.
  """
  @spec intern(t(), binary()) :: {:ok, binary(), t()} | {:error, :source_hash_collision}
  def intern(%__MODULE__{} = intern, source) when is_binary(source),
    do: intern_hash(intern, ComponentOverride.hash(source), source)

  @doc false
  @spec intern_hash(t(), binary(), binary()) ::
          {:ok, binary(), t()} | {:error, :source_hash_collision}
  def intern_hash(%__MODULE__{entries: entries} = intern, hash, source)
      when is_binary(hash) and is_binary(source) do
    case Map.fetch(entries, hash) do
      {:ok, existing} when existing == source ->
        {:ok, existing, intern}

      {:ok, _other} ->
        {:error, :source_hash_collision}

      :error ->
        {:ok, source, %{intern | entries: Map.put(entries, hash, source)}}
    end
  end

  @doc "Replaces each component's source with the interned binary for those bytes."
  @spec intern_components(t(), [Component.t()]) ::
          {:ok, t(), [Component.t()]} | {:error, :source_hash_collision}
  def intern_components(%__MODULE__{} = intern, components) when is_list(components) do
    Enum.reduce_while(components, {:ok, intern, []}, fn component, {:ok, intern, acc} ->
      case intern_component(intern, component) do
        {:ok, interned, intern} -> {:cont, {:ok, intern, [interned | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, intern, acc} -> {:ok, intern, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp intern_component(%__MODULE__{} = intern, %Component{source: source} = component) do
    case intern(intern, source) do
      {:ok, interned, intern} -> {:ok, %{component | source: interned}, intern}
      {:error, _reason} = error -> error
    end
  end
end
