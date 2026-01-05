defmodule PtcDemo.Agent do
  @moduledoc """
  PTC Agent that uses SubAgent API to generate and execute PTC-Lisp programs.

  This module provides a GenServer-based wrapper around `PtcRunner.SubAgent` to maintain
  conversation state (memory, context history, stats) for the demo CLI and test runners.

  Uses an agentic loop where:
  - LLM generates PTC-Lisp programs to query data
  - Program results are returned for further reasoning
  - LLM continues until it provides a final answer
  - Memory persists between turns via SubAgent's native memory model

  This demonstrates the key advantage of Programmatic Tool Calling:
  - Large datasets stay in BEAM memory, never enter LLM context
  - LLM generates compact programs (~100 bytes) instead of processing raw data
  - Only small results return to LLM for final response
  """

  use GenServer

  alias PtcDemo.SampleData
  alias PtcDemo.SearchTool
  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop.ResponseHandler

  @model_env "PTC_DEMO_MODEL"
  @timeout 60_000
  @max_turns 5
  @genserver_timeout @max_turns * @timeout + 30_000

  defstruct [
    :model,
    :data_mode,
    :prompt_profile,
    :datasets,
    :last_program,
    :last_result,
    :memory,
    :usage,
    :programs_history
  ]

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def ask(question, opts \\ []) do
    GenServer.call(__MODULE__, {:ask, question, opts}, @genserver_timeout)
  end

  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  def last_program do
    GenServer.call(__MODULE__, :last_program)
  end

  def last_result do
    GenServer.call(__MODULE__, :last_result)
  end

  @doc """
  Get all programs generated in this session.
  Returns a list of {program, result} tuples.
  """
  def programs do
    GenServer.call(__MODULE__, :programs)
  end

  def list_datasets do
    SampleData.available_datasets()
  end

  def model do
    GenServer.call(__MODULE__, :model)
  end

  @doc """
  Get cumulative usage statistics for this session.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Get the current data mode (:schema or :explore).
  """
  def data_mode do
    GenServer.call(__MODULE__, :data_mode)
  end

  @doc """
  Get the current prompt profile.
  """
  def prompt_profile do
    GenServer.call(__MODULE__, :prompt_profile)
  end

  @doc """
  Get the current system prompt.
  """
  def system_prompt do
    GenServer.call(__MODULE__, :system_prompt)
  end

  @doc """
  Set the data mode and reset context.
  """
  def set_data_mode(mode) when mode in [:schema, :explore] do
    GenServer.call(__MODULE__, {:set_data_mode, mode})
  end

  @doc """
  Set the prompt profile.

  See `PtcDemo.Prompts.list/0` for available profiles.
  """
  def set_prompt_profile(profile) when is_atom(profile) do
    GenServer.call(__MODULE__, {:set_prompt_profile, profile})
  end

  @doc """
  Set the model to use for LLM calls.
  """
  def set_model(model) do
    GenServer.call(__MODULE__, {:set_model, model})
  end

  @doc """
  Available preset models for easy switching.
  """
  def preset_models do
    LLMClient.presets()
  end

  @doc """
  Get the default model.
  """
  def detect_model do
    LLMClient.default_model()
  end

  # --- GenServer Callbacks ---

  defp resolve_model_from_env do
    case System.get_env(@model_env) do
      nil ->
        detect_model()

      value ->
        case LLMClient.resolve(value) do
          {:ok, model_id} -> model_id
          {:error, _} -> value
        end
    end
  end

  @impl true
  def init(opts) do
    model = resolve_model_from_env()
    data_mode = Keyword.get(opts, :data_mode, :schema)
    prompt_profile = Keyword.get(opts, :prompt, :single_shot)

    # Note: documents not included in ctx - use search tool instead
    datasets = %{
      "products" => SampleData.products(),
      "orders" => SampleData.orders(),
      "employees" => SampleData.employees(),
      "expenses" => SampleData.expenses()
    }

    {:ok,
     %__MODULE__{
       model: model,
       data_mode: data_mode,
       prompt_profile: prompt_profile,
       datasets: datasets,
       last_program: nil,
       last_result: nil,
       memory: %{},
       usage: empty_usage(),
       programs_history: []
     }}
  end

  @impl true
  def handle_call({:ask, question, opts}, _from, state) do
    max_turns = Keyword.get(opts, :max_turns, @max_turns)
    debug = Keyword.get(opts, :debug, false)
    verbose = Keyword.get(opts, :verbose, false)

    # Build the SubAgent with requested max_turns
    agent = build_agent(state.data_mode, state.prompt_profile, max_turns)

    # Build context with datasets (memory is handled internally by SubAgent)
    context = Map.merge(state.datasets, %{"question" => question})

    if verbose, do: IO.puts("\n   [Agent] Generating response...")

    case SubAgent.run(agent,
           llm: llm_callback(state.model),
           context: context,
           max_turns: max_turns
         ) do
      {:ok, step} ->
        if debug, do: SubAgent.Debug.print_trace(step)

        result = step.return
        new_memory = step.memory || %{}
        program = extract_program_from_trace(step.trace)

        # Update usage stats
        new_usage = add_usage(state.usage, step.usage)

        # Track ALL programs from this ask (for multi-turn visibility)
        all_programs = extract_all_programs_from_trace(step.trace)
        new_programs = state.programs_history ++ all_programs

        # Format answer - if it's the raw value, format it nicely
        answer = ResponseHandler.format_result(result)

        if verbose,
          do:
            IO.puts("   [Result] #{ResponseHandler.format_result(result, result_max_chars: 80)}")

        {:reply, {:ok, answer},
         %{
           state
           | last_program: program,
             last_result: result,
             memory: new_memory,
             usage: new_usage,
             programs_history: new_programs
         }}

      {:error, step} ->
        # Print trace on error for debugging when verbose
        if verbose, do: SubAgent.Debug.print_trace(step)

        error_msg = format_error(step.fail)
        if verbose, do: IO.puts("   [Error] #{error_msg}")

        new_usage = add_usage(state.usage, step.usage)

        {:reply, {:error, error_msg}, %{state | usage: new_usage}}
    end
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, :ok,
     %{
       state
       | data_mode: :schema,
         last_program: nil,
         last_result: nil,
         memory: %{},
         usage: empty_usage(),
         programs_history: []
     }}
  end

  @impl true
  def handle_call(:last_program, _from, state) do
    {:reply, state.last_program, state}
  end

  @impl true
  def handle_call(:last_result, _from, state) do
    {:reply, state.last_result, state}
  end

  @impl true
  def handle_call(:programs, _from, state) do
    {:reply, state.programs_history, state}
  end

  @impl true
  def handle_call(:model, _from, state) do
    {:reply, state.model, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state.usage, state}
  end

  @impl true
  def handle_call(:data_mode, _from, state) do
    {:reply, state.data_mode, state}
  end

  @impl true
  def handle_call(:prompt_profile, _from, state) do
    {:reply, state.prompt_profile, state}
  end

  @impl true
  def handle_call(:system_prompt, _from, state) do
    agent = build_agent(state.data_mode, state.prompt_profile)
    preview = SubAgent.preview_prompt(agent, context: state.datasets)
    {:reply, preview.system, state}
  end

  @impl true
  def handle_call({:set_data_mode, mode}, _from, state) do
    {:reply, :ok,
     %{
       state
       | data_mode: mode,
         last_program: nil,
         last_result: nil,
         memory: %{},
         programs_history: []
     }}
  end

  @impl true
  def handle_call({:set_prompt_profile, profile}, _from, state) do
    {:reply, :ok, %{state | prompt_profile: profile}}
  end

  @impl true
  def handle_call({:set_model, model}, _from, state) do
    {:reply, :ok, %{state | model: model}}
  end

  # --- Private Functions ---

  defp build_agent(data_mode, prompt_profile, max_turns \\ @max_turns) do
    SubAgent.new(
      prompt: "{{question}}",
      signature: "(question :string) -> :any",
      max_turns: max_turns,
      tools: build_tools(),
      system_prompt: build_system_prompt(data_mode, prompt_profile, max_turns)
    )
  end

  defp build_tools do
    %{
      "search" =>
        {&SearchTool.search/1,
         signature:
           "(query :string, limit :int?, cursor :string?) -> " <>
             "{results [{id :string, title :string, topics [:string], department :string}], " <>
             "cursor :string?, has_more :bool, total :int}",
         description: "Search policy documents by keyword. Returns paginated results."}
    }
  end

  # For single-shot (max_turns == 1), strip the Tools section that mentions return/fail
  defp build_system_prompt(data_mode, prompt_profile, 1) do
    fn base_prompt ->
      # Remove the entire "# Available Tools" section
      stripped =
        base_prompt
        |> String.replace(~r/# Available Tools.*?(?=\n#|\z)/s, "")

      prefix = system_prompt_prefix(data_mode, prompt_profile)
      language_spec = PtcDemo.Prompts.get(prompt_profile)
      output_format = output_format_for(prompt_profile)

      [prefix, stripped, language_spec, output_format]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")
    end
  end

  defp build_system_prompt(data_mode, prompt_profile, _max_turns) do
    %{
      prefix: system_prompt_prefix(data_mode, prompt_profile),
      language_spec: PtcDemo.Prompts.get(prompt_profile),
      output_format: output_format_for(prompt_profile)
    }
  end

  defp output_format_for(:multi_turn) do
    """
    # Output Format

    Respond with a single ```clojure code block containing your program for THIS TURN:

    ```clojure
    (->> ctx/data (filter pred) (map transform))
    ```

    Do NOT include:
    - Explanatory text before or after the code
    - Multiple code blocks
    - Programs for future turns (write ONE program, observe result, then decide next)
    """
  end

  defp output_format_for(:single_shot) do
    """
    # Output Format

    Respond with a single ```clojure code block. The expression's value IS the result.

    ```clojure
    (count ctx/products)
    ```

    **IMPORTANT:** Do NOT wrap in `(return ...)` - just write the expression directly.
    """
  end

  defp system_prompt_prefix(:schema, :multi_turn) do
    data_schema = SampleData.schema_prompt()

    """
    You are a data analyst answering questions about datasets.

    ## Closed-form vs Open-form Tasks

    Before writing a program, determine whether the task is closed-form or open-form.

    **Closed-form**: Final program can be fully specified without executing any prior program.
    → Write one PTC-Lisp program and call (return result).

    **Open-form**: Choice of entities, thresholds, or next computation depends on values
    that must be observed at runtime (e.g., "most", "unusual", "inequity").
    → Multi-turn: compute → observe → decide → compute → return.

    **Turn 2 rules:**
    - You SEE Turn 1's result as feedback
    - You CANNOT embed it as literal data in Turn 2's code
    - Turn 2 can only access: `ctx/*` (original data) and stored values (plain symbols defined via def)
    - Use your observed conclusion to hardcode values in Turn 2

    ## Datasets (access via ctx/name):

    #{data_schema}
    """
  end

  defp system_prompt_prefix(:schema, _prompt_profile) do
    data_schema = SampleData.schema_prompt()

    """
    You are a data analyst answering questions about datasets.

    ## Datasets (access via ctx/name):

    #{data_schema}
    """
  end

  defp system_prompt_prefix(:explore, _prompt_profile) do
    dataset_names =
      SampleData.available_datasets() |> Enum.map_join(", ", fn {name, _} -> name end)

    """
    You are a data analyst answering questions about datasets.

    Datasets: #{dataset_names} (access via ctx/name)
    Discover structure: (first ctx/products) or (keys (first ctx/products))
    """
  end

  defp llm_callback(model) do
    fn %{system: system, messages: messages} ->
      full_messages = [%{role: :system, content: system} | messages]

      case LLMClient.generate_text(model, full_messages,
             receive_timeout: @timeout,
             req_http_options: [retry: :transient, max_retries: 3]
           ) do
        {:ok, %{content: text, tokens: tokens}} ->
          {:ok, %{content: text || "", tokens: tokens}}

        {:error, reason} ->
          {:error, format_llm_error(reason, model)}
      end
    end
  end

  defp format_llm_error(reason, model) do
    base_msg = format_error_reason(reason)
    "#{base_msg} (model: #{model})"
  end

  defp format_error_reason(%{reason: reason}) when is_binary(reason), do: reason
  defp format_error_reason(%{message: msg}) when is_binary(msg), do: msg
  defp format_error_reason(:invalid_format), do: "Invalid model format - check model string"
  defp format_error_reason(:timeout), do: "Request timed out"
  defp format_error_reason(:econnrefused), do: "Connection refused - API unreachable"
  defp format_error_reason(reason) when is_atom(reason), do: "#{reason}"
  defp format_error_reason(reason), do: inspect(reason)

  defp extract_program_from_trace(nil), do: nil
  defp extract_program_from_trace([]), do: nil

  defp extract_program_from_trace(trace) when is_list(trace) do
    case List.last(trace) do
      %{program: program} -> program
      _ -> nil
    end
  end

  # Extract ALL programs from trace (for multi-turn visibility)
  defp extract_all_programs_from_trace(nil), do: []
  defp extract_all_programs_from_trace([]), do: []

  defp extract_all_programs_from_trace(trace) when is_list(trace) do
    Enum.map(trace, fn
      %{program: program, result: result} -> {program, result}
      %{program: program} -> {program, nil}
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp format_error(%{reason: reason, message: message}) do
    reason_str =
      reason
      |> Atom.to_string()
      |> String.split("_")
      |> Enum.map(&String.capitalize/1)
      |> Enum.join("")

    "#{reason_str}: #{message}"
  end

  defp format_error(other), do: "Error: #{inspect(other, limit: 5)}"

  # --- Usage Tracking ---

  defp empty_usage do
    %{
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      system_prompt_tokens: 0,
      total_runs: 0,
      total_cost: 0.0,
      requests: 0
    }
  end

  defp add_usage(acc, nil), do: Map.put(acc, :total_runs, acc.total_runs + 1)

  defp add_usage(acc, usage) when is_map(usage) do
    input = Map.get(usage, :input_tokens, 0)
    output = Map.get(usage, :output_tokens, 0)
    total = Map.get(usage, :total_tokens, input + output)

    %{
      input_tokens: acc.input_tokens + input,
      output_tokens: acc.output_tokens + output,
      total_tokens: acc.total_tokens + total,
      system_prompt_tokens: acc.system_prompt_tokens,
      total_runs: acc.total_runs + 1,
      total_cost: acc.total_cost,
      requests: acc.requests + Map.get(usage, :llm_requests, 1)
    }
  end
end
