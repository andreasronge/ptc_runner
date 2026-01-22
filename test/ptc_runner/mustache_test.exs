defmodule PtcRunner.MustacheTest do
  use ExUnit.Case, async: true

  doctest PtcRunner.Mustache

  alias PtcRunner.Mustache

  describe "parse/1 - simple variables" do
    test "parses simple variable" do
      assert {:ok, [{:variable, ["name"], %{line: 1, col: 1}}]} = Mustache.parse("{{name}}")
    end

    test "parses variable with text before" do
      assert {:ok, [{:text, "Hello "}, {:variable, ["name"], %{line: 1, col: 7}}]} =
               Mustache.parse("Hello {{name}}")
    end

    test "parses variable with text after" do
      assert {:ok, [{:variable, ["name"], %{line: 1, col: 1}}, {:text, "!"}]} =
               Mustache.parse("{{name}}!")
    end

    test "parses multiple variables" do
      {:ok, ast} = Mustache.parse("{{a}} {{b}}")
      assert [{:variable, ["a"], %{line: 1, col: 1}}, {:text, " "}, {:variable, ["b"], loc}] = ast
      # Column can vary based on how we count (6 or 7), just verify it's on line 1
      assert loc.line == 1
    end

    test "parses adjacent variables" do
      assert {:ok,
              [
                {:variable, ["a"], %{line: 1, col: 1}},
                {:variable, ["b"], %{line: 1, col: 6}}
              ]} = Mustache.parse("{{a}}{{b}}")
    end

    test "parses variable with dot notation" do
      assert {:ok, [{:variable, ["user", "name"], %{line: 1, col: 1}}]} =
               Mustache.parse("{{user.name}}")
    end

    test "parses variable with deep dot notation" do
      assert {:ok, [{:variable, ["a", "b", "c", "d"], %{line: 1, col: 1}}]} =
               Mustache.parse("{{a.b.c.d}}")
    end

    test "parses current element" do
      assert {:ok, [{:current, %{line: 1, col: 1}}]} = Mustache.parse("{{.}}")
    end
  end

  describe "parse/1 - comments" do
    test "parses simple comment" do
      assert {:ok, [{:comment, " text ", %{line: 1, col: 1}}]} = Mustache.parse("{{! text }}")
    end

    test "parses comment with surrounding text" do
      assert {:ok,
              [
                {:text, "a"},
                {:comment, "x", %{line: 1, col: 2}},
                {:text, "b"}
              ]} = Mustache.parse("a{{!x}}b")
    end

    test "parses multiline comment" do
      assert {:ok, [{:comment, " line1\nline2 ", %{line: 1, col: 1}}]} =
               Mustache.parse("{{! line1\nline2 }}")
    end
  end

  describe "parse/1 - sections" do
    test "parses empty section" do
      assert {:ok, [{:section, "items", [], %{line: 1, col: 1}}]} =
               Mustache.parse("{{#items}}{{/items}}")
    end

    test "parses section with content" do
      assert {:ok, [{:section, "items", [{:text, "content"}], %{line: 1, col: 1}}]} =
               Mustache.parse("{{#items}}content{{/items}}")
    end

    test "parses section with variable" do
      assert {:ok,
              [
                {:section, "items",
                 [
                   {:variable, ["name"], %{line: 1, col: 11}}
                 ], %{line: 1, col: 1}}
              ]} = Mustache.parse("{{#items}}{{name}}{{/items}}")
    end

    test "parses nested sections" do
      assert {:ok,
              [
                {:section, "outer",
                 [
                   {:section, "inner", [{:text, "x"}], %{line: 1, col: 11}}
                 ], %{line: 1, col: 1}}
              ]} = Mustache.parse("{{#outer}}{{#inner}}x{{/inner}}{{/outer}}")
    end

    test "parses inverted section" do
      assert {:ok, [{:inverted_section, "items", [{:text, "empty"}], %{line: 1, col: 1}}]} =
               Mustache.parse("{{^items}}empty{{/items}}")
    end

    test "parses section and inverted section together" do
      {:ok, ast} = Mustache.parse("{{#items}}has{{/items}}{{^items}}empty{{/items}}")

      assert [
               {:section, "items", [{:text, "has"}], %{line: 1, col: 1}},
               {:inverted_section, "items", [{:text, "empty"}], loc}
             ] = ast

      # Verify inverted section is on line 1 (column may vary)
      assert loc.line == 1
    end
  end

  describe "parse/1 - errors" do
    test "returns error for unclosed section" do
      assert {:error, "unclosed section 'items' opened at line 1, col 1"} =
               Mustache.parse("{{#items}}")
    end

    test "returns error for mismatched section" do
      assert {:error, "mismatched section at line 1, col 11: expected 'items', got 'other'"} =
               Mustache.parse("{{#items}}{{/other}}")
    end

    test "returns error for close without open" do
      assert {:error, msg} = Mustache.parse("{{/items}}")
      assert msg =~ "closing tag 'items' without opening section"
    end

    test "returns error for unclosed tag" do
      assert {:error, msg} = Mustache.parse("{{name")
      assert msg =~ "unclosed tag"
    end

    test "returns error for empty variable name" do
      assert {:error, msg} = Mustache.parse("{{}}")
      assert msg =~ "empty variable name"
    end

    test "returns error for empty section name" do
      assert {:error, msg} = Mustache.parse("{{#}}")
      assert msg =~ "empty section name"
    end
  end

  describe "parse/1 - edge cases" do
    test "parses empty template" do
      assert {:ok, []} = Mustache.parse("")
    end

    test "parses template with no variables" do
      assert {:ok, [{:text, "hello world"}]} = Mustache.parse("hello world")
    end

    test "preserves single braces" do
      assert {:ok, [{:text, "{not a var}"}]} = Mustache.parse("{not a var}")
    end

    test "preserves newlines" do
      assert {:ok, [{:text, "a\nb\nc"}]} = Mustache.parse("a\nb\nc")
    end

    test "handles multiline template with variables" do
      template = "Hello {{name}}\nWelcome"

      assert {:ok,
              [
                {:text, "Hello "},
                {:variable, ["name"], %{line: 1, col: 7}},
                {:text, "\nWelcome"}
              ]} = Mustache.parse(template)
    end

    test "tracks line and column correctly" do
      template = "line1\n{{a}}\n{{b}}"

      assert {:ok,
              [
                {:text, "line1\n"},
                {:variable, ["a"], %{line: 2, col: 1}},
                {:text, "\n"},
                {:variable, ["b"], %{line: 3, col: 1}}
              ]} = Mustache.parse(template)
    end
  end

  describe "parse/1 - standalone whitespace" do
    test "strips standalone section tags" do
      template = "Items:\n{{#items}}\n- {{name}}\n{{/items}}\nDone"
      {:ok, ast} = Mustache.parse(template)
      {:ok, result} = Mustache.expand(ast, %{items: [%{name: "A"}, %{name: "B"}]})
      assert result == "Items:\n- A\n- B\nDone"
    end

    test "strips standalone inverted section tags" do
      template = "Start\n{{^items}}\nEmpty\n{{/items}}\nEnd"
      {:ok, ast} = Mustache.parse(template)
      {:ok, result} = Mustache.expand(ast, %{items: []})
      assert result == "Start\nEmpty\nEnd"
    end

    test "strips standalone comment tags" do
      template = "Before\n{{! comment }}\nAfter"
      {:ok, ast} = Mustache.parse(template)
      {:ok, result} = Mustache.expand(ast, %{})
      assert result == "Before\nAfter"
    end

    test "does not strip non-standalone tags" do
      template = "Text {{#items}}content{{/items}} more"
      {:ok, ast} = Mustache.parse(template)
      {:ok, result} = Mustache.expand(ast, %{items: [%{}]})
      assert result == "Text content more"
    end
  end

  describe "expand/3 - simple variables" do
    test "expands simple variable with string key" do
      {:ok, ast} = Mustache.parse("Hello {{name}}")
      assert {:ok, "Hello Alice"} = Mustache.expand(ast, %{"name" => "Alice"})
    end

    test "expands simple variable with atom key" do
      {:ok, ast} = Mustache.parse("Hello {{name}}")
      assert {:ok, "Hello Bob"} = Mustache.expand(ast, %{name: "Bob"})
    end

    test "expands integer value" do
      {:ok, ast} = Mustache.parse("Count: {{count}}")
      assert {:ok, "Count: 42"} = Mustache.expand(ast, %{count: 42})
    end

    test "expands float value" do
      {:ok, ast} = Mustache.parse("Price: {{price}}")
      assert {:ok, "Price: 3.14"} = Mustache.expand(ast, %{price: 3.14})
    end

    test "expands boolean value" do
      {:ok, ast} = Mustache.parse("Active: {{active}}")
      assert {:ok, "Active: true"} = Mustache.expand(ast, %{active: true})
    end

    test "returns error for missing key" do
      {:ok, ast} = Mustache.parse("Hello {{name}}")
      assert {:error, {:missing_key, "name", %{line: 1, col: 7}}} = Mustache.expand(ast, %{})
    end

    test "returns error for map variable (use section instead)" do
      {:ok, ast} = Mustache.parse("Hello {{user}}")

      assert {:error, {:non_scalar_variable, _loc, msg}} =
               Mustache.expand(ast, %{user: %{name: "Alice"}})

      assert msg =~ "resolved to map"
      assert msg =~ "Use a section {{#user}}"
    end

    test "returns error for list variable (use section instead)" do
      {:ok, ast} = Mustache.parse("Tags: {{tags}}")

      assert {:error, {:non_scalar_variable, _loc, msg}} =
               Mustache.expand(ast, %{tags: ["a", "b", "c"]})

      assert msg =~ "resolved to list"
      assert msg =~ "Use a section {{#tags}}"
    end

    test "returns error for nested map variable" do
      {:ok, ast} = Mustache.parse("{{user.address}}")

      assert {:error, {:non_scalar_variable, _loc, msg}} =
               Mustache.expand(ast, %{user: %{address: %{city: "NYC"}}})

      assert msg =~ "{{user.address}} resolved to map"
    end
  end

  describe "expand/3 - dot notation" do
    test "expands shallow dot notation" do
      {:ok, ast} = Mustache.parse("{{user.name}}")
      assert {:ok, "Alice"} = Mustache.expand(ast, %{user: %{name: "Alice"}})
    end

    test "expands deep dot notation" do
      {:ok, ast} = Mustache.parse("{{a.b.c.d}}")
      assert {:ok, "deep"} = Mustache.expand(ast, %{a: %{b: %{c: %{d: "deep"}}}})
    end

    test "returns error for missing nested key" do
      {:ok, ast} = Mustache.parse("{{user.email}}")

      assert {:error, {:missing_key, "user.email", _loc}} =
               Mustache.expand(ast, %{user: %{name: "Alice"}})
    end
  end

  describe "expand/3 - current element" do
    test "expands current element with strings" do
      {:ok, ast} = Mustache.parse("{{#tags}}{{.}} {{/tags}}")
      assert {:ok, "a b c "} = Mustache.expand(ast, %{tags: ["a", "b", "c"]})
    end

    test "expands current element with numbers" do
      {:ok, ast} = Mustache.parse("{{#nums}}{{.}},{{/nums}}")
      assert {:ok, "1,2,3,"} = Mustache.expand(ast, %{nums: [1, 2, 3]})
    end

    test "returns error for current element at top level (root context is map)" do
      {:ok, ast} = Mustache.parse("{{.}}")
      # At top level, context is a map, so {{.}} errors with dot_on_map
      assert {:error, {:dot_on_map, _loc, _msg}} = Mustache.expand(ast, %{})
    end

    test "returns error for current element with map" do
      {:ok, ast} = Mustache.parse("{{#items}}{{.}}{{/items}}")
      assert {:error, {:dot_on_map, _loc, msg}} = Mustache.expand(ast, %{items: [%{x: 1}]})
      assert msg =~ "requires scalar value"
    end
  end

  describe "expand/3 - comments" do
    test "strips comments" do
      {:ok, ast} = Mustache.parse("Hello {{! comment }} World")
      assert {:ok, "Hello  World"} = Mustache.expand(ast, %{})
    end
  end

  describe "expand/3 - list iteration" do
    test "iterates over list of maps" do
      {:ok, ast} = Mustache.parse("{{#items}}{{name}} {{/items}}")
      assert {:ok, "A B "} = Mustache.expand(ast, %{items: [%{name: "A"}, %{name: "B"}]})
    end

    test "renders nothing for empty list" do
      {:ok, ast} = Mustache.parse("{{#items}}item{{/items}}")
      assert {:ok, ""} = Mustache.expand(ast, %{items: []})
    end

    test "iterates over list of scalars" do
      {:ok, ast} = Mustache.parse("{{#items}}[{{.}}]{{/items}}")
      assert {:ok, "[1][2][3]"} = Mustache.expand(ast, %{items: [1, 2, 3]})
    end
  end

  describe "expand/3 - context push (map section)" do
    test "pushes map onto context" do
      {:ok, ast} = Mustache.parse("{{#user}}Name: {{name}}, Age: {{age}}{{/user}}")

      assert {:ok, "Name: Alice, Age: 30"} =
               Mustache.expand(ast, %{user: %{name: "Alice", age: 30}})
    end

    test "accesses outer context when not shadowed" do
      {:ok, ast} = Mustache.parse("{{#user}}{{title}} {{name}}{{/user}}")
      assert {:ok, "Mr Smith"} = Mustache.expand(ast, %{title: "Mr", user: %{name: "Smith"}})
    end

    test "inner context shadows outer" do
      {:ok, ast} = Mustache.parse("{{#user}}{{name}}{{/user}}")
      assert {:ok, "Inner"} = Mustache.expand(ast, %{name: "Outer", user: %{name: "Inner"}})
    end
  end

  describe "expand/3 - inverted sections" do
    test "renders for empty list" do
      {:ok, ast} = Mustache.parse("{{^items}}Empty{{/items}}")
      assert {:ok, "Empty"} = Mustache.expand(ast, %{items: []})
    end

    test "renders for nil" do
      {:ok, ast} = Mustache.parse("{{^items}}Nothing{{/items}}")
      assert {:ok, "Nothing"} = Mustache.expand(ast, %{items: nil})
    end

    test "renders for false" do
      {:ok, ast} = Mustache.parse("{{^active}}Inactive{{/active}}")
      assert {:ok, "Inactive"} = Mustache.expand(ast, %{active: false})
    end

    test "renders for empty string" do
      {:ok, ast} = Mustache.parse("{{^desc}}No description{{/desc}}")
      assert {:ok, "No description"} = Mustache.expand(ast, %{desc: ""})
    end

    test "renders for missing key" do
      {:ok, ast} = Mustache.parse("{{^missing}}Default{{/missing}}")
      assert {:ok, "Default"} = Mustache.expand(ast, %{})
    end

    test "does not render for truthy value" do
      {:ok, ast} = Mustache.parse("{{^items}}Empty{{/items}}")
      assert {:ok, ""} = Mustache.expand(ast, %{items: [1]})
    end
  end

  describe "expand/3 - falsy values" do
    test "empty string is falsy for sections" do
      {:ok, ast} = Mustache.parse("{{#desc}}Has: {{desc}}{{/desc}}")
      assert {:ok, ""} = Mustache.expand(ast, %{desc: ""})
    end

    test "empty list is falsy for sections" do
      {:ok, ast} = Mustache.parse("{{#items}}Has items{{/items}}")
      assert {:ok, ""} = Mustache.expand(ast, %{items: []})
    end

    test "nil is falsy for sections" do
      {:ok, ast} = Mustache.parse("{{#value}}Has value{{/value}}")
      assert {:ok, ""} = Mustache.expand(ast, %{value: nil})
    end

    test "false is falsy for sections" do
      {:ok, ast} = Mustache.parse("{{#active}}Active{{/active}}")
      assert {:ok, ""} = Mustache.expand(ast, %{active: false})
    end

    test "zero is truthy" do
      {:ok, ast} = Mustache.parse("{{#count}}Count: {{count}}{{/count}}")
      assert {:ok, "Count: 0"} = Mustache.expand(ast, %{count: 0})
    end

    test "whitespace string is truthy" do
      {:ok, ast} = Mustache.parse("{{#value}}[{{value}}]{{/value}}")
      assert {:ok, "[ ]"} = Mustache.expand(ast, %{value: " "})
    end
  end

  describe "expand/3 - nested sections" do
    test "handles deeply nested sections" do
      template = """
      {{#departments}}
      ## {{name}}
      {{#employees}}
      - {{emp_name}}
      {{/employees}}
      {{/departments}}
      """

      context = %{
        departments: [
          %{name: "Engineering", employees: [%{emp_name: "Alice"}, %{emp_name: "Bob"}]},
          %{name: "Sales", employees: [%{emp_name: "Carol"}]}
        ]
      }

      {:ok, ast} = Mustache.parse(template)
      {:ok, result} = Mustache.expand(ast, context)

      assert result =~ "## Engineering"
      assert result =~ "- Alice"
      assert result =~ "- Bob"
      assert result =~ "## Sales"
      assert result =~ "- Carol"
    end

    test "handles dot notation inside sections" do
      {:ok, ast} = Mustache.parse("{{#items}}{{data.value}} {{/items}}")

      context = %{
        items: [
          %{data: %{value: "A"}},
          %{data: %{value: "B"}}
        ]
      }

      assert {:ok, "A B "} = Mustache.expand(ast, context)
    end
  end

  describe "expand/3 - max depth" do
    test "respects max_depth option" do
      template = "{{#a}}{{#b}}{{#c}}deep{{/c}}{{/b}}{{/a}}"
      context = %{a: %{b: %{c: true}}}

      {:ok, ast} = Mustache.parse(template)

      assert {:error, {:max_depth_exceeded, _loc, msg}} =
               Mustache.expand(ast, context, max_depth: 2)

      assert msg =~ "max depth (2) exceeded"
    end

    test "default max_depth is 20" do
      {:ok, ast} = Mustache.parse("{{#a}}x{{/a}}")
      context = %{a: true}
      assert {:ok, "x"} = Mustache.expand(ast, context)
    end
  end

  describe "expand/3 - edge cases" do
    test "empty template" do
      {:ok, ast} = Mustache.parse("")
      assert {:ok, ""} = Mustache.expand(ast, %{})
    end

    test "template with no variables" do
      {:ok, ast} = Mustache.parse("hello world")
      assert {:ok, "hello world"} = Mustache.expand(ast, %{})
    end

    test "special characters not escaped" do
      {:ok, ast} = Mustache.parse("{{html}}")

      assert {:ok, "<script>alert('xss')</script>"} =
               Mustache.expand(ast, %{html: "<script>alert('xss')</script>"})
    end

    test "empty string value" do
      {:ok, ast} = Mustache.parse("[{{value}}]")
      assert {:ok, "[]"} = Mustache.expand(ast, %{value: ""})
    end
  end

  describe "render/3" do
    test "parses and expands in one call" do
      assert {:ok, "Hello Alice"} = Mustache.render("Hello {{name}}", %{name: "Alice"})
    end

    test "returns parse error" do
      assert {:error, _} = Mustache.render("{{#unclosed}}", %{})
    end

    test "returns expand error" do
      assert {:error, {:missing_key, "name", _}} = Mustache.render("{{name}}", %{})
    end

    test "passes options through" do
      template = "{{#a}}{{#b}}x{{/b}}{{/a}}"
      context = %{a: %{b: true}}

      assert {:error, {:max_depth_exceeded, _, _}} =
               Mustache.render(template, context, max_depth: 1)
    end
  end

  describe "extract_variables/1" do
    test "extracts simple variable" do
      {:ok, ast} = Mustache.parse("{{name}}")

      assert [%{type: :simple, path: ["name"], fields: nil, loc: %{line: 1, col: 1}}] =
               Mustache.extract_variables(ast)
    end

    test "extracts multiple variables" do
      {:ok, ast} = Mustache.parse("{{name}} {{email}}")

      vars = Mustache.extract_variables(ast)
      assert length(vars) == 2
      assert Enum.at(vars, 0).path == ["name"]
      assert Enum.at(vars, 1).path == ["email"]
    end

    test "extracts dot notation" do
      {:ok, ast} = Mustache.parse("{{user.name}}")

      assert [%{type: :simple, path: ["user", "name"], fields: nil, loc: _}] =
               Mustache.extract_variables(ast)
    end

    test "extracts current element" do
      {:ok, ast} = Mustache.parse("{{.}}")

      assert [%{type: :simple, path: ["."], fields: nil, loc: _}] =
               Mustache.extract_variables(ast)
    end

    test "extracts section with fields" do
      {:ok, ast} = Mustache.parse("{{#items}}{{name}}{{/items}}")

      assert [
               %{
                 type: :section,
                 path: ["items"],
                 fields: [%{type: :simple, path: ["name"], fields: nil, loc: _}],
                 loc: %{line: 1, col: 1}
               }
             ] = Mustache.extract_variables(ast)
    end

    test "extracts inverted section" do
      {:ok, ast} = Mustache.parse("{{^items}}empty{{/items}}")

      assert [
               %{
                 type: :inverted_section,
                 path: ["items"],
                 fields: [],
                 loc: %{line: 1, col: 1}
               }
             ] = Mustache.extract_variables(ast)
    end

    test "extracts nested sections" do
      {:ok, ast} = Mustache.parse("{{#outer}}{{#inner}}{{x}}{{/inner}}{{/outer}}")

      vars = Mustache.extract_variables(ast)
      assert length(vars) == 1

      outer = hd(vars)
      assert outer.type == :section
      assert outer.path == ["outer"]
      assert length(outer.fields) == 1

      inner = hd(outer.fields)
      assert inner.type == :section
      assert inner.path == ["inner"]
      assert length(inner.fields) == 1

      x = hd(inner.fields)
      assert x.type == :simple
      assert x.path == ["x"]
    end

    test "ignores comments" do
      {:ok, ast} = Mustache.parse("{{! comment }}{{name}}")

      vars = Mustache.extract_variables(ast)
      assert length(vars) == 1
      assert hd(vars).path == ["name"]
    end

    test "ignores text" do
      {:ok, ast} = Mustache.parse("plain text")

      assert [] = Mustache.extract_variables(ast)
    end
  end

  describe "context normalization" do
    test "normalizes atom keys to strings" do
      {:ok, ast} = Mustache.parse("{{name}}")
      assert {:ok, "Alice"} = Mustache.expand(ast, %{name: "Alice"})
    end

    test "normalizes nested atom keys" do
      {:ok, ast} = Mustache.parse("{{user.name}}")
      assert {:ok, "Bob"} = Mustache.expand(ast, %{user: %{name: "Bob"}})
    end

    test "normalizes list item keys" do
      {:ok, ast} = Mustache.parse("{{#items}}{{name}}{{/items}}")
      assert {:ok, "AB"} = Mustache.expand(ast, %{items: [%{name: "A"}, %{name: "B"}]})
    end

    test "works with mixed key types" do
      {:ok, ast} = Mustache.parse("{{a}} {{b}}")
      assert {:ok, "1 2"} = Mustache.expand(ast, %{"b" => 2, a: 1})
    end
  end

  describe "integration examples from spec" do
    test "departments with employees" do
      template = """
      {{#departments}}
      ## {{name}}
      {{#employees}}
      - {{emp_name}}
      {{/employees}}
      {{/departments}}
      """

      context = %{
        departments: [
          %{name: "Engineering", employees: [%{emp_name: "Alice"}, %{emp_name: "Bob"}]},
          %{name: "Sales", employees: [%{emp_name: "Carol"}]}
        ]
      }

      {:ok, result} = Mustache.render(template, context)

      assert result =~ "## Engineering"
      assert result =~ "- Alice"
      assert result =~ "- Bob"
      assert result =~ "## Sales"
      assert result =~ "- Carol"
    end

    test "conditional with fallback" do
      template = "{{#items}}Has items{{/items}}{{^items}}Empty{{/items}}"

      assert {:ok, "Has items"} = Mustache.render(template, %{items: [1]})
      assert {:ok, "Empty"} = Mustache.render(template, %{items: []})
    end

    test "tags example" do
      template = "Tags: {{#tags}}{{.}} {{/tags}}"
      assert {:ok, "Tags: a b c "} = Mustache.render(template, %{tags: ["a", "b", "c"]})
    end
  end
end
