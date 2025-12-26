# Spike Test for SubAgent Delegation

IO.puts("--- Starting SubAgent Spike Test ---")

# Load environment variables
PtcDemo.CLIBase.load_dotenv()

# Setup dummy tools
email_tools = %{
  "list_emails" => fn _ ->
    [%{id: 1, subject: "Urgent: Project Update", body: "We need the report by EOD."},
     %{id: 2, subject: "Meeting tomorrow", body: "Don't forget the coffee."}]
  end
}

# 1. Test Ref Extraction
IO.puts("\n1. Testing Ref Extraction...")
result = [%{id: 1, name: "Alice"}, %{id: 2, name: "Bob"}]
refs_spec = %{first_id: [Access.at(0), :id], count: &length/1}
refs = PtcDemo.RefExtractor.extract(result, refs_spec)
IO.inspect(refs, label: "Extracted Refs")

# 2. Test SubAgent Delegation (Recursive)
IO.puts("\n2. Testing SubAgent Delegation...")
# Use devstral (free) for the spike
model = "devstral"
IO.puts("Using model: #{model}")

case PtcDemo.SubAgent.delegate("List all emails and find the one that is urgent.",
  tools: email_tools,
  refs: %{urgent_id: [Access.at(0), :id]},
  model: model
) do
  {:ok, result} ->
    IO.puts("SubAgent Summary: #{result.summary}")
    IO.inspect(result.refs, label: "SubAgent Refs")

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end

IO.puts("\n--- Spike Test Finished ---")
