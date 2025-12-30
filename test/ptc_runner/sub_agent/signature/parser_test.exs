defmodule PtcRunner.SubAgent.Signature.ParserTest do
  use ExUnit.Case

  alias PtcRunner.SubAgent.Signature.Parser

  describe "parse/1 - primitives" do
    test "parses :string" do
      assert {:ok, {:signature, [], :string}} = Parser.parse(":string")
    end

    test "parses :int" do
      assert {:ok, {:signature, [], :int}} = Parser.parse(":int")
    end

    test "parses :float" do
      assert {:ok, {:signature, [], :float}} = Parser.parse(":float")
    end

    test "parses :bool" do
      assert {:ok, {:signature, [], :bool}} = Parser.parse(":bool")
    end

    test "parses :keyword" do
      assert {:ok, {:signature, [], :keyword}} = Parser.parse(":keyword")
    end

    test "parses :any" do
      assert {:ok, {:signature, [], :any}} = Parser.parse(":any")
    end

    test "parses :map" do
      assert {:ok, {:signature, [], :map}} = Parser.parse(":map")
    end
  end

  describe "parse/1 - optional types" do
    test "parses optional primitive" do
      assert {:ok, {:signature, [], {:optional, :string}}} = Parser.parse(":string?")
    end

    test "parses optional in shorthand map" do
      assert {:ok, {:signature, [], {:map, [{"email", {:optional, :string}}]}}} =
               Parser.parse("{email :string?}")
    end

    test "parses optional in parameter" do
      assert {:ok, {:signature, [{"email", {:optional, :string}}], :string}} =
               Parser.parse("(email :string?) -> :string")
    end
  end

  describe "parse/1 - lists" do
    test "parses list of strings" do
      assert {:ok, {:signature, [], {:list, :string}}} = Parser.parse("[:string]")
    end

    test "parses list of integers" do
      assert {:ok, {:signature, [], {:list, :int}}} = Parser.parse("[:int]")
    end

    test "parses list of maps" do
      assert {:ok, {:signature, [], {:list, {:map, [{"id", :int}]}}}} =
               Parser.parse("[{id :int}]")
    end

    test "parses list of optional types" do
      assert {:ok, {:signature, [], {:list, {:optional, :string}}}} =
               Parser.parse("[:string?]")
    end
  end

  describe "parse/1 - maps" do
    test "parses empty map" do
      assert {:ok, {:signature, [], {:map, []}}} = Parser.parse("{}")
    end

    test "parses map with single field" do
      assert {:ok, {:signature, [], {:map, [{"id", :int}]}}} = Parser.parse("{id :int}")
    end

    test "parses map with multiple fields" do
      assert {:ok, {:signature, [], {:map, [{"id", :int}, {"name", :string}]}}} =
               Parser.parse("{id :int, name :string}")
    end

    test "parses map with optional field" do
      assert {:ok, {:signature, [], {:map, [{"id", :int}, {"email", {:optional, :string}}]}}} =
               Parser.parse("{id :int, email :string?}")
    end

    test "parses nested maps" do
      assert {:ok,
              {:signature, [], {:map, [{"user", {:map, [{"id", :int}, {"name", :string}]}}]}}} =
               Parser.parse("{user {id :int, name :string}}")
    end
  end

  describe "parse/1 - full signatures" do
    test "parses no inputs, simple output" do
      assert {:ok, {:signature, [], :string}} = Parser.parse("() -> :string")
    end

    test "parses single input" do
      assert {:ok, {:signature, [{"id", :int}], :string}} =
               Parser.parse("(id :int) -> :string")
    end

    test "parses multiple inputs" do
      assert {:ok, {:signature, [{"query", :string}, {"limit", :int}], {:list, :string}}} =
               Parser.parse("(query :string, limit :int) -> [:string]")
    end

    test "parses nested input types" do
      assert {:ok, {:signature, [{"user", {:map, [{"id", :int}]}}], {:map, [{"name", :string}]}}} =
               Parser.parse("(user {id :int}) -> {name :string}")
    end

    test "parses complex signature" do
      assert {:ok,
              {:signature, [{"query", :string}, {"limit", :int}],
               {:map, [{"count", :int}, {"items", {:list, {:map, [{"id", :int}]}}}]}}} =
               Parser.parse("(query :string, limit :int) -> {count :int, items [{id :int}]}")
    end
  end

  describe "parse/1 - shorthand signatures" do
    test "parses map shorthand" do
      assert {:ok, {:signature, [], {:map, [{"count", :int}]}}} =
               Parser.parse("{count :int}")
    end

    test "parses list shorthand" do
      assert {:ok, {:signature, [], {:list, :string}}} = Parser.parse("[:string]")
    end

    test "parses primitive shorthand" do
      assert {:ok, {:signature, [], :string}} = Parser.parse(":string")
    end
  end

  describe "parse/1 - whitespace handling" do
    test "ignores leading whitespace" do
      assert {:ok, {:signature, [], :string}} = Parser.parse("  :string")
    end

    test "ignores trailing whitespace" do
      assert {:ok, {:signature, [], :string}} = Parser.parse(":string  ")
    end

    test "ignores whitespace in full signature" do
      assert {:ok, {:signature, [{"id", :int}], :string}} =
               Parser.parse("( id :int ) -> :string")
    end

    test "ignores whitespace in map" do
      assert {:ok, {:signature, [], {:map, [{"id", :int}, {"name", :string}]}}} =
               Parser.parse("{ id :int , name :string }")
    end

    test "handles newlines" do
      assert {:ok, {:signature, [{"id", :int}], :string}} =
               Parser.parse("(\n  id :int\n) -> :string")
    end
  end

  describe "parse/1 - field names with hyphens and underscores" do
    test "parses field with hyphen" do
      assert {:ok, {:signature, [], {:map, [{"user-id", :int}]}}} =
               Parser.parse("{user-id :int}")
    end

    test "parses field with underscore" do
      assert {:ok, {:signature, [], {:map, [{"user_id", :int}]}}} =
               Parser.parse("{user_id :int}")
    end

    test "parses firewalled field (underscore prefix)" do
      assert {:ok, {:signature, [], {:map, [{"_email_ids", {:list, :int}}]}}} =
               Parser.parse("{_email_ids [:int]}")
    end

    test "parses parameter with underscore" do
      assert {:ok, {:signature, [{"user_id", :int}], :string}} =
               Parser.parse("(user_id :int) -> :string")
    end
  end

  describe "parse/1 - error cases" do
    test "rejects invalid syntax" do
      assert {:error, _} = Parser.parse("invalid syntax here")
    end

    test "rejects mismatched brackets" do
      assert {:error, _} = Parser.parse("(id :int -> :string")
    end

    test "rejects empty signature" do
      assert {:error, _} = Parser.parse("")
    end

    test "rejects incomplete type" do
      assert {:error, _} = Parser.parse("(id :)")
    end

    test "rejects extra content after signature" do
      assert {:error, _} = Parser.parse("(id :int) -> :string extra")
    end

    test "rejects unknown type keyword" do
      assert {:error, _} = Parser.parse(":unknown")
    end
  end

  describe "parse/1 - edge cases from spec" do
    test "parses :any output" do
      assert {:ok, {:signature, [], :any}} = Parser.parse(":any")
    end

    test "parses empty map" do
      assert {:ok, {:signature, [], {:map, []}}} = Parser.parse("{}")
    end

    test "parses list of empty maps" do
      assert {:ok, {:signature, [], {:list, {:map, []}}}} = Parser.parse("[{}]")
    end

    test "parses deeply nested structures" do
      assert {:ok,
              {:signature, [],
               {:map,
                [
                  {"user",
                   {:map,
                    [
                      {"profile",
                       {:map,
                        [
                          {"settings",
                           {:map,
                            [{"theme", {:map, [{"colors", {:map, [{"primary", :string}]}}]}}]}}
                        ]}}
                    ]}}
                ]}}} =
               Parser.parse("{user {profile {settings {theme {colors {primary :string}}}}}}")
    end
  end
end
