defmodule PtcRunner.SubAgent.PreludeE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  End-to-end tests for Capability Preludes using REAL LLM calls.

  Run with:
      mix test test/ptc_runner/sub_agent/prelude_e2e_test.exs --include e2e

  Requires OPENROUTER_API_KEY. Optionally set PTC_TEST_MODEL (defaults to gemini).

  ## Why these tests are meaningful (non-shortcuttable)

  The model is shown ONLY each export's docstring + signature in the prompt
  inventory — never the body. Each export returns an UNGUESSABLE value via an
  opaque internal lookup. So a correct answer can only come from the model
  actually calling the prelude export: if `risk-score "c-100"` comes back as the
  exact magic number, the program must have invoked `acme/risk-score`. The value
  IS the proof of invocation — no trace inspection needed.

  These are the deterministic capture tests' (`prelude_feedback_capture_test.exs`)
  stochastic counterpart: that file pins the prompt+feedback contract with a mock;
  this file checks a real model actually discovers and calls exports. Treat a
  single pass as a smoke signal, not a pass-rate claim (see the llm-benchmark
  skill for statistical runs).
  """

  @moduletag :e2e

  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.SubAgent
  alias PtcRunner.TestSupport.LispTestLLM
  alias PtcRunner.TestSupport.LLM
  alias PtcRunner.TestSupport.LLMSupport

  @timeout 30_000

  # Two pure exports with hidden, unguessable bodies:
  #   acme/risk-score      — :prompt (listed in the inventory)
  #   acme/account-balance — :discoverable (omitted; reachable via discovery)
  @prelude_source """
  (ns acme "Acme deployment helpers." {:visibility :prompt})

  (defn risk-score
    "Return the internal risk score for a customer id string (opaque lookup)."
    [id]
    (get {"c-100" 137 "c-200" 58} id -1))

  (defn account-balance
    "Return the internal account balance for an account id string (opaque lookup)."
    {:visibility :discoverable}
    [id]
    (get {"a-1" 909 "a-2" 410} id -1))
  """

  setup_all do
    # Shared check loads .env first (Dotenv only sets unset vars, so CLI env still
    # wins) and uses requires_api_key?/1 — so the documented `mix test --include e2e`
    # invocation works with the key in `.env`, no manual `source .env` needed.
    LLMSupport.ensure_api_key!(model())
    {:ok, prelude} = Compiler.compile(@prelude_source)
    IO.puts("\n=== Capability Prelude E2E ===")
    IO.puts("Model: #{model()}\n")
    %{prelude: prelude}
  end

  describe "real LLM uses a capability prelude" do
    test "calls a prompt-visible export it can only learn from the inventory", %{prelude: prelude} do
      agent =
        SubAgent.new(
          prompt:
            "Look up the risk score for customer \"c-100\" using the available " <>
              "capabilities, and return just that number.",
          signature: "() -> :int",
          runtime_prelude: prelude,
          max_turns: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm_callback(), timeout: @timeout)

      # 137 is unguessable from the docstring alone -> the model must have called
      # acme/risk-score to get it.
      assert step.return == 137,
             "expected 137 (proves acme/risk-score was called); got: #{inspect(step.return)} " <>
               "fail: #{inspect(step.fail)}"
    end

    test "discovers and calls a :discoverable export omitted from the inventory", %{
      prelude: prelude
    } do
      # account-balance is NOT in the prompt inventory; the model must reach for a
      # discovery form (ns-publics / apropos / dir) before it can call it. This is
      # the highest-variance behavioral claim in the design — keep that in mind if
      # it ever flakes on a weaker model.
      agent =
        SubAgent.new(
          prompt:
            "Find the account balance for account \"a-1\". The capability may not be " <>
              "listed directly — discover what the `acme` namespace exposes (e.g. via " <>
              "(ns-publics 'acme) or (apropos ...)) if you need to. Return just the number.",
          signature: "() -> :int",
          runtime_prelude: prelude,
          max_turns: 4
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm_callback(), timeout: @timeout)

      assert step.return == 909,
             "expected 909 (proves acme/account-balance was discovered + called); got: " <>
               "#{inspect(step.return)} fail: #{inspect(step.fail)}"
    end
  end

  describe "real LLM calls a tool-backed export" do
    test "the model calls a tool-backed export and surfaces the tool's result" do
      # vault/lookup! wraps a PRIVATE helper that calls (tool/call ...), so it is
      # tool-backed (non-empty tool_refs -> routes through Loop.run) and aborts on
      # failure. The model sees only the export's docstring/signature, never the
      # body or the private helper.
      vault_source = """
      (ns vault "Vault helpers." {:visibility :prompt})

      (defn- raw-lookup
        [id]
        (tool/call {:server "vault" :tool "secret" :args {:id id}}))

      (defn lookup!
        "Return the secret record for a customer id, aborting on failure."
        [id]
        (let [res (raw-lookup id)]
          (if (res :ok) (res :value) (fail {:reason (res :reason)}))))
      """

      {:ok, prelude} = Compiler.compile(vault_source)

      # The real tool the export wraps. It returns an UNGUESSABLE code derived
      # from the id, so a correct answer proves vault/lookup! -> tool/call ran:
      # the model cannot produce "ZX-alpha-42" from the docstring alone.
      call_tool = fn args ->
        id = get_in(args, ["args", "id"]) || get_in(args, [:args, :id])
        %{ok: true, value: %{"code" => "ZX-#{id}-42"}, reason: nil}
      end

      agent =
        SubAgent.new(
          prompt:
            "Look up the secret for id \"alpha\" using the available capabilities, " <>
              "and return its code.",
          signature: "() -> :string",
          runtime_prelude: prelude,
          tools: %{"call" => call_tool},
          max_turns: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm_callback(), timeout: @timeout)

      assert step.return == "ZX-alpha-42",
             "expected the tool-derived code (proves the tool-backed export ran); got: " <>
               "#{inspect(step.return)} fail: #{inspect(step.fail)}"
    end
  end

  defp model, do: LispTestLLM.model()

  defp llm_callback do
    fn %{system: system, messages: messages} ->
      full_messages = [%{role: :system, content: system} | messages]

      case LLM.generate_text(model(), full_messages, receive_timeout: @timeout) do
        {:ok, text} -> {:ok, text}
        {:error, _} = error -> error
      end
    end
  end
end
