defmodule PtcRunner.Kernel.CandidatePromotionTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Covers the promotion gate: what a candidate must satisfy before a human is
  asked to look at it, and what the gate deliberately does not claim.
  """

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CandidatePromotion
  alias PtcRunner.Kernel.ComponentOverride

  @base """
  (ns helper "Helper exports." {:visibility :prompt})

  (defn reader
    "Reads a thing."
    {:signature "() -> :string" :effect :read}
    []
    (tool/read-thing {}))

  (defn writer
    "Writes a thing."
    {:signature "() -> :string" :effect :write}
    []
    (tool/write-thing {}))
  """

  describe "effect and requirement widening" do
    test "an export that gains a capability another export already had is caught" do
      # The trap a naive implementation falls into: compared against an
      # application-wide union of capability names, `reader` gaining
      # write-thing adds nothing new, because `writer` already required it.
      # Comparison has to be per export ref to see this.
      candidate = """
      (ns helper "Helper exports." {:visibility :prompt})

      (defn reader
        "Reads a thing."
        {:signature "() -> :string" :effect :read}
        []
        (do (tool/read-thing {}) (tool/write-thing {})))

      (defn writer
        "Writes a thing."
        {:signature "() -> :string" :effect :write}
        []
        (tool/write-thing {}))
      """

      report = evaluate(candidate)

      assert report.outcome == :fail
      assert %{status: :fail, detail: detail} = criterion(report, "G3")
      assert [%{"ref" => "helper/reader"} = widened] = detail["widened"]
      assert widened["gained_requirements"] == ["write-thing"]
    end

    test "an acknowledged widening passes but is still reported" do
      candidate = String.replace(@base, "(tool/read-thing {}))", "(tool/write-thing {}))")

      report = evaluate(candidate, accept_widened_effect: true)

      assert report.outcome == :pass
      assert %{status: :pass, detail: detail} = criterion(report, "G3")
      assert detail["accepted"] == true
      # Acknowledging a risk is not the same as hiding it.
      assert [%{"ref" => "helper/reader"}] = detail["widened"]
    end

    test "an added export that requires a capability is a widening" do
      candidate =
        @base <>
          """

          (defn extra
            "Reaches a new thing."
            {:signature "() -> :string" :effect :read}
            []
            (tool/other-thing {}))
          """

      report = evaluate(candidate)

      assert report.outcome == :fail
      assert %{detail: detail} = criterion(report, "G3")
      assert [%{"ref" => "helper/extra"} = added] = detail["widened"]
      assert added["gained_requirements"] == ["other-thing"]
      assert added["effect"]["base"] == nil
    end

    test "an added pure helper is indeterminate, not a widening" do
      # join_effects([]) returns :unknown, so an ordinary pure helper resolves
      # to :unknown with no requirements. Failing on that would make every
      # added helper a widening and train operators to pass the acceptance
      # flag reflexively, which destroys its meaning.
      candidate =
        @base <>
          """

          (defn pure
            "Adds two numbers."
            {:signature "(a :int, b :int) -> :int"}
            [a b]
            (+ a b))
          """

      report = evaluate(candidate)

      assert report.outcome == :pass
      assert %{status: :pass, detail: detail} = criterion(report, "G3")
      assert [%{"ref" => "helper/pure", "effect" => "unknown"}] = detail["indeterminate"]
    end

    test "a removed export is a surface change, not a widening" do
      candidate = """
      (ns helper "Helper exports." {:visibility :prompt})

      (defn reader
        "Reads a thing."
        {:signature "() -> :string" :effect :read}
        []
        (tool/read-thing {}))
      """

      report = evaluate(candidate)

      assert report.outcome == :pass
      assert %{status: :pass, detail: detail} = criterion(report, "G3")
      assert detail["surface_changes"]["removed"] == ["helper/writer"]
    end
  end

  describe "model visibility" do
    test "a prompt-visible export without a signature is refused" do
      candidate = """
      (ns helper "Helper exports." {:visibility :prompt})

      (defn reader
        "Reads a thing."
        {:signature "() -> :string" :effect :read}
        []
        (tool/read-thing {}))

      (defn writer
        "Writes a thing."
        {:effect :write}
        []
        (tool/write-thing {}))
      """

      report = evaluate(candidate)

      assert report.outcome == :fail
      assert %{status: :fail, detail: detail} = criterion(report, "G2")
      assert [%{"ref" => "helper/writer", "missing" => ["signature"]}] = detail["exports"]
    end
  end

  describe "blocked criteria" do
    test "a candidate that does not compile blocks the criteria that need its exports" do
      report = evaluate("(ns helper \"Broken.\" {:visibility :prompt}) (defn oops [")

      assert report.outcome == :fail
      assert %{status: :fail} = criterion(report, "G1")

      # Not :fail -- these could not run at all, and reporting them as
      # failures would misattribute the cause to the export table.
      assert %{status: :blocked} = criterion(report, "G2")
      assert %{status: :blocked} = criterion(report, "G3")
    end
  end

  defp criterion(report, id), do: Enum.find(report.criteria, &(&1.id == id))

  defp evaluate(candidate_source, opts \\ []) do
    {:ok, base} =
      ApplicationPackage.request_memory("app.json", base_documents(), result_projection: :native)

    # The candidate is acquired through the same override path a run takes, so
    # the gate never sees a package a run could not have produced.
    {:ok, candidate} =
      ApplicationPackage.request_memory("app.json", candidate_documents(candidate_source),
        component_override: {"override.json", "candidate.clj"},
        result_projection: :native
      )

    CandidatePromotion.evaluate(base.package, candidate.package, opts)
  end

  defp base_documents do
    %{
      "app.json" => manifest(),
      "helper.clj" => @base,
      "w.clj" => ~S|(ns app) (defn run [_i] (return (helper/reader)))|
    }
  end

  defp candidate_documents(candidate_source) do
    Map.merge(base_documents(), %{
      "candidate.clj" => candidate_source,
      "override.json" =>
        Jason.encode!(%{
          "target" => %{"environment" => "workflow"},
          "component_id" => "helper",
          "base_source_hash" => hash(@base),
          "source_hash" => hash(candidate_source),
          "path" => "candidate.clj"
        })
    })
  end

  defp manifest do
    Jason.encode!(%{
      "version" => 1,
      "workflow" => %{
        "components" => [
          %{"id" => "helper", "path" => "helper.clj"},
          %{"id" => "app", "path" => "w.clj", "dependencies" => ["helper"]}
        ],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "limits" => %{"run_duration_ms" => 30_000}
    })
  end

  defp hash(source), do: ComponentOverride.hash(source)
end
