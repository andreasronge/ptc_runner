defmodule PtcRunner.Lisp.ConformanceRunnerTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Lisp.ClojureValidator
  alias PtcRunner.TestSupport.LispConformanceCases.Manual
  alias PtcRunner.TestSupport.LispConformanceRunner

  @moduletag :clojure

  unless ClojureValidator.available?() do
    @moduletag skip: "Babashka not installed. Run: mix ptc.install_babashka"
  end

  test "runner passes a matching case" do
    case_data = %{
      id: "runner/match-001",
      namespace: "clojure.core",
      vars: ["+"],
      form: "(+ 1 2)",
      policy: :match
    }

    assert {:pass, %{id: "runner/match-001"}} = LispConformanceRunner.run_case(case_data)
  end

  test "runner passes an intentional divergence with a PTC expected value" do
    case_data = %{
      id: "runner/div-001",
      namespace: "clojure.core",
      vars: ["subs"],
      form: ~S|(subs "abc" 9)|,
      policy: {:diverges, "DIV-22"},
      ptc_expected: "",
      reason: "PTC-Lisp returns an empty-string signal value for bad external input."
    }

    assert {:pass, %{div_id: "DIV-22"}} = LispConformanceRunner.run_case(case_data)
  end

  test "runner passes an intentional divergence with a PTC expected error" do
    case_data = %{
      id: "runner/div-error-001",
      namespace: "clojure.core",
      vars: ["first"],
      form: "(first {:a 1})",
      policy: {:diverges, "DIV-29"},
      ptc_expected: {:error, :type_error},
      reason: "PTC-Lisp rejects direct positional map access."
    }

    assert {:pass, %{div_id: "DIV-29", ptc: {:error, %{reason: :type_error}}}} =
             LispConformanceRunner.run_case(case_data)
  end

  test "runner records unsupported cases as skips" do
    case_data = %{
      id: "runner/unsupported-001",
      namespace: "clojure.core",
      vars: ["range"],
      form: "(take 3 (range))",
      policy: :unsupported,
      reason: "Unbounded lazy sequences are outside PTC-Lisp."
    }

    assert {:skip, %{skip_reason: "Unbounded lazy sequences are outside PTC-Lisp."}} =
             LispConformanceRunner.run_case(case_data)
  end

  test "runner passes a known bug only while the mismatch reproduces" do
    case_data = %{
      id: "runner/bug-001",
      namespace: "clojure.string",
      vars: ["lower-case"],
      form: "(clojure.string/lower-case 12)",
      policy: {:bug, "GAP-S139"}
    }

    assert {:pass, %{classification: :bug, gap_id: "GAP-S139"}} =
             LispConformanceRunner.run_case(case_data)
  end

  test "runner catches a PTC error when Clojure succeeds" do
    case_data = %{
      id: "runner/ptc-error-001",
      namespace: "clojure.core",
      vars: ["keyword"],
      form: ":foo/bar",
      policy: :match
    }

    assert {:fail, %{reason: :outcome_mismatch, ptc: {:error, _}, clojure: {:ok, _}}} =
             LispConformanceRunner.run_case(case_data)
  end

  test "runner catches a Clojure error when PTC succeeds" do
    case_data = %{
      id: "runner/clojure-error-001",
      namespace: "clojure.core",
      vars: ["subs"],
      form: ~S|(subs "abc" 9)|,
      policy: :match
    }

    assert {:fail, %{reason: :outcome_mismatch, ptc: {:ok, ""}, clojure: {:error, _}}} =
             LispConformanceRunner.run_case(case_data)
  end

  test "runner catches a value mismatch" do
    case_data = %{
      id: "runner/mismatch-001",
      namespace: "clojure.core",
      vars: ["format"],
      form: ~S|(format "x%s" nil)|,
      policy: :match
    }

    assert {:fail, %{reason: :value_mismatch, ptc: {:ok, "x"}, clojure: {:ok, "xnull"}}} =
             LispConformanceRunner.run_case(case_data)
  end

  test "runner normalizes direct Java temporal object renderings" do
    case_data = %{
      id: "runner/temporal-001",
      namespace: "java.time.LocalDate",
      vars: [".plusDays"],
      form: ~S|(.plusDays (java.time.LocalDate/parse "2024-01-02") -2)|,
      policy: :match
    }

    assert {:pass, %{id: "runner/temporal-001"}} = LispConformanceRunner.run_case(case_data)
  end

  test "runner preserves nested collection values inside Clojure sets" do
    case_data = %{
      id: "runner/set-vector-001",
      namespace: "clojure.core",
      vars: ["hash-set"],
      form: "(hash-set [:a 1])",
      policy: :match
    }

    assert {:pass, %{id: "runner/set-vector-001"}} = LispConformanceRunner.run_case(case_data)
  end

  test "manual seed cases have unique ids" do
    ids = Enum.map(Manual.all(), & &1.id)
    assert Enum.uniq(ids) == ids
  end

  test "manual seed case count is large enough for the first pass" do
    assert length(Manual.all()) >= 75
  end
end
