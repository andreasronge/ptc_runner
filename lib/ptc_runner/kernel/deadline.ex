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

  # Matches TokenManager's @response_transition_timeout_ms: the allowance a
  # response transition already gets once its caller's own budget is gone.
  @terminalization_floor_ms 5_000

  @doc """
  Budget for recording an outcome that must outlive the caller's deadline.

  A worker that crossed a dispatch fence has to report how the dispatch
  ended even when it learns that outcome after the caller's cutoff.
  Budgeting that report with `max(remaining, 1)` gave the store call one
  millisecond once the deadline had passed; under load the call timed out,
  the discarded report left the mutation lease `:dispatched`, and every
  later acquire returned `:mutation_indeterminate`. The floor keeps any
  longer live budget and never lets the report's allowance collapse with
  the caller's.
  """
  @spec terminalization(integer()) :: t()
  def terminalization(expires_at_ms) when is_integer(expires_at_ms) do
    # One clock sample: computing "remaining" and re-anchoring with new/1
    # would read the clock twice, and preemption between the reads extends
    # a live absolute cutoff — the drift this module exists to forbid.
    from_expires_at(max(expires_at_ms, now_ms() + @terminalization_floor_ms))
  end

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
