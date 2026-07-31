defmodule IncidentCompiler.Scorer do
  @moduledoc """
  Scores one incident report against its oracle.

  This is deliberately independent of the runtime. Three of the four systems
  the comparison will run have no fail-closed publication, so the scorer
  cannot assume a citation resolves — it resolves every one itself against the
  corpus and reports fabrication as a first-class metric.

  Every metric here is mechanical. Whether a cited record semantically
  supports the claim it is attached to is not decidable this way and is left
  to blind human adjudication; the oracle's `rubric` exists for that pass, and
  nothing in this module reads it.
  """

  @record_fields ~w(body evidence_id observed_at source title)

  @doc "Loads one incident's records, keyed by evidence id, with derived digests."
  def load_records(corpus_dir, incident_id) do
    corpus_dir
    |> Path.join("#{incident_id}/evidence/records.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.new(&{&1["evidence_id"], Map.put(&1, "content_digest", digest(&1))})
  end

  @doc """
  Derives the content identity of the whole corpus.

  Mirrors the evidence server's `evidence_snapshot`, deliberately as a second
  implementation: two independent derivations agreeing is a stronger
  determinism claim than one derivation repeating itself.
  """
  def snapshot_hash(corpus_dir) do
    corpus_dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.map(fn incident ->
      digests =
        corpus_dir
        |> load_records(incident)
        |> Map.values()
        |> Enum.sort_by(&{&1["observed_at"], &1["evidence_id"]})
        |> Enum.map(& &1["content_digest"])

      [incident, digests]
    end)
    |> then(&("sha256:" <> Base.encode16(:crypto.hash(:sha256, :json.encode(&1)), case: :lower)))
  end

  @doc "Loads one incident's oracle."
  def load_oracle(corpus_dir, incident_id) do
    corpus_dir
    |> Path.join("#{incident_id}/oracle/oracle.json")
    |> File.read!()
    |> Jason.decode!()
  end

  @doc """
  Derives a record's content digest.

  This must agree exactly with the evidence server's derivation; a test
  asserts that for every record in the corpus, because the two implementations
  are deliberately separate — the server has no dependencies and the scorer
  should not need to spawn one to grade an offline report.
  """
  def digest(record) do
    canonical = Enum.map(@record_fields, &[&1, Map.fetch!(record, &1)])
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, :json.encode(canonical)), case: :lower)
  end

  @doc "Scores one report against its oracle and the incident's records."
  def score(report, oracle, records) do
    claims = claims(report)
    citations = Enum.flat_map(claims, & &1.citations)

    %{
      incident_id: oracle["incident_id"],
      abstained: report["status"] == "insufficient_evidence",
      # An abstaining report structurally cannot carry observed facts, so its
      # required-fact recall is always 0. That is a failure on an incident whose
      # evidence supports a report and the correct answer on one whose evidence
      # does not, and only the oracle knows which — so both facts travel
      # together rather than collapsing into one misleading ratio.
      abstention_defensible: oracle["abstention_defensible"] == true,
      citations: citation_integrity(citations, records),
      citation_completeness: citation_completeness(claims),
      required_fact_recall: required_fact_recall(report, oracle),
      contradiction_recall: contradiction_recall(report, oracle),
      open_question_recall: open_question_recall(report, oracle),
      separation_violations: separation_violations(report, oracle),
      noise_citations: noise_citations(citations, oracle)
    }
  end

  ## Claim extraction

  # A material claim is anything the report asserts and the contract requires a
  # citation for. Open questions are excluded: they assert an absence, and
  # their citations are optional by design.
  defp claims(report) do
    timeline = Enum.map(list(report["timeline"]), &claim(&1["statement"], &1["citations"]))
    facts = Enum.map(list(report["observed_facts"]), &claim(&1["statement"], &1["citations"]))

    hypotheses =
      Enum.map(
        list(report["hypotheses"]),
        &claim(
          &1["statement"],
          list(&1["supporting_citations"]) ++ list(&1["contradicting_citations"])
        )
      )

    timeline ++ facts ++ hypotheses
  end

  defp claim(statement, citations),
    do: %{statement: to_string(statement), citations: list(citations)}

  ## Metrics

  defp citation_integrity(citations, records) do
    {unresolved, mismatched} =
      Enum.reduce(citations, {[], []}, fn citation, {unresolved, mismatched} ->
        id = citation["evidence_id"]

        case Map.fetch(records, id) do
          :error ->
            {[id | unresolved], mismatched}

          {:ok, record} ->
            if record["content_digest"] == citation["content_digest"],
              do: {unresolved, mismatched},
              else: {unresolved, [id | mismatched]}
        end
      end)

    %{
      total: length(citations),
      unresolved: Enum.reverse(unresolved),
      mismatched: Enum.reverse(mismatched),
      grounded?: unresolved == [] and mismatched == []
    }
  end

  defp citation_completeness(claims) do
    cited = Enum.count(claims, &(&1.citations != []))
    ratio(cited, length(claims), %{claims: length(claims), cited: cited})
  end

  defp required_fact_recall(report, oracle) do
    facts = list(report["observed_facts"])
    required = list(oracle["required_facts"])

    {recalled, missed} =
      Enum.split_with(required, fn requirement ->
        Enum.any?(facts, fn fact ->
          cites_any?(fact["citations"], requirement["evidence_ids"]) and
            includes_all?(fact["statement"], requirement["must_include"])
        end)
      end)

    ratio(length(recalled), length(required), %{
      required: length(required),
      recalled: length(recalled),
      missed: Enum.map(missed, & &1["id"])
    })
  end

  defp contradiction_recall(report, oracle) do
    hypotheses = list(report["hypotheses"])
    required = list(oracle["contradicted_hypotheses"])

    {recalled, missed} =
      Enum.split_with(required, fn requirement ->
        Enum.any?(hypotheses, fn hypothesis ->
          includes_all?(hypothesis["statement"], requirement["must_include"]) and
            cites_any?(
              hypothesis["contradicting_citations"],
              requirement["contradicting_evidence_ids"]
            )
        end)
      end)

    ratio(length(recalled), length(required), %{
      required: length(required),
      recalled: length(recalled),
      missed: Enum.map(missed, & &1["id"])
    })
  end

  defp open_question_recall(report, oracle) do
    questions = list(report["open_questions"])
    required = list(oracle["required_open_questions"])

    {recalled, missed} =
      Enum.split_with(required, fn requirement ->
        Enum.any?(questions, fn question ->
          includes_all?(
            "#{question["question"]} #{question["missing_evidence"]}",
            requirement["must_include"]
          )
        end)
      end)

    ratio(length(recalled), length(required), %{
      required: length(required),
      recalled: length(recalled),
      missed: Enum.map(missed, & &1["id"])
    })
  end

  # Best-effort and deliberately conservative: an inference stated as an
  # observed fact is caught only when the oracle's whole token conjunction
  # appears in the statement. Paraphrase escapes it, which is why this is a
  # violation count rather than a separation score.
  defp separation_violations(report, oracle) do
    facts = list(report["observed_facts"])

    oracle
    |> list_key("inference_only")
    |> Enum.filter(fn inference ->
      Enum.any?(facts, &includes_all?(&1["statement"], inference["all_of"]))
    end)
    |> Enum.map(& &1["id"])
  end

  defp noise_citations(citations, oracle) do
    noise = MapSet.new(list_key(oracle, "irrelevant_evidence_ids"))
    Enum.count(citations, &MapSet.member?(noise, &1["evidence_id"]))
  end

  ## Helpers

  defp cites_any?(citations, evidence_ids) do
    cited = citations |> list() |> MapSet.new(& &1["evidence_id"])
    Enum.any?(list(evidence_ids), &MapSet.member?(cited, &1))
  end

  defp includes_all?(text, tokens) do
    haystack = text |> to_string() |> String.downcase()
    Enum.all?(list(tokens), &String.contains?(haystack, String.downcase(&1)))
  end

  defp ratio(_hit, 0, base), do: Map.put(base, :ratio, nil)
  defp ratio(hit, total, base), do: Map.put(base, :ratio, hit / total)

  defp list(nil), do: []
  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp list_key(map, key), do: list(Map.get(map, key))
end
