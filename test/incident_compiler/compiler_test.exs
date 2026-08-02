defmodule IncidentCompiler.CompilerTest do
  @moduledoc """
  Phase 1 exit gate for the incident-evidence compiler reference application.

  Every test here is credential-free: the model is an `llm_replay` alias over
  frozen fixtures and the evidence source is the checked-in stdio MCP server.

  Each scenario runs once in `setup_all` and every assertion reads those
  results. A scenario run spawns a BEAM for the fixture MCP server, so running
  one per assertion would both slow this file down and starve the timing-
  sensitive transport tests running alongside it.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ptc.Run
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.ValueContract

  @app Path.expand("../../incident_compiler", __DIR__)
  @host Path.join(@app, "ptc-host.json")

  setup_all do
    dir = Path.join(System.tmp_dir!(), "incident-compiler-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    artifact = Path.join(dir, "checkout.inspection.jsonl")
    trace = Path.join(dir, "auth.jsonl")

    %{
      checkout: run!("ptc.json", ["--inspect", artifact]),
      queue: run!("ptc.queue-backlog.json", []),
      selftest: run!("selftest.json", []),
      refusal: refusal!("ptc.auth-partial.json", ["--trace", trace]),
      transcripts: model_request_transcripts(artifact),
      stages: annotation_stages(trace)
    }
  end

  describe "grounded publication" do
    test "compiles checkout-5xx and corrects an uncited claim before publishing", context do
      report = context.checkout

      assert report["status"] == "report"
      assert report["incident_id"] == "checkout-5xx"

      # The scripted draft asserted a customer-impact number no record states.
      # It must not survive into the published report, and the question it
      # raised must survive as an open question instead.
      statements = Enum.map(report["observed_facts"], & &1["statement"])
      refute Enum.any?(statements, &String.contains?(&1, "12000"))

      assert Enum.any?(report["open_questions"], fn question ->
               String.contains?(question["question"], "How many customers")
             end)
    end

    test "returns the result-contract diagnostics to the model for correction", context do
      assert length(context.transcripts) == 5

      assert context.transcripts
             |> List.last()
             |> Enum.any?(
               &String.contains?(&1, "did not satisfy the application result contract")
             )
    end

    test "generates the agent task shape from the compiled result contract", context do
      schema =
        @app
        |> Path.join("contracts/report.schema.json")
        |> File.read!()
        |> Jason.decode!()

      assert {:ok, contract} = ValueContract.compile(schema)
      task = context.transcripts |> List.first() |> List.first()

      for branch <- String.split(ValueContract.describe(contract), "\n") do
        assert task =~ branch
      end
    end

    test "compiles queue-backlog without needing a correction turn", context do
      report = context.queue

      assert report["status"] == "report"
      assert report["incident_id"] == "queue-backlog"

      # The property that matters is not how many hypotheses there are — that
      # would only assert the shape of the scripted fixture. It is that a
      # hypothesis carrying evidence against it is not asserted confidently.
      contradicted =
        Enum.filter(report["hypotheses"], &(&1["contradicting_citations"] not in [nil, []]))

      assert contradicted != []
      assert Enum.all?(contradicted, &(&1["confidence"] == "low"))
    end

    test "every published citation is well formed", context do
      for report <- [context.checkout, context.queue] do
        citations = citations(report)

        assert citations != []

        assert Enum.all?(citations, fn citation ->
                 is_binary(citation["evidence_id"]) and
                   String.match?(citation["content_digest"], ~r/\Asha256:[0-9a-f]{64}\z/)
               end)
      end
    end
  end

  describe "fail-closed publication" do
    test "refuses a structurally valid report whose citation names no record", context do
      # The draft satisfies the result contract in every structural respect, so
      # only citation resolution can reject it.
      #
      # The manifest declares this kind, so the refusal names itself instead of
      # arriving as a fingerprint an operator has to precompute to recognise.
      assert context.refusal =~ "failure_kind: \"unresolved-citations\""
      refute context.refusal =~ SafeMetadata.fingerprint("failure-kind:unresolved-citations")
    end

    test "records the refusal as a failed validation stage in the trace", context do
      assert context.stages == ["validating", "failed"]
    end
  end

  describe "evidence surface" do
    test "resolves a genuine citation and rejects an unknown one and a tampered digest",
         context do
      outcome = context.selftest

      assert outcome["source_count"] == 6
      assert outcome["record_count"] == 13

      assert outcome["resolved"] == %{"checked" => 1, "unresolved" => [], "mismatched" => []}
      assert outcome["unknown"]["unresolved"] == ["missing-record"]
      assert outcome["tampered"]["mismatched"] == [outcome["sampled_evidence_id"]]
    end
  end

  describe "static authority" do
    test "the installed evidence source declares no write effect" do
      {:ok, host} = HostConfig.load(@host)
      effects = host.install |> Map.fetch!("evidence") |> installed_effects()

      assert effects != []
      assert Enum.all?(effects, &(&1 == :read))
    end

    test "no shipped manifest selects a provider the host installs with a write effect" do
      {:ok, host} = HostConfig.load(@host)

      writable =
        for {alias_name, installation} <- host.install,
            :write in installed_effects(installation),
            do: alias_name

      assert writable == []
    end
  end

  describe "result contract" do
    setup do
      schema =
        @app
        |> Path.join("contracts/report.schema.json")
        |> File.read!()
        |> Jason.decode!()

      {:ok, contract} = ValueContract.compile(schema)
      %{contract: contract}
    end

    test "accepts a structured abstention", %{contract: contract} do
      assert ValueContract.valid?(contract, %{
               "status" => "insufficient_evidence",
               "incident_id" => "checkout-5xx",
               "reason" => "The retained evidence does not cover the incident window.",
               "open_questions" => [
                 %{
                   "question" => "What happened between 09:00Z and 09:30Z?",
                   "missing_evidence" => "No records are retained for that window."
                 }
               ]
             })
    end

    test "rejects an observed fact carrying no citation", %{contract: contract} do
      refute ValueContract.valid?(
               contract,
               report_with_facts([%{"statement" => "It broke.", "citations" => []}])
             )
    end

    test "rejects a citation whose digest is not a sha256 digest", %{contract: contract} do
      refute ValueContract.valid?(
               contract,
               report_with_facts([
                 %{
                   "statement" => "It broke.",
                   "citations" => [%{"evidence_id" => "alert-1", "content_digest" => "deadbeef"}]
                 }
               ])
             )
    end
  end

  defp run!(manifest, extra_args) do
    output =
      capture_io(fn ->
        Mix.Task.reenable("ptc.run")
        Run.run([Path.join(@app, manifest), "--host-config", @host] ++ extra_args)
      end)

    output
    |> String.split("\n", trim: true)
    |> List.last()
    |> Jason.decode!()
    |> Map.fetch!("value")
  end

  defp refusal!(manifest, extra_args) do
    error =
      assert_raise Mix.Error, fn ->
        capture_io(fn ->
          Mix.Task.reenable("ptc.run")
          Run.run([Path.join(@app, manifest), "--host-config", @host] ++ extra_args)
        end)
      end

    error.message
  end

  defp citations(report) do
    Enum.flat_map(report["timeline"] ++ report["observed_facts"], & &1["citations"]) ++
      Enum.flat_map(
        report["hypotheses"],
        &(&1["supporting_citations"] ++ (&1["contradicting_citations"] || []))
      )
  end

  defp model_request_transcripts(artifact) do
    artifact
    |> records()
    |> Enum.filter(
      &(&1["record_type"] == "capability-input" and
          get_in(&1, ["payload", "name"]) == "llm-request")
    )
    |> Enum.sort_by(& &1["sequence"])
    |> Enum.map(fn record ->
      record
      |> get_in(["payload", "arguments", "messages"])
      |> Enum.map(&to_string(&1["content"]))
    end)
  end

  defp annotation_stages(trace) do
    trace
    |> records()
    |> Enum.filter(&(&1["type"] == "workflow-annotation"))
    |> Enum.map(&get_in(&1, ["data", "data", "stage"]))
    |> Enum.reject(&is_nil/1)
  end

  defp records(path), do: path |> File.stream!() |> Enum.map(&Jason.decode!/1)

  defp installed_effects(installation) do
    installation
    |> Map.get(:tools, %{})
    |> Map.values()
    |> Enum.map(& &1.effect)
  end

  defp report_with_facts(facts) do
    %{
      "status" => "report",
      "incident_id" => "checkout-5xx",
      "summary" => "Something happened.",
      "timeline" => [
        %{
          "observed_at" => "2026-05-14T09:12:03Z",
          "statement" => "An alert fired.",
          "citations" => [
            %{
              "evidence_id" => "alert-4471",
              "content_digest" => "sha256:" <> String.duplicate("a", 64)
            }
          ]
        }
      ],
      "observed_facts" => facts,
      "hypotheses" => [],
      "open_questions" => []
    }
  end
end
