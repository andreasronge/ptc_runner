defmodule PtcRunner.SubAgent.RuntimePreludeTest do
  @moduledoc """
  P5: a compiled prelude attaches to SubAgent execution via the
  `runtime_prelude:` field on `%PtcRunner.SubAgent.Definition{}` and flows
  through `LispOpts.build/4` -> `Lisp.run(prelude:)` (the single attach seam).

  The dynamic prompt-inventory section is inserted through
  `SystemPrompt.generate_context/2` (dynamic context assembly), NOT static core
  prompt templates — and the CORE templates must stay DOMAIN-BLIND (no "crm").
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.SubAgent.Loop.LispOpts
  alias PtcRunner.SubAgent.Loop.State
  alias PtcRunner.SubAgent.SystemPrompt

  @crm_source """
  (ns crm
    "CRM helpers."
    {:visibility :prompt})

  (defn get-user
    "Return a CRM user by id."
    [id]
    (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
  """

  setup do
    {:ok, prelude} = Compiler.compile(@crm_source)
    %{prelude: prelude}
  end

  describe "Definition.runtime_prelude" do
    test "accepts a compiled prelude artifact", %{prelude: prelude} do
      agent = PtcRunner.SubAgent.new(prompt: "x", runtime_prelude: prelude)
      assert agent.runtime_prelude == prelude
    end

    test "defaults to nil" do
      agent = PtcRunner.SubAgent.new(prompt: "x")
      assert agent.runtime_prelude == nil
    end

    test "rejects a non-prelude value" do
      assert_raise ArgumentError, fn ->
        PtcRunner.SubAgent.new(prompt: "x", runtime_prelude: %{not: :a_prelude})
      end
    end
  end

  describe "LispOpts.build threads runtime_prelude as :prelude" do
    test "passes the prelude artifact through to Lisp.run opts", %{prelude: prelude} do
      agent = PtcRunner.SubAgent.new(prompt: "x", runtime_prelude: prelude)
      state = state_fixture()

      opts = LispOpts.build(agent, state, %{}, %{})
      assert Keyword.get(opts, :prelude) == prelude
    end

    test "omits :prelude when no runtime_prelude is configured" do
      agent = PtcRunner.SubAgent.new(prompt: "x")
      opts = LispOpts.build(agent, state_fixture(), %{}, %{})
      refute Keyword.has_key?(opts, :prelude)
    end

    defp state_fixture do
      %State{
        llm: fn _ -> {:error, :stub} end,
        context: %{},
        turn: 1,
        messages: [],
        start_time: 0,
        work_turns_remaining: 5
      }
    end
  end

  describe "SystemPrompt.generate_context inserts the prompt inventory after tools/data" do
    test "renders the prelude inventory with the compact crm/get-user entry", %{prelude: prelude} do
      agent = PtcRunner.SubAgent.new(prompt: "x", runtime_prelude: prelude)
      context_prompt = SystemPrompt.generate_context(agent, context: %{user_id: "u_1"})

      assert context_prompt =~ "crm/get-user"
      assert context_prompt =~ "(get-user id)"
      assert context_prompt =~ "Return a CRM user by id."

      # Inserted AFTER the data/ and tools sections.
      data_idx = index_of(context_prompt, "=== data/ ===")
      prelude_idx = index_of(context_prompt, "=== prelude capabilities ===")
      assert is_integer(data_idx)
      assert is_integer(prelude_idx)
      assert prelude_idx > data_idx
    end

    test "no prelude section when no runtime_prelude is configured" do
      agent = PtcRunner.SubAgent.new(prompt: "x")
      context_prompt = SystemPrompt.generate_context(agent, context: %{})
      refute context_prompt =~ "=== prelude capabilities ==="
      refute context_prompt =~ "crm/get-user"
    end

    defp index_of(haystack, needle) do
      case :binary.match(haystack, needle) do
        {start, _len} -> start
        :nomatch -> nil
      end
    end
  end

  describe "core prompt templates stay domain-blind" do
    test "the static system prompt contains no deployment-specific terms", %{prelude: prelude} do
      # Even with a crm prelude attached, the STATIC (cacheable) system prompt
      # must not contain deployment-specific terms — those live only in the
      # dynamic context section.
      agent = PtcRunner.SubAgent.new(prompt: "x", runtime_prelude: prelude)
      static = SystemPrompt.generate_system(agent)

      # The crm prelude's namespace name must not leak into the cacheable static
      # prompt; only the dynamic context section carries deployment-specific
      # terms. ("get-user" is intentionally NOT asserted here: it appears as a
      # coincidental substring of the generic example tool `(tool/get-users …)`.)
      refute static =~ "crm"
      refute static =~ "=== prelude capabilities ==="
    end

    test "every shipped core prompt template is domain-blind" do
      Path.wildcard("priv/prompts/*.md")
      |> Enum.each(fn path ->
        contents = File.read!(path)
        refute contents =~ "crm", "core template #{path} must not mention 'crm'"
      end)
    end
  end

  describe "end-to-end SubAgent execution resolves prelude exports (codex round 5 #2)" do
    @pure_prelude """
    (ns greet "Greeting helpers." {:visibility :prompt})
    (defn hello [name] (str "hi " name))
    """

    test "the single-shot fast path (max_turns: 1) attaches the prelude" do
      {:ok, prelude} = Compiler.compile(@pure_prelude)

      agent =
        PtcRunner.SubAgent.new(
          prompt: "Greet {{name}}",
          signature: "(name :string) -> {msg :string}",
          runtime_prelude: prelude,
          max_turns: 1
        )

      # max_turns: 1 + no tools routes through Runner.run_single_shot, a SEPARATE
      # execution path from the multi-turn Loop. Without the prelude attached
      # there, `(greet/hello ...)` would fail with an unknown namespace.
      mock_llm = fn _ -> {:ok, ~S|(return {:msg (greet/hello data/name)})|} end

      assert {:ok, step} =
               PtcRunner.SubAgent.run(agent, llm: mock_llm, context: %{"name" => "ada"})

      assert step.return["msg"] == "hi ada"
    end

    @tool_backed_prelude """
    (ns find "Find helpers." {:visibility :prompt})
    (defn lines [pat text] (tool/grep {:pattern pat :text text}))
    """

    test "a tool-backed prelude (max_turns: 1, no declared tools) runs through the loop" do
      # `find/lines` wraps `(tool/grep ...)`, so its `tool_refs` is non-empty.
      # The single-shot fast path runs with `tools: %{}` and could not back that
      # call (the export would be advertised but fail preflight). Runner routes a
      # tool-backed prelude to `Loop.run/2`, whose `effective_tools` supplies the
      # `:grep` builtin so the wrapped call actually resolves.
      {:ok, prelude} = Compiler.compile(@tool_backed_prelude)

      agent =
        PtcRunner.SubAgent.new(
          prompt: "Find {{pat}}",
          signature: "(pat :string) -> {out :any}",
          runtime_prelude: prelude,
          builtin_tools: [:grep],
          max_turns: 1
        )

      mock_llm = fn _ -> {:ok, ~S|(return {:out (find/lines data/pat "a\nb\nc\nbb")})|} end

      assert {:ok, step} =
               PtcRunner.SubAgent.run(agent, llm: mock_llm, context: %{"pat" => "b"})

      assert step.return["out"] == ["b", "bb"]
    end
  end
end
