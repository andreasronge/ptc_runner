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
#
# Verifier fetches do not count as reads. `resolve-citations` re-reads every
# cited record from the evidence source — that re-read is what makes the check a
# check — but a record the model cited from a *search summary*, which carries
# `content_digest`, would then be credited as a record the model had read. That
# is precisely backwards for a metric whose job is to separate retrieval from
# reasoning. The artifact records each dynamic evaluation's source text against
# its `evaluation_id`, so the verification evaluations can be excluded exactly
# rather than guessed at by position.
#
# It changes no number in the 2026-08-04 round — every cited record had already
# been fetched while gathering, so the verifier contributed nothing unique in
# any run — but it would silently inflate coverage the first time an arm cited
# from a summary.
inspection_records =
  case File.read(inspect_path) do
    {:ok, raw} -> raw |> String.split("\n", trim: true) |> Enum.map(&:json.decode/1)
    _unreadable -> nil
  end

verifier_evaluations =
  for record <- inspection_records || [],
      record["record_type"] == "evaluation-source",
      source = record["payload"]["source"],
      is_binary(source) and String.contains?(source, "resolve-citations"),
      into: MapSet.new(),
      do: record["correlation"]["evaluation_id"]

read_ids =
  inspection_records &&
    for record <- inspection_records,
        record["record_type"] == "capability-output",
        payload = record["payload"],
        payload["name"] == "evidence.get",
        payload["result"]["status"] == "ok",
        payload["result"]["value"]["found"] == true,
        not MapSet.member?(verifier_evaluations, payload["evaluation_id"]),
        into: MapSet.new(),
        do: payload["result"]["value"]["evidence_id"]

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

#
# Every record any requirement rests on, including the gaps: a required open
# question names the evidence that establishes the gap, and an arm that never
# retrieved it cannot raise the question. Omitting those let `oracle_coverage`
# read 1.0 on an incident where every record behind its required gaps was
# missed — `queue-backlog` would drop `chat-4460`, `metric-lag-window` and
# `ticket-8815`.
oracle_ids =
  [
    Enum.flat_map(oracle["required_facts"] || [], &(&1["evidence_ids"] || [])),
    Enum.flat_map(
      oracle["contradicted_hypotheses"] || [],
      &(&1["contradicting_evidence_ids"] || [])
    ),
    Enum.flat_map(oracle["injected_faults"] || [], &(&1["evidence_ids"] || [])),
    Enum.flat_map(oracle["required_open_questions"] || [], &(&1["evidence_ids"] || []))
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
  # `published` is the run-level fact: the workflow returned a contract-valid
  # terminal. That is true of an abstention too, so it is not the number to
  # quote as "published a report" — `report_published` is. Reporting only the
  # first counts a withheld report as a delivered one.
  "published" => String.to_integer(status) == 0,
  "report_published" => String.to_integer(status) == 0 and score != nil and not score.abstained,
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

# `:json.encode/1` renders the atom `nil` as the *string* `"nil"`, not as JSON
# null — only `true`, `false` and `null` are special-cased. Every absent metric
# was therefore landing in the results file as a string, so a consumer doing
# `is_number/1` or `is_boolean/1` saw a type error rather than a missing value,
# and the nil-not-zero distinction this collector goes to some trouble to
# preserve was destroyed at the last step. Rewrite `nil` to `:null` on the way
# out, all the way down: `coverage`, `authoring`, `attempts` and `verified` are
# nested maps that can carry it too.
normalize = fn
  nil, _recur -> :null
  %{} = map, recur -> Map.new(map, fn {k, v} -> {k, recur.(v, recur)} end)
  list, recur when is_list(list) -> Enum.map(list, &recur.(&1, recur))
  other, _recur -> other
end

IO.puts(:json.encode(normalize.(row, normalize)))
