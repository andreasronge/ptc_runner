# Chained SubAgent Spike Test

IO.puts("--- Starting Chained SubAgent Spike Test ---")

# Load environment variables
PtcDemo.CLIBase.load_dotenv()

# Start the LispAgent
# Use devstral (free) for the spike
model = "devstral"
IO.puts("Using model: #{model}")
{:ok, _pid} = PtcDemo.LispAgent.start_link(model: model)

question = """
Find the top customer by revenue using the "customer-finder".
Then, using their ID, get all their orders using the "order-fetcher".
What is the ID and amount of their biggest order?
"""

IO.puts("\nPrompting Agent: #{question}")

case PtcDemo.LispAgent.ask(question) do
  {:ok, answer} ->
    IO.puts("\nFinal Answer: #{answer}")

    IO.puts("\n--- Execution Stats ---")
    IO.inspect(PtcDemo.LispAgent.stats(), label: "Total Usage")

    IO.puts("\n--- Execution Trace ---")
    trace = PtcDemo.LispAgent.trace()

    Enum.each(trace, fn step ->
       IO.puts("\nSTEP:")
       IO.inspect(Map.delete(step, :result), label: "Metadata")
       if step[:result] do
         IO.puts("Result: #{inspect(step.result)}")
         if is_map(step.result) and step.result[:trace] do
           IO.puts("  >> Sub-trace has #{length(step.result.trace)} steps")
         end
       end
    end)

  {:error, reason} ->
    IO.puts("\nError: #{inspect(reason)}")
    IO.inspect(PtcDemo.LispAgent.trace(), label: "Trace on Error")
end

IO.puts("\n--- Chained Spike Test Finished ---")
