defmodule PtcDemo.LispCLI do
  @moduledoc """
  Interactive CLI for the PTC-Lisp Demo.

  Demonstrates how PtcRunner.Lisp enables LLMs to query large datasets efficiently
  by generating Lisp programs that execute in BEAM memory, keeping data out of
  LLM context.
  """

  def main(args) do
    # Load .env if present (check both demo dir and parent)
    load_dotenv()

    ensure_api_key!()

    # Parse command line arguments
    {opts, _rest} = parse_args(args)

    data_mode = if opts[:explore], do: :explore, else: :schema
    model = opts[:model]
    run_tests = opts[:test]
    verbose = opts[:verbose]
    report_path = opts[:report]

    # Start the agent
    {:ok, _pid} = PtcDemo.LispAgent.start_link(data_mode: data_mode)

    # Set model if specified
    if model do
      resolved_model = resolve_model(model)
      PtcDemo.LispAgent.set_model(resolved_model)
    end

    # Run tests if --test flag is present
    if run_tests do
      run_tests_and_exit(verbose: verbose, report: report_path)
    else
      IO.puts(banner(PtcDemo.LispAgent.model(), PtcDemo.LispAgent.data_mode()))

      # Enter REPL loop
      loop()
    end
  end

  defp parse_args(args) do
    # Simple argument parser
    opts =
      Enum.reduce(args, %{}, fn arg, acc ->
        cond do
          arg == "--explore" ->
            Map.put(acc, :explore, true)

          arg == "--test" ->
            Map.put(acc, :test, true)

          arg == "--verbose" or arg == "-v" ->
            Map.put(acc, :verbose, true)

          String.starts_with?(arg, "--model=") ->
            model = String.replace_prefix(arg, "--model=", "")
            Map.put(acc, :model, model)

          String.starts_with?(arg, "--report=") ->
            report = String.replace_prefix(arg, "--report=", "")
            Map.put(acc, :report, report)

          String.starts_with?(arg, "--model") ->
            # Handle --model value as next arg would require more complex parsing
            # For now, require --model=value format
            IO.puts("Error: Use --model=<name> format (e.g., --model=haiku)")
            System.halt(1)

          String.starts_with?(arg, "--report") ->
            IO.puts("Error: Use --report=<path> format (e.g., --report=report.md)")
            System.halt(1)

          String.starts_with?(arg, "--") ->
            IO.puts("Unknown flag: #{arg}")
            IO.puts(usage())
            System.halt(1)

          true ->
            acc
        end
      end)

    {opts, []}
  end

  defp resolve_model(name) do
    presets = PtcDemo.LispAgent.preset_models()

    case Map.get(presets, name) do
      nil -> name
      preset -> preset
    end
  end

  defp run_tests_and_exit(opts) do
    result = PtcDemo.LispTestRunner.run_all(opts)

    if result.failed > 0 do
      System.halt(1)
    else
      System.halt(0)
    end
  end

  defp usage do
    """

    Usage: mix lisp [options]

    Options:
      --explore        Start in explore mode (LLM discovers schema)
      --model=<name>   Set model (haiku, gemini, deepseek, gpt, or full model ID)
      --test           Run automated tests and exit
      --verbose, -v    Verbose output (for --test mode)
      --report=<path>  Write test report to file (for --test mode)

    Examples:
      mix lisp
      mix lisp --explore
      mix lisp --model=haiku
      mix lisp --model=google:gemini-2.0-flash-exp
      mix lisp --test
      mix lisp --test --model=haiku --verbose
      mix lisp --test --model=gemini --report=report.md
    """
  end

  defp loop do
    case IO.gets("you> ") do
      nil ->
        IO.puts("\nGoodbye!")
        :ok

      line ->
        line = String.trim(line)
        handle_input(line)
    end
  end

  defp handle_input(""), do: loop()
  defp handle_input("/quit"), do: IO.puts("Goodbye!")
  defp handle_input("/exit"), do: IO.puts("Goodbye!")

  defp handle_input("/help") do
    IO.puts(help_text())
    loop()
  end

  defp handle_input("/reset") do
    PtcDemo.LispAgent.reset()
    IO.puts("   [Context cleared, data mode reset to schema]\n")
    loop()
  end

  defp handle_input("/mode") do
    mode = PtcDemo.LispAgent.data_mode()
    IO.puts("   [Data mode: #{mode}]\n")
    loop()
  end

  defp handle_input("/mode schema") do
    PtcDemo.LispAgent.set_data_mode(:schema)
    IO.puts("   [Switched to schema mode - LLM receives full schema]\n")
    loop()
  end

  defp handle_input("/mode explore") do
    PtcDemo.LispAgent.set_data_mode(:explore)
    IO.puts("   [Switched to explore mode - LLM must discover schema]\n")
    loop()
  end

  defp handle_input("/mode " <> _invalid) do
    IO.puts("   [Unknown mode. Use: /mode, /mode schema, or /mode explore]\n")
    loop()
  end

  defp handle_input("/model") do
    model = PtcDemo.LispAgent.model()
    presets = PtcDemo.LispAgent.preset_models()

    IO.puts("\nCurrent model: #{model}")
    IO.puts("\nAvailable presets:")

    for {name, full_model} <- Enum.sort(presets) do
      marker = if full_model == model, do: " *", else: ""
      IO.puts("  /model #{name}#{marker} - #{full_model}")
    end

    IO.puts("\nOr use any model: /model openrouter:provider/model-name\n")
    loop()
  end

  defp handle_input("/model " <> name) do
    presets = PtcDemo.LispAgent.preset_models()
    name = String.trim(name)

    model =
      case Map.get(presets, name) do
        nil -> name
        preset -> preset
      end

    PtcDemo.LispAgent.set_model(model)
    IO.puts("   [Switched to model: #{model}]\n")
    loop()
  end

  defp handle_input("/datasets") do
    IO.puts("\nAvailable datasets:")

    for {name, desc} <- PtcDemo.LispAgent.list_datasets() do
      IO.puts("  - #{name}: #{desc}")
    end

    IO.puts("")
    loop()
  end

  defp handle_input("/program") do
    case PtcDemo.LispAgent.last_program() do
      nil ->
        IO.puts("   No program generated yet.\n")

      program ->
        IO.puts("\nLast generated program:")
        IO.puts(program)
        IO.puts("")
    end

    loop()
  end

  defp handle_input("/programs") do
    case PtcDemo.LispAgent.programs() do
      [] ->
        IO.puts("   No programs generated yet.\n")

      programs ->
        IO.puts("\nAll programs generated this session:\n")

        programs
        |> Enum.with_index(1)
        |> Enum.each(fn {{program, result}, idx} ->
          IO.puts("--- Program #{idx} ---")
          IO.puts(program)
          IO.puts("\nResult: #{format_program_result(result)}\n")
        end)
    end

    loop()
  end

  defp handle_input("/result") do
    case PtcDemo.LispAgent.last_result() do
      nil ->
        IO.puts("   No result yet.\n")

      result ->
        IO.puts("\nLast execution result:")
        IO.puts(inspect(result, pretty: true, limit: 50))
        IO.puts("")
    end

    loop()
  end

  defp handle_input("/context") do
    messages = PtcDemo.LispAgent.context()

    if messages == [] do
      IO.puts("\n   No conversation yet (system prompt excluded, use /system to view).\n")
    else
      IO.puts("\nConversation context (#{length(messages)} messages):")

      for msg <- messages do
        role = msg.role |> to_string() |> String.upcase()
        content = format_message_content(msg.content)
        IO.puts("\n[#{role}]")
        IO.puts(truncate(content, 500))
      end

      IO.puts("")
    end

    loop()
  end

  defp handle_input("/system") do
    prompt = PtcDemo.LispAgent.system_prompt()
    IO.puts("\n[SYSTEM PROMPT]\n")
    IO.puts(prompt)
    IO.puts("")
    loop()
  end

  defp handle_input("/examples") do
    IO.puts(examples_text())
    loop()
  end

  defp handle_input("/stats") do
    stats = PtcDemo.LispAgent.stats()
    IO.puts(format_stats(stats))
    loop()
  end

  defp handle_input(question) do
    case PtcDemo.LispAgent.ask(question) do
      {:ok, answer} ->
        IO.puts("\nassistant> #{answer}\n")

      {:error, reason} ->
        IO.puts("\n   [Error] #{reason}\n")
    end

    loop()
  end

  defp banner(model, data_mode) do
    data_mode_desc =
      case data_mode do
        :schema -> "schema (LLM receives full schema)"
        :explore -> "explore (LLM discovers schema via introspection)"
      end

    """

    +-----------------------------------------------------------------+
    |        PTC-Lisp Demo - Programmatic Tool Calling                |
    +-----------------------------------------------------------------+
    |  Ask questions about data. The LLM generates Lisp programs      |
    |  that execute in a sandbox - large data stays in BEAM memory,   |
    |  never entering LLM context. Only small results return.         |
    +-----------------------------------------------------------------+

    Model: #{model}
    Data:  #{data_mode_desc}

    Type /help for commands, /examples for sample queries.
    """
  end

  defp help_text do
    """

    Commands:
      /help         - Show this help
      /datasets     - List available datasets
      /program      - Show last generated PTC-Lisp program
      /programs     - Show all programs generated this session
      /result       - Show last execution result (raw value)
      /system       - Show current system prompt
      /context      - Show conversation history (excludes system prompt)
      /examples     - Show example queries
      /stats        - Show token usage and cost statistics
      /mode         - Show current data mode
      /mode schema  - Switch to schema mode (LLM gets full schema)
      /mode explore - Switch to explore mode (LLM discovers schema)
      /model        - Show current model and available presets
      /model <name> - Switch model (haiku, gemini, deepseek, kimi, gpt)
      /reset        - Clear conversation context, stats, and reset to schema mode
      /quit         - Exit

    Just type your question to query the data!

    CLI Options (when starting):
      mix lisp --test              Run automated tests
      mix lisp --test --verbose    Run tests with detailed output
      mix lisp --model=<name>      Start with specific model
      mix lisp --explore           Start in explore mode
    """
  end

  defp examples_text do
    """

    Example queries to try:

    Products (500 records):
      "How many products are in the electronics category?"
      "What's the average price of active products?"
      "Find the most expensive product"
      "Count products with rating above 4"

    Orders (1000 records):
      "What's the total revenue from delivered orders?"
      "How many orders were cancelled?"
      "What's the average order value?"

    Employees (200 records):
      "What's the total salary for the engineering department?"
      "How many remote employees are there?"
      "What's the average bonus for senior level?"

    Expenses (800 records):
      "Sum all travel expenses"
      "How many expenses are pending approval?"
      "What's the average expense amount by category?"

    Cross-dataset queries (combining multiple datasets):
      "How many unique products have been ordered?"
      "What is the total expense amount for engineering employees?"
      "How many employees have submitted expenses?"
      "What's the average order value per product category?"

    Expected Lisp programs:
      (count (filter (where :category = "electronics") ctx/products))
      (->> ctx/orders (filter (where :status = "delivered")) (sum-by :total))
      (avg-by :salary (filter (where :department = "engineering") ctx/employees))
      (count (distinct (pluck :product_id ctx/orders)))

    """
  end

  defp format_program_result(nil), do: "(no result captured)"
  defp format_program_result({:error, msg}), do: "ERROR: #{msg}"
  defp format_program_result(result), do: truncate(result, 200)

  defp format_stats(stats) do
    cost_str = format_cost(stats.total_cost)

    """

    Session Statistics:
      Requests:      #{stats.requests}
      Input tokens:  #{format_number(stats.input_tokens)}
      Output tokens: #{format_number(stats.output_tokens)}
      Total tokens:  #{format_number(stats.total_tokens)}
      Total cost:    #{cost_str}
    """
  end

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(n), do: inspect(n)

  defp format_cost(cost) when is_float(cost) and cost > 0 do
    "$#{:erlang.float_to_binary(cost, decimals: 6)}"
  end

  defp format_cost(_), do: "$0.00 (not available for this provider)"

  defp format_message_content(content) when is_binary(content), do: content

  defp format_message_content(content) when is_list(content) do
    Enum.map_join(content, "\n", &format_message_content/1)
  end

  defp format_message_content(%{text: text}), do: text
  defp format_message_content(%{content: content}), do: format_message_content(content)
  defp format_message_content(other), do: inspect(other)

  defp truncate(str, max_len) do
    if String.length(str) > max_len do
      String.slice(str, 0, max_len) <> "..."
    else
      str
    end
  end

  defp load_dotenv do
    env_file =
      cond do
        File.exists?(".env") -> ".env"
        File.exists?("../.env") -> "../.env"
        true -> nil
      end

    if env_file do
      env_file
      |> Dotenvy.source!()
      |> Enum.each(fn {key, value} -> System.put_env(key, value) end)
    end
  end

  defp ensure_api_key! do
    has_key =
      System.get_env("OPENROUTER_API_KEY") ||
        System.get_env("ANTHROPIC_API_KEY") ||
        System.get_env("OPENAI_API_KEY")

    unless has_key do
      IO.puts("""

      ERROR: No API key found!

      Set one of these environment variables:
        - OPENROUTER_API_KEY (recommended, supports many models)
        - ANTHROPIC_API_KEY
        - OPENAI_API_KEY

      You can create a .env file in the demo directory:
        OPENROUTER_API_KEY=sk-or-...

      Or export directly:
        export OPENROUTER_API_KEY=sk-or-...

      """)

      System.halt(1)
    end
  end
end
