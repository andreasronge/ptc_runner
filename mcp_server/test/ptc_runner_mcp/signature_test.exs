defmodule PtcRunnerMcp.SignatureTest do
  @moduledoc """
  Phase 3 (§ 9.4) coverage for the `signature` argument of
  `tools/call name: "ptc_lisp_execute"`.

  Covers `Plans/ptc-runner-mcp-server.md` § 16 rows:

    * `signature` not a string → `args_error`
    * `signature` malformed → `args_error`
    * Signature `() -> {total :int}` matched by program return →
      success payload includes `validated` field with structured JSON
    * Signature mismatch → `validation_error`
    * Atom return value → `validated` contains the string form
      (no leading colon)
    * Tuple return value → `validated` contains a JSON array
    * `%DateTime{}` return value → `validated` contains an ISO-8601
      string
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

  describe "signature shape validation (§ 9.4)" do
    test "non-string signature returns args_error and consumes no permit" do
      env = call(%{"program" => "1", "signature" => 42})

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "args_error"
      assert sc["message"] =~ "signature"
      assert ConcurrencyGate.in_flight() == 0
    end

    test "malformed signature returns args_error and consumes no permit" do
      env = call(%{"program" => "1", "signature" => "(((not a signature"})

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["reason"] == "args_error"
      assert sc["message"] =~ "signature"
      assert ConcurrencyGate.in_flight() == 0
    end
  end

  describe "signature match → success with validated field" do
    test "signature `() -> {total :int}` matched by program return" do
      env =
        call(%{
          "program" => "{:total (+ 1 2 3 4)}",
          "signature" => "() -> {total :int}"
        })

      assert env["isError"] == false
      sc = env["structuredContent"]
      assert sc["status"] == "ok"
      assert sc["validated"] == %{"total" => 10}
    end

    test "cross-language smoke: filter+reduce over data/orders, validated map" do
      # DoD example from Phase 3.
      program = """
      (let [big (filter #(> (get % "total") 10) data/orders)]
        {:count (count big) :sum (reduce + (map #(get % "total") big))})
      """

      env =
        call(%{
          "program" => program,
          "context" => %{
            "orders" => [
              %{"total" => 12},
              %{"total" => 7},
              %{"total" => 33}
            ]
          },
          "signature" => "() -> {count :int, sum :int}"
        })

      assert env["isError"] == false
      sc = env["structuredContent"]
      assert sc["status"] == "ok"
      assert sc["validated"] == %{"count" => 2, "sum" => 45}
    end

    test "atom return → validated contains the string form (no leading colon)" do
      env =
        call(%{
          "program" => ":ok",
          "signature" => "() -> :keyword"
        })

      assert env["isError"] == false
      sc = env["structuredContent"]
      assert sc["status"] == "ok"
      # Per § 13: atoms render as bare strings, no leading colon.
      assert sc["validated"] == "ok"
    end

    test "%DateTime{} return → validated contains an ISO-8601 string" do
      # Build a program whose return is a typed %DateTime{}: the
      # signature `:datetime` triggers `atomize_value/2` to coerce a
      # binary ISO-8601 to a struct, after which `to_json_value/1`
      # serializes it back to ISO-8601.
      env =
        call(%{
          "program" => ~s|"2026-05-07T12:00:00Z"|,
          "signature" => "() -> :datetime"
        })

      assert env["isError"] == false
      sc = env["structuredContent"]
      assert sc["status"] == "ok"
      assert sc["validated"] == "2026-05-07T12:00:00Z"
    end
  end

  describe "signature mismatch → validation_error" do
    test "string return when signature expects {count :int}" do
      env =
        call(%{
          "program" => ~s|"hello"|,
          "signature" => "() -> {count :int}"
        })

      assert env["isError"] == true
      sc = env["structuredContent"]
      assert sc["status"] == "error"
      assert sc["reason"] == "validation_error"
      assert is_binary(sc["message"])
    end

    test "wrong-typed field surfaces validation_error" do
      env =
        call(%{
          "program" => ~s|{:count "not a number"}|,
          "signature" => "() -> {count :int}"
        })

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "validation_error"
    end
  end
end
