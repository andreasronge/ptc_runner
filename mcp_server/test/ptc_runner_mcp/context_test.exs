defmodule PtcRunnerMcp.ContextTest do
  @moduledoc """
  Phase 3 (§ 9.3) coverage for the `context` argument of
  `tools/call name: "ptc_lisp_execute"`.

  Covers `Plans/ptc-runner-mcp-server.md` § 16 rows:

    * `context` not an object → `args_error`
    * `context` exceeding `max_context_bytes` → `args_error`
    * `context` key containing `/` → `args_error`
    * `context` key empty string → `args_error`
    * `context: {"records": [...]}` makes `data/records` accessible
    * Reference to `data/missing` USED in an arithmetic op (with no
      such key) → `runtime_error`. Note: a bare `data/missing`
      reference returns `nil` silently in the current `:ptc_runner`
      runtime. The DoD assertion that names "the missing binding"
      directly is partially met — the runtime error message currently
      reports the downstream type error ("invalid argument types: nil,
      number") rather than naming `missing`. Tracked as a `:ptc_runner`
      finding in the Phase 3 final note (analyzer/runtime change is
      out of Phase 3 MCP-package scope).
    * JSON integer round-trips as integer (not float).
    * JSON map keys remain strings inside the program (no atom creation).

  Plus the § 8.4 feedback-quality smoke test for `(get context "k")`.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{ConcurrencyGate, Limits, Tools}

  setup do
    Limits.set(Limits.defaults())
    ConcurrencyGate.reset()
    :ok
  end

  defp call(args) do
    Tools.call(%{"name" => "ptc_lisp_execute", "arguments" => args})
  end

  describe "context shape validation (§ 9.3)" do
    test "non-object context returns args_error" do
      env = call(%{"program" => "1", "context" => "not-an-object"})

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "args_error"
      assert sc["message"] =~ "context"
    end

    test "list context returns args_error" do
      env = call(%{"program" => "1", "context" => [1, 2, 3]})

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "args_error"
    end

    test "context key containing `/` returns args_error" do
      env = call(%{"program" => "1", "context" => %{"foo/bar" => 1}})

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "args_error"
      assert sc["message"] =~ "/"
    end

    test "empty-string context key returns args_error" do
      env = call(%{"program" => "1", "context" => %{"" => 1}})

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "args_error"
      assert sc["message"] =~ "non-empty"
    end

    test "absent context is treated as empty object" do
      env = call(%{"program" => "(+ 1 2)"})

      assert env["isError"] == false
      assert env["structuredContent"]["result"] == "user=> 3"
    end

    test "explicit nil context is treated as empty object" do
      env = call(%{"program" => "(+ 1 2)", "context" => nil})

      assert env["isError"] == false
      assert env["structuredContent"]["result"] == "user=> 3"
    end
  end

  describe "max_context_bytes enforcement (§ 9.3)" do
    test "oversized context returns args_error and does not consume a permit" do
      Limits.set(%{max_context_bytes: 64})

      # Construct a context whose JSON encoding exceeds 64 bytes.
      big_value = String.duplicate("x", 256)
      env = call(%{"program" => "1", "context" => %{"big" => big_value}})

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "args_error"
      assert sc["message"] =~ "max_context_bytes"

      # Validation must short-circuit BEFORE permit acquisition.
      assert ConcurrencyGate.in_flight() == 0
    end
  end

  describe "context binding under data/" do
    test "context: {\"records\": [...]} makes data/records accessible" do
      env =
        call(%{
          "program" => "(count data/records)",
          "context" => %{"records" => [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}]}
        })

      assert env["isError"] == false
      assert env["structuredContent"]["result"] == "user=> 3"
    end

    test "JSON integer round-trips as integer (not float)" do
      env =
        call(%{
          "program" => "(+ data/n 0)",
          "context" => %{"n" => 42}
        })

      assert env["isError"] == false
      # If `42` had been silently coerced to a float we'd see "42.0".
      assert env["structuredContent"]["result"] == "user=> 42"
    end

    test "data/missing used in an arithmetic op surfaces runtime_error" do
      env =
        call(%{
          "program" => "(+ data/missing 1)",
          "context" => %{"other" => 5}
        })

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "runtime_error"
      # Current `:ptc_runner` runtime surfaces this as a type error
      # whose message references `nil` (the result of the missing
      # lookup) rather than the binding name. Tracked as a finding.
      assert sc["message"] =~ "nil" or sc["message"] =~ "missing"
    end

    test "JSON map keys remain strings inside the program (no atom creation)" do
      env =
        call(%{
          "program" => ~s|(get data/row "name")|,
          "context" => %{"row" => %{"name" => "Alice"}}
        })

      assert env["isError"] == false
      # EDN-rendered string preview keeps the quotes.
      assert env["structuredContent"]["result"] =~ "Alice"
    end
  end

  describe "feedback-quality smoke (§ 8.4 / Phase 3)" do
    test "(get context \"k\") feedback names `context` or points at `data/`" do
      env = call(%{"program" => ~s|(get context "k")|})

      assert env["isError"] == true
      sc = env["structuredContent"]

      feedback = sc["feedback"]

      assert feedback =~ "context" or feedback =~ "data/",
             "feedback was: #{inspect(feedback)}"
    end
  end
end
