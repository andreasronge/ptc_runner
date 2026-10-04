defmodule PtcRunner.Kernel.MCPBorrowToken do
  @moduledoc false

  @enforce_keys [:id, :seal]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{id: reference(), seal: :atomics.atomics_ref()}

  @spec new() :: t()
  def new, do: %__MODULE__{id: make_ref(), seal: :atomics.new(1, signed: false)}

  def id(%__MODULE__{id: id}), do: id

  def sealed?(%__MODULE__{seal: seal}), do: :atomics.get(seal, 1) == 1

  # Called by a transport owner while handling seal, before it can admit the
  # next request. Copies of the token keep the seal without transport-owned
  # tombstones, so returning borrows cannot grow a shared transport's state.
  def seal(%__MODULE__{seal: seal}), do: :atomics.put(seal, 1, 1)
end
