defmodule PtcRunner.SubAgent.Compaction do
  @moduledoc """
  Pressure-triggered context compaction for multi-turn agents.

  Compaction reduces the LLM-input message list when turn count or estimated
  token usage crosses a threshold. Recent turns are preserved verbatim; older
  turns are trimmed (Phase 1) or summarized (Phase 2 — not yet implemented).

  Phase 1 ships **one** strategy: `:trim`. Custom strategy modules and
  `:summarize` are deferred to Phase 2.

  ## Configuration

      SubAgent.run(prompt, llm: llm, compaction: true)

      SubAgent.run(prompt,
        llm: llm,
        compaction: [
          strategy: :trim,
          trigger: [turns: 8, tokens: 12_000],
          keep_recent_turns: 3,
          keep_initial_user: true,
          token_counter: nil
        ]
      )

  Defaults for `compaction: true`:

      [
        strategy: :trim,
        trigger: [turns: 8],
        keep_recent_turns: 3,
        keep_initial_user: true,
        token_counter: nil
      ]

  Library default is `false` — compaction is opt-in.

  ## Token estimation

  Default counter is `String.length(content) / 4`, matching the existing
  metrics heuristic. Override via `token_counter: fun/1`. This is explicitly
  a pressure heuristic and **not** model-accurate.
  """

  alias PtcRunner.SubAgent.Compaction.{Context, Trim}

  @type message :: %{role: :user | :assistant, content: String.t()}

  @type stats :: map()

  @type normalized :: {:disabled, []} | {:trim, keyword()}

  @default_trim_opts [
    strategy: :trim,
    trigger: [turns: 8],
    keep_recent_turns: 3,
    keep_initial_user: true,
    token_counter: nil
  ]

  @valid_top_keys [
    :strategy,
    :trigger,
    :keep_recent_turns,
    :keep_initial_user,
    :token_counter
  ]

  @phase_2_doc "docs/plans/pressure-triggered-context-compaction-phase-2.md"

  @doc """
  Normalize compaction configuration.

  Accepts:

  - `nil` or `false` → `{:disabled, []}`
  - `true` → `{:trim, default_opts}`
  - `keyword()` with `strategy: :trim` (or unspecified) → `{:trim, merged_opts}`

  Raises `ArgumentError` for invalid input. The error message is the source of
  truth for what Phase 1 supports.
  """
  @spec normalize(nil | boolean() | keyword()) :: normalized()
  def normalize(nil), do: {:disabled, []}
  def normalize(false), do: {:disabled, []}
  def normalize(true), do: {:trim, @default_trim_opts}

  def normalize(opts) when is_list(opts) do
    cond do
      opts == [] ->
        raise ArgumentError,
              "compaction: [] is invalid. Use `compaction: true` for defaults."

      not Keyword.keyword?(opts) ->
        raise ArgumentError,
              "compaction must be a keyword list. Got: #{inspect(opts)}"

      true ->
        validate_keyword(opts)
    end
  end

  def normalize({mod, _mod_opts}) when is_atom(mod) and not is_nil(mod) do
    raise ArgumentError,
          phase_2_message("Custom strategy modules (`{Module, opts}`) are not supported.")
  end

  def normalize(mod) when is_atom(mod) do
    raise ArgumentError,
          phase_2_message("Custom strategy modules are not supported. Got: #{inspect(mod)}.")
  end

  def normalize(other) do
    raise ArgumentError,
          phase_2_message("Unsupported compaction configuration: #{inspect(other)}.")
  end

  defp validate_keyword(opts) do
    reject_unknown_keys!(opts)
    strategy = Keyword.get(opts, :strategy, :trim)
    reject_unsupported_strategy!(strategy)

    merged =
      @default_trim_opts
      |> Keyword.merge(opts)
      |> Keyword.put(:strategy, :trim)

    validate_trigger!(Keyword.fetch!(merged, :trigger))
    validate_keep_recent_turns!(Keyword.fetch!(merged, :keep_recent_turns))
    validate_keep_initial_user!(Keyword.fetch!(merged, :keep_initial_user))
    validate_token_counter!(Keyword.get(merged, :token_counter))

    {:trim, merged}
  end

  defp reject_unknown_keys!(opts) do
    case Keyword.keys(opts) -- @valid_top_keys do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "Unknown compaction option(s): #{inspect(unknown)}. " <>
                "Valid keys: #{inspect(@valid_top_keys)}."
    end
  end

  defp reject_unsupported_strategy!(:trim), do: :ok

  defp reject_unsupported_strategy!(other) do
    raise ArgumentError,
          phase_2_message("Phase 1 supports `strategy: :trim` only. Got: #{inspect(other)}.")
  end

  defp validate_trigger!(trigger) when not is_list(trigger) do
    raise ArgumentError, "compaction trigger must be a keyword list. Got: #{inspect(trigger)}"
  end

  defp validate_trigger!([]) do
    raise ArgumentError,
          "compaction trigger must specify at least one of `:turns` or `:tokens`."
  end

  defp validate_trigger!(trigger) do
    case Keyword.keys(trigger) -- [:turns, :tokens] do
      [] -> :ok
      bad -> raise ArgumentError, "Unknown trigger key(s): #{inspect(bad)}"
    end

    validate_positive!(trigger, :turns, "trigger[:turns]")
    validate_positive!(trigger, :tokens, "trigger[:tokens]")
  end

  defp validate_positive!(trigger, key, label) do
    case Keyword.get(trigger, key) do
      nil -> :ok
      n when is_integer(n) and n > 0 -> :ok
      bad -> raise ArgumentError, "#{label} must be a positive integer. Got: #{inspect(bad)}"
    end
  end

  defp validate_keep_recent_turns!(n) when is_integer(n) and n >= 1, do: :ok

  defp validate_keep_recent_turns!(other) do
    raise ArgumentError,
          "keep_recent_turns must be an integer >= 1. Got: #{inspect(other)}"
  end

  defp validate_keep_initial_user!(b) when is_boolean(b), do: :ok

  defp validate_keep_initial_user!(other) do
    raise ArgumentError,
          "keep_initial_user must be a boolean. Got: #{inspect(other)}"
  end

  defp validate_token_counter!(nil), do: :ok

  defp validate_token_counter!(fun) when is_function(fun, 1), do: :ok

  defp validate_token_counter!(other) do
    raise ArgumentError,
          "token_counter must be a 1-arity function or nil. Got: #{inspect(other)}"
  end

  defp phase_2_message(prefix) do
    prefix <>
      " Custom strategies and `:summarize` are deferred to Phase 2 — see " <>
      @phase_2_doc <> "."
  end

  @doc """
  Run compaction for a list of LLM-input messages.

  `normalized` is the output of `normalize/1`. Always returns
  `{messages, stats | nil}`:

  - When the strategy is `:disabled`, returns `{messages, nil}` — no work, no stats.
  - Otherwise dispatches to the strategy and returns its `{messages, stats}` result.
    Use `stats.triggered` (boolean) to distinguish a triggered trim from a
    not-triggered pass-through; the stats shape is consistent either way.
  """
  @spec maybe_compact([message()], Context.t(), normalized()) ::
          {[message()], stats() | nil}
  def maybe_compact(messages, %Context{} = _ctx, {:disabled, _}) do
    {messages, nil}
  end

  def maybe_compact(messages, %Context{} = ctx, {:trim, opts}) do
    Trim.run(messages, ctx, opts)
  end

  @doc """
  Default token counter — `String.length/1` divided by 4, with a floor of 1
  for any non-empty content.

  Mirrors `PtcRunner.SubAgent.Loop.Metrics.estimate_tokens/1` so token-pressure
  detection still fires on histories made of short messages. Pressure heuristic,
  not adapter-accurate.

  ## Examples

      iex> PtcRunner.SubAgent.Compaction.default_token_counter("hello world")
      2

      iex> PtcRunner.SubAgent.Compaction.default_token_counter("hi")
      1

      iex> PtcRunner.SubAgent.Compaction.default_token_counter("")
      0

  """
  @spec default_token_counter(String.t()) :: non_neg_integer()
  def default_token_counter(""), do: 0

  def default_token_counter(content) when is_binary(content) do
    max(1, div(String.length(content), 4))
  end

  @doc """
  Build a `Compaction.Context` for a given turn.

  Resolves the token counter from `opts` (or falls back to the default).
  """
  @spec build_context(keyword(), keyword()) :: Context.t()
  def build_context(loop_fields, opts) when is_list(loop_fields) and is_list(opts) do
    counter = Keyword.get(opts, :token_counter) || (&default_token_counter/1)

    %Context{
      turn: Keyword.fetch!(loop_fields, :turn),
      max_turns: Keyword.fetch!(loop_fields, :max_turns),
      retry_phase?: Keyword.get(loop_fields, :retry_phase?, false),
      memory: Keyword.get(loop_fields, :memory),
      token_counter: counter
    }
  end

  @doc "Default trim options used when `compaction: true`."
  @spec default_trim_opts() :: keyword()
  def default_trim_opts, do: @default_trim_opts
end
