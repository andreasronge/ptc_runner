defmodule PtcRunner.SubAgent.Compaction.Trim do
  @moduledoc """
  Deterministic pressure-triggered trimming strategy.

  Keeps:

  1. The first user message (when `keep_initial_user: true`) — the *first*
     message with role `:user` in the input list, defined as the head, not a
     re-derivation from turns.
  2. The last `keep_recent_turns × 2` messages.

  Drops everything in between when triggered. Pure function — no LLM calls,
  no state mutations.

  ## Triggers

  - `trigger[:turns]` — fires when `ctx.turn > N`.
  - `trigger[:tokens]` — fires when estimated total message tokens ≥ `N`.

  Both may be set; either firing triggers compaction (OR, not AND). When
  not triggered, returns the input unchanged.

  ## Edge cases

  - Fewer messages than `keep_recent_turns × 2 + 1` → input unchanged,
    `triggered: false`.
  - First message not `:user` → skip initial-user retention; `kept_initial_user?: false`.
  - Recent slice begins with `:assistant` → drop one more from the front so it
    starts with `:user`.
  - Single retained message exceeds token budget → keep it whole, set
    `over_budget?: true`.

  Token estimation is a pressure heuristic, not adapter-accurate.
  """

  @type message :: %{role: :user | :assistant, content: String.t()}

  @type stats :: %{
          enabled: boolean(),
          triggered: boolean(),
          strategy: String.t(),
          reason: :turn_pressure | :token_pressure | nil,
          messages_before: non_neg_integer(),
          messages_after: non_neg_integer(),
          estimated_tokens_before: non_neg_integer(),
          estimated_tokens_after: non_neg_integer(),
          kept_initial_user?: boolean(),
          kept_recent_turns: non_neg_integer(),
          over_budget?: boolean()
        }

  alias PtcRunner.SubAgent.Compaction.Context

  @doc """
  Run the trim strategy.

  Returns `{messages, stats}` when triggered, or `{:not_triggered, messages, stats}`
  when no pressure threshold was crossed (or when there aren't enough messages
  to trim usefully).
  """
  @spec run([message()], Context.t(), keyword()) ::
          {[message()], stats()} | {:not_triggered, [message()], stats()}
  def run(messages, %Context{} = ctx, opts) when is_list(messages) and is_list(opts) do
    keep_recent_turns = Keyword.fetch!(opts, :keep_recent_turns)
    keep_initial_user = Keyword.fetch!(opts, :keep_initial_user)
    trigger = Keyword.fetch!(opts, :trigger)

    tokens_before = estimate_tokens(messages, ctx.token_counter)

    case detect_pressure(messages, ctx, trigger, tokens_before) do
      nil ->
        {:not_triggered, messages, not_triggered_stats()}

      reason ->
        do_run(messages, ctx, opts, keep_recent_turns, keep_initial_user, tokens_before, reason)
    end
  end

  defp do_run(messages, ctx, opts, keep_recent_turns, keep_initial_user, tokens_before, reason) do
    min_required = keep_recent_turns * 2 + if(keep_initial_user, do: 1, else: 0)

    if length(messages) <= min_required do
      {:not_triggered, messages, not_triggered_stats()}
    else
      {trimmed, kept_initial?} = do_trim(messages, keep_recent_turns, keep_initial_user)
      tokens_after = estimate_tokens(trimmed, ctx.token_counter)

      stats = %{
        enabled: true,
        triggered: true,
        strategy: "trim",
        reason: reason,
        messages_before: length(messages),
        messages_after: length(trimmed),
        estimated_tokens_before: tokens_before,
        estimated_tokens_after: tokens_after,
        kept_initial_user?: kept_initial?,
        kept_recent_turns: keep_recent_turns,
        over_budget?: over_budget?(trimmed, ctx.token_counter, opts)
      }

      {trimmed, stats}
    end
  end

  defp detect_pressure(messages, ctx, trigger, tokens_before) do
    cond do
      turn_pressure?(ctx, trigger) -> :turn_pressure
      token_pressure?(messages, trigger, tokens_before) -> :token_pressure
      true -> nil
    end
  end

  defp turn_pressure?(%Context{turn: turn}, trigger) do
    case Keyword.get(trigger, :turns) do
      nil -> false
      n when is_integer(n) -> turn > n
    end
  end

  defp token_pressure?(_messages, trigger, tokens) do
    case Keyword.get(trigger, :tokens) do
      nil -> false
      n when is_integer(n) -> tokens >= n
    end
  end

  defp do_trim([first | _] = messages, keep_recent_turns, true)
       when is_map_key(first, :role) do
    case first do
      %{role: :user} ->
        recent = take_recent(messages, keep_recent_turns, _skip_head = 1)
        {[first | recent], true}

      _ ->
        recent = take_recent(messages, keep_recent_turns, _skip_head = 0)
        {recent, false}
    end
  end

  defp do_trim(messages, keep_recent_turns, false) do
    recent = take_recent(messages, keep_recent_turns, _skip_head = 0)
    {recent, false}
  end

  defp take_recent(messages, keep_recent_turns, skip_head) do
    take_count = keep_recent_turns * 2
    available = length(messages) - skip_head
    n = min(take_count, max(available, 0))
    recent = Enum.take(messages, -n)
    align_user_leading(recent, messages, skip_head, n)
  end

  defp align_user_leading([], _all, _skip, _n), do: []

  defp align_user_leading([%{role: :user} | _] = recent, _all, _skip, _n), do: recent

  defp align_user_leading([%{role: :assistant} | rest], all, skip, n) do
    # Drop one more from the front so the slice starts with :user. If that
    # would over-shrink and re-include the head we already kept (or below 0),
    # just return what's left.
    available = length(all) - skip
    next_n = min(n - 1, available)

    if next_n <= 0 do
      rest
    else
      recent = Enum.take(all, -next_n)
      align_user_leading(recent, all, skip, next_n)
    end
  end

  defp estimate_tokens(messages, token_counter) do
    Enum.reduce(messages, 0, fn %{content: content}, acc ->
      acc + token_counter.(content)
    end)
  end

  defp over_budget?(messages, token_counter, opts) do
    case get_in(opts, [:trigger, :tokens]) do
      nil ->
        false

      budget when is_integer(budget) ->
        Enum.any?(messages, fn %{content: content} -> token_counter.(content) > budget end)
    end
  end

  defp not_triggered_stats do
    %{enabled: true, triggered: false, strategy: "trim"}
  end
end
