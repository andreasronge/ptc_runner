defmodule PtcRunner.Kernel.PublicationAuthority do
  @moduledoc """
  Sealed, anchored artifact destinations authorized before execution.

  The authority carries only the four publication destinations. Paths must be
  absolute, and callers cannot replace or add a destination after preflight
  without invalidating the in-VM construction attestation.

  This is an in-VM construction attestation, not a security boundary against
  trusted code running in the same VM.
  """

  alias PtcRunner.Kernel.Attestation

  @destination_keys [:trace, :inspect, :output, :private_output]
  @enforce_keys @destination_keys ++ [:attestation]
  defstruct @enforce_keys
  @field_keys Enum.sort([:__struct__ | @enforce_keys])

  @opaque t :: %__MODULE__{
            trace: binary() | nil,
            inspect: binary() | nil,
            output: binary() | nil,
            private_output: binary() | nil,
            attestation: binary()
          }

  @doc false
  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_publication_authority}
  def new(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      if keys -- @destination_keys == [] and length(keys) == MapSet.size(MapSet.new(keys)) do
        authority = %__MODULE__{
          trace: Keyword.get(opts, :trace),
          inspect: Keyword.get(opts, :inspect),
          output: Keyword.get(opts, :output),
          private_output: Keyword.get(opts, :private_output),
          attestation: <<>>
        }

        if fields_valid?(authority) do
          {:ok, %{authority | attestation: Attestation.attest(__MODULE__, payload(authority))}}
        else
          {:error, :invalid_publication_authority}
        end
      else
        {:error, :invalid_publication_authority}
      end
    else
      {:error, :invalid_publication_authority}
    end
  end

  def new(_opts), do: {:error, :invalid_publication_authority}

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{attestation: attestation} = authority),
    do:
      fields_valid?(authority) and
        Attestation.valid?(__MODULE__, payload(authority), attestation)

  def valid?(_authority), do: false

  @doc false
  @spec options(t()) :: keyword()
  def options(%__MODULE__{} = authority) do
    if valid?(authority) do
      Enum.flat_map(@destination_keys, fn key ->
        case Map.fetch!(authority, key) do
          nil -> []
          path -> [{key, path}]
        end
      end)
    else
      raise ArgumentError, "invalid publication authority"
    end
  end

  @doc false
  @spec binding(term()) :: binary() | :invalid
  def binding(%__MODULE__{} = authority) do
    if valid?(authority),
      do: authority.attestation,
      else: :invalid
  end

  def binding(_authority), do: :invalid

  @doc false
  @spec matches?(term(), term()) :: boolean()
  def matches?(%__MODULE__{} = authority, binding) do
    valid?(authority) and Attestation.valid?(__MODULE__, payload(authority), binding)
  end

  def matches?(_authority, _binding), do: false

  defp fields_valid?(authority) do
    Enum.sort(Map.keys(authority)) == @field_keys and
      Enum.all?(@destination_keys, &valid_destination?(Map.fetch!(authority, &1)))
  end

  defp valid_destination?(nil), do: true

  defp valid_destination?(path) when is_binary(path),
    do: String.valid?(path) and not String.contains?(path, <<0>>) and Path.type(path) == :absolute

  defp valid_destination?(_path), do: false

  defp payload(authority) do
    {authority.trace, authority.inspect, authority.output, authority.private_output}
  end
end
