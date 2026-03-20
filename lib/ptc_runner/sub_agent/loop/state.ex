defmodule PtcRunner.SubAgent.Loop.State do
  @moduledoc """
  Typed state struct for the SubAgent execution loop.

  All loop state fields live in one flat struct, providing compile-time field
  checking and clear documentation of the state shape. TextMode-specific fields
  (`schema`, `json_mode`, `tool_schemas`, etc.) default to `nil`/`0`/`[]`.

  ## Field Groups

  **Core** — required for every run:
  `llm`, `context`, `turn`, `messages`, `start_time`, `work_turns_remaining`

  **Budget** — turn/token budget tracking:
  `remaining_turns`, `work_turns_remaining`, `retry_turns_remaining`,
  `token_limit`, `budget_callback`, `on_budget_exceeded`

  **Metrics** — accumulated token/request counts:
  `total_input_tokens`, `total_output_tokens`, `total_cache_creation_tokens`,
  `total_cache_read_tokens`, `llm_requests`, `system_prompt_tokens`, `turn_tokens`

  **TextMode** — only used by text output mode:
  `schema`, `json_mode`, `tool_schemas`, `normalized_tools_map`,
  `api_name_map`, `total_tool_calls`, `all_tool_calls`

  **Transient** — set per-turn, not carried across runs:
  `current_turn_type`, `current_system_prompt`, `current_messages`, `compression_stats`
  """

  @enforce_keys [:llm, :context, :turn, :messages, :start_time, :work_turns_remaining]

  defstruct [
    # Core
    :llm,
    :llm_registry,
    :context,
    :messages,
    :start_time,
    turn: 1,
    turns: [],
    memory: nil,
    last_fail: nil,
    nesting_depth: 0,
    remaining_turns: 0,
    mission_deadline: nil,
    cache: false,
    debug: false,
    trace_mode: true,
    llm_retry: nil,
    collect_messages: false,

    # Token accumulation
    total_input_tokens: 0,
    total_output_tokens: 0,
    total_cache_creation_tokens: 0,
    total_cache_read_tokens: 0,
    llm_requests: 0,
    system_prompt_tokens: 0,
    turn_tokens: nil,

    # Turn history
    turn_history: [],

    # Field descriptions from upstream agent
    received_field_descriptions: nil,

    # System prompt for message collection
    collected_system_prompt: nil,

    # Prompt tracking
    expanded_prompt: nil,
    original_prompt: nil,
    normalized_tools: nil,

    # Budget model
    work_turns_remaining: 0,
    retry_turns_remaining: 0,
    last_return_error: nil,

    # Budget callback options
    token_limit: nil,
    on_budget_exceeded: nil,
    budget_callback: nil,

    # Trace context
    trace_context: nil,

    # Lisp resource limits
    max_heap: nil,

    # Journal / summaries / tool_cache
    journal: nil,
    summaries: %{},
    tool_cache: nil,

    # Child steps for TraceTree
    child_steps: [],

    # Agent name
    agent_name: nil,

    # Streaming callback
    on_chunk: nil,

    # Prior conversation history
    initial_messages: nil,

    # Transient per-turn fields
    current_turn_type: nil,
    current_system_prompt: nil,
    current_messages: nil,
    compression_stats: nil,

    # TextMode-specific fields
    schema: nil,
    json_mode: nil,
    tool_schemas: nil,
    normalized_tools_map: nil,
    api_name_map: nil,
    total_tool_calls: 0,
    all_tool_calls: []
  ]

  @type t :: %__MODULE__{}
end
