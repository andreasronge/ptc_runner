defmodule PtcRunner.SubAgent.LLMToolTest do
  use ExUnit.Case, async: true

  doctest PtcRunner.SubAgent.LLMTool

  alias PtcRunner.SubAgent.LLMTool

  describe "new/1" do
    test "creates LLMTool with minimal valid input (prompt + signature)" do
      tool =
        LLMTool.new(
          prompt: "Is {{email}} urgent?",
          signature: "(email :string) -> :bool"
        )

      assert tool.prompt == "Is {{email}} urgent?"
      assert tool.signature == "(email :string) -> :bool"
      assert tool.llm == :caller
      assert tool.description == nil
      assert tool.tools == nil
    end

    test "creates LLMTool with all fields provided" do
      custom_llm = fn _input -> {:ok, "response"} end
      custom_tools = %{"helper" => fn _args -> :ok end}

      tool =
        LLMTool.new(
          prompt: "Classify {{text}}",
          signature: "(text :string) -> {category :string}",
          llm: custom_llm,
          description: "Classifies text into categories",
          tools: custom_tools
        )

      assert tool.prompt == "Classify {{text}}"
      assert tool.signature == "(text :string) -> {category :string}"
      assert tool.llm == custom_llm
      assert tool.description == "Classifies text into categories"
      assert tool.tools == custom_tools
    end

    test "defaults llm to :caller" do
      tool = LLMTool.new(prompt: "Test {{x}}", signature: "(x :string) -> :string")
      assert tool.llm == :caller
    end

    test "allows llm as :caller explicitly" do
      tool = LLMTool.new(prompt: "Test {{x}}", signature: "(x :string) -> :string", llm: :caller)
      assert tool.llm == :caller
    end

    test "allows llm as atom" do
      tool = LLMTool.new(prompt: "Test {{x}}", signature: "(x :string) -> :string", llm: :haiku)
      assert tool.llm == :haiku
    end

    test "allows llm as function" do
      llm_fn = fn _input -> {:ok, "response"} end

      tool =
        LLMTool.new(prompt: "Test {{x}}", signature: "(x :string) -> :string", llm: llm_fn)

      assert tool.llm == llm_fn
    end

    test "allows llm as nil" do
      tool = LLMTool.new(prompt: "Test {{x}}", signature: "(x :string) -> :string", llm: nil)
      assert tool.llm == nil
    end

    test "allows description as string" do
      tool =
        LLMTool.new(
          prompt: "Test {{x}}",
          signature: "(x :string) -> :string",
          description: "A test tool"
        )

      assert tool.description == "A test tool"
    end

    test "allows description as nil" do
      tool =
        LLMTool.new(prompt: "Test {{x}}", signature: "(x :string) -> :string", description: nil)

      assert tool.description == nil
    end

    test "allows tools as map" do
      tools = %{"helper" => fn _args -> :ok end}

      tool =
        LLMTool.new(prompt: "Test {{x}}", signature: "(x :string) -> :string", tools: tools)

      assert tool.tools == tools
    end

    test "allows tools as nil" do
      tool = LLMTool.new(prompt: "Test {{x}}", signature: "(x :string) -> :string", tools: nil)
      assert tool.tools == nil
    end

    test "raises when prompt is missing" do
      assert_raise ArgumentError, "prompt is required", fn ->
        LLMTool.new(signature: ":string")
      end

      assert_raise ArgumentError, "prompt is required", fn ->
        LLMTool.new([])
      end
    end

    test "raises when signature is missing" do
      assert_raise ArgumentError, "signature is required", fn ->
        LLMTool.new(prompt: "Test")
      end

      # When both are missing, prompt is checked first
      assert_raise ArgumentError, "prompt is required", fn ->
        LLMTool.new([])
      end
    end

    test "raises when prompt is not a string" do
      assert_raise ArgumentError, "prompt must be a string", fn ->
        LLMTool.new(prompt: 123, signature: ":string")
      end

      assert_raise ArgumentError, "prompt must be a string", fn ->
        LLMTool.new(prompt: :atom, signature: ":string")
      end

      assert_raise ArgumentError, "prompt must be a string", fn ->
        LLMTool.new(prompt: nil, signature: ":string")
      end

      assert_raise ArgumentError, "prompt must be a string", fn ->
        LLMTool.new(prompt: %{}, signature: ":string")
      end
    end

    test "raises when prompt is empty string" do
      assert_raise ArgumentError, "prompt cannot be empty", fn ->
        LLMTool.new(prompt: "", signature: ":string")
      end
    end

    test "raises when signature is not a string" do
      assert_raise ArgumentError, "signature must be a string", fn ->
        LLMTool.new(prompt: "Test", signature: 123)
      end

      assert_raise ArgumentError, "signature must be a string", fn ->
        LLMTool.new(prompt: "Test", signature: :atom)
      end

      assert_raise ArgumentError, "signature must be a string", fn ->
        LLMTool.new(prompt: "Test", signature: nil)
      end

      assert_raise ArgumentError, "signature must be a string", fn ->
        LLMTool.new(prompt: "Test", signature: %{})
      end
    end

    test "raises when llm is invalid type" do
      assert_raise ArgumentError, "llm must be :caller, an atom, a function, or nil", fn ->
        LLMTool.new(prompt: "Test {{x}}", signature: "(x :string) -> :string", llm: "invalid")
      end

      assert_raise ArgumentError, "llm must be :caller, an atom, a function, or nil", fn ->
        LLMTool.new(prompt: "Test {{x}}", signature: "(x :string) -> :string", llm: 123)
      end

      assert_raise ArgumentError, "llm must be :caller, an atom, a function, or nil", fn ->
        LLMTool.new(prompt: "Test {{x}}", signature: "(x :string) -> :string", llm: %{})
      end
    end

    test "raises when description is not a string or nil" do
      assert_raise ArgumentError, "description must be a string or nil", fn ->
        LLMTool.new(prompt: "Test {{x}}", signature: "(x :string) -> :string", description: 123)
      end

      assert_raise ArgumentError, "description must be a string or nil", fn ->
        LLMTool.new(prompt: "Test {{x}}", signature: "(x :string) -> :string", description: :atom)
      end

      assert_raise ArgumentError, "description must be a string or nil", fn ->
        LLMTool.new(prompt: "Test {{x}}", signature: "(x :string) -> :string", description: %{})
      end
    end

    test "raises when tools is not a map or nil" do
      assert_raise ArgumentError, "tools must be a map or nil", fn ->
        LLMTool.new(prompt: "Test {{x}}", signature: "(x :string) -> :string", tools: [])
      end

      assert_raise ArgumentError, "tools must be a map or nil", fn ->
        LLMTool.new(prompt: "Test {{x}}", signature: "(x :string) -> :string", tools: "invalid")
      end

      assert_raise ArgumentError, "tools must be a map or nil", fn ->
        LLMTool.new(prompt: "Test {{x}}", signature: "(x :string) -> :string", tools: 123)
      end
    end

    test "validates placeholders match signature parameters (simple placeholder)" do
      # Valid: placeholder matches parameter
      tool = LLMTool.new(prompt: "Hello {{name}}", signature: "(name :string) -> :string")
      assert tool.prompt == "Hello {{name}}"

      # Invalid: placeholder not in signature
      assert_raise ArgumentError, ~r/placeholders {{missing}} not found in signature/, fn ->
        LLMTool.new(prompt: "Hello {{missing}}", signature: "(name :string) -> :string")
      end
    end

    test "validates placeholders match signature parameters (nested placeholder)" do
      # Note: Nested placeholders like {{email.subject}} require exact match in signature
      # This follows SubAgent's current behavior where the full placeholder string
      # (including dots) must match a parameter name

      # Invalid: nested placeholder treated as full string "email.subject"
      assert_raise ArgumentError,
                   ~r/placeholders {{email.subject}} not found in signature/,
                   fn ->
                     LLMTool.new(
                       prompt: "Subject: {{email.subject}}",
                       signature: "(email {:subject :string}) -> :string"
                     )
                   end

      # Invalid: nested placeholder also fails with different parameter
      assert_raise ArgumentError,
                   ~r/placeholders {{email.subject}} not found in signature/,
                   fn ->
                     LLMTool.new(
                       prompt: "Subject: {{email.subject}}",
                       signature: "(name :string) -> :string"
                     )
                   end
    end

    test "validates placeholders match signature parameters (multiple placeholders)" do
      # Valid: all placeholders match parameters
      tool =
        LLMTool.new(
          prompt: "Is {{email}} urgent for {{tier}} customer?",
          signature: "(email :string, tier :string) -> {urgent :bool, reason :string}"
        )

      assert tool.prompt == "Is {{email}} urgent for {{tier}} customer?"

      # Invalid: one placeholder missing from signature
      assert_raise ArgumentError, ~r/placeholders {{tier}} not found in signature/, fn ->
        LLMTool.new(
          prompt: "Is {{email}} urgent for {{tier}} customer?",
          signature: "(email :string) -> :bool"
        )
      end

      # Invalid: multiple placeholders missing
      assert_raise ArgumentError, ~r/placeholders {{email}}, {{tier}} not found/, fn ->
        LLMTool.new(
          prompt: "Is {{email}} urgent for {{tier}} customer?",
          signature: "() -> :bool"
        )
      end
    end

    test "validates placeholders when signature has no parameters" do
      # Valid: no placeholders, no parameters
      tool = LLMTool.new(prompt: "Generate a greeting", signature: "() -> :string")
      assert tool.prompt == "Generate a greeting"

      # Also valid with shorthand signature
      tool2 = LLMTool.new(prompt: "Generate a greeting", signature: ":string")
      assert tool2.prompt == "Generate a greeting"

      # Invalid: placeholder but no parameters
      assert_raise ArgumentError, ~r/placeholders {{name}} not found in signature/, fn ->
        LLMTool.new(prompt: "Hello {{name}}", signature: "() -> :string")
      end
    end

    test "allows extra signature parameters (not used in placeholders)" do
      # Valid: signature has more parameters than placeholders reference
      tool =
        LLMTool.new(
          prompt: "Hello {{name}}",
          signature: "(name :string, age :int) -> :string"
        )

      assert tool.prompt == "Hello {{name}}"
    end

    test "ignores unknown options (lenient per Elixir convention)" do
      tool =
        LLMTool.new(
          prompt: "Test {{x}}",
          signature: "(x :string) -> :string",
          unknown_field: "ignored",
          another: 123
        )

      assert tool.prompt == "Test {{x}}"
      refute Map.has_key?(tool, :unknown_field)
    end
  end
end
