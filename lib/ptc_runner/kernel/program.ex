defmodule PtcRunner.Kernel.Program do
  @moduledoc "An opaque static subordinate program with canonical source identity."
  @enforce_keys [:source, :byte_size, :digest]
  defstruct [:source, :byte_size, :digest]

  @spec new(binary()) :: t()
  def new(source) when is_binary(source) do
    %__MODULE__{
      source: source,
      byte_size: byte_size(source),
      digest: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
    }
  end

  @type t :: %__MODULE__{source: binary(), byte_size: non_neg_integer(), digest: binary()}
end
