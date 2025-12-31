defmodule PtcRunner.SubAgent.PromptTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Prompt
  alias PtcRunner.SubAgent.Signature

  doctest PtcRunner.SubAgent.Prompt

  describe "generate/2" do
    test "generates complete system prompt with all sections" do
      agent = SubAgent.new(prompt: "Process data", tools: %{"search" => fn _ -> [] end})
      context = %{user: "Alice"}

      prompt = Prompt.generate(agent, context: context)

      # Check all major sections are present
      assert prompt =~ "# Role"
      assert prompt =~ "You are a PTC-Lisp program generator"
      assert prompt =~ "# Rules"
      assert prompt =~ "# Data Inventory"
      assert prompt =~ "# Available Tools"
      assert prompt =~ "# PTC-Lisp Quick Reference"
      assert prompt =~ "# Output Format"
      assert prompt =~ "# Mission"
    end

    test "includes context variables in data inventory" do
      agent = SubAgent.new(prompt: "Test")
      context = %{user_id: 123, name: "Bob"}

      prompt = Prompt.generate(agent, context: context)

      assert prompt =~ "ctx/user_id"
      assert prompt =~ "ctx/name"
    end

    test "includes tools in tool schemas" do
      tools = %{"search" => fn _ -> [] end, "fetch" => fn _ -> %{} end}
      agent = SubAgent.new(prompt: "Test", tools: tools)

      prompt = Prompt.generate(agent, context: %{})

      assert prompt =~ "### search"
      assert prompt =~ "### fetch"
    end

    test "expands mission template with context" do
      agent = SubAgent.new(prompt: "Find emails for {{user}}")
      context = %{user: "Alice"}

      prompt = Prompt.generate(agent, context: context)

      assert prompt =~ "Find emails for Alice"
    end

    test "handles missing template variables gracefully" do
      agent = SubAgent.new(prompt: "Find emails for {{user}}")
      context = %{}

      prompt = Prompt.generate(agent, context: context)

      # Should keep original template if expansion fails
      assert prompt =~ "Find emails for {{user}}"
    end

    test "works with empty context and no tools" do
      agent = SubAgent.new(prompt: "Simple task")

      prompt = Prompt.generate(agent, context: %{})

      assert prompt =~ "# Role"
      assert prompt =~ "Simple task"
    end
  end

  describe "generate_data_inventory/2" do
    test "formats simple context correctly" do
      context = %{user_id: 123, name: "Alice"}

      inventory = Prompt.generate_data_inventory(context, nil)

      assert inventory =~ "# Data Inventory"
      assert inventory =~ "ctx/user_id"
      assert inventory =~ "ctx/name"
      assert inventory =~ "123"
      assert inventory =~ "\"Alice\""
    end

    test "handles nested maps" do
      context = %{user: %{id: 1, name: "Bob"}}

      inventory = Prompt.generate_data_inventory(context, nil)

      assert inventory =~ "ctx/user"
      # Should show map keys
      assert inventory =~ "{id, name}"
    end

    test "handles lists with sampling" do
      context = %{items: [1, 2, 3, 4, 5]}

      inventory = Prompt.generate_data_inventory(context, nil)

      assert inventory =~ "ctx/items"
      # Should show sample with count
      assert inventory =~ "5 items"
    end

    test "handles empty lists" do
      context = %{items: []}

      inventory = Prompt.generate_data_inventory(context, nil)

      assert inventory =~ "ctx/items"
      assert inventory =~ "[]"
    end

    test "truncates large values" do
      long_string = String.duplicate("a", 100)
      context = %{text: long_string}

      inventory = Prompt.generate_data_inventory(context, nil)

      assert inventory =~ "..."
    end

    test "marks firewalled fields" do
      context = %{_token: "secret", public: "data"}

      inventory = Prompt.generate_data_inventory(context, nil)

      assert inventory =~ "[Firewalled]"
      assert inventory =~ "ctx/_token"
      assert inventory =~ "[Hidden]"
      refute inventory =~ "secret"
    end

    test "handles empty context" do
      inventory = Prompt.generate_data_inventory(%{}, nil)

      assert inventory =~ "No data available"
    end

    test "sorts keys alphabetically" do
      context = %{z: 1, a: 2, m: 3}

      inventory = Prompt.generate_data_inventory(context, nil)

      # Extract the lines
      lines = String.split(inventory, "\n")

      # Find ctx/ lines
      ctx_lines =
        lines
        |> Enum.filter(&String.contains?(&1, "ctx/"))
        |> Enum.map(fn line ->
          # Extract key name
          case Regex.run(~r/ctx\/(\w+)/, line) do
            [_, key] -> key
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      assert ctx_lines == ["a", "m", "z"]
    end

    test "uses signature types when available" do
      context = %{user_id: 123}

      {:ok, signature} = Signature.parse("(user_id :string) -> :any")

      inventory = Prompt.generate_data_inventory(context, signature)

      # Should use :string from signature, not inferred :int
      assert inventory =~ ":string"
    end
  end

  describe "generate_tool_schemas/1" do
    test "handles empty tools" do
      schemas = Prompt.generate_tool_schemas(%{})

      assert schemas =~ "# Available Tools"
      # Even with no user tools, should show return/fail
      assert schemas =~ "### return"
      assert schemas =~ "### fail"
    end

    test "generates schemas for user tools" do
      tools = %{"search" => fn _ -> [] end, "fetch" => fn _ -> %{} end}

      schemas = Prompt.generate_tool_schemas(tools)

      assert schemas =~ "### search"
      assert schemas =~ "### fetch"
      assert schemas =~ "User-defined tool"
    end

    test "includes return and fail tools" do
      tools = %{"custom" => fn _ -> :ok end}

      schemas = Prompt.generate_tool_schemas(tools)

      assert schemas =~ "### return"
      assert schemas =~ "### fail"
      assert schemas =~ "exit-success"
      assert schemas =~ "exit-error"
    end

    test "does not duplicate return/fail if already present" do
      tools = %{"return" => fn _ -> :ok end, "fail" => fn _ -> :error end}

      schemas = Prompt.generate_tool_schemas(tools)

      # Count occurrences of "### return"
      return_count =
        schemas
        |> String.split("### return")
        |> length()
        |> Kernel.-(1)

      assert return_count == 1
    end

    test "sorts tools alphabetically" do
      tools = %{"zebra" => fn _ -> :ok end, "alpha" => fn _ -> :ok end}

      schemas = Prompt.generate_tool_schemas(tools)

      alpha_pos = String.split(schemas, "### alpha") |> List.first() |> String.length()
      zebra_pos = String.split(schemas, "### zebra") |> List.first() |> String.length()

      assert alpha_pos < zebra_pos
    end
  end

  describe "integration" do
    test "E2E: generates complete prompt for realistic agent" do
      tools = %{
        "search" => fn _ -> [] end,
        "send_email" => fn _ -> :ok end
      }

      agent =
        SubAgent.new(
          prompt: "Find urgent emails for {{user}} and send replies",
          signature: "(user :string) -> {count :int}",
          tools: tools
        )

      context = %{user: "Alice", emails: [%{id: 1, subject: "Urgent"}]}

      prompt = Prompt.generate(agent, context: context)

      # Role section
      assert prompt =~ "You are a PTC-Lisp"

      # Data inventory
      assert prompt =~ "ctx/user"
      assert prompt =~ "ctx/emails"

      # Tools
      assert prompt =~ "search"
      assert prompt =~ "send_email"

      # Mission with expanded template
      assert prompt =~ "Find urgent emails for Alice"

      # PTC-Lisp reference
      assert prompt =~ "(call \"search\""

      # Output format
      assert prompt =~ "```clojure"
    end

    test "handles agent with signature but no tools" do
      agent =
        SubAgent.new(
          prompt: "Calculate {{x}} + {{y}}",
          signature: "(x :int, y :int) -> :int"
        )

      context = %{x: 5, y: 3}

      prompt = Prompt.generate(agent, context: context)

      assert prompt =~ "Calculate 5 + 3"
      assert prompt =~ "ctx/x"
      assert prompt =~ "ctx/y"
      # Should still show return/fail tools
      assert prompt =~ "### return"
    end

    test "handles very long tool descriptions gracefully" do
      long_desc_tool = fn _ -> "result" end

      tools = %{
        "very_long_named_tool_with_lots_of_words" => long_desc_tool
      }

      agent = SubAgent.new(prompt: "Test", tools: tools)

      prompt = Prompt.generate(agent, context: %{})

      # Should not error and should include the tool
      assert prompt =~ "very_long_named_tool_with_lots_of_words"
    end

    test "handles large nested maps in context" do
      context = %{
        config: %{
          setting1: "value1",
          setting2: "value2",
          setting3: "value3",
          setting4: "value4"
        }
      }

      prompt = Prompt.generate(SubAgent.new(prompt: "Test"), context: context)

      # Should handle gracefully without erroring
      assert prompt =~ "ctx/config"
    end
  end
end
