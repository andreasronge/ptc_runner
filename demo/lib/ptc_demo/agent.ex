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
  alias PtcRunner.SubAgent

  @model_env "PTC_DEMO_MODEL"
  @timeout 60_000
  @max_turns 5
  @genserver_timeout @max_turns * @timeout + 30_000

  defstruct [
    :model,
    :data_mode,
    :datasets,
    :last_program,
    :last_result,
    :memory,
    :usage,
    :programs_history,
    :context_messages
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
  Get the current conversation context (list of messages).
  """
  def context do
    GenServer.call(__MODULE__, :context)
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
  Set the model to use for LLM calls.
  """
  def set_model(model) do
    GenServer.call(__MODULE__, {:set_model, model})
  end

  @doc """
  Available preset models for easy switching.
  """
  def preset_models do
    PtcDemo.ModelRegistry.preset_models()
  end

  @doc """
  Auto-detect which model to use based on available API keys.
  """
  def detect_model do
    PtcDemo.ModelRegistry.default_model()
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    model = System.get_env(@model_env) || detect_model()
    data_mode = Keyword.get(opts, :data_mode, :schema)

    datasets = %{
      products: SampleData.products(),
      orders: SampleData.orders(),
      employees: SampleData.employees(),
      expenses: SampleData.expenses()
    }

    IO.puts("   [Data] #{data_mode}")

    {:ok,
     %__MODULE__{
       model: model,
       data_mode: data_mode,
       datasets: datasets,
       last_program: nil,
       last_result: nil,
       memory: %{},
       usage: empty_usage(),
       programs_history: [],
       context_messages: []
     }}
  end

  @impl true
  def handle_call({:ask, question, opts}, _from, state) do
    stop_on_success = Keyword.get(opts, :stop_on_success, false)

    # Build the SubAgent
    agent = build_agent(state.data_mode)

    # Build context with datasets and current memory
    context = Map.merge(state.datasets, %{memory: state.memory})

    IO.puts("\n   [Agent] Generating response...")

    case SubAgent.run(agent,
           llm: llm_callback(state.model),
           context: context,
           max_turns: if(stop_on_success, do: 1, else: @max_turns)
         ) do
      {:ok, step} ->
        result = step.return
        new_memory = step.memory || %{}
        program = extract_program_from_trace(step.trace)

        # Update usage stats
        new_usage = add_usage(state.usage, step.usage)

        # Track program/result for programs/0
        program_entry = {program, result}
        new_programs = state.programs_history ++ [program_entry]

        # Update context messages for display
        new_context = state.context_messages ++ [%{role: :user, content: question}]

        # Format answer - if it's the raw value, format it nicely
        answer = format_answer(result)

        IO.puts("   [Result] #{truncate(inspect(result), 80)}")

        {:reply, {:ok, answer},
         %{
           state
           | last_program: program,
             last_result: result,
             memory: new_memory,
             usage: new_usage,
             programs_history: new_programs,
             context_messages: new_context
         }}

      {:error, step} ->
        error_msg = format_error(step.fail)
        IO.puts("   [Error] #{error_msg}")

        new_usage = add_usage(state.usage, step.usage)

        {:reply, {:error, error_msg},
         %{state | usage: new_usage}}
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
         programs_history: [],
         context_messages: []
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
  def handle_call(:context, _from, state) do
    {:reply, state.context_messages, state}
  end

  @impl true
  def handle_call(:system_prompt, _from, state) do
    agent = build_agent(state.data_mode)
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
         programs_history: [],
         context_messages: []
     }}
  end

  @impl true
  def handle_call({:set_model, model}, _from, state) do
    {:reply, :ok, %{state | model: model}}
  end

  # --- Private Functions ---

  defp build_agent(data_mode) do
    SubAgent.new(
      prompt: "{{question}}",
      signature: "(question :string) -> :any",
      max_turns: @max_turns,
      system_prompt: %{
        prefix: system_prompt_prefix(data_mode)
      }
    )
  end

  defp system_prompt_prefix(:schema) do
    data_schema = SampleData.schema_prompt()

    """
    You are a data analyst. Answer questions about data by querying datasets.

    To query data, output a PTC-Lisp program in a ```clojure code block. The result will be returned to you.
    When you have the answer, call (return <value>) with your final answer.
    Memory persists between programs - reference stored values with memory/key.
    Return types: "store X as Y" -> call (return {:Y value}), "what is X?" -> call (return value) directly.
    Note: Large results (200+ chars) are truncated. Use count, first, or take to limit output.

    Available datasets (access via ctx/name, e.g., ctx/products):

    #{data_schema}
    """
  end

  defp system_prompt_prefix(:explore) do
    dataset_names =
      SampleData.available_datasets() |> Enum.map_join(", ", fn {name, _} -> name end)

    """
    You are a data analyst. Answer questions about data by querying datasets.

    To query data, output a PTC-Lisp program in a ```clojure code block. The result will be returned to you.
    When you have the answer, call (return <value>) with your final answer.
    Memory persists between programs - reference stored values with memory/key.
    Return types: "store X as Y" -> call (return {:Y value}), "what is X?" -> call (return value) directly.
    IMPORTANT: Output only ONE program per response. Wait for the result before generating another.
    Note: Large results (200+ chars) are truncated. Use count, first, or take to limit output.

    Available datasets (access via ctx/name): #{dataset_names}

    Discover structure with: (first ctx/products) or (keys (first ctx/products))
    """
  end

  defp llm_callback(model) do
    fn %{system: system, messages: messages} ->
      full_messages = [%{role: :system, content: system} | messages]

      case ReqLLM.generate_text(model, full_messages,
             receive_timeout: @timeout,
             req_http_options: [retry: :transient, max_retries: 3]
           ) do
        {:ok, response} ->
          text = ReqLLM.Response.text(response)
          usage = ReqLLM.Response.usage(response)

          tokens =
            if usage do
              %{
                input: usage[:input_tokens] || usage["input_tokens"] || 0,
                output: usage[:output_tokens] || usage["output_tokens"] || 0
              }
            else
              %{input: 0, output: 0}
            end

          {:ok, %{content: text || "", tokens: tokens}}

        {:error, _} = error ->
          error
      end
    end
  end

  defp extract_program_from_trace(nil), do: nil
  defp extract_program_from_trace([]), do: nil

  defp extract_program_from_trace(trace) when is_list(trace) do
    case List.last(trace) do
      %{program: program} -> program
      _ -> nil
    end
  end

  defp format_answer(result) when is_number(result) do
    if is_float(result) do
      :erlang.float_to_binary(result, decimals: 2)
    else
      Integer.to_string(result)
    end
  end

  defp format_answer(result), do: inspect(result, limit: 50, pretty: false)

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

  defp truncate(str, max_len) do
    if String.length(str) > max_len do
      String.slice(str, 0, max_len) <> "..."
    else
      str
    end
  end

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
