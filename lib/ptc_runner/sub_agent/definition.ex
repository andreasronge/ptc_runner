defmodule PtcRunner.SubAgent.Definition do
  @moduledoc false

  @typedoc """
  Language spec for system prompts.

  Can be:
  - String: used as-is
  - Atom: resolved via `PtcRunner.Lisp.LanguageSpec.get!/1` (e.g., `:explicit_return`, `:single_shot`)
  - Tuple: structured profile `{:profile, behavior, opts}` — see `PtcRunner.Lisp.LanguageSpec.resolve_profile/1`
  - Function: callback receiving context map with `:turn`, `:model`, `:memory`, `:messages`
  """
  @type language_spec ::
          String.t()
          | atom()
          | {:profile, atom()}
          | {:profile, atom(), keyword()}
          | (map() -> String.t())

  @type system_prompt_opts ::
          %{
            optional(:prefix) => String.t(),
            optional(:suffix) => String.t(),
            optional(:language_spec) => language_spec(),
            optional(:output_format) => String.t()
          }
          | (String.t() -> String.t())
          | String.t()

  @typedoc """
  LLM response format.

  Can be either a plain string (backward compatible) or a map with content and optional tokens.
  When tokens are provided, they are included in telemetry measurements and accumulated in Step.usage.

  For `:tool_calling` mode, the LLM callback may also return tool calls:
  `%{tool_calls: [%{id: "call_1", name: "search", args: %{"q" => "foo"}}], content: nil | "...", tokens: %{...}}`
  """
  @type llm_response ::
          String.t()
          | %{
              required(:content) => String.t(),
              optional(:tokens) => %{
                optional(:input) => pos_integer(),
                optional(:output) => pos_integer()
              }
            }
          | %{
              required(:tool_calls) => [map()],
              optional(:content) => String.t() | nil,
              optional(:tokens) => map()
            }

  @type llm_callback :: (map() -> {:ok, llm_response()} | {:error, term()})

  @type llm_registry :: %{atom() => llm_callback()}

  @typedoc """
  Compression strategy configuration.

  Can be:
  - `nil` or `false` - Compression disabled (default)
  - `true` - Use default strategy (`SingleUserCoalesced`) with default options
  - `Module` - Use custom strategy module with default options
  - `{Module, opts}` - Use custom strategy module with custom options

  See `PtcRunner.SubAgent.Compression` for details.
  """
  @type compression_opts :: nil | false | true | module() | {module(), keyword()}

  @typedoc """
  Output mode for SubAgent execution.

  - `:ptc_lisp` - Default. LLM generates PTC-Lisp code that is executed.
  - `:text` - Auto-detects behavior from tools and signature return type:
    - No tools + `:string`/no signature → raw text response
    - No tools + complex return type → JSON response (validated)
    - Tools + `:string`/no signature → tool loop → text answer
    - Tools + complex return type → tool loop → JSON answer
  """
  @type output_mode :: :ptc_lisp | :text

  @typedoc """
  Output format options for truncation and display.

  Fields:
  - `feedback_limit` - Max collection items in turn feedback (default: 10)
  - `feedback_max_chars` - Max chars in turn feedback (default: 512)
  - `history_max_bytes` - Truncation limit for `*1/*2/*3` history (default: 512)
  - `result_limit` - Inspect `:limit` for final result (default: 50)
  - `result_max_chars` - Final string truncation (default: 500)
  - `max_print_length` - Max chars per `println` call (default: 2000)
  """
  @type format_options :: [
          feedback_limit: pos_integer(),
          feedback_max_chars: pos_integer(),
          history_max_bytes: pos_integer(),
          result_limit: pos_integer(),
          result_max_chars: pos_integer(),
          max_print_length: pos_integer()
        ]

  @typedoc """
  Plan step definition.

  Each step is a `{id, description}` tuple where:
  - `id` is a string identifier (used as key in summaries)
  - `description` is a human-readable description of the step
  """
  @type plan_step :: {String.t(), String.t()}

  @type t :: %__MODULE__{
          prompt: String.t(),
          signature: String.t() | nil,
          parsed_signature: {:signature, list(), term()} | nil,
          tools: map(),
          llm_query: boolean(),
          builtin_tools: [atom()],
          max_turns: pos_integer(),
          retry_turns: non_neg_integer(),
          prompt_limit: map() | nil,
          timeout: pos_integer(),
          max_heap: pos_integer() | nil,
          mission_timeout: pos_integer() | nil,
          llm_retry: map() | nil,
          llm: atom() | (map() -> {:ok, llm_response()} | {:error, term()}) | nil,
          system_prompt: system_prompt_opts() | nil,
          memory_limit: pos_integer() | nil,
          max_depth: pos_integer(),
          turn_budget: pos_integer(),
          name: String.t() | nil,
          description: String.t() | nil,
          field_descriptions: map() | nil,
          context_descriptions: map() | nil,
          format_options: format_options(),
          float_precision: non_neg_integer(),
          compression: compression_opts(),
          thinking: boolean(),
          output: output_mode(),
          max_tool_calls: pos_integer() | nil,
          pmap_max_concurrency: pos_integer(),
          memory_strategy: :strict | :rollback,
          plan: [plan_step()],
          journaling: boolean(),
          completion_mode: :explicit | :auto
        }

  @default_format_options [
    feedback_limit: 10,
    feedback_max_chars: 512,
    history_max_bytes: 512,
    result_limit: 50,
    result_max_chars: 500,
    max_print_length: 2000
  ]

  defstruct [
    :prompt,
    :signature,
    :parsed_signature,
    :schema,
    :prompt_limit,
    :max_heap,
    :mission_timeout,
    :llm_retry,
    :llm,
    :system_prompt,
    :name,
    :description,
    :field_descriptions,
    :context_descriptions,
    :compression,
    thinking: false,
    tools: %{},
    llm_query: false,
    builtin_tools: [],
    max_turns: 5,
    retry_turns: 0,
    timeout: 5000,
    pmap_timeout: 5000,
    pmap_max_concurrency: System.schedulers_online() * 2,
    memory_limit: 1_048_576,
    max_depth: 3,
    turn_budget: 20,
    format_options: @default_format_options,
    float_precision: 2,
    max_tool_calls: nil,
    output: :ptc_lisp,
    memory_strategy: :strict,
    plan: [],
    journaling: false,
    completion_mode: :explicit
  ]

  @doc false
  @spec default_format_options() :: format_options()
  def default_format_options, do: @default_format_options

  @doc false
  @spec text_return?(t()) :: boolean()
  def text_return?(%__MODULE__{parsed_signature: nil}), do: true
  def text_return?(%__MODULE__{parsed_signature: {:signature, _, :string}}), do: true
  def text_return?(%__MODULE__{}), do: false

  @doc false
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    alias PtcRunner.SubAgent.{Signature, Validator}
    Validator.validate!(opts)

    # Parse signature if provided (cached for loop return validation)
    # Note: Validator.validate! already ensures signature parses correctly
    opts =
      case Keyword.fetch(opts, :signature) do
        {:ok, sig_str} when is_binary(sig_str) ->
          {:ok, parsed} = Signature.parse(sig_str)
          Keyword.put(opts, :parsed_signature, parsed)

        _ ->
          opts
      end

    # Merge format_options with defaults (user values override)
    opts =
      case Keyword.fetch(opts, :format_options) do
        {:ok, user_opts} when is_list(user_opts) ->
          merged = Keyword.merge(@default_format_options, user_opts)
          Keyword.put(opts, :format_options, merged)

        _ ->
          opts
      end

    # Normalize and validate plan to [{id, description}] format
    opts =
      case Keyword.fetch(opts, :plan) do
        {:ok, plan} when is_list(plan) ->
          Keyword.put(opts, :plan, normalize_plan(plan))

        {:ok, _} ->
          raise ArgumentError, "plan must be a list"

        :error ->
          opts
      end

    # Auto-enable journaling when a plan is present, regardless of completion_mode.
    # The plan progress checklist and step-done tracking require journaling to
    # render in turn feedback. Without it, the LLM never sees the checklist.
    # This overrides an explicit journaling: false when a non-empty plan is given.
    opts =
      if Keyword.get(opts, :plan, []) != [] do
        Keyword.put(opts, :journaling, true)
      else
        opts
      end

    struct(__MODULE__, opts)
  end

  # Normalize plan: accept ["step1", "step2"] or [{"id", "desc"}, ...] or keyword list
  # Also validates — raises ArgumentError on bad input
  defp normalize_plan(plan) do
    normalized =
      plan
      |> Enum.with_index(1)
      |> Enum.map(fn
        {{id, desc}, _idx} when is_binary(id) and is_binary(desc) ->
          if desc == "",
            do: raise(ArgumentError, "plan description cannot be empty for id #{inspect(id)}")

          {id, desc}

        {{id, desc}, _idx} when is_atom(id) and is_binary(desc) ->
          if desc == "",
            do: raise(ArgumentError, "plan description cannot be empty for id #{inspect(id)}")

          {to_string(id), desc}

        {desc, idx} when is_binary(desc) ->
          if desc == "", do: raise(ArgumentError, "plan description cannot be empty")
          {to_string(idx), desc}

        {other, _idx} ->
          raise ArgumentError, "invalid plan item: #{inspect(other)}"
      end)

    # Check for duplicate IDs
    ids = Enum.map(normalized, fn {id, _} -> id end)
    dupes = ids -- Enum.uniq(ids)

    if dupes != [] do
      raise ArgumentError, "duplicate plan IDs: #{inspect(Enum.uniq(dupes))}"
    end

    normalized
  end

  @doc false
  @spec unwrap_sentinels(PtcRunner.Step.t()) ::
          {:ok, PtcRunner.Step.t()} | {:error, PtcRunner.Step.t()}
  def unwrap_sentinels(%{return: {:__ptc_return__, value}} = step) do
    {:ok, %{step | return: value}}
  end

  def unwrap_sentinels(%{return: {:__ptc_fail__, value}} = step) do
    # Handle both structured and simple fail values
    {reason, message} =
      if is_map(value) do
        {Map.get(value, :reason, :failed), Map.get(value, :message, inspect(value))}
      else
        {:failed, inspect(value)}
      end

    # Convert to error step to preserve failure intent
    {:error, %{step | return: nil, fail: %{reason: reason, message: message}}}
  end

  def unwrap_sentinels(step), do: {:ok, step}
end
