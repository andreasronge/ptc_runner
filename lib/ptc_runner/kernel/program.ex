defmodule PtcRunner.Kernel.Program do
  @moduledoc """
  Internal opaque representation of a static subordinate PTC-Lisp program.

  The Lisp `(program ...)` form captures canonical source without resolving or
  evaluating it in the workflow environment. Only bounded identity metadata is
  projected through public results; the source is evaluated later against the
  mission environment and current native evaluation continuation.
  """
  @enforce_keys [:source, :byte_size, :digest]
  defstruct [:source, :byte_size, :digest]

  @spec new(binary()) :: t()
  @doc "Constructs opaque source identity with byte size and SHA-256 digest."
  def new(source) when is_binary(source) do
    %__MODULE__{
      source: source,
      byte_size: byte_size(source),
      digest: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
    }
  end

  @type t :: %__MODULE__{source: binary(), byte_size: non_neg_integer(), digest: binary()}
end
