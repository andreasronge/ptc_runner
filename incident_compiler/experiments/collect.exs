Code.require_file("incident_compiler/tools/scorer.exs")
alias IncidentCompiler.Scorer

[tag, incident, arm, rep, status, secs, trace, report] = System.argv()

events =
  case File.read(trace) do
    {:ok, raw} -> raw |> String.split("\n", trim: true) |> Enum.map(&:json.decode/1)
    _ -> []
  end

annotations =
  for e <- events,
      e["type"] == "workflow-annotation",
      into: %{},
      do: {e["data"]["annotation_type"], e["data"]["data"]}

stopped = Enum.find(events, &(&1["type"] == "run-stopped")) || %{"data" => %{}}
usage = stopped["data"]["usage"] || %{}
llm_calls = get_in(usage, ["capability_calls", "workflow", "llm-request"]) || 0

score =
  case File.read(report) do
    {:ok, raw} ->
      r = :json.decode(raw)
      r = Map.get(r, "value", r)

      Scorer.score(
        r,
        Scorer.load_oracle("incident_compiler/fixtures/corpus", incident),
        Scorer.load_records("incident_compiler/fixtures/corpus", incident)
      )

    _ ->
      nil
  end

path = annotations["path"] || %{}

row = %{
  "tag" => tag,
  "incident" => incident,
  "arm" => arm,
  "rep" => String.to_integer(rep),
  "exit" => String.to_integer(status),
  "published" => String.to_integer(status) == 0,
  "wall_s" => String.to_integer(secs),
  "llm_calls" => llm_calls,
  "failure_kind" => stopped["data"]["failure_kind"],
  "triage_fast" => path["triage_fast"],
  "used_fast" => path["used_fast"],
  "deopt" => path["deopt"],
  "attempts" => annotations["attempts"],
  "verified" => annotations["citations-verified"],
  "required_fact_recall" => score && score.required_fact_recall.ratio,
  "facts_missed" => score && score.required_fact_recall.missed,
  "open_question_recall" => score && score.open_question_recall.ratio,
  "contradiction_recall" => score && score.contradiction_recall.ratio,
  "citations_total" => score && score.citations.total,
  "grounded" => score && score.citations.grounded?,
  "claims" => score && score.citation_completeness.claims
}

IO.puts(:json.encode(row))
