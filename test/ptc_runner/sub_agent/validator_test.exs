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

    test "accepts :json output mode with signature" do
      agent = SubAgent.new(prompt: "Test", output: :json, signature: "() -> {x :string}")
      assert agent.output == :json
    end

    test "rejects invalid output mode atom" do
      assert_raise ArgumentError, ~r/output must be :ptc_lisp or :json/, fn ->
        SubAgent.new(prompt: "Test", output: :invalid)
      end
    end

    test "defaults to :ptc_lisp when output not specified" do
      agent = SubAgent.new(prompt: "Test")
      assert agent.output == :ptc_lisp
    end
  end

  describe "json mode constraints" do
    test "rejects json mode with tools" do
      assert_raise ArgumentError, "output: :json cannot be used with tools", fn ->
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {x :string}",
          tools: %{foo: fn _ -> :ok end}
        )
      end
    end

    test "rejects json mode without signature" do
      assert_raise ArgumentError, "output: :json requires a signature", fn ->
        SubAgent.new(prompt: "Test", output: :json)
      end
    end

    test "rejects json mode with compression: true" do
      assert_raise ArgumentError, "output: :json cannot be used with compression", fn ->
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {x :string}",
          compression: true
        )
      end
    end

    test "rejects json mode with compression module" do
      assert_raise ArgumentError, "output: :json cannot be used with compression", fn ->
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {x :string}",
          compression: SomeModule
        )
      end
    end

    test "accepts json mode with compression: nil" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {x :string}",
          compression: nil
        )

      assert agent.output == :json
    end

    test "accepts json mode with compression: false" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {x :string}",
          compression: false
        )

      assert agent.output == :json
    end

    test "rejects json mode with firewall field in signature" do
      assert_raise ArgumentError,
                   ~r/output: :json signature cannot have firewall fields \(_hidden\)/,
                   fn ->
                     SubAgent.new(
                       prompt: "Test",
                       output: :json,
                       signature: "() -> {_hidden :string}"
                     )
                   end
    end

    test "rejects json mode with nested firewall field in signature" do
      assert_raise ArgumentError,
                   ~r/output: :json signature cannot have firewall fields \(_nested\)/,
                   fn ->
                     SubAgent.new(
                       prompt: "Test",
                       output: :json,
                       signature: "() -> {x {_nested :int}}"
                     )
                   end
    end

    test "rejects json mode with firewall field in array element" do
      assert_raise ArgumentError,
                   ~r/output: :json signature cannot have firewall fields \(_secret\)/,
                   fn ->
                     SubAgent.new(
                       prompt: "Test",
                       output: :json,
                       signature: "() -> {items [{name :string, _secret :string}]}"
                     )
                   end
    end

    test "accepts json mode with non-firewall nested fields" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {user {name :string, email :string}}"
        )

      assert agent.output == :json
    end

    test "accepts json mode with list of primitives" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {items [:string]}"
        )

      assert agent.output == :json
    end

    test "accepts json mode with optional fields (non-firewall)" do
      agent =
        SubAgent.new(
          prompt: "Test",
          output: :json,
          signature: "() -> {name :string, nickname :string?}"
        )

      assert agent.output == :json
    end

    test "rejects json mode with firewall field inside optional map field" do
      # Optional map field containing another map with firewall field
      assert_raise ArgumentError,
                   ~r/output: :json signature cannot have firewall fields \(_id\)/,
                   fn ->
                     SubAgent.new(
                       prompt: "Test",
                       output: :json,
                       signature: "() -> {data {user :string, _id :int}}"
                     )
                   end
    end
  end

  describe "json mode all-params-used validation" do
    test "rejects json mode with unused signature params" do
      assert_raise ArgumentError,
                   ~r/JSON mode requires all signature params in prompt. Unused: \["name"\]/,
                   fn ->
                     SubAgent.new(
                       prompt: "Analyze {{text}}",
                       output: :json,
                       signature: "(text :string, name :string) -> {result :string}"
                     )
                   end
    end

    test "accepts json mode when all params used as variables" do
      agent =
        SubAgent.new(
          prompt: "Analyze {{text}} for {{name}}",
          output: :json,
          signature: "(text :string, name :string) -> {result :string}"
        )

      assert agent.output == :json
    end

    test "accepts json mode when param used in section" do
      agent =
        SubAgent.new(
          prompt: "Process {{#items}}{{name}}{{/items}}",
          output: :json,
          signature: "(items [{name :string}]) -> {count :int}"
        )

      assert agent.output == :json
    end

    test "accepts json mode when param used in inverted section" do
      agent =
        SubAgent.new(
          prompt: "{{^debug}}Production mode{{/debug}}",
          output: :json,
          signature: "(debug :bool) -> {status :string}"
        )

      assert agent.output == :json
    end

    test "accepts zero-param json mode signature" do
      agent =
        SubAgent.new(
          prompt: "Return a greeting",
          output: :json,
          signature: "() -> {greeting :string}"
        )

      assert agent.output == :json
    end
  end

  describe "json mode section field validation" do
    test "accepts valid section fields matching signature" do
      agent =
        SubAgent.new(
          prompt: "{{#items}}{{name}}: {{price}}{{/items}}",
          output: :json,
          signature: "(items [{name :string, price :float}]) -> {total :float}"
        )

      assert agent.output == :json
    end

    test "rejects section field not in element type" do
      assert_raise ArgumentError,
                   ~r/\{\{unknown\}\} inside \{\{#items\}\} not found in element type/,
                   fn ->
                     SubAgent.new(
                       prompt: "{{#items}}{{unknown}}{{/items}}",
                       output: :json,
                       signature: "(items [{name :string}]) -> {count :int}"
                     )
                   end
    end

    test "accepts dot placeholder for scalar list" do
      agent =
        SubAgent.new(
          prompt: "Tags: {{#tags}}{{.}}, {{/tags}}",
          output: :json,
          signature: "(tags [:string]) -> {count :int}"
        )

      assert agent.output == :json
    end

    test "rejects dot placeholder for list of maps" do
      assert_raise ArgumentError,
                   ~r/\{\{.\}\}.*inside \{\{#items\}\}.*use \{\{field\}\} instead/,
                   fn ->
                     SubAgent.new(
                       prompt: "{{#items}}{{.}}{{/items}}",
                       output: :json,
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
                       output: :json,
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
end
