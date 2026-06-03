defmodule PtcRunnerMcp.SessionsOutputSchemaTest do
  @moduledoc """
  Regression coverage for GitHub issue #944 finding #5: `lisp_session_eval`
  must accept `output_schema` and validate the program's return value,
  mirroring the stateless `lisp_eval` contract.

  Validation failure does NOT commit the session candidate state — the
  eval is rejected, same precedent as `session_limit_exceeded`. Side
  effects (upstream calls) still surface in the response because they
  already happened.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{ConcurrencyGate, Limits, ResponseProfile, Sessions, Tools}
  alias PtcRunnerMcp.Sessions.Config, as: SessionsConfig
  alias PtcRunnerMcp.Sessions.Registry, as: SessionsRegistry

  setup do
    old_limits = Limits.get()
    old_profile = ResponseProfile.current()
    stop_sessions_processes()
    Limits.set(Limits.defaults())
    SessionsConfig.set(%{enabled: true})
    ResponseProfile.set(:structured)
    ConcurrencyGate.reset()
    assert :ok = Sessions.ensure_started()

    on_exit(fn ->
      stop_sessions_processes()
      Limits.set(old_limits)
      SessionsConfig.reset()
      ConcurrencyGate.reset()
      ResponseProfile.set(old_profile)
    end)

    :ok
  end

  describe "output_schema on lisp_session_eval" do
    test "matching return value is committed and surfaces a `validated` field" do
      session_id = start_session()

      response =
        eval(session_id, "{:count (+ 1 2 3) :label \"hello\"}",
          output_schema: %{
            "type" => "object",
            "properties" => %{
              "count" => %{"type" => "integer"},
              "label" => %{"type" => "string"}
            },
            "required" => ["count", "label"]
          }
        )

      assert response["status"] == "ok"
      assert response["validated"] == %{"count" => 6, "label" => "hello"}

      # State was committed — turn advanced.
      assert response["session"]["turn"] == 1
    end

    test "oversized validated return is committed but omitted from the MCP payload" do
      ResponseProfile.set(:structured)
      session_id = start_session()

      response =
        eval(session_id, large_string_vector_program(),
          output_schema: %{"type" => "array", "items" => %{"type" => "string"}}
        )

      assert response["status"] == "ok"
      refute Map.has_key?(response, "validated")
      assert is_binary(response["validated_preview"])
      assert response["validated_bytes"] > 32 * 1024
      assert response["output_truncated"] == true
      assert response["truncated"] == true

      # The eval still committed even though the client-facing exact
      # validated copy was too large to include.
      assert response["session"]["turn"] == 1
    end

    test "non-matching return rejects the eval and does NOT commit state" do
      session_id = start_session()

      # First commit so we can confirm the failed eval's memory delta
      # didn't merge into state.
      eval(session_id, "(def baseline 1)")

      response =
        eval(session_id, "(do (def will-be-rolled-back 999) \"not-an-integer\")",
          output_schema: %{"type" => "integer"}
        )

      assert response["status"] == "error"
      assert response["reason"] == "validation_error"
      assert response["message"] =~ "return"

      # Confirm rollback: the def from the failed eval did NOT land in memory.
      after_failure = eval(session_id, "(list baseline)")
      assert after_failure["status"] == "ok"
      assert after_failure["memory"]["stored_keys"] == ["baseline"]
    end

    test "legacy signature is rejected" do
      session_id = start_session()

      envelope =
        Tools.call(%{
          "name" => "lisp_session_eval",
          "arguments" => %{
            "session_id" => session_id,
            "program" => "{:count (+ 1 2)}",
            "signature" => "() -> {count :int}"
          }
        })

      assert envelope["isError"] == true
      assert envelope["structuredContent"]["reason"] == "session_args_error"
      assert envelope["structuredContent"]["message"] =~ "no longer supported"
    end

    test "output_schema with legacy signature is an args_error before the gate" do
      session_id = start_session()

      envelope =
        Tools.call(%{
          "name" => "lisp_session_eval",
          "arguments" => %{
            "session_id" => session_id,
            "program" => "42",
            "output_schema" => %{"type" => "integer"},
            "signature" => "() -> int"
          }
        })

      assert envelope["isError"] == true
      assert envelope["structuredContent"]["reason"] == "session_args_error"
      assert envelope["structuredContent"]["message"] =~ "no longer supported"
    end

    test "malformed output_schema is an args_error" do
      session_id = start_session()

      envelope =
        Tools.call(%{
          "name" => "lisp_session_eval",
          "arguments" => %{
            "session_id" => session_id,
            "program" => "42",
            "output_schema" => "not-a-map"
          }
        })

      assert envelope["isError"] == true
      assert envelope["structuredContent"]["reason"] == "session_args_error"
      assert envelope["structuredContent"]["message"] =~ "output_schema"
    end

    test "eval without output_schema works exactly as before (no `validated` field)" do
      session_id = start_session()

      response = eval(session_id, "(+ 1 2)")

      assert response["status"] == "ok"
      refute Map.has_key?(response, "validated")
    end

    # Regression for codex P1 on this fix: validation must work on the
    # JSON-RPC/stdio path too, not just the direct `Tools.call` path. That
    # path goes via Sessions.reserve_eval/eval_reserved, which previously
    # dropped `:parsed_signature` when building the reservation.
    test "reserve_eval/eval_reserved path threads parsed_signature through" do
      session_id = start_session()

      {:ok, validated} =
        Sessions.validate_eval(%{
          "session_id" => session_id,
          "program" => "\"not-an-integer\"",
          "output_schema" => %{"type" => "integer"}
        })

      assert validated.parsed_signature != nil

      {:ok, reservation} = Sessions.reserve_eval(validated, make_ref())
      assert reservation.opts[:parsed_signature] == validated.parsed_signature

      envelope = Sessions.eval_reserved(reservation)
      assert envelope["isError"] == true
      assert envelope["structuredContent"]["reason"] == "validation_error"
    end

    # Regression for codex P2-1 and the latent sentinel leak: programs
    # using `(return v)` wrap step.return in {:__ptc_return__, v}. The
    # session response — `result`, `*1` history, and `validated` — must
    # all see the unwrapped value, mirroring the stateless renderer.
    test "(return v) is unwrapped before validation and across the response" do
      session_id = start_session()

      response =
        eval(session_id, "(return 42)", output_schema: %{"type" => "integer"})

      assert response["status"] == "ok"
      assert response["validated"] == 42
      assert response["result"] == "user=> 42"

      # The next eval's *1 history reference must see 42, not the sentinel.
      followup = eval(session_id, "*1")
      assert followup["status"] == "ok"
      assert followup["result"] == "user=> 42"
    end

    test "non-contracted (return v) is also unwrapped (was a latent leak)" do
      session_id = start_session()

      response = eval(session_id, "(return 7)")
      assert response["status"] == "ok"
      assert response["result"] == "user=> 7"

      followup = eval(session_id, "*1")
      assert followup["result"] == "user=> 7"
    end

    test "legacy optional signature is rejected" do
      session_id = start_session()

      envelope =
        Tools.call(%{
          "name" => "lisp_session_eval",
          "arguments" => %{
            "session_id" => session_id,
            "program" => "nil",
            "signature" => "() -> :int?"
          }
        })

      assert envelope["isError"] == true
      assert envelope["structuredContent"]["reason"] == "session_args_error"
      assert envelope["structuredContent"]["message"] =~ "no longer supported"
    end

    test "tool advertises output_schema but not signature in inputSchema" do
      tool =
        Tools.list()["tools"]
        |> Enum.find(&(&1["name"] == "lisp_session_eval"))

      props = tool["inputSchema"]["properties"]
      assert Map.has_key?(props, "output_schema")
      refute Map.has_key?(props, "signature")
      assert props["output_schema"]["type"] == "object"
    end
  end

  defp start_session do
    call!("lisp_session_start", %{})["session_id"]
  end

  defp eval(session_id, program, extra \\ []) do
    base = %{"session_id" => session_id, "program" => program}

    args =
      Enum.reduce(extra, base, fn
        {:output_schema, v}, acc -> Map.put(acc, "output_schema", v)
      end)

    call!("lisp_session_eval", args)
  end

  defp call!(name, args) do
    envelope = Tools.call(%{"name" => name, "arguments" => args})
    envelope["structuredContent"]
  end

  defp large_string_vector_program do
    value = String.duplicate("x", 80)

    items =
      1..400
      |> Enum.map_join(" ", fn _ -> Jason.encode!(value) end)

    "[" <> items <> "]"
  end

  defp stop_sessions_processes do
    stop_if_alive(SessionsRegistry)
    stop_if_alive(PtcRunnerMcp.Sessions.Supervisor)
    stop_if_alive(PtcRunnerMcp.Sessions.Names)
  end

  defp stop_if_alive(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> stop_process(pid)
    end
  end

  defp stop_process(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, 5_000)
    end
  catch
    :exit, _ -> :ok
  end
end
