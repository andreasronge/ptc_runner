# Summarize retained measurements after a fail-closed stop; never generate new observations.
lab = Path.expand("../../../scripts/labs/prelude-search", __DIR__)

for name <- ~w(mutations inputs lab statistics phase1) do
  Code.require_file("support/#{name}.exs", lab)
end

alias PtcRunner.Labs.PreludeSearch.Phase1
alias PtcRunner.Labs.PreludeSearch.Statistics
root = __DIR__
read = fn path -> path |> File.read!() |> Jason.decode!() end
rows = read.(Path.join(root, "live/results.json"))
reservation = read.(Path.join(root, "live/reservation.json"))
completion = read.(Path.join(root, "completion.json"))
protocol = read.(Path.join(root, "live/protocol.json"))
fixture_root = Path.join(root, "live/fixtures")

index =
  fixture_root
  |> Path.join("*.jsonl")
  |> Path.wildcard()
  |> Enum.sort()
  |> Enum.map(fn path ->
    %{
      "file" => Path.basename(path),
      "sha256" => :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
    }
  end)

File.write!(Path.join(fixture_root, "index.json"), Jason.encode!(index, pretty: true))
failed = Path.join(root, "live/runs/intervals-0-E1-three-turn")
failed_envelope = read.(Path.join(failed, "envelope.json"))
failed_outcome = read.(Path.join(failed, "result.json"))
[%{"error" => %{"reason" => "llm_request_timeout"}}] = failed_outcome
1 = length(rows)

result = %{
  "schema_version" => 1,
  "experiment" => "prelude-search/002",
  "protocol" => protocol,
  "completion" => completion,
  "status" => "stopped",
  "stop_reason" => "unreplayable_kernel_llm_request_timeout",
  "planned_cases" => 240,
  "completed_cases" => length(rows),
  "stopped_cases" => 1,
  "unstarted_cases" => 240 - length(rows) - 1,
  "known_cost_microusd" => reservation["spent_microusd"],
  "unresolved_reservation_microusd" => reservation["reserved_microusd"],
  "spent_or_reserved_microusd" =>
    reservation["spent_microusd"] + reservation["reserved_microusd"],
  "prior_validation_spent_or_reserved_microusd" => 209_881,
  "rows" => Phase1.report(rows),
  "observations" => rows,
  "unscored_stopped_case" => %{
    "reservation" => reservation,
    "outcome" => failed_outcome,
    "usage" => failed_envelope["execution"]["usage"]
  },
  "hypotheses" => [
    %{
      "id" => "H1",
      "metric" => "untouched final-test success",
      "verdict" => "stopped",
      "decision_rule_version" => "descriptive-pilot-v1",
      "comparisons" => Statistics.compare(rows, "E1 three-turn", ["E2 K=2", "E2 K=4"])
    }
  ],
  "failure_modes" => %{
    "selection_check_failed" => Enum.count(rows, &(&1["winner"] == nil)),
    "llm_request_timeout" => 1
  },
  "available_fixture_count" => length(index),
  "replay_verification" => read.(Path.join(root, "replay-verification.json")),
  "analysis_findings" => read.(Path.join(root, "analysis-findings.json"))
}

output = Path.expand("../../../docs/research/reports/prelude-search/002.json", root)
File.write!(output, Jason.encode!(result, pretty: true) <> "\n")
IO.puts("Summarized #{length(rows)} completed case(s); preserved one unresolved reservation.")
