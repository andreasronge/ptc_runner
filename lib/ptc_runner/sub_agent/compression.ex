defmodule PtcRunner.SubAgent.Compression do
  @moduledoc """
  Behaviour for message history compression strategies.

  Compression strategies transform turn history into LLM messages at render time.
  This enables various prompt optimization techniques like coalescing multiple turns
  into a single USER message.

  ## Strategy Pattern

  Strategies implement `to_messages/3` which receives:
  - `turns` - List of completed turns to compress
  - `memory` - Accumulated definitions from all turns
  - `opts` - Rendering options (mission, tools, data, limits, etc.)

  ## Configuration

  Use `normalize/1` to handle the various compression option formats:

      # Disabled (default)
      normalize(nil)   # => {nil, []}
      normalize(false) # => {nil, []}

      # Enabled with defaults
      normalize(true)  # => {SingleUserCoalesced, [println_limit: 15, tool_call_limit: 20]}

      # Custom strategy or options
      normalize(MyStrategy)               # => {MyStrategy, [println_limit: 15, ...]}
      normalize({MyStrategy, opts})       # => {MyStrategy, merged_opts}

  See [Message History Optimization](docs/specs/message-history-optimization-architecture.md) for context.
  """

  alias PtcRunner.Turn

  @typedoc """
  An LLM message with role and content.
  """
  @type message :: %{role: :system | :user | :assistant, content: String.t()}

  @typedoc """
  Options passed to compression strategies.

  - `mission` - The agent's mission/prompt text
  - `system_prompt` - Static system prompt content
  - `tools` - Map of available tools
  - `data` - Input data provided to the agent
  - `println_limit` - Max println calls to include (default: 15)
  - `tool_call_limit` - Max tool calls to include (default: 20)
  - `turns_left` - Remaining turns for the agent
  """
  @type opts :: [
          prompt: String.t(),
          system_prompt: String.t(),
          tools: map(),
          data: map(),
          println_limit: non_neg_integer(),
          tool_call_limit: non_neg_integer(),
          turns_left: non_neg_integer()
        ]

  @typedoc """
  Statistics about what compression did.

  Returned alongside messages to report exactly what was dropped or collapsed.
  """
  @type stats :: %{
          enabled: boolean(),
          strategy: String.t(),
          turns_compressed: non_neg_integer(),
          tool_calls_total: non_neg_integer(),
          tool_calls_shown: non_neg_integer(),
          tool_calls_dropped: non_neg_integer(),
          printlns_total: non_neg_integer(),
          printlns_shown: non_neg_integer(),
          printlns_dropped: non_neg_integer(),
          error_turns_collapsed: non_neg_integer()
        }

  @doc "Human-readable name for this compression strategy."
  @callback name() :: String.t()

  @doc """
  Render turns into LLM messages with compression statistics.

  Returns a tuple of `{messages, stats}` where stats reports exactly what
  the compression did (items dropped, errors collapsed, etc.).

  Compression is a pure function - same inputs always produce the same output.
  Turn count is derived from `length(turns)`, not message count.
  """
  @callback to_messages(
              turns :: [Turn.t()],
              memory :: map(),
              opts :: opts()
            ) :: {[message()], stats()}

  # Default strategy module - will be implemented in issue #620
  @default_strategy PtcRunner.SubAgent.Compression.SingleUserCoalesced

  @default_opts [println_limit: 15, tool_call_limit: 20]

  @doc """
  Normalize compression configuration into `{strategy, opts}` tuple.

  Handles various configuration formats:
  - `nil` or `false` - Compression disabled, returns `{nil, []}`
  - `true` - Use default strategy with default options
  - `Module` - Use custom strategy with default options
  - `{Module, opts}` - Use custom strategy with merged options

  ## Examples

      iex> PtcRunner.SubAgent.Compression.normalize(nil)
      {nil, []}

      iex> PtcRunner.SubAgent.Compression.normalize(false)
      {nil, []}

      iex> {strategy, opts} = PtcRunner.SubAgent.Compression.normalize(true)
      iex> strategy
      PtcRunner.SubAgent.Compression.SingleUserCoalesced
      iex> opts[:println_limit]
      15
      iex> opts[:tool_call_limit]
      20

      iex> {strategy, _opts} = PtcRunner.SubAgent.Compression.normalize(SomeStrategy)
      iex> strategy
      SomeStrategy

      iex> {strategy, opts} = PtcRunner.SubAgent.Compression.normalize({SomeStrategy, println_limit: 5})
      iex> strategy
      SomeStrategy
      iex> opts[:println_limit]
      5
      iex> opts[:tool_call_limit]
      20

  """
  @spec normalize(boolean() | module() | {module(), keyword()} | nil) ::
          {module() | nil, keyword()}
  def normalize(nil), do: {nil, []}
  def normalize(false), do: {nil, []}
  def normalize(true), do: {@default_strategy, @default_opts}

  def normalize(module) when is_atom(module) do
    {module, @default_opts}
  end

  def normalize({module, opts}) when is_atom(module) and is_list(opts) do
    {module, Keyword.merge(@default_opts, opts)}
  end

  @doc """
  Returns the default compression options.

  ## Examples

      iex> PtcRunner.SubAgent.Compression.default_opts()
      [println_limit: 15, tool_call_limit: 20]

  """
  @spec default_opts() :: keyword()
  def default_opts, do: @default_opts
end
