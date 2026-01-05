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
      assert prompt =~ "## PTC-Lisp"
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
  end

  describe "customization" do
    test "prefix prepends to generated prompt" do
      agent =
        SubAgent.new(
          prompt: "Analyze data",
          system_prompt: %{prefix: "You are an expert analyst."}
        )

      prompt = Prompt.generate(agent, context: %{data: [1, 2, 3]})

      assert String.starts_with?(prompt, "You are an expert analyst.")
      assert prompt =~ "# Role"
      assert prompt =~ "ctx/data"
    end

    test "suffix appends to generated prompt" do
      agent =
        SubAgent.new(
          prompt: "Analyze data",
          system_prompt: %{suffix: "Always explain your reasoning."}
        )

      prompt = Prompt.generate(agent, context: %{data: [1, 2, 3]})

      assert String.ends_with?(prompt, "Always explain your reasoning.")
      assert prompt =~ "# Role"
      assert prompt =~ "ctx/data"
    end

    test "prefix and suffix work together" do
      agent =
        SubAgent.new(
          prompt: "Analyze data",
          system_prompt: %{
            prefix: "You are an expert analyst.",
            suffix: "Always explain your reasoning."
          }
        )

      prompt = Prompt.generate(agent, context: %{data: [1, 2, 3]})

      assert String.starts_with?(prompt, "You are an expert analyst.")
      assert String.ends_with?(prompt, "Always explain your reasoning.")
      assert prompt =~ "ctx/data"
    end

    test "language_spec replaces language section" do
      custom_lang = "Use Python-like syntax only."

      agent =
        SubAgent.new(
          prompt: "Test",
          system_prompt: %{language_spec: custom_lang}
        )

      prompt = Prompt.generate(agent, context: %{})

      assert prompt =~ custom_lang
      refute prompt =~ "Clojure-inspired"
    end

    # TODO: Fix in #538 - prompt no longer contains "Core Functions"
    @tag :skip
    test "language_spec atom resolves to prompt profile" do
      agent =
        SubAgent.new(
          prompt: "Test",
          system_prompt: %{language_spec: :single_shot}
        )

      prompt = Prompt.generate(agent, context: %{})
      assert prompt =~ "PTC-Lisp"
      assert prompt =~ "PTC Extensions"
      # single_shot should not have memory docs
      refute prompt =~ "Memory: Persisting Data Between Turns"
    end

    test "language_spec callback receives resolution context" do
      callback = fn ctx ->
        "turn:#{ctx.turn}"
      end

      agent =
        SubAgent.new(
          prompt: "Test",
          system_prompt: %{language_spec: callback}
        )

      prompt =
        Prompt.generate(agent,
          context: %{},
          resolution_context: %{turn: 2, model: :test, memory: %{}, messages: []}
        )

      assert prompt =~ "turn:2"
    end

    test "output_format replaces output section" do
      custom_output = "Return JSON only."

      agent =
        SubAgent.new(
          prompt: "Test",
          system_prompt: %{output_format: custom_output}
        )

      prompt = Prompt.generate(agent, context: %{})

      assert prompt =~ custom_output
      # Check the Output Format section was replaced (not in code examples elsewhere)
      refute prompt =~ "# Output Format\n\nRespond with a single ```clojure"
    end

    test "function transformer modifies prompt" do
      transformer = fn prompt -> String.upcase(prompt) end

      agent =
        SubAgent.new(
          prompt: "Test",
          system_prompt: transformer
        )

      prompt = Prompt.generate(agent, context: %{})

      assert prompt == String.upcase(prompt)
      assert prompt =~ "# ROLE"
    end

    test "string override bypasses generation entirely" do
      override = "Custom prompt completely replacing default"

      agent =
        SubAgent.new(
          prompt: "Test",
          system_prompt: override
        )

      prompt = Prompt.generate(agent, context: %{data: 123})

      assert prompt == override
      refute prompt =~ "# Role"
    end

    test "nil system_prompt uses default generation" do
      agent = SubAgent.new(prompt: "Test", system_prompt: nil)

      prompt = Prompt.generate(agent, context: %{})

      assert prompt =~ "# Role"
      assert prompt =~ "# Rules"
    end
  end

  describe "error_recovery_prompt" do
    test "generates error recovery prompt" do
      error = %{type: :parse_error, message: "Unexpected token at position 45"}

      recovery = Prompt.generate_error_recovery_prompt(error)

      assert recovery =~ "# Previous Turn Error"
      assert recovery =~ "parse_error"
      assert recovery =~ "Unexpected token at position 45"
      assert recovery =~ "```clojure code block"
    end

    test "handles missing error fields" do
      error = %{}

      recovery = Prompt.generate_error_recovery_prompt(error)

      assert recovery =~ "# Previous Turn Error"
      assert recovery =~ "unknown_error"
    end

    test "error context is appended to prompt" do
      agent = SubAgent.new(prompt: "Test")
      error = %{type: :parse_error, message: "Bad syntax"}

      prompt = Prompt.generate(agent, context: %{}, error_context: error)

      assert prompt =~ "# Role"
      assert prompt =~ "# Previous Turn Error"
      assert prompt =~ "Bad syntax"
    end
  end

  describe "truncation" do
    test "does not truncate when no limit set" do
      long_prompt = String.duplicate("x", 10_000)

      result = Prompt.truncate_if_needed(long_prompt, nil)

      assert result == long_prompt
    end

    test "does not truncate when under limit" do
      short_prompt = "Short prompt"

      result = Prompt.truncate_if_needed(short_prompt, %{max_chars: 1000})

      assert result == short_prompt
    end

    @tag :capture_log
    test "truncates when over limit" do
      long_prompt = String.duplicate("x", 1000)

      result = Prompt.truncate_if_needed(long_prompt, %{max_chars: 100})

      assert String.length(result) > 100
      assert String.length(result) < 300
      assert result =~ "truncated"
    end

    @tag :capture_log
    test "truncation preserves beginning of prompt" do
      prompt = "# Role\n\nImportant content" <> String.duplicate("x", 1000)

      result = Prompt.truncate_if_needed(prompt, %{max_chars: 100})

      assert result =~ "# Role"
      assert result =~ "Important content"
    end

    @tag :capture_log
    test "truncation with agent applies to final prompt" do
      # Create an agent with lots of tools and data
      tools =
        Map.new(1..50, fn i ->
          {"tool_#{i}", fn _ -> :ok end}
        end)

      agent =
        SubAgent.new(
          prompt: "Process everything",
          tools: tools,
          prompt_limit: %{max_chars: 500}
        )

      context = Map.new(1..50, fn i -> {"key_#{i}", "value_#{i}"} end)

      prompt = Prompt.generate(agent, context: context)

      assert String.length(prompt) < 1000
      assert prompt =~ "truncated"
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

      # PTC-Lisp reference (updated to ctx/tool-name syntax)
      assert prompt =~ "(ctx/tool-name"

      # Output format
      assert prompt =~ "```clojure"
    end

    test "includes Expected Output section when signature is present" do
      agent =
        SubAgent.new(
          prompt: "Test",
          signature: "(x :int) -> {count :int, ids [:string]}"
        )

      prompt = Prompt.generate(agent, context: %{x: 10})

      assert prompt =~ "# Expected Output"
      assert prompt =~ "Your final answer must match this format: `{count :int, ids [:string]}`"
      assert prompt =~ "Call `(return {:count 42, :ids []})` when complete."
    end

    test "omits Expected Output section when signature is nil" do
      agent = SubAgent.new(prompt: "Test")
      prompt = Prompt.generate(agent, context: %{})

      refute prompt =~ "# Expected Output"
    end

    test "handles different return types in examples" do
      # Int
      agent = SubAgent.new(prompt: "T", signature: ":int")
      assert Prompt.generate(agent) =~ "(return 42)"

      # String
      agent = SubAgent.new(prompt: "T", signature: ":string")
      assert Prompt.generate(agent) =~ "(return \"result\")"

      # Boolean
      agent = SubAgent.new(prompt: "T", signature: ":bool")
      assert Prompt.generate(agent) =~ "(return true)"

      # List
      agent = SubAgent.new(prompt: "T", signature: "[:int]")
      assert Prompt.generate(agent) =~ "(return [])"

      # Nested Map
      agent = SubAgent.new(prompt: "T", signature: "{a {b :int}}")
      assert Prompt.generate(agent) =~ "(return {:a {:b 42}})"
    end

    test "handles firewalled fields in signatures" do
      # Firewalled fields should be visible in the expected output format
      agent = SubAgent.new(prompt: "T", signature: "{_id :int, status :string}")
      prompt = Prompt.generate(agent)

      assert prompt =~ "{_id :int, status :string}"
      assert prompt =~ "(return {:_id 42, :status \"result\"})"
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

    test "handles very long tool names gracefully" do
      tools = %{
        "very_long_named_tool_with_lots_of_words" => fn _ -> "result" end
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

    test "generates prompt with both tools and tool_catalog" do
      tools = %{"search" => fn _ -> [] end}
      catalog = %{"email_agent" => nil, "report_agent" => nil}

      agent =
        SubAgent.new(
          prompt: "Find and process data",
          tools: tools,
          tool_catalog: catalog
        )

      prompt = Prompt.generate(agent, context: %{})

      # Should have both sections
      assert prompt =~ "## Tools you can call"
      assert prompt =~ "### search"
      assert prompt =~ "## Tools for planning (do not call)"
      assert prompt =~ "These tools are shown for context but cannot be called directly"
      assert prompt =~ "### email_agent"
      assert prompt =~ "### report_agent"
    end

    test "generates prompt with only tool_catalog (no callable tools)" do
      catalog = %{"email_agent" => nil}

      agent =
        SubAgent.new(
          prompt: "Review available agents",
          tool_catalog: catalog
        )

      prompt = Prompt.generate(agent, context: %{})

      # Should show standard return/fail tools
      assert prompt =~ "## Tools you can call"
      assert prompt =~ "### return"
      assert prompt =~ "### fail"
      # And the catalog section
      assert prompt =~ "## Tools for planning (do not call)"
      assert prompt =~ "### email_agent"
    end
  end
end
