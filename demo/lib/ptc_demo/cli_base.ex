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
      |> Enum.each(fn {key, value} -> System.put_env(key, value) end)
    end
  end

  @doc """
  Ensure that an API key environment variable is set.

  Checks for OPENROUTER_API_KEY, ANTHROPIC_API_KEY, or OPENAI_API_KEY.
  Halts the program with exit code 1 if none are found.
  """
  def ensure_api_key! do
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

  @doc """
  Parse common CLI arguments.

  Supports:
    - --explore: use explore data mode
    - --test: run tests
    - --verbose or -v: verbose output
    - --model=<name>: specify model (e.g., --model=haiku)
    - --report=<path>: generate report file (e.g., --report=report.md)
    - --runs=<n>: number of test runs (e.g., --runs=3)
    - --list-models: list available models and exit
    - --validate-clojure: validate generated programs against Babashka
    - --no-validate-clojure: skip Clojure validation

  Returns a map with keys: :explore, :test, :verbose, :model, :report, :runs, :list_models, :validate_clojure
  """
  def parse_common_args(args) do
    Enum.reduce(args, %{}, fn arg, acc ->
      cond do
        arg == "--explore" ->
          Map.put(acc, :explore, true)

        arg == "--test" ->
          Map.put(acc, :test, true)

        arg == "--verbose" or arg == "-v" ->
          Map.put(acc, :verbose, true)

        arg == "--list-models" ->
          Map.put(acc, :list_models, true)

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

        String.starts_with?(arg, "--runs=") ->
          runs_str = String.replace_prefix(arg, "--runs=", "")

          case Integer.parse(runs_str) do
            {n, ""} when n > 0 ->
              Map.put(acc, :runs, n)

            _ ->
              IO.puts("Error: --runs must be a positive integer (e.g., --runs=3)")
              System.halt(1)
          end

        String.starts_with?(arg, "--model") ->
          IO.puts("Error: Use --model=<name> format (e.g., --model=haiku)")
          System.halt(1)

        String.starts_with?(arg, "--report") ->
          IO.puts("Error: Use --report=<path> format (e.g., --report=report.md)")
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
      IO.puts(PtcDemo.ModelRegistry.format_model_list())
      System.halt(0)
    end
  end

  @doc """
  Resolve a model name using ModelRegistry.

  Returns the resolved model ID or exits with an error message.
  """
  def resolve_model(name) do
    case PtcDemo.ModelRegistry.resolve(name) do
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

    """

    Session Statistics:
      Requests:      #{stats.requests}
      Input tokens:  #{format_number(stats.input_tokens)}
      Output tokens: #{format_number(stats.output_tokens)}
      Total tokens:  #{format_number(stats.total_tokens)}
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
  def format_program_result(result), do: truncate(result, 200)

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
end
