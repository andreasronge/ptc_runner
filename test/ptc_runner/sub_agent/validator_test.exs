defmodule PtcRunner.SubAgent.ValidatorTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  describe "timeout validation" do
    test "accepts positive integer timeout" do
      agent = SubAgent.new(prompt: "Test", timeout: 5000)
      assert agent.timeout == 5000
    end

    test "rejects timeout: 0" do
      assert_raise ArgumentError, ~r/timeout must be a positive integer/, fn ->
        SubAgent.new(prompt: "Test", timeout: 0)
      end
    end

    test "rejects negative timeout" do
      assert_raise ArgumentError, ~r/timeout must be a positive integer/, fn ->
        SubAgent.new(prompt: "Test", timeout: -1)
      end
    end

    test "rejects timeout: nil" do
      assert_raise ArgumentError, ~r/timeout cannot be nil/, fn ->
        SubAgent.new(prompt: "Test", timeout: nil)
      end
    end

    test "uses default timeout when not specified" do
      agent = SubAgent.new(prompt: "Test")
      assert agent.timeout == 5000
    end
  end

  describe "output validation" do
    test "accepts :ptc_lisp output mode" do
      agent = SubAgent.new(prompt: "Test", output: :ptc_lisp)
      assert agent.output == :ptc_lisp
    end

    test "accepts :text output mode with signature" do
      agent = SubAgent.new(prompt: "Test", output: :text, signature: "() -> {x :string}")
      assert agent.output == :text
    end

    test "rejects invalid output mode atom" do
      assert_raise ArgumentError, ~r/output must be :ptc_lisp or :text/, fn ->
        SubAgent.new(prompt: "Test", output: :invalid)
      end
    end

    test "defaults to :ptc_lisp when output not specified" do
      agent = SubAgent.new(prompt: "Test")
      assert agent.output == :ptc_lisp
    end
  end

  describe "text mode constraints" do
    test "accepts text mode with tools" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :text,
          signature: "() -> {x :string}",
          tools: %{foo: fn _ -> :ok end}
        )

      assert agent.output == :text
    end

    test "accepts text mode without signature (plain text return)" do
      agent = SubAgent.new(prompt: "Test", output: :text)
      assert agent.output == :text
      assert agent.parsed_signature == nil
    end

    test "rejects text mode with compression: true" do
      assert_raise ArgumentError, "output: :text cannot be used with compression", fn ->
        SubAgent.new(
          prompt: "Test",
          output: :text,
          signature: "() -> {x :string}",
          compression: true
        )
      end
    end

    test "rejects json mode with compression module" do
      assert_raise ArgumentError, "output: :text cannot be used with compression", fn ->
        SubAgent.new(
          prompt: "Test",
          output: :text,
          signature: "() -> {x :string}",
          compression: SomeModule
        )
      end
    end

    test "accepts json mode with compression: nil" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :text,
          signature: "() -> {x :string}",
          compression: nil
        )

      assert agent.output == :text
    end

    test "accepts json mode with compression: false" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :text,
          signature: "() -> {x :string}",
          compression: false
        )

      assert agent.output == :text
    end

    test "rejects text mode with compaction: true" do
      assert_raise ArgumentError, "output: :text cannot be used with compaction", fn ->
        SubAgent.new(
          prompt: "Test",
          output: :text,
          signature: "() -> {x :string}",
          compaction: true
        )
      end
    end

    test "rejects text mode with compaction keyword" do
      assert_raise ArgumentError, "output: :text cannot be used with compaction", fn ->
        SubAgent.new(
          prompt: "Test",
          output: :text,
          signature: "() -> {x :string}",
          compaction: [trigger: [turns: 5]]
        )
      end
    end

    test "accepts text mode with compaction: nil" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :text,
          signature: "() -> {x :string}",
          compaction: nil
        )

      assert agent.output == :text
      assert agent.compaction == nil
    end

    test "accepts text mode with compaction: false" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :text,
          signature: "() -> {x :string}",
          compaction: false
        )

      assert agent.output == :text
      assert agent.compaction == false
    end

    test "rejects json mode with firewall field in signature" do
      assert_raise ArgumentError,
                   ~r/output: :text signature cannot have firewall fields \(_hidden\)/,
                   fn ->
                     SubAgent.new(
                       prompt: "Test",
                       output: :text,
                       signature: "() -> {_hidden :string}"
                     )
                   end
    end

    test "rejects json mode with nested firewall field in signature" do
      assert_raise ArgumentError,
                   ~r/output: :text signature cannot have firewall fields \(_nested\)/,
                   fn ->
                     SubAgent.new(
                       prompt: "Test",
                       output: :text,
                       signature: "() -> {x {_nested :int}}"
                     )
                   end
    end

    test "rejects json mode with firewall field in array element" do
      assert_raise ArgumentError,
                   ~r/output: :text signature cannot have firewall fields \(_secret\)/,
                   fn ->
                     SubAgent.new(
                       prompt: "Test",
                       output: :text,
                       signature: "() -> {items [{name :string, _secret :string}]}"
                     )
                   end
    end

    test "accepts json mode with non-firewall nested fields" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :text,
          signature: "() -> {user {name :string, email :string}}"
        )

      assert agent.output == :text
    end

    test "accepts json mode with list of primitives" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :text,
          signature: "() -> {items [:string]}"
        )

      assert agent.output == :text
    end

    test "accepts json mode with optional fields (non-firewall)" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :text,
          signature: "() -> {name :string, nickname :string?}"
        )

      assert agent.output == :text
    end

    test "rejects json mode with firewall field inside optional map field" do
      # Optional map field containing another map with firewall field
      assert_raise ArgumentError,
                   ~r/output: :text signature cannot have firewall fields \(_id\)/,
                   fn ->
                     SubAgent.new(
                       prompt: "Test",
                       output: :text,
                       signature: "() -> {data {user :string, _id :int}}"
                     )
                   end
    end
  end

  describe "text mode all-params-used validation" do
    test "rejects text mode with unused signature params" do
      assert_raise ArgumentError,
                   ~r/Text mode requires all signature params in prompt. Unused: \["name"\]/,
                   fn ->
                     SubAgent.new(
                       prompt: "Analyze {{text}}",
                       output: :text,
                       signature: "(text :string, name :string) -> {result :string}"
                     )
                   end
    end

    test "accepts json mode when all params used as variables" do
      agent =
        SubAgent.new(
          prompt: "Analyze {{text}} for {{name}}",
          output: :text,
          signature: "(text :string, name :string) -> {result :string}"
        )

      assert agent.output == :text
    end

    test "accepts json mode when param used in section" do
      agent =
        SubAgent.new(
          prompt: "Process {{#items}}{{name}}{{/items}}",
          output: :text,
          signature: "(items [{name :string}]) -> {count :int}"
        )

      assert agent.output == :text
    end

    test "accepts json mode when param used in inverted section" do
      agent =
        SubAgent.new(
          prompt: "{{^debug}}Production mode{{/debug}}",
          output: :text,
          signature: "(debug :bool) -> {status :string}"
        )

      assert agent.output == :text
    end

    test "accepts zero-param json mode signature" do
      agent =
        SubAgent.new(
          prompt: "Return a greeting",
          output: :text,
          signature: "() -> {greeting :string}"
        )

      assert agent.output == :text
    end
  end

  describe "json mode section field validation" do
    test "accepts valid section fields matching signature" do
      agent =
        SubAgent.new(
          prompt: "{{#items}}{{name}}: {{price}}{{/items}}",
          output: :text,
          signature: "(items [{name :string, price :float}]) -> {total :float}"
        )

      assert agent.output == :text
    end

    test "rejects section field not in element type" do
      assert_raise ArgumentError,
                   ~r/\{\{unknown\}\} inside \{\{#items\}\} not found in element type/,
                   fn ->
                     SubAgent.new(
                       prompt: "{{#items}}{{unknown}}{{/items}}",
                       output: :text,
                       signature: "(items [{name :string}]) -> {count :int}"
                     )
                   end
    end

    test "accepts dot placeholder for scalar list" do
      agent =
        SubAgent.new(
          prompt: "Tags: {{#tags}}{{.}}, {{/tags}}",
          output: :text,
          signature: "(tags [:string]) -> {count :int}"
        )

      assert agent.output == :text
    end

    test "rejects dot placeholder for list of maps" do
      assert_raise ArgumentError,
                   ~r/\{\{.\}\}.*inside \{\{#items\}\}.*use \{\{field\}\} instead/,
                   fn ->
                     SubAgent.new(
                       prompt: "{{#items}}{{.}}{{/items}}",
                       output: :text,
                       signature: "(items [{name :string}]) -> {count :int}"
                     )
                   end
    end

    test "rejects field access on scalar list element" do
      assert_raise ArgumentError,
                   ~r/\{\{name\}\} inside \{\{#tags\}\}.*cannot access field on string/,
                   fn ->
                     SubAgent.new(
                       prompt: "{{#tags}}{{name}}{{/tags}}",
                       output: :text,
                       signature: "(tags [:string]) -> {count :int}"
                     )
                   end
    end
  end

  describe "ptc_lisp mode allows all features" do
    test "ptc_lisp mode allows tools" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :ptc_lisp,
          tools: %{foo: fn _ -> :ok end}
        )

      assert agent.output == :ptc_lisp
    end

    test "ptc_lisp mode allows compression" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :ptc_lisp,
          compression: true
        )

      assert agent.output == :ptc_lisp
    end

    test "ptc_lisp mode allows firewall fields in signature" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :ptc_lisp,
          signature: "() -> {visible :string, _hidden :string}"
        )

      assert agent.output == :ptc_lisp
    end

    test "ptc_lisp mode allows no signature" do
      agent = SubAgent.new(prompt: "Test", output: :ptc_lisp)
      assert agent.output == :ptc_lisp
      assert agent.signature == nil
    end
  end

  describe "completion_mode validation" do
    test "defaults to :explicit" do
      agent = SubAgent.new(prompt: "test")
      assert agent.completion_mode == :explicit
    end

    test "accepts :explicit" do
      agent = SubAgent.new(prompt: "test", completion_mode: :explicit)
      assert agent.completion_mode == :explicit
    end

    test "rejects invalid values" do
      assert_raise ArgumentError, ~r/completion_mode must be :explicit/, fn ->
        SubAgent.new(prompt: "test", completion_mode: :invalid)
      end
    end

    test "plan does not auto-enable journaling" do
      agent = SubAgent.new(prompt: "test", plan: ["step1"])
      assert agent.journaling == false
    end

    test "plan with explicit journaling: true" do
      agent = SubAgent.new(prompt: "test", plan: ["step1"], journaling: true)
      assert agent.journaling == true
    end
  end

  describe "progress_fn validation" do
    test "accepts nil progress_fn (default)" do
      agent = SubAgent.new(prompt: "test")
      assert agent.progress_fn == nil
    end

    test "accepts 2-arity function" do
      fun = fn _input, state -> {"", state} end
      agent = SubAgent.new(prompt: "test", progress_fn: fun)
      assert is_function(agent.progress_fn, 2)
    end

    test "rejects non-function progress_fn" do
      assert_raise ArgumentError, ~r/progress_fn must be a 2-arity function/, fn ->
        SubAgent.new(prompt: "test", progress_fn: "not a function")
      end
    end

    test "rejects 1-arity function" do
      assert_raise ArgumentError, ~r/progress_fn must be a 2-arity function/, fn ->
        SubAgent.new(prompt: "test", progress_fn: fn _input -> "" end)
      end
    end
  end

  describe "compaction validation" do
    test "accepts compaction: true (defaults to :trim)" do
      agent = SubAgent.new(prompt: "test", compaction: true)
      assert agent.compaction == true
    end

    test "accepts compaction: false (default)" do
      agent = SubAgent.new(prompt: "test", compaction: false)
      assert agent.compaction == false
    end

    test "compaction defaults to false when omitted" do
      agent = SubAgent.new(prompt: "test")
      assert agent.compaction == false
    end

    test "accepts valid compaction keyword list" do
      agent =
        SubAgent.new(
          prompt: "test",
          compaction: [
            strategy: :trim,
            trigger: [turns: 4, tokens: 1_000],
            keep_recent_turns: 2,
            keep_initial_user: false
          ]
        )

      assert agent.compaction[:keep_recent_turns] == 2
    end

    test "rejects empty keyword (compaction: [])" do
      assert_raise ArgumentError, ~r/compaction: \[\] is invalid/, fn ->
        SubAgent.new(prompt: "test", compaction: [])
      end
    end

    test "rejects unsupported strategy with phase 2 pointer" do
      assert_raise ArgumentError,
                   ~r/Phase 1 supports `strategy: :trim` only.*phase-2/,
                   fn ->
                     SubAgent.new(prompt: "test", compaction: [strategy: :summarize])
                   end
    end

    test "rejects custom strategy module forms with phase 2 pointer" do
      assert_raise ArgumentError, ~r/Custom strategy modules.*phase-2/, fn ->
        SubAgent.new(prompt: "test", compaction: SomeModule)
      end

      assert_raise ArgumentError, ~r/Custom strategy modules.*phase-2/, fn ->
        SubAgent.new(prompt: "test", compaction: {SomeModule, []})
      end
    end

    test "rejects unknown top-level keys" do
      assert_raise ArgumentError, ~r/Unknown compaction option/, fn ->
        SubAgent.new(prompt: "test", compaction: [keep_recent_turn: 3])
      end
    end

    test "rejects bad trigger types" do
      assert_raise ArgumentError, ~r/trigger\[:turns\] must be a positive integer/, fn ->
        SubAgent.new(prompt: "test", compaction: [trigger: [turns: 0]])
      end

      assert_raise ArgumentError, ~r/trigger must specify at least one of/, fn ->
        SubAgent.new(prompt: "test", compaction: [trigger: []])
      end
    end

    test "rejects bad token_counter arity" do
      assert_raise ArgumentError, ~r/token_counter must be a 1-arity function/, fn ->
        SubAgent.new(prompt: "test", compaction: [token_counter: fn _a, _b -> 0 end])
      end
    end
  end
end
