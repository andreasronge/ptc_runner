# examples/parallel_workers/gen_data.exs

# This script generates a large "System Log" for parallel workers testing.
# It creates a 2MB file (approx 20,000 lines) where rare errors
# are injected to test the agent's ability to find and summarize incidents.

defmodule ParallelWorkers.DataGen do
  def run(path \\ "examples/parallel_workers/test_corpus.log") do
    File.mkdir_p!(Path.dirname(path))

    n_lines = String.to_integer(System.get_env("N_LINES") || "5000")

    stream =
      Stream.iterate(1, &(&1 + 1))
      |> Stream.map(fn i ->
        timestamp = DateTime.utc_now() |> DateTime.add(i, :second) |> to_string()

        # Occasionally inject a "Critical Error"
        event =
          cond do
            rem(i, 500) == 0 ->
              "CRITICAL [Service=Auth] Database connection timeout at #{timestamp}"

            rem(i, 777) == 0 ->
              "ERROR [Service=Payment] Refund failed for user_#{i}: Insufficient funds"

            true ->
              "INFO [Service=Worker] Task #{i} completed successfully"
          end

        "[#{timestamp}] #{event}\n"
      end)
      |> Stream.take(n_lines)

    File.write!(path, Enum.to_list(stream))
    IO.puts("Generated #{path} (#{n_lines} lines)")
  end
end

ParallelWorkers.DataGen.run()
