defmodule PtcRunner.PtcToolProtocolTest do
  use ExUnit.Case, async: true

  alias PtcRunner.PtcToolProtocol
  alias PtcRunner.SubAgent.Loop.PtcToolCall

  doctest PtcRunner.PtcToolProtocol

  # ================================================================
  # tool_description/1 — capability profiles
  # ================================================================

  describe "tool_description/1 — capability profiles" do
    test ":in_process_with_app_tools matches the legacy v1 string byte-for-byte" do
      # Addendum #10: the v1 PTC `:tool_call` transport string is the
      # locked baseline. PtcToolCall.tool_description/0 delegates here,
      # so this asserts both the legacy public surface and the new
      # protocol module agree.
      assert PtcToolProtocol.tool_description(:in_process_with_app_tools) ==
               PtcToolCall.tool_description()
    end

    test ":in_process_with_app_tools — stable substring (only lisp_eval is native)" do
      desc = PtcToolProtocol.tool_description(:in_process_with_app_tools)
      assert desc =~ "only `lisp_eval` is available natively"
      assert desc =~ "Call app tools as `(tool/name ...)` from inside the program"
    end

    test ":in_process_text_mode — stable substring (combined-mode rule)" do
      desc = PtcToolProtocol.tool_description(:in_process_text_mode)

      assert desc =~
               "in this assistant turn, but not in the same turn as `lisp_eval`"

      assert desc =~ "Call `:both`-exposed app tools as `(tool/name ...)` from inside the program"
    end

    test ":mcp_no_tools — stable substring (no app tools, context arg)" do
      desc = PtcToolProtocol.tool_description(:mcp_no_tools)
      assert desc =~ "No app tools are available inside the program"
      assert desc =~ "Pass external data via the `context` argument"
      assert desc =~ "each invocation is independent"
    end

    test "all three profiles return distinct strings" do
      a = PtcToolProtocol.tool_description(:in_process_with_app_tools)
      b = PtcToolProtocol.tool_description(:in_process_text_mode)
      c = PtcToolProtocol.tool_description(:mcp_no_tools)

      assert a != b
      assert b != c
      assert a != c
    end
  end

  # ================================================================
  # render_success/2
  # ================================================================

  # A representative `lisp_step`-like map. The renderer only consults
  # `:return`, but pinning a realistic shape documents the contract.
  defp lisp_step(return) do
    %{return: return}
  end

  defp execution_map(overrides) do
    base = %{
      result: nil,
      prints: [],
      feedback: "ok",
      memory: %{
        changed: false,
        stored_keys: [],
        truncated: false
      },
      visible_truncated: false,
      truncated: false
    }

    Map.merge(base, overrides)
  end

  describe "render_success/2 — JSON payload shape" do
    test "encodes status, result, prints, feedback, memory, truncated when result present" do
      json =
        PtcToolProtocol.render_success(
          lisp_step(42),
          execution: execution_map(%{result: 42, prints: ["hi"], feedback: "computed 42"})
        )

      decoded = Jason.decode!(json)

      assert decoded["status"] == "ok"
      assert decoded["result"] == 42
      assert decoded["prints"] == ["hi"]
      assert decoded["feedback"] == "computed 42"
      assert decoded["memory"] == %{"changed" => false, "stored_keys" => [], "truncated" => false}
      assert decoded["truncated"] == false
    end

    test "drops `result` field when both execution.result and lisp_step.return are nil" do
      json =
        PtcToolProtocol.render_success(
          lisp_step(nil),
          execution: execution_map(%{result: nil})
        )

      decoded = Jason.decode!(json)
      refute Map.has_key?(decoded, "result")
    end

    test "keeps `result` field (as null) when execution.result is nil but lisp_step.return is present" do
      json =
        PtcToolProtocol.render_success(
          lisp_step("non-nil-return"),
          execution: execution_map(%{result: nil})
        )

      decoded = Jason.decode!(json)
      assert Map.has_key?(decoded, "result")
      assert decoded["result"] == nil
    end

    test "keeps `result` field when execution.result is non-nil even if lisp_step.return is nil" do
      json =
        PtcToolProtocol.render_success(
          lisp_step(nil),
          execution: execution_map(%{result: "x"})
        )

      decoded = Jason.decode!(json)
      assert decoded["result"] == "x"
    end

    test "memory.{changed,stored_keys,truncated} are surfaced verbatim by default" do
      json =
        PtcToolProtocol.render_success(
          lisp_step(1),
          execution:
            execution_map(%{
              result: 1,
              memory: %{changed: true, stored_keys: ["a", "b"], truncated: true}
            })
        )

      decoded = Jason.decode!(json)

      assert decoded["memory"] == %{
               "changed" => true,
               "stored_keys" => ["a", "b"],
               "truncated" => true
             }
    end

    # Issue #879: include_memory: false opt drops the memory key entirely.
    # render_success_from_step/2 (the one-shot wrapper used by the MCP
    # server) sets this to false because state never persists across calls.
    test "include_memory: false opt drops the memory key (issue #879)" do
      json =
        PtcToolProtocol.render_success(
          lisp_step(1),
          execution:
            execution_map(%{
              result: 1,
              memory: %{changed: true, stored_keys: ["a"], truncated: false}
            }),
          include_memory: false
        )

      decoded = Jason.decode!(json)

      refute Map.has_key?(decoded, "memory"),
             "include_memory: false should omit memory key: #{inspect(decoded)}"
    end

    # Codex review of ece7f13: when memory is hidden but a hidden memory
    # preview was clipped, the top-level `truncated` flag would still
    # read `true`, misleading callers into thinking their visible output
    # was incomplete. Renderer must use :visible_truncated when memory
    # is hidden.
    test "include_memory: false uses visible_truncated, not memory's truncated" do
      json =
        PtcToolProtocol.render_success(
          lisp_step(1),
          execution: %{
            result: 1,
            prints: [],
            feedback: "",
            memory: %{changed: false, stored_keys: [], truncated: true},
            visible_truncated: false,
            truncated: true
          },
          include_memory: false
        )

      decoded = Jason.decode!(json)

      assert decoded["truncated"] == false,
             "top-level truncated should reflect only visible fields when memory is hidden: " <>
               inspect(decoded)
    end

    test "include_memory: false still reports truncated=true when prints/result were truncated" do
      json =
        PtcToolProtocol.render_success(
          lisp_step(1),
          execution: %{
            result: 1,
            prints: [],
            feedback: "",
            memory: %{changed: false, stored_keys: [], truncated: false},
            visible_truncated: true,
            truncated: true
          },
          include_memory: false
        )

      assert Jason.decode!(json)["truncated"] == true
    end

    test "top-level truncated is surfaced verbatim" do
      json =
        PtcToolProtocol.render_success(
          lisp_step(1),
          execution: execution_map(%{result: 1, truncated: true})
        )

      assert Jason.decode!(json)["truncated"] == true
    end

    test "validated: opt — when present, included as `validated` field" do
      json =
        PtcToolProtocol.render_success(
          lisp_step(1),
          execution: execution_map(%{result: 1}),
          validated: %{"count" => 7}
        )

      decoded = Jason.decode!(json)
      assert decoded["validated"] == %{"count" => 7}
    end

    test "validated: opt — when absent, no `validated` field present" do
      json =
        PtcToolProtocol.render_success(
          lisp_step(1),
          execution: execution_map(%{result: 1})
        )

      decoded = Jason.decode!(json)
      refute Map.has_key?(decoded, "validated")
    end

    test "ignores unknown opts without raising (Addendum #12)" do
      json =
        PtcToolProtocol.render_success(
          lisp_step(1),
          execution: execution_map(%{result: 1}),
          some_future_opt: :ignored,
          another: 42
        )

      assert is_binary(json)
      decoded = Jason.decode!(json)
      assert decoded["status"] == "ok"
    end
  end

  # ================================================================
  # render_error/3 — every error_reason() member
  # ================================================================

  describe "render_error/3 — :fail (Addendum #4: only reason carrying a result)" do
    test "encodes reason=fail, message, feedback (default = message), and result from opt" do
      json = PtcToolProtocol.render_error(:fail, "boom", result: "{:bad-input 42}")
      decoded = Jason.decode!(json)

      assert decoded["status"] == "error"
      assert decoded["reason"] == "fail"
      assert decoded["message"] == "boom"
      assert decoded["feedback"] == "boom"
      assert decoded["result"] == "{:bad-input 42}"
    end

    test "carries the result value verbatim — including non-string preview" do
      json = PtcToolProtocol.render_error(:fail, "msg", result: nil)
      decoded = Jason.decode!(json)

      assert Map.has_key?(decoded, "result")
      assert decoded["result"] == nil
    end

    test "feedback: opt overrides the default" do
      json = PtcToolProtocol.render_error(:fail, "raw", result: "v", feedback: "polished")
      assert Jason.decode!(json)["feedback"] == "polished"
    end
  end

  describe "render_error/3 — non-:fail reasons never carry a `result` field" do
    for reason <- [
          :parse_error,
          :runtime_error,
          :timeout,
          :memory_limit,
          :args_error,
          :validation_error
        ] do
      test "reason=#{reason} encodes status/reason/message/feedback and omits result" do
        reason = unquote(reason)
        json = PtcToolProtocol.render_error(reason, "something went wrong")
        decoded = Jason.decode!(json)

        assert decoded["status"] == "error"
        assert decoded["reason"] == Atom.to_string(reason)
        assert decoded["message"] == "something went wrong"
        assert decoded["feedback"] == "something went wrong"
        refute Map.has_key?(decoded, "result")
      end

      test "reason=#{reason} ignores `result:` opt (only :fail honors it)" do
        reason = unquote(reason)
        json = PtcToolProtocol.render_error(reason, "msg", result: "ignored")
        decoded = Jason.decode!(json)

        refute Map.has_key?(decoded, "result")
      end

      test "reason=#{reason} respects `feedback:` opt override" do
        reason = unquote(reason)
        json = PtcToolProtocol.render_error(reason, "msg", feedback: "custom")
        assert Jason.decode!(json)["feedback"] == "custom"
      end
    end
  end

  describe "render_error/3 — opts contract" do
    test "ignores unknown opts without raising (Addendum #12)" do
      json = PtcToolProtocol.render_error(:runtime_error, "msg", future_field: 1, hint: :nope)
      assert is_binary(json)
      assert Jason.decode!(json)["reason"] == "runtime_error"
    end

    test "feedback defaults to message across all reasons" do
      for reason <- [
            :parse_error,
            :runtime_error,
            :timeout,
            :memory_limit,
            :args_error,
            :fail,
            :validation_error
          ] do
        opts = if reason == :fail, do: [result: "v"], else: []
        json = PtcToolProtocol.render_error(reason, "msg-#{reason}", opts)
        assert Jason.decode!(json)["feedback"] == "msg-#{reason}"
      end
    end
  end

  # ================================================================
  # render_success_from_step/2 — § 13.1 high-level wrapper
  # ================================================================

  describe "render_success_from_step/2 — round-trip from Lisp.run/2" do
    test "renders `(+ 1 2)` as status:ok with EDN-rendered result preview" do
      {:ok, step} = PtcToolProtocol.lisp_run("(+ 1 2)")
      decoded = step |> PtcToolProtocol.render_success_from_step() |> Jason.decode!()

      assert decoded["status"] == "ok"
      assert decoded["result"] == "user=> 3"
      assert decoded["prints"] == []
      assert is_binary(decoded["feedback"])
      assert decoded["truncated"] == false

      # Issue #879: render_success_from_step is the canonical one-shot
      # wrapper. State never persists across calls, so memory is omitted.
      refute Map.has_key?(decoded, "memory"),
             "render_success_from_step should omit memory: #{inspect(decoded)}"
    end

    test "drops `result` when program returns nil (println-only)" do
      {:ok, step} = PtcToolProtocol.lisp_run("(println \"hi\")")
      decoded = step |> PtcToolProtocol.render_success_from_step() |> Jason.decode!()

      assert decoded["status"] == "ok"
      refute Map.has_key?(decoded, "result")
      assert decoded["prints"] == ["hi"]
    end

    test "forwards :validated opt into the rendered payload" do
      {:ok, step} = PtcToolProtocol.lisp_run("(+ 1 2)")

      decoded =
        step
        |> PtcToolProtocol.render_success_from_step(validated: %{"count" => 3})
        |> Jason.decode!()

      assert decoded["validated"] == %{"count" => 3}
    end

    test "ignores unknown opts (Addendum #12)" do
      {:ok, step} = PtcToolProtocol.lisp_run("(+ 1 2)")

      decoded =
        step
        |> PtcToolProtocol.render_success_from_step(future_field: :whatever)
        |> Jason.decode!()

      assert decoded["status"] == "ok"
    end
  end

  # ================================================================
  # Re-exports
  # ================================================================

  describe "re-exports" do
    test "lisp_run/2 delegates to PtcRunner.Lisp.run/2" do
      {:ok, step} = PtcToolProtocol.lisp_run("(+ 1 2)")
      assert step.return == 3
    end

    test "atomize_value/2 delegates to JsonHandler.atomize_value/2" do
      # No type info → maps with binary keys get atomized via
      # safe_to_atom (string→existing atom, falls back to string).
      result = PtcToolProtocol.atomize_value(%{"unknown_key_xyz" => 1}, nil)
      # The string key has no existing atom, so it stays a string.
      assert result == %{"unknown_key_xyz" => 1}
    end

    test "validate_return/2 delegates to JsonHandler.validate_return/2 — nil signature is :ok" do
      assert PtcToolProtocol.validate_return(%{parsed_signature: nil}, "anything") == :ok
    end
  end

  describe "to_json_value/1 — codex review fixes" do
    test "rejects integer map keys (would silently collide with string equivalents)" do
      # %{1 => "a", "1" => "b"} is the collision case — without rejection
      # both keys would map to "1" and one would overwrite the other.
      assert {:error, msg} = PtcToolProtocol.to_json_value(%{1 => "a", "1" => "b"})
      assert is_binary(msg)
    end

    test "rejects a single integer-keyed map (not just collision case)" do
      assert {:error, _} = PtcToolProtocol.to_json_value(%{42 => "value"})
    end

    test "still accepts atom and binary keys" do
      assert {:ok, %{"a" => 1, "b" => 2}} =
               PtcToolProtocol.to_json_value(%{:a => 1, "b" => 2})
    end
  end
end
