defmodule PtcDemo.LispAgent do
  @moduledoc """
  PTC-Lisp Agent that uses LLM to generate Lisp programs and PtcRunner.Lisp to execute them.

  Uses an agentic loop where:
  - LLM decides when to query data by outputting a PTC-Lisp program
  - Program results are returned as tool results
  - LLM continues until it provides a final answer (no program)

  This demonstrates the key advantage of Programmatic Tool Calling:
  - Large datasets stay in BEAM memory, never enter LLM context
  - LLM generates compact programs (~100 bytes) instead of processing raw data
  - Only small results return to LLM for final response
  """

  use GenServer

  import ReqLLM.Context

  alias PtcDemo.SampleData

  @model_env "PTC_DEMO_MODEL"
  @timeout 60_000
  @max_iterations 5
  # GenServer timeout must accommodate worst case: max_iterations * timeout + retries + buffer
  @genserver_timeout @max_iterations * @timeout + 30_000

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
  Get all programs generated in this session (extracted from conversation context).
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
    # PtcRunner.Lisp now supports flexible key access (atom or string keys)
    datasets = %{
      products: SampleData.products(),
      orders: SampleData.orders(),
      employees: SampleData.employees(),
      expenses: SampleData.expenses()
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
  def handle_call({:ask, question, opts}, _from, state) do
    # Add user question to context
    context = ReqLLM.Context.append(state.context, user(question))
    stop_on_success = Keyword.get(opts, :stop_on_success, false)

    # Run the agentic loop with persisted memory from state
    case agent_loop(
           state.model,
           context,
           state.datasets,
           state.usage,
           @max_iterations,
           {nil, nil},
           state.memory,
           stop_on_success
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

  defp agent_loop(_model, context, _datasets, usage, 0, _last_exec, _memory, _stop_on_success) do
    {:error, "Max iterations reached", context, usage}
  end

  defp agent_loop(model, context, datasets, usage, remaining, last_exec, memory, stop_on_success) do
    IO.puts("\n   [Agent] Generating response (#{remaining} iterations left)...")

    case ReqLLM.generate_text(model, context.messages,
           receive_timeout: @timeout,
           retry: :transient,
           max_retries: 3
         ) do
      {:ok, response} ->
        text = ReqLLM.Response.text(response)
        new_usage = add_usage(usage, ReqLLM.Response.usage(response))

        # Handle nil or empty response from LLM
        case validate_llm_response(text, response) do
          {:error, error_msg} ->
            IO.puts("   [LLM Error] #{error_msg}")

            # Add error feedback and retry
            new_context =
              context
              |> ReqLLM.Context.append(
                user("[System Error]\n#{error_msg}\nPlease try again with a valid response.")
              )

            agent_loop(
              model,
              new_context,
              datasets,
              new_usage,
              remaining - 1,
              last_exec,
              memory,
              stop_on_success
            )

          :ok ->
            # Check if response contains a PTC-Lisp program
            case extract_ptc_program(text) do
              {:ok, program} ->
                IO.puts("   [Program] #{truncate(program, 80)}")

                # Increment run counter when program is generated
                run_tracked_usage = increment_run_count(new_usage)

                # Execute the program using PtcRunner.Lisp with persistent memory
                case PtcRunner.Lisp.run(program,
                       context: datasets,
                       memory: memory,
                       timeout: 5000,
                       float_precision: 2
                     ) do
                  {:ok, result, _delta, new_memory} ->
                    result_str = format_result(result)
                    IO.puts("   [Result] #{truncate(result_str, 80)}")

                    # Track raw result for test runner
                    new_last_exec = {program, result}

                    # If stop_on_success, return immediately with the result
                    if stop_on_success do
                      final_context =
                        context
                        |> ReqLLM.Context.append(assistant(text))
                        |> ReqLLM.Context.append(user("[Tool Result]\n#{result_str}"))

                      {:ok, result_str, final_context, run_tracked_usage, program, result,
                       new_memory}
                    else
                      # Add assistant message and tool result, then continue loop
                      new_context =
                        context
                        |> ReqLLM.Context.append(assistant(text))
                        |> ReqLLM.Context.append(user("[Tool Result]\n#{result_str}"))

                      agent_loop(
                        model,
                        new_context,
                        datasets,
                        run_tracked_usage,
                        remaining - 1,
                        new_last_exec,
                        new_memory,
                        stop_on_success
                      )
                    end

                  {:error, reason} ->
                    error_msg = format_lisp_error(reason)
                    IO.puts("   [Error] #{error_msg}")

                    # Add error as tool result and continue (preserve memory)
                    new_context =
                      context
                      |> ReqLLM.Context.append(assistant(text))
                      |> ReqLLM.Context.append(user("[Tool Error]\n#{error_msg}"))

                    agent_loop(
                      model,
                      new_context,
                      datasets,
                      run_tracked_usage,
                      remaining - 1,
                      last_exec,
                      memory,
                      stop_on_success
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
        end

      {:error, reason} ->
        {:error, "LLM error: #{inspect(reason)}", context, usage}
    end
  end

  # --- Private Functions ---

  # Validate LLM response and return helpful error messages
  defp validate_llm_response(nil, response) do
    # Try to extract useful info from the response for debugging
    reason =
      cond do
        # Check if there's a finish reason that explains the nil
        (finish_reason = ReqLLM.Response.finish_reason(response)) != nil ->
          "LLM returned no text content (finish_reason: #{finish_reason})"

        # Check for tool calls without text
        (tool_calls = ReqLLM.Response.tool_calls(response)) != [] ->
          tool_names = Enum.map(tool_calls, & &1.name) |> Enum.join(", ")

          "LLM returned tool calls instead of text: [#{tool_names}]. This demo expects text responses with ```clojure code blocks."

        true ->
          "LLM returned nil/empty text content. Response: #{inspect(response, limit: 300)}"
      end

    {:error, reason}
  end

  defp validate_llm_response("", _response) do
    {:error, "LLM returned empty text content"}
  end

  defp validate_llm_response(text, _response) when is_binary(text) do
    :ok
  end

  defp validate_llm_response(other, _response) do
    {:error, "LLM returned unexpected content type: #{inspect(other, limit: 100)}"}
  end

  defp system_prompt(:schema) do
    # Get schema from data module
    data_schema = SampleData.schema_prompt()
    # Get PTC-Lisp language reference from library API
    lisp_reference = PtcRunner.Lisp.Schema.to_prompt()

    """
    You are a data analyst. Answer questions about data by querying datasets.

    To query data, output a PTC-Lisp program in a ```clojure code block. The result will be returned to you.
    When you have the answer, respond in plain text WITHOUT a code block.
    Memory persists between programs - reference stored values with memory/key.
    Return types: "store X as Y" → {:Y value}, "what is X?" → return the value directly (not a map).
    Note: Large results (200+ chars) are truncated. Use count, first, or take to limit output.

    Available datasets (access via ctx/name, e.g., ctx/products):

    #{data_schema}

    #{lisp_reference}
    """
  end

  defp system_prompt(:explore) do
    # Get PTC-Lisp language reference from library API
    lisp_reference = PtcRunner.Lisp.Schema.to_prompt()
    # Get dataset names dynamically
    dataset_names =
      SampleData.available_datasets() |> Enum.map_join(", ", fn {name, _} -> name end)

    """
    You are a data analyst. Answer questions about data by querying datasets.

    To query data, output a PTC-Lisp program in a ```clojure code block. The result will be returned to you.
    When you have the answer, respond in plain text WITHOUT a code block.
    Memory persists between programs - reference stored values with memory/key.
    Return types: "store X as Y" → {:Y value}, "what is X?" → return the value directly (not a map).
    IMPORTANT: Output only ONE program per response. Wait for the result before generating another.
    Note: Large results (200+ chars) are truncated. Use count, first, or take to limit output.

    Available datasets (access via ctx/name): #{dataset_names}

    Discover structure with: (first ctx/products) or (keys (first ctx/products))

    #{lisp_reference}
    """
  end

  # Extract PTC-Lisp program from LLM response (looks for ```lisp or ```clojure blocks)
  defp extract_ptc_program(text) do
    # Try extracting from markdown code block (lisp, clojure, or unmarked)
    case Regex.run(~r/```(?:lisp|clojure)?\s*([\s\S]+?)\s*```/, text) do
      [_, content] ->
        content = String.trim(content)

        # Valid Lisp starts with (, {, or [
        if valid_lisp_start?(content) do
          {:ok, content}
        else
          :none
        end

      nil ->
        # Try finding a bare S-expression (starts with paren)
        case Regex.run(~r/\([\w-]+\s[\s\S]+?\)(?=\s*$|\s*\n\n)/m, text) do
          [match] -> {:ok, String.trim(match)}
          nil -> :none
        end
    end
  end

  defp valid_lisp_start?(content) do
    # Must start with (, {, or [ and NOT be JSON
    cond do
      String.starts_with?(content, "(") -> true
      String.starts_with?(content, "[") -> not json_like?(content)
      String.starts_with?(content, "{") -> not json_like?(content)
      true -> false
    end
  end

  # Check if content looks like JSON (has quotes around keys)
  defp json_like?(content) do
    String.contains?(content, "\"program\"") or
      String.contains?(content, "\"op\"") or
      Regex.match?(~r/^\s*\{\s*"/, content)
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
        {:ok, program} ->
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

          [{program, result}]

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

  # Truncated format for LLM tool results
  # Goal: Give LLM enough info to know what was truncated and how to refine
  @max_result_chars 300

  @truncation_hint """
  Run another query to get the data you need:
  - (select [:field1 :field2] data) - select only needed fields
  - (take N data) or (first data) - limit number of results
  - (filter (where :field = value) data) - filter to relevant items
  - (count data), (sum :field data) - aggregate instead of listing
  - (pluck :field data) - extract single field as list
  """

  defp format_result(result) when is_number(result) do
    if is_float(result) do
      :erlang.float_to_binary(result, decimals: 2)
    else
      Integer.to_string(result)
    end
  end

  defp format_result(result) when is_list(result) do
    count = length(result)
    full = inspect(result, limit: :infinity, pretty: false)

    if String.length(full) > @max_result_chars do
      # Show as many complete items as possible within limit
      truncated = truncate_list_items(result, @max_result_chars)
      shown = count_shown_items(truncated)
      "#{truncated} (showing #{shown} of #{count} items, TRUNCATED)\n#{@truncation_hint}"
    else
      full
    end
  end

  defp format_result(result) do
    full = inspect(result, limit: :infinity, pretty: false)

    if String.length(full) > @max_result_chars do
      truncated = String.slice(full, 0, @max_result_chars)
      "#{truncated}... (TRUNCATED)\n#{@truncation_hint}"
    else
      full
    end
  end

  # Truncate list to show complete items that fit within char limit
  defp truncate_list_items(list, max_chars) do
    list
    |> Enum.reduce_while({"[", 0}, fn item, {acc, count} ->
      item_str = inspect(item, limit: :infinity, pretty: false)
      separator = if count == 0, do: "", else: ", "
      new_acc = acc <> separator <> item_str

      if String.length(new_acc) + 5 > max_chars do
        # +5 for ", ...]"
        {:halt, {acc <> ", ...", count}}
      else
        {:cont, {new_acc, count + 1}}
      end
    end)
    |> elem(0)
    |> Kernel.<>("]")
  end

  # Count items shown (before "...")
  defp count_shown_items(str) do
    # Count commas before "..." plus 1, or count all items if no truncation
    case String.split(str, ", ...") do
      [before, _] -> (String.graphemes(before) |> Enum.count(&(&1 == ","))) + 1
      [_] -> String.graphemes(str) |> Enum.count(&(&1 == ",")) |> Kernel.+(1)
    end
  end

  defp truncate(str, max_len) do
    if String.length(str) > max_len do
      String.slice(str, 0, max_len) <> "..."
    else
      str
    end
  end

  # --- Error Formatting ---

  defp format_lisp_error({:parse_error, msg}), do: "ParseError: #{msg}"
  defp format_lisp_error({:analyze_error, msg}), do: "AnalyzeError: #{msg}"
  defp format_lisp_error({:eval_error, msg}), do: "EvalError: #{msg}"
  defp format_lisp_error({:timeout, ms}), do: "TimeoutError: exceeded #{ms}ms"
  defp format_lisp_error({:memory_exceeded, bytes}), do: "MemoryError: exceeded #{bytes} bytes"
  defp format_lisp_error(other), do: "Error: #{inspect(other, limit: 5)}"

  # --- Usage Tracking Helpers ---

  defp estimate_system_prompt_tokens(prompt) when is_binary(prompt) do
    # Rough approximation: ~4 characters per token on average
    div(String.length(prompt), 4)
  end

  defp empty_usage do
    %{
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      system_prompt_tokens: estimate_system_prompt_tokens(system_prompt(:schema)),
      total_runs: 0,
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
      system_prompt_tokens: acc.system_prompt_tokens,
      total_runs: acc.total_runs,
      total_cost: acc.total_cost + normalized.total_cost,
      requests: acc.requests + 1
    }
  end

  defp increment_run_count(usage) do
    %{usage | total_runs: usage.total_runs + 1}
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
