defmodule PtcDemo.CLI do
  @moduledoc """
  Interactive CLI for the PTC Demo.

  Demonstrates how PtcRunner enables LLMs to query large datasets efficiently
  by generating programs that execute in BEAM memory, keeping data out of
  LLM context.
  """

  def main(args) do
    # Load .env if present (check both demo dir and parent)
    cond do
      File.exists?(".env") -> Dotenvy.source!(".env")
      File.exists?("../.env") -> Dotenvy.source!("../.env")
      true -> :ok
    end

    ensure_api_key!()

    # Parse mode from args: --structured or text (default, token-efficient)
    mode = if "--structured" in args, do: :structured, else: :text

    # Start the agent
    {:ok, _pid} = PtcDemo.Agent.start_link(mode: mode)

    IO.puts(banner(PtcDemo.Agent.model(), mode))

    # Enter REPL loop
    loop()
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
    IO.puts("   [Context cleared]\n")
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
        IO.puts(pretty_json(program))
        IO.puts("")
    end

    loop()
  end

  defp handle_input("/examples") do
    IO.puts(examples_text())
    loop()
  end

  defp handle_input("/stats") do
    stats = PtcDemo.Agent.stats()
    IO.puts(format_stats(stats))
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

  defp banner(model, mode) do
    mode_desc =
      case mode do
        :text -> "text (token-efficient, ~600 tokens/call)"
        :structured -> "structured (reliable, ~11k tokens/call)"
      end

    """

    ╔══════════════════════════════════════════════════════════════════╗
    ║           PTC Runner Demo - Programmatic Tool Calling            ║
    ╠══════════════════════════════════════════════════════════════════╣
    ║  Ask questions about data. The LLM generates programs that       ║
    ║  execute in a sandbox - large data stays in BEAM memory,         ║
    ║  never entering LLM context. Only small results return.          ║
    ╚══════════════════════════════════════════════════════════════════╝

    Model: #{model}
    Mode:  #{mode_desc}

    Type /help for commands, /examples for sample queries.
    """
  end

  defp help_text do
    """

    Commands:
      /help      - Show this help
      /datasets  - List available datasets
      /program   - Show last generated PTC program
      /examples  - Show example queries
      /stats     - Show token usage and cost statistics
      /reset     - Clear conversation context and stats
      /quit      - Exit

    Just type your question to query the data!
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

    """
  end

  defp pretty_json(json_str) do
    case Jason.decode(json_str) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
      _ -> json_str
    end
  end

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
