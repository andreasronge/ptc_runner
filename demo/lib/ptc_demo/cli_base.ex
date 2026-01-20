defmodule PtcDemo.CLIBase do
  @moduledoc """
  Shared CLI utilities for JSON and Lisp entry points.

  Provides common functionality for argument parsing, environment setup, and output formatting.
  """

  @doc """
  Load environment variables from .env file if present.

  Checks for .env in the demo directory first, then the parent directory.
  """
  def load_dotenv do
    env_file =
      cond do
        File.exists?(".env") -> ".env"
        File.exists?("../.env") -> "../.env"
        true -> nil
      end

    if env_file do
      env_file
      |> Dotenvy.source!()
      |> Enum.each(fn {key, value} ->
        # Only set if not already set (command line env vars take precedence)
        unless System.get_env(key) do
          System.put_env(key, value)
        end
      end)
    end
  end

  @doc """
  Ensure that an API key environment variable is set (unless using local models).

  Checks for OPENROUTER_API_KEY, ANTHROPIC_API_KEY, or OPENAI_API_KEY.
  Halts the program with exit code 1 if none are found.

  If a model is specified that uses a local provider (e.g., ollama:*),
  the check is skipped.
  """
  def ensure_api_key!(model \\ nil) do
    # Skip check for local providers
    if local_provider?(model) do
      :ok
    else
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

        Or use a local model (no API key required):
          mix lisp --model=ollama:deepseek-coder:6.7b

        """)

        System.halt(1)
      end
    end
  end

  defp local_provider?(nil), do: false

  defp local_provider?(model) when is_binary(model) do
    String.starts_with?(model, "ollama:") or
      String.starts_with?(model, "openai-compat:")
  end

  defp local_provider?(_), do: false

  @doc """
  Parse common CLI arguments.

  Supports:
    - --explore: use explore data mode
    - --test: run all tests
    - --test=<n>: run a single test by index (e.g., --test=14)
    - --verbose or -v: verbose output
    - --model=<name>: specify model (e.g., --model=haiku)
    - --prompt=<name>: specify prompt profile (e.g., --prompt=minimal)
    - --report=<path>: generate report file (e.g., --report=report.md)
    - --runs=<n>: number of test runs (e.g., --runs=3)
    - --list-models: list available models and exit
    - --list-prompts: list available prompt profiles and exit
    - --show-prompt: show system prompt and exit
    - --validate-clojure: validate generated programs against Babashka
    - --no-validate-clojure: skip Clojure validation
    - --compression: enable message history compression
    - --no-compression: disable message history compression (default)

  Returns a map with keys: :explore, :test, :test_index, :verbose, :model, :prompt, :report, :runs, :list_models, :list_prompts, :show_prompt, :validate_clojure, :compression
  """
  def parse_common_args(args) do
    Enum.reduce(args, %{}, fn arg, acc ->
      cond do
        arg == "--explore" ->
          Map.put(acc, :explore, true)

        arg == "--test" ->
          Map.put(acc, :test, true)

        String.starts_with?(arg, "--test=") ->
          index_str = String.replace_prefix(arg, "--test=", "")

          case Integer.parse(index_str) do
            {n, ""} when n > 0 ->
              acc |> Map.put(:test, true) |> Map.put(:test_index, n)

            _ ->
              IO.puts("Error: --test=N requires a positive integer (e.g., --test=14)")
              System.halt(1)
          end

        arg == "--help" or arg == "-h" ->
          Map.put(acc, :help, true)

        arg == "--verbose" or arg == "-v" ->
          Map.put(acc, :verbose, true)

        arg == "--debug" or arg == "-d" ->
          Map.put(acc, :debug, true)

        arg == "--list-models" ->
          Map.put(acc, :list_models, true)

        arg == "--list-prompts" ->
          Map.put(acc, :list_prompts, true)

        arg == "--show-prompt" ->
          Map.put(acc, :show_prompt, true)

        String.starts_with?(arg, "--prompt=") ->
          prompt_value = String.replace_prefix(arg, "--prompt=", "")

          # Support comma-separated prompts for comparison mode
          prompt_names = String.split(prompt_value, ",")

          prompts =
            Enum.map(prompt_names, fn name ->
              case PtcDemo.Prompts.validate_profile(String.trim(name)) do
                {:ok, atom} ->
                  atom

                {:error, message} ->
                  IO.puts("Error: #{message}")
                  System.halt(1)
              end
            end)

          # If single prompt, store as atom; if multiple, store as list for comparison mode
          if length(prompts) == 1 do
            Map.put(acc, :prompt, hd(prompts))
          else
            Map.put(acc, :prompts, prompts)
          end

        arg == "--validate-clojure" ->
          Map.put(acc, :validate_clojure, true)

        arg == "--no-validate-clojure" ->
          Map.put(acc, :validate_clojure, false)

        String.starts_with?(arg, "--model=") ->
          model = String.replace_prefix(arg, "--model=", "")
          Map.put(acc, :model, model)

        String.starts_with?(arg, "--report=") ->
          report = String.replace_prefix(arg, "--report=", "")
          Map.put(acc, :report, report)

        arg == "--report" ->
          # Flag without value - will generate default filename later
          Map.put(acc, :report, :auto)

        String.starts_with?(arg, "--runs=") ->
          runs_str = String.replace_prefix(arg, "--runs=", "")

          case Integer.parse(runs_str) do
            {n, ""} when n > 0 ->
              Map.put(acc, :runs, n)

            _ ->
              IO.puts("Error: --runs must be a positive integer (e.g., --runs=3)")
              System.halt(1)
          end

        arg == "--compression" ->
          Map.put(acc, :compression, true)

        arg == "--no-compression" ->
          Map.put(acc, :compression, false)

        String.starts_with?(arg, "--filter=") ->
          filter_str = String.replace_prefix(arg, "--filter=", "")

          case filter_str do
            "multi_turn" ->
              Map.put(acc, :filter, :multi_turn)

            "single_turn" ->
              Map.put(acc, :filter, :single_turn)

            "all" ->
              Map.put(acc, :filter, :all)

            _ ->
              IO.puts("Error: --filter must be one of: multi_turn, single_turn, all")
              System.halt(1)
          end

        String.starts_with?(arg, "--model") ->
          IO.puts("Error: Use --model=<name> format (e.g., --model=haiku)")
          System.halt(1)

        String.starts_with?(arg, "--") ->
          IO.puts("Unknown flag: #{arg}")
          System.halt(1)

        true ->
          acc
      end
    end)
  end

  @doc """
  Handle --list-models flag. Prints model list and exits if flag is set.
  """
  def handle_list_models(opts) do
    if opts[:list_models] do
      IO.puts(LLMClient.format_model_list())
      System.halt(0)
    end
  end

  @doc """
  Handle --list-prompts flag. Prints prompt profiles and exits if flag is set.
  """
  def handle_list_prompts(opts) do
    if opts[:list_prompts] do
      IO.puts("\nAvailable prompt profiles:\n")

      for {name, description} <- PtcDemo.Prompts.list() do
        IO.puts("  #{name}")
        IO.puts("    #{description}\n")
      end

      IO.puts("Usage: --prompt=<name>  (e.g., --prompt=single_shot)\n")
      System.halt(0)
    end
  end

  @doc """
  Handle --help flag. Prints usage information and exits if flag is set.

  Takes opts map and the task name (e.g., "lisp", "json").
  """
  def handle_help(opts, task_name) do
    if opts[:help] do
      IO.puts(cli_help_text(task_name))
      System.halt(0)
    end
  end

  defp cli_help_text(task_name) do
    """

    Usage: mix #{task_name} [options]

    Options:
      -h, --help              Show this help message
      -v, --verbose           Enable verbose output
      -d, --debug             Enable debug mode (shows full prompts/responses)

    Test Options:
      --test                  Run all automated tests
      --test=N                Run a single test by index (e.g., --test=16)
      --filter=TYPE           Filter tests: multi_turn, single_turn, or all (default: all)
      --runs=N                Run tests N times (e.g., --runs=3)
      --report                Generate markdown report (auto-named)
      --report=FILE           Generate report with custom filename
      --validate-clojure      Validate programs against Babashka

    Model & Prompt:
      --model=NAME            Use specific model (e.g., --model=haiku, --model=gemini)
      --prompt=NAME           Use specific prompt profile (e.g., --prompt=single_shot)
      --prompt=A,B            Compare multiple prompts (e.g., --prompt=single_shot,multi_turn)
      --explore               Start in explore mode (LLM discovers schema)

    Info:
      --list-models           Show available models and exit
      --list-prompts          Show available prompt profiles and exit
      --show-prompt           Show the system prompt and exit

    Examples:
      mix #{task_name}                           Start interactive REPL
      mix #{task_name} --test                    Run all tests
      mix #{task_name} --test=16 --verbose       Run test 16 with verbose output
      mix #{task_name} --test --runs=5 --report  Run tests 5 times, generate report
      mix #{task_name} --model=haiku             Start REPL with Haiku model
    """
  end

  @doc """
  Handle --show-prompt flag. Starts the agent, prints the system prompt, and exits.

  Takes opts map and the agent module (PtcDemo.Agent or PtcDemo.LispAgent).
  The data_mode is determined from opts[:explore].
  The prompt profile is determined from opts[:prompt] or opts[:prompts] (first one).
  """
  def handle_show_prompt(opts, agent_module) do
    if opts[:show_prompt] do
      data_mode = if opts[:explore], do: :explore, else: :schema

      # Resolve prompt: use opts[:prompt], first of opts[:prompts], or default to :single_shot
      prompt_profile =
        cond do
          opts[:prompt] -> opts[:prompt]
          opts[:prompts] -> hd(opts[:prompts])
          true -> :single_shot
        end

      {:ok, _pid} = agent_module.start_link(data_mode: data_mode, prompt: prompt_profile)
      prompt = agent_module.system_prompt()
      IO.puts("\n[SYSTEM PROMPT]\n")
      IO.puts(prompt)
      System.halt(0)
    end
  end

  @doc """
  Resolve a model name using ModelRegistry.

  Returns the resolved model ID or exits with an error message.
  """
  def resolve_model(name) do
    case LLMClient.resolve(name) do
      {:ok, model_id} ->
        model_id

      {:error, reason} ->
        IO.puts("\nError: #{reason}")
        System.halt(1)
    end
  end

  @doc """
  Resolve a model name using a presets map (legacy, for backwards compatibility).

  If the name is found in presets, returns the preset value.
  Otherwise returns the name as-is.

  ## Examples

      iex> presets = %{"haiku" => "anthropic/claude-haiku"}
      iex> resolve_model("haiku", presets)
      "anthropic/claude-haiku"

      iex> resolve_model("custom-model", presets)
      "custom-model"
  """
  def resolve_model(name, presets) do
    case Map.get(presets, name) do
      nil -> name
      preset -> preset
    end
  end

  @doc """
  Format session statistics for terminal display.

  Takes a stats map with keys: :total_cost, :requests, :input_tokens, :output_tokens, :total_tokens
  Returns a formatted string suitable for printing.
  """
  def format_stats(stats) do
    cost_str = format_cost(stats.total_cost)

    system_prompt_line =
      if stats.system_prompt_tokens > 0 do
        "\n      System prompt (est.): #{format_number(stats.system_prompt_tokens)}"
      else
        ""
      end

    """

    Session Statistics:
      Requests:      #{stats.requests}
      Input tokens:  #{format_number(stats.input_tokens)}
      Output tokens: #{format_number(stats.output_tokens)}
      Total tokens:  #{format_number(stats.total_tokens)}#{system_prompt_line}
      Total cost:    #{cost_str}
    """
  end

  @doc """
  Format an integer with thousand separators.

  ## Examples

      iex> format_number(1000)
      "1,000"

      iex> format_number(1234567)
      "1,234,567"
  """
  def format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def format_number(n), do: inspect(n)

  @doc """
  Format a cost value as a dollar amount with 6 decimal places.

  ## Examples

      iex> format_cost(1.5)
      "$1.500000"

      iex> format_cost(0)
      "$0.00 (not available for this provider)"
  """
  def format_cost(cost) when is_float(cost) and cost > 0 do
    "$#{:erlang.float_to_binary(cost, decimals: 6)}"
  end

  def format_cost(_), do: "$0.00 (not available for this provider)"

  @doc """
  Format a program result for display.

  Handles nil results, errors, and regular values.
  Truncates long results to 200 characters.
  """
  def format_program_result(nil), do: "(no result captured)"
  def format_program_result({:error, msg}), do: "ERROR: #{msg}"
  def format_program_result(result), do: truncate(inspect(result, limit: 20), 200)

  @doc """
  Format message content which can be various types.

  Handles binary strings, lists, and structured content with text/content fields.
  """
  def format_message_content(content) when is_binary(content), do: content

  def format_message_content(content) when is_list(content) do
    Enum.map_join(content, "\n", &format_message_content/1)
  end

  def format_message_content(%{text: text}), do: text
  def format_message_content(%{content: content}), do: format_message_content(content)
  def format_message_content(other), do: inspect(other)

  @doc """
  Truncate a string to a maximum length.

  If the string exceeds max_len characters, it is truncated and "..." is appended.

  ## Examples

      iex> truncate("hello world", 5)
      "hello..."

      iex> truncate("hi", 5)
      "hi"
  """
  def truncate(str, max_len) do
    if String.length(str) > max_len do
      String.slice(str, 0, max_len) <> "..."
    else
      str
    end
  end

  @doc """
  Generate a default report filename based on DSL, model, and timestamp.

  Format: `{dsl}_{model_short}_{YYYYMMDD-HHMM}.md`

  ## Examples

      iex> generate_report_filename("lisp", "openrouter:anthropic/claude-3-5-haiku-latest")
      "lisp_claude-3-5-haiku-latest_20251212-1430.md"

      iex> generate_report_filename("json", "deepseek")
      "json_deepseek_20251212-1430.md"
  """
  def generate_report_filename(dsl, model) do
    model_short = extract_model_short_name(model)
    timestamp = format_timestamp_for_filename()
    "#{dsl}_#{model_short}_#{timestamp}.md"
  end

  defp extract_model_short_name(model) do
    model
    |> String.split("/")
    |> List.last()
    |> String.split(":")
    |> List.last()
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
  end

  defp format_timestamp_for_filename do
    now = DateTime.utc_now()
    Calendar.strftime(now, "%Y%m%d-%H%M")
  end
end
