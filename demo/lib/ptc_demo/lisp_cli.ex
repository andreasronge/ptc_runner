defmodule PtcDemo.LispCLI do
  @moduledoc """
  Interactive CLI for the PTC-Lisp Demo using SubAgent.

  Demonstrates how PtcRunner enables LLMs to query large datasets efficiently
  by generating Lisp programs that execute in BEAM memory, keeping data out of
  LLM context.
  """

  alias PtcDemo.CLIBase

  def main(args) do
    # Load .env if present (check both demo dir and parent)
    CLIBase.load_dotenv()

    # Parse command line arguments
    opts = CLIBase.parse_common_args(args)

    # Handle --help, --list-models and --list-prompts early (before API key check)
    CLIBase.handle_help(opts, "lisp")
    CLIBase.handle_list_models(opts)
    CLIBase.handle_list_prompts(opts)

    # Handle trace management (no API key or agent needed)
    CLIBase.handle_export_traces(opts)
    CLIBase.handle_clean_traces(opts)

    # Handle --show-prompt (needs agent but not API key)
    CLIBase.handle_show_prompt(opts, PtcDemo.LispAgent)

    data_mode = if opts[:explore], do: :explore, else: :schema
    prompt_profile = opts[:prompt] || :auto
    prompts_for_comparison = opts[:prompts]
    model = opts[:model]
    run_tests = opts[:test]
    test_index = opts[:test_index]
    verbose = opts[:verbose]
    report_path = opts[:report]
    runs = opts[:runs]
    validate_clojure = opts[:validate_clojure]
    compression = Map.get(opts, :compression, false)
    filter = Map.get(opts, :filter, :all)
    return_retries = Map.get(opts, :return_retries, 0)

    # Resolve model early so we can check if it's a local provider
    resolved_model = if model, do: CLIBase.resolve_model(model), else: nil

    # Check API key (skipped for local providers like Ollama)
    CLIBase.ensure_api_key!(resolved_model)

    # Start the agent (use first prompt for comparison mode, or specified prompt)
    # Note: :auto is resolved to :single_shot for agent startup; test runner overrides per-test
    initial_prompt =
      cond do
        prompts_for_comparison -> hd(prompts_for_comparison)
        prompt_profile == :auto -> :single_shot
        true -> prompt_profile
      end

    {:ok, _pid} =
      PtcDemo.LispAgent.start_link(
        data_mode: data_mode,
        prompt: initial_prompt,
        compression: compression,
        return_retries: return_retries
      )

    # Set model if specified
    if resolved_model do
      PtcDemo.LispAgent.set_model(resolved_model)
    end

    # Handle comparison mode (multiple prompts)
    if run_tests && prompts_for_comparison do
      run_comparison_and_exit(prompts_for_comparison,
        verbose: verbose,
        data_mode: data_mode,
        compression: compression
      )
    end

    # Run tests if --test flag is present
    if run_tests do
      run_tests_and_exit(
        verbose: verbose,
        debug: opts[:debug] || false,
        report: report_path,
        runs: runs,
        validate_clojure: validate_clojure,
        test_index: test_index,
        prompt: prompt_profile,
        compression: compression,
        filter: filter,
        return_retries: return_retries
      )
    else
      IO.puts(
        banner(
          PtcDemo.LispAgent.model(),
          PtcDemo.LispAgent.data_mode(),
          PtcDemo.LispAgent.prompt_profile(),
          PtcDemo.LispAgent.compression()
        )
      )

      # Enter REPL loop
      loop(debug: opts[:debug] || false, verbose: opts[:verbose] || false)
    end
  end

  defp run_comparison_and_exit(prompts, opts) do
    PtcDemo.LispTestRunner.run_comparison(prompts, opts)
    System.halt(0)
  end

  defp run_tests_and_exit(opts) do
    # Filter out nil values so Keyword.get defaults work properly
    opts = Enum.reject(opts, fn {_k, v} -> is_nil(v) end)
    test_index = Keyword.get(opts, :test_index)

    if test_index do
      # Run a single test
      result = PtcDemo.LispTestRunner.run_one(test_index, opts)

      if result && result.passed do
        System.halt(0)
      else
        System.halt(1)
      end
    else
      # Run all tests - always exit 0, test failures are expected
      # Crashes (unhandled exceptions) will exit non-zero automatically
      PtcDemo.LispTestRunner.run_all(opts)
      System.halt(0)
    end
  end

  defp loop(opts) do
    case IO.gets("you> ") do
      nil ->
        IO.puts("\nGoodbye!")
        :ok

      line ->
        line = String.trim(line)
        handle_input(line, opts)
    end
  end

  defp handle_input("", opts), do: loop(opts)
  defp handle_input("/quit", _opts), do: IO.puts("Goodbye!")
  defp handle_input("/exit", _opts), do: IO.puts("Goodbye!")

  defp handle_input("/help", opts) do
    IO.puts(help_text())
    loop(opts)
  end

  defp handle_input("/reset", opts) do
    PtcDemo.LispAgent.reset()
    IO.puts("   [Context cleared, data mode reset to schema]\n")
    loop(opts)
  end

  defp handle_input("/mode", opts) do
    mode = PtcDemo.LispAgent.data_mode()
    IO.puts("   [Data mode: #{mode}]\n")
    loop(opts)
  end

  defp handle_input("/mode schema", opts) do
    PtcDemo.LispAgent.set_data_mode(:schema)
    IO.puts("   [Switched to schema mode - LLM receives full schema]\n")
    loop(opts)
  end

  defp handle_input("/mode explore", opts) do
    PtcDemo.LispAgent.set_data_mode(:explore)
    IO.puts("   [Switched to explore mode - LLM must discover schema]\n")
    loop(opts)
  end

  defp handle_input("/mode " <> _invalid, opts) do
    IO.puts("   [Unknown mode. Use: /mode, /mode schema, or /mode explore]\n")
    loop(opts)
  end

  defp handle_input("/prompt", opts) do
    profile = PtcDemo.LispAgent.prompt_profile()
    profiles = PtcDemo.Prompts.list()

    IO.puts("\nCurrent prompt: #{profile}")
    IO.puts("\nAvailable profiles:")

    for {name, description} <- profiles do
      marker = if name == profile, do: " *", else: ""
      IO.puts("  /prompt #{name}#{marker}")
      IO.puts("    #{description}")
    end

    IO.puts("")
    loop(opts)
  end

  defp handle_input("/prompt " <> name, opts) do
    case PtcDemo.Prompts.validate_profile(String.trim(name)) do
      {:ok, profile_atom} ->
        PtcDemo.LispAgent.set_prompt_profile(profile_atom)
        IO.puts("   [Switched to prompt profile: #{profile_atom}]\n")

      {:error, message} ->
        IO.puts("   [#{message}]\n")
    end

    loop(opts)
  end

  defp handle_input("/model", opts) do
    model = PtcDemo.LispAgent.model()
    provider = LLMClient.provider_from_model(model)
    presets = LLMClient.presets(provider)

    IO.puts("\nCurrent model: #{model}")
    IO.puts("\nAvailable presets for #{provider || "default provider"}:")

    for {name, full_model} <- Enum.sort(presets) do
      marker = if full_model == model, do: " *", else: ""
      IO.puts("  /model #{name}#{marker} - #{full_model}")
    end

    IO.puts("\nOr use any model: /model provider:alias (e.g., bedrock:haiku)\n")
    loop(opts)
  end

  defp handle_input("/model " <> name, opts) do
    name = String.trim(name)

    # If no provider prefix, use the current model's provider
    model_spec =
      if String.contains?(name, ":") do
        name
      else
        current_model = PtcDemo.LispAgent.model()
        provider = LLMClient.provider_from_model(current_model)
        # Normalize amazon_bedrock -> bedrock for resolution
        provider = if provider == :amazon_bedrock, do: :bedrock, else: provider
        if provider, do: "#{provider}:#{name}", else: name
      end

    case LLMClient.resolve(model_spec) do
      {:ok, model} ->
        PtcDemo.LispAgent.set_model(model)
        IO.puts("   [Switched to model: #{model}]\n")

      {:error, reason} ->
        IO.puts("   [Error] #{reason}\n")
    end

    loop(opts)
  end

  defp handle_input("/compression", opts) do
    compression = PtcDemo.LispAgent.compression()
    status = if compression, do: "enabled", else: "disabled"
    IO.puts("   [Compression: #{status}]\n")
    loop(opts)
  end

  defp handle_input("/compression on", opts) do
    PtcDemo.LispAgent.set_compression(true)
    IO.puts("   [Compression enabled - message history will be coalesced]\n")
    loop(opts)
  end

  defp handle_input("/compression off", opts) do
    PtcDemo.LispAgent.set_compression(false)
    IO.puts("   [Compression disabled - full message history preserved]\n")
    loop(opts)
  end

  defp handle_input("/compression " <> _invalid, opts) do
    IO.puts("   [Unknown option. Use: /compression, /compression on, or /compression off]\n")
    loop(opts)
  end

  defp handle_input("/turns", opts) do
    turns = PtcDemo.LispAgent.max_turns()
    IO.puts("   [Max turns: #{turns}]\n")
    loop(opts)
  end

  defp handle_input("/turns " <> value, opts) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 ->
        PtcDemo.LispAgent.set_max_turns(n)
        IO.puts("   [Max turns set to #{n}]\n")

      _ ->
        IO.puts("   [Invalid value. Use: /turns <number> (e.g., /turns 10)]\n")
    end

    loop(opts)
  end

  defp handle_input("/debug", opts) do
    status = if opts[:debug], do: "enabled", else: "disabled"
    IO.puts("   [Debug mode: #{status}]\n")
    loop(opts)
  end

  defp handle_input("/debug on", opts) do
    IO.puts("   [Debug mode enabled - will show raw LLM responses]\n")
    loop(Keyword.put(opts, :debug, true))
  end

  defp handle_input("/debug off", opts) do
    IO.puts("   [Debug mode disabled]\n")
    loop(Keyword.put(opts, :debug, false))
  end

  defp handle_input("/debug " <> _invalid, opts) do
    IO.puts("   [Unknown option. Use: /debug, /debug on, or /debug off]\n")
    loop(opts)
  end

  defp handle_input("/datasets", opts) do
    IO.puts("\nAvailable datasets:")

    for {name, desc} <- PtcDemo.LispAgent.list_datasets() do
      IO.puts("  - #{name}: #{desc}")
    end

    IO.puts("")
    loop(opts)
  end

  defp handle_input("/program", opts) do
    case PtcDemo.LispAgent.last_program() do
      nil ->
        IO.puts("   No program generated yet.\n")

      program ->
        IO.puts("\nLast generated program:")
        IO.puts(program)
        IO.puts("")
    end

    loop(opts)
  end

  defp handle_input("/programs", opts) do
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
          IO.puts("\nResult: #{CLIBase.format_program_result(result)}\n")
        end)
    end

    loop(opts)
  end

  defp handle_input("/result", opts) do
    case PtcDemo.LispAgent.last_result() do
      nil ->
        IO.puts("   No result yet.\n")

      result ->
        IO.puts("\nLast execution result:")
        IO.puts(inspect(result, pretty: true, limit: 50))
        IO.puts("")
    end

    loop(opts)
  end

  defp handle_input("/context", opts) do
    programs = PtcDemo.LispAgent.programs()

    if programs == [] do
      IO.puts("\n   No conversation yet (system prompt excluded, use /system to view).\n")
    else
      IO.puts("\nConversation history (#{length(programs)} exchanges):\n")

      programs
      |> Enum.with_index(1)
      |> Enum.each(fn {{program, result}, idx} ->
        IO.puts("─── Exchange #{idx} ───")
        IO.puts("[PROGRAM]")
        IO.puts(CLIBase.truncate(program || "(no program)", 300))
        IO.puts("\n[RESULT]")
        IO.puts(CLIBase.truncate(CLIBase.format_program_result(result), 200))
        IO.puts("")
      end)
    end

    loop(opts)
  end

  defp handle_input("/system", opts) do
    prompt = PtcDemo.LispAgent.system_prompt()
    IO.puts("\n[SYSTEM PROMPT]\n")
    IO.puts(prompt)
    IO.puts("")
    loop(opts)
  end

  defp handle_input("/examples", opts) do
    IO.puts(examples_text())
    loop(opts)
  end

  defp handle_input("/stats", opts) do
    stats = PtcDemo.LispAgent.stats()
    IO.puts(CLIBase.format_stats(stats))
    loop(opts)
  end

  defp handle_input(question, opts) do
    case PtcDemo.LispAgent.ask(question, debug: opts[:debug], verbose: opts[:verbose]) do
      {:ok, answer} ->
        IO.puts("\nassistant> #{answer}\n")

      {:error, reason} ->
        IO.puts("\n   [Error] #{reason}\n")
    end

    loop(opts)
  end

  defp banner(model, data_mode, prompt_profile, compression) do
    data_mode_desc =
      case data_mode do
        :schema -> "schema (LLM receives full schema)"
        :explore -> "explore (LLM discovers schema via introspection)"
      end

    prompt_desc = "#{prompt_profile}"
    compression_desc = if compression, do: "enabled", else: "disabled"

    """

    +-----------------------------------------------------------------+
    |    PTC-Lisp Demo - Programmatic Tool Calling via SubAgent       |
    +-----------------------------------------------------------------+
    |  Ask questions about data. The LLM generates Lisp programs      |
    |  that execute in a sandbox - large data stays in BEAM memory,   |
    |  never entering LLM context. Only small results return.         |
    +-----------------------------------------------------------------+

    Model:       #{model}
    Data:        #{data_mode_desc}
    Prompt:      #{prompt_desc}
    Compression: #{compression_desc}

    Type /help for commands, /examples for sample queries.
    """
  end

  defp help_text do
    """

    Commands:
      /help            - Show this help
      /datasets        - List available datasets
      /program         - Show last generated PTC-Lisp program
      /programs        - Show all programs generated this session
      /result          - Show last execution result (raw value)
      /system          - Show current system prompt
      /context         - Show conversation history (excludes system prompt)
      /examples        - Show example queries
      /stats           - Show token usage and cost statistics
      /mode            - Show current data mode
      /mode schema     - Switch to schema mode (LLM gets full schema)
      /mode explore    - Switch to explore mode (LLM discovers schema)
      /prompt          - Show current prompt profile and available profiles
      /prompt <name>   - Switch prompt profile (default, minimal, single_shot, multi_turn)
      /model           - Show current model and available presets
      /model <name>    - Switch model (haiku, gemini, deepseek, kimi, gpt)
      /compression     - Show current compression setting
      /compression on  - Enable message history compression
      /compression off - Disable message history compression
      /turns           - Show current max turns setting
      /turns <n>       - Set max turns (e.g., /turns 10)
      /debug           - Show current debug mode setting
      /debug on        - Enable debug mode (show raw LLM responses)
      /debug off       - Disable debug mode
      /reset           - Clear conversation context, stats, and reset to schema mode
      /quit            - Exit

    Just type your question to query the data!

    CLI Options (when starting):
      mix lisp --test              Run all automated tests
      mix lisp --test=14           Run a single test by index
      mix lisp --test --verbose    Run tests with detailed output
      mix lisp --test --runs=3     Run tests multiple times
      mix lisp --test --filter=multi_turn   Run only multi-turn tests
      mix lisp --test --filter=single_turn  Run only single-turn tests
      mix lisp --model=<name>      Start with specific model
      mix lisp --prompt=<name>     Start with prompt profile (minimal, single_shot, etc.)
      mix lisp --prompt=a,b        Compare multiple prompts (e.g., --prompt=minimal,default)
      mix lisp --explore           Start in explore mode
      mix lisp --list-models       Show available models and exit
      mix lisp --list-prompts      Show available prompt profiles and exit
      mix lisp --show-prompt       Show system prompt and exit
      mix lisp --compression       Start with compression enabled
      mix lisp --no-compression    Start with compression disabled (default)
      mix lisp --debug             Start with debug mode enabled (show raw LLM responses)
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

    Search tool (40 policy documents, use /prompt multi_turn first):
      "Search for documents about remote work"
      "Find policies related to expense reimbursement"
      "Which document covers both remote work and expenses?"

    Expected Lisp programs:
      (count (filter (where :category = "electronics") ctx/products))
      (->> ctx/orders (filter (where :status = "delivered")) (sum-by :total))
      (avg-by :salary (filter (where :department = "engineering") ctx/employees))
      (count (distinct (pluck :product_id ctx/orders)))
      (ctx/search {:query "remote work"})

    """
  end
end
