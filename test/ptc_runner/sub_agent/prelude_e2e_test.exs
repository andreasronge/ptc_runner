defmodule PtcRunner.SubAgent.PreludeE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  End-to-end tests for Capability Preludes using REAL LLM calls.

  Run with:
      mix test test/ptc_runner/sub_agent/prelude_e2e_test.exs --include e2e

  Requires OPENROUTER_API_KEY. Optionally set PTC_TEST_MODEL (defaults to gemini).

  ## Domain-blind + non-shortcuttable

  Prompts and fixtures are deliberately domain-NEUTRAL (generic `reg`/`svc`
  namespaces, opaque ids, opaque values) per the repo's domain-blind test-prompt
  rule — they encode no business domain or expected answer pattern. The model is
  shown ONLY each export's docstring + signature in the prompt inventory, never
  the body, and each export returns an UNGUESSABLE value, so a correct answer can
  only come from the model actually calling the export (the value IS the proof of
  invocation). The tool-backed tests additionally assert the tool callback fired
  (`assert_receive`), making that guarantee explicit rather than inferential.

  These are the deterministic capture tests' (`prelude_feedback_capture_test.exs`)
  stochastic counterpart. Treat a single pass as a smoke signal, not a pass-rate
  claim (see the llm-benchmark skill for statistical runs).
  """

  @moduletag :e2e

  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.SubAgent
  alias PtcRunner.TestSupport.LispTestLLM
  alias PtcRunner.TestSupport.LLM
  alias PtcRunner.TestSupport.LLMSupport

  @timeout 30_000

  # One pure, prompt-visible export with a hidden, unguessable body.
  @prelude_source """
  (ns reg "Registry helpers." {:visibility :prompt})

  (defn value-of
    "Return the registered value for a key string (opaque lookup)."
    [key]
    (get {"k-100" 137 "k-200" 58} key -1))
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
            "Look up the registered value for key \"k-100\" using the available " <>
              "capabilities, and return just that number.",
          signature: "() -> :int",
          runtime_prelude: prelude,
          max_turns: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm_callback(), timeout: @timeout)

      # 137 is unguessable from the docstring alone -> the model must have called
      # reg/value-of to get it.
      assert step.return == 137,
             "expected 137 (proves reg/value-of was called); got: #{inspect(step.return)} " <>
               "fail: #{inspect(step.fail)}"
    end

    test "discovers and calls a :discoverable export omitted from the inventory" do
      # The needed export (cat/lookup) is :discoverable, so it is NOT in the prompt
      # inventory. A prompt-visible DECOY (cat/size) IS listed but is an obvious
      # non-fit — a zero-arg count, not a keyed lookup — so the model cannot
      # shortcut to it and must reach for a discovery form (ns-publics / apropos)
      # to find lookup. This is the test's subject: DISCOVERY.
      #
      # lookup accepts the key as a bare string OR wrapped in a map, because
      # discovery currently surfaces only a generic `(lookup arg1)` arity (no
      # param name/type — see private/Plans/prelude-param-names-and-typed-signatures.md),
      # so a model legitimately guesses the call shape. Tolerating both isolates
      # this test to discovery rather than arg-convention guessing.
      cat_source = """
      (ns cat "Catalog helpers." {:visibility :prompt})

      (defn size
        "Return how many entries the catalog has."
        []
        2)

      (defn lookup
        "Return the cataloged value for a key string (opaque lookup)."
        {:visibility :discoverable}
        [k]
        (get {"r-1" 909 "r-2" 410}
             (if (map? k) (or (get k :key) (get k "key")) k)
             -1))
      """

      {:ok, prelude} = Compiler.compile(cat_source)

      agent =
        SubAgent.new(
          prompt:
            "Find the cataloged value for key \"r-1\". The capability you need may " <>
              "not be listed directly — discover what the `cat` namespace exposes " <>
              "(e.g. via (ns-publics 'cat) or (apropos \"...\")), then call it. " <>
              "Return just the number.",
          signature: "() -> :int",
          runtime_prelude: prelude,
          max_turns: 4
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm_callback(), timeout: @timeout)

      assert step.return == 909,
             "expected 909 (proves cat/lookup was discovered + called, not the " <>
               "visible decoy cat/size); got: #{inspect(step.return)} fail: #{inspect(step.fail)}"
    end
  end

  describe "real LLM calls a tool-backed export" do
    test "the model calls a tool-backed export and surfaces the tool's result" do
      # svc/fetch! wraps a PRIVATE helper that calls (tool/call ...), so it is
      # tool-backed (non-empty tool_refs -> routes through Loop.run) and aborts on
      # failure. The model sees only the export's docstring/signature.
      svc_source = """
      (ns svc "Service helpers." {:visibility :prompt})

      (defn- raw-fetch
        [key]
        (tool/call {:server "svc" :tool "fetch" :args {:key key}}))

      (defn fetch!
        "Return the record for a key string, aborting on failure."
        [key]
        (let [res (raw-fetch key)]
          (if (res :ok) (res :value) (fail {:reason (res :reason)}))))
      """

      {:ok, prelude} = Compiler.compile(svc_source)

      # The real tool the export wraps. It returns an UNGUESSABLE token derived
      # from the key, so a correct answer proves svc/fetch! -> tool/call ran; we
      # also assert the callback fired (assert_receive) to make that explicit.
      parent = self()

      call_tool = fn args ->
        send(parent, {:tool_called, args})
        key = get_in(args, ["args", "key"]) || get_in(args, [:args, :key])
        %{ok: true, value: %{"token" => "TK-#{key}-42"}, reason: nil}
      end

      agent =
        SubAgent.new(
          prompt:
            "Fetch the record for key \"x1\" using the available capabilities, " <>
              "and return its token.",
          signature: "() -> :string",
          runtime_prelude: prelude,
          tools: %{"call" => call_tool},
          max_turns: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm_callback(), timeout: @timeout)

      assert_receive {:tool_called, _args}

      assert step.return == "TK-x1-42",
             "expected the tool-derived token (proves the tool-backed export ran); got: " <>
               "#{inspect(step.return)} fail: #{inspect(step.fail)}"
    end
  end

  describe "real LLM recovers from a recoverable tool failure" do
    test "the model surfaces the :reason from a (:ok false ...) result" do
      # A RECOVERABLE export (plain wrapper, NOT a !-abort): a tool failure comes
      # back as a branchable {:ok false :reason ...} map, not a crash. The
      # docstring states the result-map shape (the export's real contract), so
      # the test measures whether the model ACTS on the failure, not whether it
      # guesses the shape.
      svc_source = """
      (ns svc "Service helpers." {:visibility :prompt})

      (defn submit
        "Submit a key. Returns a result map: (:ok true :value ...) on success,
         or (:ok false :reason ...) on a recoverable failure."
        [key]
        (tool/call {:server "svc" :tool "submit" :args {:key key}}))
      """

      {:ok, prelude} = Compiler.compile(svc_source)

      # The tool fails with an UNGUESSABLE reason. The model can only produce
      # "ERR-7q9z" by calling submit, getting {:ok false ...}, and reading
      # (res :reason); we also assert the callback fired.
      parent = self()

      call_tool = fn args ->
        send(parent, {:tool_called, args})
        %{ok: false, value: nil, reason: "ERR-7q9z"}
      end

      agent =
        SubAgent.new(
          prompt:
            "Try to submit key \"u-9\" using the available capabilities. If it " <>
              "fails, return only the failure reason string, with no other text.",
          signature: "() -> :string",
          runtime_prelude: prelude,
          tools: %{"call" => call_tool},
          max_turns: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm_callback(), timeout: @timeout)

      assert_receive {:tool_called, _args}

      # Strict equality: the prompt asks for ONLY the reason and the signature is
      # () -> :string, so a verbose/malformed answer should fail the test.
      assert step.return == "ERR-7q9z",
             "expected exactly the recoverable :reason (proves the model branched " <>
               "on (:ok false ...)); got: #{inspect(step.return)} fail: #{inspect(step.fail)}"
    end
  end

  defp model, do: LispTestLLM.model()

  defp llm_callback do
    fn %{system: system, messages: messages} ->
      full_messages = [%{role: :system, content: system} | messages]

      case LLM.generate_text(model(), full_messages, receive_timeout: @timeout) do
        {:ok, text} ->
          {:ok, text}

        {:error, _} = error ->
          error
      end
    end
  end
end
