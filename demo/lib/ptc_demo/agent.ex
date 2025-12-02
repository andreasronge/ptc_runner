defmodule PtcDemo.Agent do
  @moduledoc """
  PTC Agent that uses LLM to generate programs and PtcRunner to execute them.

  This demonstrates the key advantage of Programmatic Tool Calling:
  - Large datasets stay in BEAM memory, never enter LLM context
  - LLM generates compact programs (~200 bytes) instead of processing raw data
  - Only small results return to LLM for final response
  """

  use GenServer

  import ReqLLM.Context

  alias PtcDemo.SampleData

  @model_env "REQ_LLM_MODEL"
  @timeout 60_000

  # --- State ---
  defstruct [:model, :context, :datasets, :last_program, :last_result, :mode, :usage]

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
  Auto-detect which model to use based on available API keys.
  """
  def detect_model do
    cond do
      System.get_env("ANTHROPIC_API_KEY") -> "anthropic:claude-haiku-4.5"
      System.get_env("OPENROUTER_API_KEY") -> "openrouter:anthropic/claude-haiku-4.5"
      System.get_env("OPENAI_API_KEY") -> "openai:gpt-4o-mini"
      true -> "anthropic:claude-haiku-4.5"
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    model = System.get_env(@model_env) || detect_model()
    # Mode: :text (default, token-efficient) or :structured (reliable but expensive)
    mode = Keyword.get(opts, :mode, :text)

    # Pre-load datasets into memory (simulating a real system)
    datasets = %{
      "products" => SampleData.products(),
      "orders" => SampleData.orders(),
      "employees" => SampleData.employees(),
      "expenses" => SampleData.expenses()
    }

    context = ReqLLM.Context.new([system(system_prompt())])

    IO.puts("   [Mode] #{mode}")

    {:ok,
     %__MODULE__{
       model: model,
       context: context,
       datasets: datasets,
       last_program: nil,
       last_result: nil,
       mode: mode,
       usage: empty_usage()
     }}
  end

  @impl true
  def handle_call({:ask, question}, _from, state) do
    # Add user question to context
    context = ReqLLM.Context.append(state.context, user(question))

    # Phase 1: Generate PTC program
    IO.puts("\n   [Phase 1] Generating PTC program (#{state.mode} mode)...")

    case generate_program(state.model, context, state.mode) do
      {:ok, program_json, phase1_usage} ->
        IO.puts("   [Program] #{truncate(program_json, 100)}")

        # Phase 2: Execute program with PtcRunner
        IO.puts("   [Phase 2] Executing in sandbox...")

        # Pass datasets as context - this is where the magic happens!
        # The LLM generates a program that references data via "load",
        # but the actual data (potentially huge) stays in BEAM memory,
        # never entering the LLM context.
        case PtcRunner.run(program_json, context: state.datasets, timeout: 5000) do
          {:ok, result, metrics} ->
            result_str = format_result(result)
            IO.puts("   [Result] #{truncate(result_str, 80)} (#{metrics.duration_ms}ms)")

            # Phase 3: Generate natural language response
            IO.puts("   [Phase 3] Generating response...")

            result_context =
              ReqLLM.Context.append(
                context,
                assistant("I executed a program and got: #{result_str}")
              )

            final_prompt = """
            The PTC program returned: #{result_str}

            Provide a helpful, concise answer to the user's question based on this result.
            If the result is a number, format it nicely. If it's a list, summarize key points.
            """

            result_context = ReqLLM.Context.append(result_context, user(final_prompt))

            {:ok, response} =
              ReqLLM.generate_text(state.model, result_context.messages,
                receive_timeout: @timeout
              )

            answer = ReqLLM.Response.text(response)
            phase3_usage = ReqLLM.Response.usage(response)

            # Accumulate usage from both phases
            new_usage =
              state.usage
              |> add_usage(phase1_usage)
              |> add_usage(phase3_usage)

            # Update context with the exchange
            new_context =
              state.context
              |> ReqLLM.Context.append(user(question))
              |> ReqLLM.Context.append(assistant(answer))

            {:reply, {:ok, answer},
             %{
               state
               | context: new_context,
                 last_program: program_json,
                 last_result: result,
                 usage: new_usage
             }}

          {:error, reason} ->
            error_msg = "Program execution failed: #{inspect(reason)}"
            {:reply, {:error, error_msg}, state}
        end

      {:error, reason} ->
        {:reply, {:error, "Failed to generate program: #{reason}"}, state}
    end
  end

  @impl true
  def handle_call(:reset, _from, state) do
    new_context = ReqLLM.Context.new([system(system_prompt())])

    {:reply, :ok,
     %{state | context: new_context, last_program: nil, last_result: nil, usage: empty_usage()}}
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
  def handle_call(:model, _from, state) do
    {:reply, state.model, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state.usage, state}
  end

  # --- Private Functions ---

  defp system_prompt do
    # Get schema from data module (simulates MCP tool schema discovery)
    data_schema = SampleData.schema_prompt()
    # Get operations prompt from library (~300 tokens vs ~10k for full schema)
    operations = PtcRunner.Schema.to_prompt()

    """
    You are a data analyst. Generate PTC programs to answer questions about data.

    IMPORTANT: Respond with ONLY valid JSON. No explanation, no markdown.

    Available datasets (with field types and enum values):

    #{data_schema}

    #{operations}
    """
  end

  # Structured mode - uses generate_object for guaranteed valid JSON with usage tracking
  defp generate_program(model, context, :structured) do
    llm_schema = PtcRunner.Schema.to_llm_schema()

    # Get the user's question from context
    user_question =
      context.messages
      |> Enum.filter(fn msg -> msg.role == :user end)
      |> List.last()
      |> case do
        nil -> ""
        msg -> msg |> Map.get(:content, "") |> extract_text_content()
      end

    # Build prompt with system context included (like E2E test pattern)
    prompt = """
    #{system_prompt()}

    User question: #{user_question}
    """

    case ReqLLM.generate_object(model, prompt, llm_schema, receive_timeout: @timeout) do
      {:ok, response} ->
        result = ReqLLM.Response.object(response)
        usage = ReqLLM.Response.usage(response)

        # Wrap in program envelope if needed
        json =
          case result do
            %{"program" => _} -> Jason.encode!(result)
            %{} -> Jason.encode!(%{"program" => result})
          end

        {:ok, json, usage}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  # Text mode - uses generate_text with retry logic and usage tracking
  defp generate_program(model, context, :text) do
    generate_program_text(model, context, 2, nil)
  end

  defp generate_program_text(_model, _context, 0, _accumulated_usage) do
    {:error, "Failed to generate valid program after retries"}
  end

  defp generate_program_text(model, context, retries, accumulated_usage) do
    case ReqLLM.generate_text(model, context.messages, receive_timeout: @timeout) do
      {:ok, response} ->
        text = ReqLLM.Response.text(response)
        usage = ReqLLM.Response.usage(response)
        total_usage = add_usage(accumulated_usage, usage)
        json = clean_json(text)

        # Validate it's actually a valid program before returning
        case validate_program(json) do
          :ok ->
            {:ok, json, total_usage}

          {:error, reason} ->
            IO.puts("   [Retry] Invalid response: #{reason}, retrying...")
            # Add error context to help LLM correct itself
            error_context =
              ReqLLM.Context.append(context, assistant(text))

            error_context =
              ReqLLM.Context.append(
                error_context,
                user(
                  "That was invalid: #{reason}. Return ONLY valid JSON: {\"program\": {\"op\": ...}}"
                )
              )

            generate_program_text(model, error_context, retries - 1, total_usage)
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp validate_program(json) do
    case Jason.decode(json) do
      {:ok, %{"program" => %{"op" => _}}} ->
        :ok

      {:ok, %{"program" => _}} ->
        {:error, "program must have 'op' field"}

      {:ok, _} ->
        {:error, "missing 'program' key"}

      {:error, _} ->
        {:error, "invalid JSON"}
    end
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

  defp clean_json(text) do
    text
    |> String.trim()
    |> String.replace(~r/^```json\s*/i, "")
    |> String.replace(~r/^```\s*/i, "")
    |> String.replace(~r/\s*```$/i, "")
    |> String.trim()
  end

  defp format_result(result) when is_list(result) do
    count = length(result)

    if count > 3 do
      sample = result |> Enum.take(2) |> inspect()
      "#{sample} ... (#{count} items total)"
    else
      inspect(result)
    end
  end

  defp format_result(result) when is_number(result) do
    if is_float(result) do
      :erlang.float_to_binary(result, decimals: 2)
    else
      Integer.to_string(result)
    end
  end

  defp format_result(result), do: inspect(result)

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
