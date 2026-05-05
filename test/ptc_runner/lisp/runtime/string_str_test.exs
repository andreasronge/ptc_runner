defmodule PtcRunner.Lisp.Runtime.StringStrTest do
  use ExUnit.Case, async: true

  defp run!(code) do
    {:ok, step} = PtcRunner.Lisp.run(code, context: %{})
    step.return
  end

  describe "(str) with single non-string argument" do
    test "converts a map to Clojure-style string" do
      assert run!("(str {:a 1})") == "{:a 1}"
    end

    test "converts a multi-key map to Clojure-style string" do
      result = run!("(str {:a 1 :b 2})")
      assert result =~ ~r/^\{.*\}$/
      assert result =~ ":a 1"
      assert result =~ ":b 2"
    end

    test "converts a list to Clojure-style string" do
      assert run!("(str [1 2 3])") == "[1 2 3]"
    end

    test "converts an integer to string" do
      assert run!("(str 42)") == "42"
    end

    test "converts nil to empty string" do
      assert run!("(str nil)") == ""
    end

    test "returns a string unchanged" do
      assert run!("(str \"hello\")") == "hello"
    end

    test "converts keyword to string" do
      assert run!("(str :foo)") == ":foo"
    end

    test "converts boolean to string" do
      assert run!("(str true)") == "true"
    end
  end

  describe "(str) concatenation" do
    test "concatenates multiple values without separator" do
      assert run!(~s|(str "a" "b" "c")|) == "abc"
    end

    test "concatenates mixed types" do
      assert run!(~s|(str "count: " 42)|) == "count: 42"
    end

    test "nil is empty in concatenation" do
      assert run!(~s|(str "a" nil "b")|) == "ab"
    end

    test "no arguments returns empty string" do
      assert run!("(str)") == ""
    end
  end

  # Regression: temporal structs must render as ISO 8601, not as Elixir sigils.
  # Without these clauses the LLM's program would see `~U[2026-05-03 09:14:00Z]`
  # which `(java.util.Date. ...)` cannot parse. See `PtcRunner.Temporal`.
  describe "(str) with temporal structs" do
    defp run_with!(code, context) do
      {:ok, step} = PtcRunner.Lisp.run(code, context: context)
      step.return
    end

    test "DateTime renders as ISO 8601" do
      assert run_with!("(str data/dt)", %{dt: ~U[2026-05-03 09:14:00Z]}) ==
               "2026-05-03T09:14:00Z"
    end

    test "NaiveDateTime renders as ISO 8601 (no offset)" do
      assert run_with!("(str data/dt)", %{dt: ~N[2026-05-03 09:14:00]}) ==
               "2026-05-03T09:14:00"
    end

    test "Date renders as ISO 8601" do
      assert run_with!("(str data/d)", %{d: ~D[2026-05-03]}) == "2026-05-03"
    end

    test "Time renders as ISO 8601" do
      assert run_with!("(str data/t)", %{t: ~T[09:14:00]}) == "09:14:00"
    end

    test "(java.util.Date. (str dt)) round-trips through PTC-Lisp" do
      # The whole point: an LLM's program can stringify and re-parse a DateTime.
      result =
        run_with!(
          "(.getTime (java.util.Date. (str data/dt)))",
          %{dt: ~U[2026-05-03 09:14:00Z]}
        )

      assert is_integer(result)
      # Sanity check: 2026-05-03T09:14:00Z is a real instant, just confirm it's
      # in the right ballpark (UNIX millis around 1.77e12 for that date).
      assert result > 1_700_000_000_000
      assert result < 2_000_000_000_000
    end
  end
end
