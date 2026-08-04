Code.require_file("incident_compiler/tools/scorer.exs")
alias IncidentCompiler.Scorer

[tag, incident, arm, rep, status, secs, trace, report, inspect_path] = System.argv()

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
coverage = annotations["coverage"] || %{}

# Retrieval coverage travels beside required-fact recall rather than inside it.
# A 0.00 on an arm that retrieved every record means the model had the evidence
# and missed it; the same 0.00 on an arm that retrieved a fifth of it means the
# evidence never arrived, and the two were indistinguishable while the row
# carried only the ratio. `abstained` is the third case: a withheld report
# carries no observed facts at all, so its recall is 0.00 by construction and
# says nothing about either.
#
# Two coverages, because they answer different questions and no single number
# answers both. `prompt_coverage` is what the arm put in front of the model and
# only the single-pass arms can state it. `read_coverage` is derived from the
# private inspection record — every evidence id the run successfully fetched a
# body for — so it is measured the same way for all three arms, including the
# loop, which self-reports nothing. They differ where an arm fetched records it
# then did not use.
corpus_size = map_size(Scorer.load_records("incident_compiler/fixtures/corpus", incident))

prompt_coverage =
  case {coverage["gathered"], coverage["available"]} do
    {gathered, available} when is_integer(gathered) and is_integer(available) and available > 0 ->
      gathered / available

    _not_reported ->
      nil
  end

# `nil`, not zero, when there is no artifact to read. A run whose inspection
# capture failed to persist read an unknown number of records, and reporting
# that as 0.00 is the same conflation this metric exists to prevent — it would
# read as "retrieved nothing" when the trace may show hundreds of fetches.
read_ids =
  case File.read(inspect_path) do
    {:ok, raw} ->
      raw
      |> String.split("\n", trim: true)
      |> Enum.map(&:json.decode/1)
      |> Enum.filter(&(&1["record_type"] == "capability-output"))
      |> Enum.map(& &1["payload"])
      |> Enum.filter(&(&1["name"] == "evidence.get" and &1["result"]["status"] == "ok"))
      |> Enum.filter(&(&1["result"]["value"]["found"] == true))
      |> MapSet.new(& &1["result"]["value"]["evidence_id"])

    _unreadable ->
      nil
  end

# `read_coverage` counts records; it does not ask which. That is not pedantry:
# one loop run reached 320 of 332 — 96% — holding **none** of the eleven records
# the oracle names, because it could not page past the search cap and instead
# inferred the identifier scheme from its first page and enumerated
# `prefix-1001`.. per source. Every guess that existed was filler; every record
# that mattered had an identifier off the pattern. It then published universal
# negatives ("no lock waits were recorded") whose citations all resolved.
#
# So coverage against the whole corpus can be satisfied by guessing, and the
# citation check cannot tell the difference. Coverage against the records the
# oracle actually requires cannot: those identifiers are not derivable from the
# data, only from having retrieved them. This is the number to read first.
oracle = Scorer.load_oracle("incident_compiler/fixtures/corpus", incident)

oracle_ids =
  [
    Enum.flat_map(oracle["required_facts"] || [], &(&1["evidence_ids"] || [])),
    Enum.flat_map(
      oracle["contradicted_hypotheses"] || [],
      &(&1["contradicting_evidence_ids"] || [])
    ),
    Enum.flat_map(oracle["injected_faults"] || [], &(&1["evidence_ids"] || []))
  ]
  |> Enum.concat()
  |> MapSet.new()

oracle_read = read_ids && MapSet.size(MapSet.intersection(read_ids, oracle_ids))

row = %{
  "tag" => tag,
  "incident" => incident,
  "arm" => arm,
  "rep" => String.to_integer(rep),
  "exit" => String.to_integer(status),
  "published" => String.to_integer(status) == 0,
  "wall_s" => String.to_integer(secs),
  "llm_calls" => llm_calls,
  "coverage" => coverage,
  "prompt_coverage" => prompt_coverage,
  "records_read" => read_ids && MapSet.size(read_ids),
  "corpus_size" => corpus_size,
  "read_coverage" => (read_ids && corpus_size > 0 && MapSet.size(read_ids) / corpus_size) || nil,
  "oracle_records" => MapSet.size(oracle_ids),
  "oracle_records_read" => oracle_read,
  "oracle_coverage" =>
    (oracle_read && MapSet.size(oracle_ids) > 0 && oracle_read / MapSet.size(oracle_ids)) || nil,
  "abstained" => score && score.abstained,
  "abstention_defensible" => score && score.abstention_defensible,
  "failure_kind" => stopped["data"]["failure_kind"],
  "triage_fast" => path["triage_fast"],
  "used_fast" => path["used_fast"],
  "deopt" => path["deopt"],
  "attempts" => annotations["attempts"],
  "authoring" => annotations["authoring"],
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
