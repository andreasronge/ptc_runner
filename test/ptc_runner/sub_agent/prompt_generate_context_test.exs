defmodule PtcRunner.SubAgent.PromptGenerateContextTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Prompt
  alias PtcRunner.SubAgent.Signature

  describe "generate_context/2" do
    test "includes dynamic sections" do
      agent = SubAgent.new(prompt: "Test", tools: %{"search" => fn _ -> [] end})
      context = %{user: "Alice", count: 5}

      context_prompt = Prompt.generate_context(agent, context: context)

      # Should have dynamic sections
      assert context_prompt =~ "# Data Inventory"
      assert context_prompt =~ "# Available Tools"
      assert context_prompt =~ "ctx/user"
      assert context_prompt =~ "ctx/count"
      assert context_prompt =~ "### search"

      # Should NOT have static sections
      refute context_prompt =~ "## Role"
      refute context_prompt =~ "# Output Format"
    end

    test "does not include mission" do
      agent = SubAgent.new(prompt: "This is the mission")

      context_prompt = Prompt.generate_context(agent, context: %{})

      refute context_prompt =~ "# Mission"
      refute context_prompt =~ "This is the mission"
    end

    test "includes Expected Output when signature is present" do
      agent = SubAgent.new(prompt: "Test", signature: "(x :int) -> {count :int}")

      context_prompt = Prompt.generate_context(agent, context: %{x: 5})

      assert context_prompt =~ "# Expected Output"
      assert context_prompt =~ "{count :int}"
    end

    test "includes return/fail tools for multi-turn mode" do
      agent = SubAgent.new(prompt: "Test", max_turns: 5)

      context_prompt = Prompt.generate_context(agent, context: %{})

      assert context_prompt =~ "### return"
      assert context_prompt =~ "### fail"
    end

    test "omits return/fail tools for single-shot mode" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      context_prompt = Prompt.generate_context(agent, context: %{})

      # Single-shot should NOT have return/fail
      refute context_prompt =~ "### return"
      refute context_prompt =~ "### fail"
    end

    test "merges field descriptions from upstream" do
      agent = SubAgent.new(prompt: "Test", context_descriptions: %{user: "Local desc"})

      context_prompt =
        Prompt.generate_context(agent,
          context: %{user: "Alice", items: [1, 2]},
          received_field_descriptions: %{items: "Received desc"}
        )

      # Both descriptions should appear
      assert context_prompt =~ "Local desc"
      assert context_prompt =~ "Received desc"
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

    test "formats floats with 2 decimal places" do
      context = %{ratio: 3.333333333, pi: 3.14159265}

      inventory = Prompt.generate_data_inventory(context, nil)

      assert inventory =~ "3.33"
      assert inventory =~ "3.14"
      refute inventory =~ "3.333333"
      refute inventory =~ "3.14159"
    end

    test "formats floats that round up correctly" do
      context = %{value: 2.999}

      inventory = Prompt.generate_data_inventory(context, nil)

      assert inventory =~ "3.00"
    end
  end

  describe "generate_tool_schemas/2" do
    test "handles empty tools" do
      schemas = Prompt.generate_tool_schemas(%{})

      assert schemas =~ "# Available Tools"
      # Even with no user tools, should show return/fail
      assert schemas =~ "### return"
      assert schemas =~ "### fail"
    end

    test "generates catalog section when tool_catalog is provided" do
      tools = %{"search" => fn _ -> [] end}
      catalog = %{"email_agent" => nil, "report_agent" => nil}

      schemas = Prompt.generate_tool_schemas(tools, catalog)

      assert schemas =~ "## Tools you can call"
      assert schemas =~ "### search"
      assert schemas =~ "## Tools for planning (do not call)"
      assert schemas =~ "These tools are shown for context but cannot be called directly"
      assert schemas =~ "### email_agent"
      assert schemas =~ "### report_agent"
    end

    test "handles empty tool_catalog" do
      tools = %{"search" => fn _ -> [] end}

      schemas = Prompt.generate_tool_schemas(tools, %{})

      assert schemas =~ "### search"
      refute schemas =~ "Tools for planning"
    end

    test "handles nil tool_catalog" do
      tools = %{"search" => fn _ -> [] end}

      schemas = Prompt.generate_tool_schemas(tools, nil)

      assert schemas =~ "### search"
      refute schemas =~ "Tools for planning"
    end

    test "catalog with no callable tools still shows return/fail" do
      catalog = %{"email_agent" => nil}

      schemas = Prompt.generate_tool_schemas(%{}, catalog)

      assert schemas =~ "### return"
      assert schemas =~ "### fail"
      assert schemas =~ "## Tools for planning (do not call)"
      assert schemas =~ "### email_agent"
    end

    test "sorts catalog tools alphabetically" do
      catalog = %{"zebra_agent" => nil, "alpha_agent" => nil}

      schemas = Prompt.generate_tool_schemas(%{}, catalog)

      alpha_pos = String.split(schemas, "### alpha_agent") |> List.first() |> String.length()
      zebra_pos = String.split(schemas, "### zebra_agent") |> List.first() |> String.length()

      assert alpha_pos < zebra_pos
    end

    test "allows duplicate tool names in tools and catalog" do
      tools = %{"search" => fn _ -> [] end}
      catalog = %{"search" => nil}

      schemas = Prompt.generate_tool_schemas(tools, catalog)

      # Count occurrences of "### search"
      search_count =
        schemas
        |> String.split("### search")
        |> length()
        |> Kernel.-(1)

      # Should appear twice: once in callable, once in catalog
      assert search_count == 2
      assert schemas =~ "## Tools you can call"
      assert schemas =~ "## Tools for planning (do not call)"
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

    test "renders explicit tool signature in prompt with example" do
      # Tool with explicit signature string
      tools = %{
        "search" => {fn _args -> [] end, "(query :string, limit :int) -> [{id :int}]"}
      }

      schemas = Prompt.generate_tool_schemas(tools)

      assert schemas =~ "### search"
      # The signature should be rendered, not just "User-defined tool"
      assert schemas =~ "search(query :string, limit :int) -> [{id :int}]"
      # Should include usage example with ctx/ prefix
      assert schemas =~ "Example: `(ctx/search {:query \"...\" :limit 10})`"
    end

    test "renders tool with keyword options signature and description" do
      tools = %{
        "analyze" =>
          {fn _args -> %{} end,
           signature: "(data :map) -> {score :float}",
           description: "Analyzes data and returns a score."}
      }

      schemas = Prompt.generate_tool_schemas(tools)

      assert schemas =~ "### analyze"
      assert schemas =~ "analyze(data :map) -> {score :float}"
      assert schemas =~ "Analyzes data and returns a score."
    end

    test "renders signature extracted from bare function reference" do
      # Bare function reference - signature/description auto-extracted from @spec/@doc
      alias PtcRunner.TypeExtractorFixtures, as: TestFunctions

      tools = %{
        "search" => &TestFunctions.search/2
      }

      schemas = Prompt.generate_tool_schemas(tools)

      assert schemas =~ "### search"
      assert schemas =~ "search(query :string, limit :int) -> [:map]"
      assert schemas =~ "Search for items matching query"
    end

    test "simplifies single map parameter in signature and example" do
      # When a tool has a single map parameter with named fields,
      # the signature should show the fields directly (not wrapped in param name)
      # and the example should expand the fields
      tools = %{
        "search" => {fn _args -> [] end, "(args {query :string, limit :int?}) -> [:map]"}
      }

      schemas = Prompt.generate_tool_schemas(tools)

      # Signature should NOT show "args" parameter name
      refute schemas =~ "search(args"
      # Signature should show fields directly
      assert schemas =~ "ctx/search({query :string, limit :int?}) -> [:map]"
      # Example should expand fields, not show {:args {...}}
      assert schemas =~ ~s|Example: `(ctx/search {:query "..." :limit 10})`|
      refute schemas =~ ":args"
    end
  end
end
