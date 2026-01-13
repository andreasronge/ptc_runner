defmodule PtcRunner.SubAgent.NamespaceTest do
  use ExUnit.Case, async: true
  doctest PtcRunner.SubAgent.Namespace

  alias PtcRunner.SubAgent.Namespace

  defp make_tool(name, signature) do
    %PtcRunner.Tool{name: name, signature: signature, type: :native}
  end

  describe "render/1" do
    test "returns no tools message for empty config" do
      assert Namespace.render(%{}) == ";; No tools available"
    end

    test "returns no tools message when all sections are empty" do
      config = %{tools: %{}, data: %{}, memory: %{}, has_println: false}
      assert Namespace.render(config) == ";; No tools available"
    end

    test "renders tools section only when tools present" do
      config = %{tools: %{"search" => make_tool("search", "(q :string) -> :string")}}
      result = Namespace.render(config)

      assert result == ";; === tools ===\ntool/search(q) -> string"
    end

    test "renders data/ section with no tools message" do
      config = %{data: %{count: 42}}
      result = Namespace.render(config)

      assert result ==
               ";; No tools available\n\n;; === data/ ===\ndata/count                    ; integer, sample: 42"
    end

    test "renders user/ section with no tools message" do
      config = %{memory: %{total: 100}, has_println: false}
      result = Namespace.render(config)

      assert result ==
               ";; No tools available\n\n;; === user/ (your prelude) ===\ntotal                         ; = integer, sample: 100"
    end

    test "joins sections with blank lines" do
      config = %{
        tools: %{"search" => make_tool("search", "-> :map")},
        data: %{count: 1}
      }

      result = Namespace.render(config)
      sections = String.split(result, "\n\n")

      assert length(sections) == 2
      assert String.starts_with?(Enum.at(sections, 0), ";; === tools ===")
      assert String.starts_with?(Enum.at(sections, 1), ";; === data/ ===")
    end

    test "maintains section order: tools -> data/ -> user/" do
      closure = {:closure, [{:var, :x}], nil, %{}, [], %{}}

      config = %{
        tools: %{"a" => make_tool("a", "-> :int")},
        data: %{b: 2},
        memory: %{c: closure},
        has_println: true
      }

      result = Namespace.render(config)
      sections = String.split(result, "\n\n")

      assert length(sections) == 3
      assert String.starts_with?(Enum.at(sections, 0), ";; === tools ===")
      assert String.starts_with?(Enum.at(sections, 1), ";; === data/ ===")
      assert String.starts_with?(Enum.at(sections, 2), ";; === user/ (your prelude) ===")
    end

    test "always includes tools section even when empty" do
      # Only data present, tools and memory empty
      config = %{
        tools: %{},
        data: %{val: 5},
        memory: %{}
      }

      result = Namespace.render(config)

      # Should have no tools message and data section
      assert result ==
               ";; No tools available\n\n;; === data/ ===\ndata/val                      ; integer, sample: 5"

      assert String.contains?(result, ";; No tools available")
      refute String.contains?(result, ";; === user/")
    end

    test "handles missing config keys with defaults" do
      # Config with only some keys
      config = %{data: %{x: 1}}
      result = Namespace.render(config)

      assert result ==
               ";; No tools available\n\n;; === data/ ===\ndata/x                        ; integer, sample: 1"
    end

    test "passes has_println to User renderer" do
      config = %{memory: %{total: 42}, has_println: true}
      result = Namespace.render(config)

      # With has_println: true, sample is not shown
      assert String.contains?(result, "; = integer")
      refute String.contains?(result, "sample:")
    end

    test "shows sample in user/ when has_println is false" do
      config = %{memory: %{total: 42}, has_println: false}
      result = Namespace.render(config)

      # With has_println: false, sample is shown
      assert String.contains?(result, "sample: 42")
    end

    test "shows map field info in tool signature" do
      # When a tool takes a structured map like %{path: String.t()},
      # the rendered signature should show the required field names
      # so the LLM knows what keys to use
      config = %{
        tools: %{
          "read_file" => make_tool("read_file", "(map {path :string}) -> :string")
        }
      }

      result = Namespace.render(config)

      # Should show the field info, not just "map"
      # The LLM needs to know to use {:path "..."} not {:file "..."}
      assert String.contains?(result, "path"),
             "Expected tool signature to show map field 'path', got: #{result}"

      refute result =~ ~r/read_file\(map\)/,
             "Tool signature should not show bare 'map' without field info"
    end
  end
end
