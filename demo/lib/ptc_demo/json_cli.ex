defmodule PtcDemo.JsonCLI do
  @moduledoc """
  Interactive CLI for the PTC-JSON Demo.

  Demonstrates how PtcRunner.Json enables LLMs to query large datasets efficiently
  by generating JSON programs that execute in BEAM memory, keeping data out of
  LLM context.
  """

  alias PtcDemo.CLIBase

  def main(args) do
    # Load .env if present (check both demo dir and parent)
    CLIBase.load_dotenv()

    # Parse command line arguments
    opts = CLIBase.parse_common_args(args)

    # Handle --list-models early (before API key check)
    CLIBase.handle_list_models(opts)

    # Handle --show-prompt (needs agent but not API key)
    CLIBase.handle_show_prompt(opts, PtcDemo.Agent)

    CLIBase.ensure_api_key!()

    data_mode = if opts[:explore], do: :explore, else: :schema
    model = opts[:model]
    run_tests = opts[:test]
    test_index = opts[:test_index]
    verbose = opts[:verbose]
    report_path = opts[:report]
    runs = opts[:runs]

    # Start the agent
    {:ok, _pid} = PtcDemo.Agent.start_link(data_mode: data_mode)

    # Set model if specified
    if model do
      resolved_model = CLIBase.resolve_model(model)
      PtcDemo.Agent.set_model(resolved_model)
    end

    # Run tests if --test flag is present
    if run_tests do
      run_tests_and_exit(
        verbose: verbose,
        report: report_path,
        runs: runs,
        test_index: test_index
      )
    else
      IO.puts(banner(PtcDemo.Agent.model(), PtcDemo.Agent.data_mode()))

      # Enter REPL loop
      loop()
    end
  end

  defp run_tests_and_exit(opts) do
    # Filter out nil values so Keyword.get defaults work properly
    opts = Enum.reject(opts, fn {_k, v} -> is_nil(v) end)
    test_index = Keyword.get(opts, :test_index)

    if test_index do
      # Run a single test
      result = PtcDemo.JsonTestRunner.run_one(test_index, opts)

      if result && result.passed do
        System.halt(0)
      else
        System.halt(1)
      end
    else
      # Run all tests - always exit 0, test failures are expected
      # Crashes (unhandled exceptions) will exit non-zero automatically
      PtcDemo.JsonTestRunner.run_all(opts)
      System.halt(0)
    end
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
    PtcDemo.Agent.reset()
    IO.puts("   [Context cleared, data mode reset to schema]\n")
    loop()
  end

  defp handle_input("/mode") do
    mode = PtcDemo.Agent.data_mode()
    IO.puts("   [Data mode: #{mode}]\n")
    loop()
  end

  defp handle_input("/mode schema") do
    PtcDemo.Agent.set_data_mode(:schema)
    IO.puts("   [Switched to schema mode - LLM receives full schema]\n")
    loop()
  end

  defp handle_input("/mode explore") do
    PtcDemo.Agent.set_data_mode(:explore)
    IO.puts("   [Switched to explore mode - LLM must discover schema]\n")
    loop()
  end

  defp handle_input("/mode " <> _invalid) do
    IO.puts("   [Unknown mode. Use: /mode, /mode schema, or /mode explore]\n")
    loop()
  end

  defp handle_input("/model") do
    model = PtcDemo.Agent.model()
    presets = PtcDemo.Agent.preset_models()

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
    name = String.trim(name)

    case PtcDemo.ModelRegistry.resolve(name) do
      {:ok, model} ->
        PtcDemo.Agent.set_model(model)
        IO.puts("   [Switched to model: #{model}]\n")

      {:error, reason} ->
        IO.puts("   [Error] #{reason}\n")
    end

    loop()
  end

  defp handle_input("/datasets") do
    IO.puts("\nAvailable datasets:")

    for {name, desc} <- PtcDemo.Agent.list_datasets() do
      IO.puts("  - #{name}: #{desc}")
    end

    IO.puts("")
    loop()
  end

  defp handle_input("/program") do
    case PtcDemo.Agent.last_program() do
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
    case PtcDemo.Agent.programs() do
      [] ->
        IO.puts("   No programs generated yet.\n")

      programs ->
        IO.puts("\nAll programs generated this session:\n")

        programs
        |> Enum.with_index(1)
        |> Enum.each(fn {{program, result}, idx} ->
          IO.puts("--- Program #{idx} ---")
          IO.puts(program)
          IO.puts("\nResult: #{CLIBase.format_program_result(result)}\n")
        end)
    end

    loop()
  end

  defp handle_input("/result") do
    case PtcDemo.Agent.last_result() do
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
    messages = PtcDemo.Agent.context()

    if messages == [] do
      IO.puts("\n   No conversation yet (system prompt excluded, use /system to view).\n")
    else
      IO.puts("\nConversation context (#{length(messages)} messages):")

      for msg <- messages do
        role = msg.role |> to_string() |> String.upcase()
        content = CLIBase.format_message_content(msg.content)
        IO.puts("\n[#{role}]")
        IO.puts(CLIBase.truncate(content, 500))
      end

      IO.puts("")
    end

    loop()
  end

  defp handle_input("/system") do
    prompt = PtcDemo.Agent.system_prompt()
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
    stats = PtcDemo.Agent.stats()
    IO.puts(CLIBase.format_stats(stats))
    loop()
  end

  defp handle_input(question) do
    case PtcDemo.Agent.ask(question) do
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
    |        PTC-JSON Demo - Programmatic Tool Calling                |
    +-----------------------------------------------------------------+
    |  Ask questions about data. The LLM generates JSON programs      |
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
      /program      - Show last generated PTC-JSON program
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
      mix json --test              Run all automated tests
      mix json --test=14           Run a single test by index
      mix json --test --verbose    Run tests with detailed output
      mix json --test --runs=3     Run tests multiple times
      mix json --model=<name>      Start with specific model
      mix json --explore           Start in explore mode
      mix json --list-models       Show available models and exit
      mix json --show-prompt       Show system prompt and exit
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

    Expected JSON programs:
      {"op": "count", "value": {"op": "filter", "data": "products", ...}}
      {"op": "sum-by", "data": "orders", "field": "total", ...}
      {"op": "avg-by", "data": "employees", "field": "salary", ...}
      {"op": "count", "value": {"op": "distinct", ...}}

    """
  end
end
