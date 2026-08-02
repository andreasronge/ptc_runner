defmodule PtcRunner.Kernel.DeclaredVocabularyTest do
  use ExUnit.Case, async: true

  @moduledoc """
  A component declares the closed vocabularies its own code emits.

  Both the application failure kinds a public taxonomy may name and the
  annotation types a canonical trace may carry are declared in `(ns ...)`
  metadata, beside the `fail`/`annotate` calls that produce them, so neither
  can drift from the code and both are covered by the component source hash.
  """

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.Environment
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.TraceCapability
  alias PtcRunner.Kernel.WorkflowEnvironment

  @declaring ~S"""
  (ns app "Declares its own vocabulary."
    {:failure-kinds ["budget-exceeded"]
     :annotations {"records-checked" ["checked" "rejected"]}})

  (defn refuse [_] (fail {"kind" "budget-exceeded"}))
  (defn undeclared-refusal [_] (fail {"kind" "some-other-kind"}))

  (defn note [_]
    (return (workflow.event/annotate "records-checked" {"checked" 12 "rejected" 1})))

  (defn note-unknown-counter [_]
    (return (workflow.event/annotate "records-checked" {"checked" 12 "note" 1})))

  (defn note-undeclared-type [_]
    (return (workflow.event/annotate "audit" {"checked" 12})))
  """

  @silent ~S"""
  (ns app "Declares nothing.")

  (defn refuse [_] (fail {"kind" "budget-exceeded"}))
  (defn note [_]
    (return (workflow.event/annotate "records-checked" {"checked" 12 "rejected" 1})))
  """

  defp run(source, entry, run_id) do
    {:ok, component} = Component.new(id: "app", source: source, dependencies: ["workflow.event"])
    {:ok, extra} = Library.resolve_components([{:library, "workflow.event"}])
    {:ok, bundle} = Kernel.compile_bundle(extra ++ [component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: run_id)

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    outcome = Kernel.run("(app/#{entry} nil)", config)

    annotations =
      sink
      |> EventSink.events()
      |> Enum.filter(&(&1.type == "workflow-annotation"))
      |> Enum.map(& &1.data)

    {outcome, annotations, sink}
  end

  defp component!(id, source) do
    {:ok, component} = Component.new(id: id, source: "#{source}\n(defn run [_] (return 1))")
    [component]
  end

  defp summary(sink) do
    {:ok, capabilities} = TraceCapability.new(source: sink, max_result_bytes: 100_000)
    callbacks = Map.new(capabilities, &{&1.name, &1.callback})
    {:ok, %{"items" => [metadata]}} = callbacks["trace-list-runs"].(%{})
    metadata
  end

  describe "declared failure kinds" do
    test "a declared kind names itself in the error and the trace summary" do
      {outcome, _annotations, sink} = run(@declaring, "refuse", "declared-refusal")

      assert {:error, %{reason: :explicit_failure, details: %{failure_kind: "budget-exceeded"}}} =
               outcome

      assert summary(sink)["failure_kind"] == "budget-exceeded"
    end

    test "an undeclared kind still fingerprints" do
      {outcome, _annotations, sink} = run(@declaring, "undeclared-refusal", "undeclared-refusal")

      assert {:error, %{details: %{failure_kind_fingerprint: fingerprint}}} = outcome
      assert fingerprint == SafeMetadata.fingerprint("failure-kind:some-other-kind")
      assert summary(sink)["failure_kind"] == nil
    end

    test "a component that declares nothing keeps the previous behaviour" do
      {outcome, _annotations, _sink} = run(@silent, "refuse", "silent-refusal")
      assert {:error, %{details: %{failure_kind_fingerprint: _}}} = outcome
    end
  end

  describe "declared annotations" do
    test "a declared type carries its counters into a canonical trace" do
      {outcome, annotations, _sink} = run(@declaring, "note", "declared-annotation")

      assert {:ok, %{value: %{status: :ok}}} = outcome

      assert [
               %{
                 annotation_type: "records-checked",
                 provenance: :workflow,
                 data: %{"checked" => 12, "rejected" => 1}
               }
             ] = annotations
    end

    test "a counter the declaration does not name is rejected" do
      {outcome, annotations, _sink} =
        run(@declaring, "note-unknown-counter", "unknown-counter")

      assert {:ok, %{value: %{status: :error, kind: :invalid_annotation}}} = outcome
      assert annotations == []
    end

    test "an undeclared type is rejected" do
      {outcome, annotations, _sink} =
        run(@declaring, "note-undeclared-type", "undeclared-type")

      assert {:ok, %{value: %{status: :error, kind: :invalid_annotation}}} = outcome
      assert annotations == []
    end

    test "a component that declares nothing cannot annotate its own type" do
      {outcome, annotations, _sink} = run(@silent, "note", "silent-annotation")

      assert {:ok, %{value: %{status: :error, kind: :invalid_annotation}}} = outcome
      assert annotations == []
    end
  end

  describe "the declaration surface stays closed" do
    test "malformed declarations fail the component compile" do
      for meta <- [
            ~S|{:failure-kinds ["Budget Exceeded"]}|,
            ~S|{:failure-kinds ["budget_exceeded"]}|,
            ~S|{:failure-kinds ["dup" "dup"]}|,
            ~S|{:failure-kinds "budget-exceeded"}|,
            ~S|{:annotations {"records-checked" []}}|,
            ~S|{:annotations {"records-checked" ["Checked"]}}|,
            ~S|{:annotations {"records checked" ["checked"]}}|,
            ~S|{:annotations ["records-checked"]}|
          ] do
        source = "(ns app \"doc\" #{meta})\n(defn run [_] (return 1))"
        {:ok, component} = Component.new(id: "app", source: source)

        assert {:error, %{reason: :component_compile_error}} =
                 Kernel.compile_bundle([component]),
               "accepted #{meta}"
      end
    end

    test "two namespaces cannot declare the same annotation type differently" do
      # Merging would keep one list by fold order and silently reject the
      # loser's own annotations at runtime, where a rejection emits no event
      # and counts no protocol error. Refused at assembly instead, matching
      # how the prelude compiler refuses a redeclared namespace.
      conflicting =
        component!("a", ~S|(ns a {:annotations {"checked" ["hits"]}})|) ++
          component!("b", ~S|(ns b {:annotations {"checked" ["hits" "misses"]}})|)

      assert {:ok, bundle} = Kernel.compile_bundle(conflicting)

      assert {:error, :conflicting_annotation_declaration} =
               WorkflowEnvironment.new(bundle: bundle)

      assert {:error, :conflicting_annotation_declaration} =
               MissionEnvironment.new(bundle: bundle)
    end

    test "the same declaration in two namespaces is allowed regardless of order" do
      agreeing =
        component!("a", ~S|(ns a {:annotations {"checked" ["hits" "misses"]}})|) ++
          component!("b", ~S|(ns b {:annotations {"checked" ["misses" "hits"]}})|)

      assert {:ok, bundle} = Kernel.compile_bundle(agreeing)
      assert {:ok, environment} = WorkflowEnvironment.new(bundle: bundle)
      assert %{"checked" => counters} = Environment.vocabulary(environment).annotations
      assert Enum.sort(counters) == ["hits", "misses"]
    end

    test "a declaration cannot shadow a framework kind or a canonical annotation" do
      refute SafeMetadata.declarable_failure_kind?("turn-limit")
      refute SafeMetadata.declarable_annotation?("progress", ["stage"])
      refute SafeMetadata.declarable_annotation?("agent-action", ["turn"])
    end

    test "counters are bounded non-negative integers only" do
      declared = %{"records-checked" => ["checked"]}

      assert SafeMetadata.annotation?("records-checked", %{"checked" => 0}, declared)
      assert SafeMetadata.annotation?("records-checked", %{"checked" => 65_535}, declared)
      refute SafeMetadata.annotation?("records-checked", %{"checked" => 65_536}, declared)
      refute SafeMetadata.annotation?("records-checked", %{"checked" => -1}, declared)
      refute SafeMetadata.annotation?("records-checked", %{"checked" => 1.0}, declared)
      refute SafeMetadata.annotation?("records-checked", %{"checked" => "12"}, declared)
      refute SafeMetadata.annotation?("records-checked", %{"checked" => ["INC-42"]}, declared)
      refute SafeMetadata.annotation?("records-checked", %{}, declared)
    end
  end
end
