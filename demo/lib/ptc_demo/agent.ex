defmodule PtcDemo.Agent do
  @moduledoc """
  PTC Agent that uses LLM to generate programs and PtcRunner to execute them.

  Uses an agentic loop where:
  - LLM decides when to query data by outputting a PTC program
  - Program results are returned as tool results
  - LLM continues until it provides a final answer (no program)
  - Values can be stored and retrieved across queries using "store as X" pattern

  This demonstrates the key advantage of Programmatic Tool Calling:
  - Large datasets stay in BEAM memory, never enter LLM context
  - LLM generates compact programs (~200 bytes) instead of processing raw data
  - Only small results return to LLM for final response
  - Multi-turn conversations with persistent memory across queries
  """

  use GenServer

  import ReqLLM.Context

  alias PtcDemo.SampleData

  @model_env "PTC_DEMO_MODEL"
  @timeout 60_000
  @max_iterations 5

  # --- State ---
  defstruct [
    :model,
    :context,
    :datasets,
    :last_program,
    :last_result,
    :data_mode,
    :usage,
    :memory
  ]

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def ask(question) do
    GenServer.call(__MODULE__, {:ask, question}, @timeout)
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
  Get all programs generated in this session (extracted from conversation context).
  Returns a list of {program_json, result} tuples.
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
  Get the current conversation context (list of messages, excluding system prompt).
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
  Set the data mode and reset context with new system prompt.
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
  Delegates to ModelRegistry for single source of truth.
  """
  def preset_models do
    PtcDemo.ModelRegistry.preset_models()
  end

  @doc """
  Auto-detect which model to use based on available API keys.
  Delegates to ModelRegistry for single source of truth.
  """
  def detect_model do
    PtcDemo.ModelRegistry.default_model()
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    model = System.get_env(@model_env) || detect_model()
    # Data mode: :schema (default, full schema) or :explore (discover via introspection)
    data_mode = Keyword.get(opts, :data_mode, :schema)

    # Pre-load datasets into memory (simulating a real system)
    datasets = %{
      "products" => SampleData.products(),
      "orders" => SampleData.orders(),
      "employees" => SampleData.employees(),
      "expenses" => SampleData.expenses()
    }

    context = ReqLLM.Context.new([system(system_prompt(data_mode))])

    IO.puts("   [Data] #{data_mode}")

    {:ok,
     %__MODULE__{
       model: model,
       context: context,
       datasets: datasets,
       last_program: nil,
       last_result: nil,
       data_mode: data_mode,
       usage: empty_usage(),
       memory: %{}
     }}
  end

  @impl true
  def handle_call({:ask, question}, _from, state) do
    # Add user question to context
    context = ReqLLM.Context.append(state.context, user(question))

    # Run the agentic loop with initial last_exec = {nil, nil} and persisted memory
    case agent_loop(
           state.model,
           context,
           state.datasets,
           state.usage,
           @max_iterations,
           {nil, nil},
           state.memory
         ) do
      {:ok, answer, final_context, new_usage, last_program, last_result, new_memory} ->
        {:reply, {:ok, answer},
         %{
           state
           | context: final_context,
             last_program: last_program,
             last_result: last_result,
             usage: new_usage,
             memory: new_memory
         }}

      {:error, reason, final_context, new_usage} ->
        {:reply, {:error, reason}, %{state | context: final_context, usage: new_usage}}
    end
  end

  @impl true
  def handle_call(:reset, _from, state) do
    # Reset to :schema mode (default)
    new_context = ReqLLM.Context.new([system(system_prompt(:schema))])

    {:reply, :ok,
     %{
       state
       | context: new_context,
         last_program: nil,
         last_result: nil,
         data_mode: :schema,
         usage: empty_usage(),
         memory: %{}
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
    programs = extract_all_programs(state.context)
    {:reply, programs, state}
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
    # Exclude system messages
    messages = Enum.reject(state.context.messages, &(&1.role == :system))
    {:reply, messages, state}
  end

  @impl true
  def handle_call(:system_prompt, _from, state) do
    system_msg = Enum.find(state.context.messages, &(&1.role == :system))
    content = if system_msg, do: extract_text_content(system_msg.content), else: ""
    {:reply, content, state}
  end

  @impl true
  def handle_call({:set_data_mode, mode}, _from, state) do
    new_context = ReqLLM.Context.new([system(system_prompt(mode))])

    {:reply, :ok,
     %{
       state
       | data_mode: mode,
         context: new_context,
         last_program: nil,
         last_result: nil,
         memory: %{}
     }}
  end

  @impl true
  def handle_call({:set_model, model}, _from, state) do
    {:reply, :ok, %{state | model: model}}
  end

  # --- Agentic Loop ---

  defp agent_loop(_model, context, _datasets, usage, 0, _last_exec, _memory) do
    {:error, "Max iterations reached", context, usage}
  end

  defp agent_loop(model, context, datasets, usage, remaining, last_exec, memory) do
    IO.puts("\n   [Agent] Generating response (#{remaining} iterations left)...")

    # Capture the original question from the most recent user message
    original_query =
      context.messages
      |> Enum.reverse()
      |> Enum.find(&(&1.role == :user))
      |> case do
        nil -> ""
        msg -> extract_text_content(msg.content)
      end

    case ReqLLM.generate_text(model, context.messages, receive_timeout: @timeout) do
      {:ok, response} ->
        text = ReqLLM.Response.text(response)
        new_usage = add_usage(usage, ReqLLM.Response.usage(response))

        # Check if response contains a PTC program
        case extract_ptc_program(text) do
          {:ok, program_json} ->
            IO.puts("   [Program] #{truncate(program_json, 80)}")

            # Inject memory into context with memory_ prefix
            context_with_memory =
              memory
              |> Enum.reduce(datasets, fn {key, value}, acc ->
                Map.put(acc, "memory_#{key}", value)
              end)

            # Execute the program
            case PtcRunner.Json.run(program_json, context: context_with_memory, timeout: 5000) do
              {:ok, result, metrics} ->
                result_str = format_result(result)
                IO.puts("   [Result] #{truncate(result_str, 80)} (#{metrics.duration_ms}ms)")

                # Detect "store as {name}" pattern in the original query
                new_memory =
                  case Regex.run(~r/store (?:it |the result |this )?as ([\w-]+)/i, original_query) do
                    [_, name] -> Map.put(memory, name, result)
                    nil -> memory
                  end

                # Add assistant message and tool result, then continue loop
                new_context =
                  context
                  |> ReqLLM.Context.append(assistant(text))
                  |> ReqLLM.Context.append(user("[Tool Result]\n#{result_str}"))

                # Track raw result for test runner
                new_last_exec = {program_json, result}

                agent_loop(
                  model,
                  new_context,
                  datasets,
                  new_usage,
                  remaining - 1,
                  new_last_exec,
                  new_memory
                )

              {:error, reason} ->
                error_msg = PtcRunner.Json.format_error(reason)
                IO.puts("   [Error] #{error_msg}")

                # Add error as tool result and continue
                new_context =
                  context
                  |> ReqLLM.Context.append(assistant(text))
                  |> ReqLLM.Context.append(user("[Tool Error]\n#{error_msg}"))

                agent_loop(
                  model,
                  new_context,
                  datasets,
                  new_usage,
                  remaining - 1,
                  last_exec,
                  memory
                )
            end

          :none ->
            # No program found - this is the final answer
            IO.puts("   [Answer] Final response (no program)")
            final_context = ReqLLM.Context.append(context, assistant(text))

            # Use tracked last execution (raw values, not formatted strings)
            {last_program, last_result} = last_exec

            {:ok, text, final_context, new_usage, last_program, last_result, memory}
        end

      {:error, reason} ->
        {:error, "LLM error: #{inspect(reason)}", context, usage}
    end
  end

  # --- Private Functions ---

  defp system_prompt(:schema) do
    # Get schema from data module (simulates MCP tool schema discovery)
    data_schema = SampleData.schema_prompt()
    # Get operations prompt from library
    operations = PtcRunner.Schema.to_prompt()

    """
    You are a data analyst. Answer questions about data by querying datasets.

    To query data, output a PTC program in a ```json code block. The result will be returned to you.
    Memory: Store results across queries with "store as X" in your question.
    Access stored values with: {"op": "load", "name": "memory_X"}
    Note: Large results (200+ chars) are truncated. Use count, first, or take to limit output.

    Available datasets (with field types):

    #{data_schema}

    #{operations}
    """
  end

  defp system_prompt(:explore) do
    # Get operations prompt from library
    operations = PtcRunner.Schema.to_prompt()
    # Get dataset names dynamically
    dataset_names =
      SampleData.available_datasets() |> Enum.map_join(", ", fn {name, _} -> name end)

    """
    You are a data analyst. Answer questions about data by querying datasets.

    To query data, output a PTC program in a ```json code block. The result will be returned to you.
    IMPORTANT: Output only ONE program per response. Wait for the result before generating another.
    Memory: Store results across queries with "store as X" in your question.
    Access stored values with: {"op": "load", "name": "memory_X"}
    Note: Large results (200+ chars) are truncated. Use count, first, or take to limit output.

    Available datasets: #{dataset_names}

    Discover structure with: load <name> | first | keys

    #{operations}
    """
  end

  # Extract PTC program from LLM response (looks for ```json blocks)
  defp extract_ptc_program(text) do
    # Try extracting from markdown code block
    case Regex.run(~r/```(?:json)?\s*([\s\S]+?)\s*```/, text) do
      [_, content] ->
        content = String.trim(content)

        if String.starts_with?(content, "{") do
          json = extract_balanced_json(content)

          case validate_program(json) do
            :ok -> {:ok, json}
            {:error, _} -> :none
          end
        else
          :none
        end

      nil ->
        # Try finding a JSON object with "program" key anywhere in text
        case :binary.match(text, "{\"program\"") do
          {start, _} ->
            substring = binary_part(text, start, byte_size(text) - start)
            json = extract_balanced_json(substring)

            case validate_program(json) do
              :ok -> {:ok, json}
              {:error, _} -> :none
            end

          :nomatch ->
            :none
        end
    end
  end

  defp validate_program(json) do
    case Jason.decode(json) do
      {:ok, %{"program" => %{"op" => _}}} -> :ok
      {:ok, %{"program" => _}} -> {:error, "program must have 'op' field"}
      {:ok, _} -> {:error, "missing 'program' key"}
      {:error, _} -> {:error, "invalid JSON"}
    end
  end

  # Extract a complete JSON object by counting balanced braces
  defp extract_balanced_json(text) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({0, []}, fn
      "{", {depth, acc} -> {:cont, {depth + 1, ["{" | acc]}}
      "}", {1, acc} -> {:halt, {0, ["}" | acc]}}
      "}", {depth, acc} -> {:cont, {depth - 1, ["}" | acc]}}
      char, {depth, acc} when depth > 0 -> {:cont, {depth, [char | acc]}}
      _, {0, _} = state -> {:cont, state}
    end)
    |> case do
      {0, chars} -> chars |> Enum.reverse() |> Enum.join()
      _ -> text
    end
  end

  # Extract all programs and their results from conversation context
  defp extract_all_programs(context) do
    messages = context.messages

    messages
    |> Enum.with_index()
    |> Enum.filter(fn {msg, _idx} -> msg.role == :assistant end)
    |> Enum.flat_map(fn {msg, idx} ->
      content = extract_text_content(msg.content)

      case extract_ptc_program(content) do
        {:ok, program_json} ->
          # Look for the next user message which should be the tool result
          result =
            messages
            |> Enum.drop(idx + 1)
            |> Enum.find(fn m -> m.role == :user end)
            |> case do
              nil ->
                nil

              user_msg ->
                user_content = extract_text_content(user_msg.content)

                cond do
                  String.starts_with?(user_content, "[Tool Result]") ->
                    user_content |> String.replace_prefix("[Tool Result]\n", "") |> String.trim()

                  String.starts_with?(user_content, "[Tool Error]") ->
                    {:error,
                     user_content |> String.replace_prefix("[Tool Error]\n", "") |> String.trim()}

                  true ->
                    nil
                end
            end

          [{program_json, result}]

        :none ->
          []
      end
    end)
  end

  # Extract text from various content formats (string, ContentPart list, etc.)
  defp extract_text_content(content) when is_binary(content), do: content

  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.map(&extract_text_content/1)
    |> Enum.join("")
  end

  defp extract_text_content(%{text: text}), do: text
  defp extract_text_content(%{content: content}), do: extract_text_content(content)
  defp extract_text_content(_), do: ""

  # Truncated format for console output
  # Uses string length (not item count) to preserve short lists like keys output
  @max_result_chars 200

  defp format_result(result) when is_number(result) do
    if is_float(result) do
      :erlang.float_to_binary(result, decimals: 2)
    else
      Integer.to_string(result)
    end
  end

  defp format_result(result) do
    full = inspect(result, limit: 50)

    if String.length(full) > @max_result_chars do
      truncate_with_context(result, full)
    else
      full
    end
  end

  defp truncate_with_context(result, full) when is_list(result) do
    count = length(result)
    truncated = String.slice(full, 0, @max_result_chars)
    "#{truncated}... (#{count} items total)"
  end

  defp truncate_with_context(_result, full) do
    truncated = String.slice(full, 0, @max_result_chars)
    "#{truncated}..."
  end

  defp truncate(str, max_len) do
    if String.length(str) > max_len do
      String.slice(str, 0, max_len) <> "..."
    else
      str
    end
  end

  # --- Usage Tracking Helpers ---

  defp empty_usage do
    %{
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      total_cost: 0.0,
      requests: 0
    }
  end

  defp add_usage(acc, nil), do: acc
  defp add_usage(nil, usage), do: normalize_usage(usage)

  defp add_usage(acc, usage) when is_map(usage) do
    normalized = normalize_usage(usage)

    %{
      input_tokens: acc.input_tokens + normalized.input_tokens,
      output_tokens: acc.output_tokens + normalized.output_tokens,
      total_tokens: acc.total_tokens + normalized.total_tokens,
      total_cost: acc.total_cost + normalized.total_cost,
      requests: acc.requests + 1
    }
  end

  defp normalize_usage(usage) when is_map(usage) do
    %{
      input_tokens: usage[:input_tokens] || usage["input_tokens"] || 0,
      output_tokens: usage[:output_tokens] || usage["output_tokens"] || 0,
      total_tokens: usage[:total_tokens] || usage["total_tokens"] || 0,
      total_cost: usage[:total_cost] || usage["total_cost"] || 0.0,
      requests: 1
    }
  end
end
