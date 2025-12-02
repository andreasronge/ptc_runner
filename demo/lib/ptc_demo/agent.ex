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
  defstruct [:model, :context, :datasets, :last_program, :mode]

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

  def list_datasets do
    SampleData.available_datasets()
  end

  def model do
    GenServer.call(__MODULE__, :model)
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
    # Mode: :structured (default, reliable) or :text (for debugging)
    mode = Keyword.get(opts, :mode, :structured)

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
       mode: mode
     }}
  end

  @impl true
  def handle_call({:ask, question}, _from, state) do
    # Add user question to context
    context = ReqLLM.Context.append(state.context, user(question))

    # Phase 1: Generate PTC program
    IO.puts("\n   [Phase 1] Generating PTC program (#{state.mode} mode)...")

    case generate_program(state.model, context, state.mode) do
      {:ok, program_json} ->
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

            # Update context with the exchange
            new_context =
              state.context
              |> ReqLLM.Context.append(user(question))
              |> ReqLLM.Context.append(assistant(answer))

            {:reply, {:ok, answer}, %{state | context: new_context, last_program: program_json}}

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
    {:reply, :ok, %{state | context: new_context, last_program: nil}}
  end

  @impl true
  def handle_call(:last_program, _from, state) do
    {:reply, state.last_program, state}
  end

  @impl true
  def handle_call(:model, _from, state) do
    {:reply, state.model, state}
  end

  # --- Private Functions ---

  defp system_prompt do
    # Get schema from data module (simulates MCP tool schema discovery)
    data_schema = SampleData.schema_prompt()

    operations = """
    PTC Operations:
    - pipe: Chain operations. Example: {"op":"pipe","steps":[...]}
    - load: Load dataset by name. Example: {"op":"load","name":"orders"}
    - filter: Keep matching items. Example: {"op":"filter","where":{"op":"eq","field":"status","value":"active"}}
    - count: Count items. Example: {"op":"count"}
    - sum/avg/min/max: Aggregate a field. Example: {"op":"sum","field":"amount"}
    - first/last: Get first/last item
    - and/or: Combine conditions. Example: {"op":"and","conditions":[...]}

    Comparisons for filter: eq, neq, gt, gte, lt, lte
    """

    """
    You are a data analyst. Generate PTC programs to answer questions about data.

    IMPORTANT: Respond with ONLY valid JSON. No explanation, no markdown.

    Available datasets (with field types and enum values):

    #{data_schema}

    #{operations}

    Example - count orders over $1000 paid by credit_card:
    {"program":{"op":"pipe","steps":[{"op":"load","name":"orders"},{"op":"filter","where":{"op":"and","conditions":[{"op":"gt","field":"total","value":1000},{"op":"eq","field":"payment_method","value":"credit_card"}]}},{"op":"count"}]}}
    """
  end

  # Structured mode - uses generate_object! for guaranteed valid JSON
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

    try do
      result = ReqLLM.generate_object!(model, prompt, llm_schema, receive_timeout: @timeout)

      # Wrap in program envelope if needed
      json =
        case result do
          %{"program" => _} -> Jason.encode!(result)
          %{} -> Jason.encode!(%{"program" => result})
        end

      {:ok, json}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  # Text mode - uses generate_text! with retry logic
  defp generate_program(model, context, :text) do
    generate_program_text(model, context, 2)
  end

  defp generate_program_text(_model, _context, 0) do
    {:error, "Failed to generate valid program after retries"}
  end

  defp generate_program_text(model, context, retries) do
    case ReqLLM.generate_text(model, context.messages, receive_timeout: @timeout) do
      {:ok, response} ->
        text = ReqLLM.Response.text(response)
        json = clean_json(text)

        # Validate it's actually a valid program before returning
        case validate_program(json) do
          :ok ->
            {:ok, json}

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

            generate_program_text(model, error_context, retries - 1)
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
end
