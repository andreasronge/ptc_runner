defmodule PtcRunner.Kernel.Deadline do
  @moduledoc """
  Absolute monotonic deadline shared by bounded Kernel operations.

  A deadline is anchored once. Passing it to nested work preserves the same
  cutoff; callers may select an earlier deadline but cannot extend one by
  reconstructing a relative timeout.
  """

  @enforce_keys [:expires_at_ms]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{expires_at_ms: integer()}

  @spec new(pos_integer()) :: t()
  def new(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: new(timeout_ms, now_ms())

  @doc "Creates a deadline from a shared monotonic anchor."
  @spec new(pos_integer(), integer()) :: t()
  def new(timeout_ms, anchor_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 and is_integer(anchor_ms),
      do: %__MODULE__{expires_at_ms: anchor_ms + timeout_ms}

  @doc false
  @spec from_expires_at(integer()) :: t()
  def from_expires_at(expires_at_ms) when is_integer(expires_at_ms),
    do: %__MODULE__{expires_at_ms: expires_at_ms}

  @doc "Returns the non-negative duration remaining before the cutoff."
  @spec remaining(t()) :: non_neg_integer()
  def remaining(%__MODULE__{} = deadline), do: remaining(deadline, now_ms())

  @doc false
  @spec remaining(t(), integer()) :: non_neg_integer()
  def remaining(%__MODULE__{expires_at_ms: expires_at_ms}, current_ms)
      when is_integer(current_ms),
      do: max(expires_at_ms - current_ms, 0)

  @doc "Returns whether the monotonic cutoff has been reached."
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{} = deadline), do: expired?(deadline, now_ms())

  @doc false
  @spec expired?(t(), integer()) :: boolean()
  def expired?(%__MODULE__{expires_at_ms: expires_at_ms}, current_ms)
      when is_integer(current_ms),
      do: current_ms >= expires_at_ms

  @doc "Selects the earlier of two already-anchored deadlines."
  @spec earliest(t(), t()) :: t()
  def earliest(
        %__MODULE__{expires_at_ms: left} = left_deadline,
        %__MODULE__{expires_at_ms: right} = right_deadline
      ) do
    if left <= right, do: left_deadline, else: right_deadline
  end

  @doc false
  @spec expires_at(t()) :: integer()
  def expires_at(%__MODULE__{expires_at_ms: expires_at_ms}), do: expires_at_ms

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{expires_at_ms: expires_at_ms} = deadline),
    do:
      Map.keys(deadline) |> Enum.sort() == [:__struct__, :expires_at_ms] and
        is_integer(expires_at_ms)

  def valid?(_deadline), do: false

  @doc false
  @spec live?(term()) :: boolean()
  def live?(deadline), do: valid?(deadline) and not expired?(deadline)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
