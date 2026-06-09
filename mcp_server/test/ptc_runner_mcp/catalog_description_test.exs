defmodule PtcRunnerMcp.CatalogDescriptionTest do
  @moduledoc """
  Tests for `PtcRunnerMcp.CatalogDescription` — the renderer whose
  output is injected verbatim into the LLM-facing `lisp_eval` tool
  description. Every assertion here guards the text an agent actually
  reads, so a rendering regression is a quality regression for every
  agent call.

  These exercise the two public seams directly with hand-built snapshot
  entries + `CatalogConfig` maps, so no `:persistent_term` is touched
  (the module reads config only via the `render/0` boot path, which we
  intentionally avoid). Hence `async: true`.
  """
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.{CatalogConfig, CatalogDescription}

  defp config(overrides \\ %{}) do
    Map.merge(CatalogConfig.defaults(), overrides)
  end

  defp tool(name, opts \\ []) do
    %{
      "name" => name,
      "description" => Keyword.get(opts, :description, ""),
      "inputSchema" => Keyword.get(opts, :input_schema, %{}),
      "outputSchema" => Keyword.get(opts, :output_schema, %{})
    }
  end

  defp server(name, tools, metadata \\ %{}) do
    %{name: name, tools: tools, metadata: metadata}
  end

  describe "render_for_entries/2 empty / nil short-circuit" do
    test "empty entry list renders nil" do
      assert CatalogDescription.render_for_entries([], config()) == nil
    end
  end

  describe "resolve_mode/2 — explicit modes" do
    test ":lazy config forces lazy regardless of catalog availability" do
      entries = [server("alpha", [tool("a")])]
      assert CatalogDescription.resolve_mode(entries, config(%{catalog_mode: :lazy})) == :lazy
    end

    test ":inline config with a fully-loaded catalog has no warnings" do
      entries = [server("alpha", [tool("a")])]

      assert CatalogDescription.resolve_mode(entries, config(%{catalog_mode: :inline})) ==
               {:inline, []}
    end

    test ":inline config surfaces unknown (nil-tools) servers as sorted warnings" do
      entries = [
        server("zulu", nil),
        server("alpha", nil),
        server("bravo", [tool("ok")])
      ]

      assert CatalogDescription.resolve_mode(entries, config(%{catalog_mode: :inline})) ==
               {:inline, ["alpha", "zulu"]}
    end
  end

  describe "resolve_mode/2 — :auto downgrades" do
    test "auto downgrades to lazy when any catalog is unknown (tools == nil)" do
      entries = [server("loaded", [tool("a")]), server("unknown", nil)]
      assert CatalogDescription.resolve_mode(entries, config()) == :lazy
    end

    test "auto downgrades to lazy when total tool count exceeds the max" do
      tools = for i <- 1..3, do: tool("t#{i}")
      entries = [server("a", tools)]
      cfg = config(%{catalog_inline_max_tools: 2})
      assert CatalogDescription.resolve_mode(entries, cfg) == :lazy
    end

    test "auto downgrades to lazy when the rendered inline body exceeds the char budget" do
      entries = [server("alpha", [tool("a"), tool("b")])]
      # A tiny char budget cannot fit even the signature-only body.
      cfg = config(%{catalog_inline_max_chars: 10})
      assert CatalogDescription.resolve_mode(entries, cfg) == :lazy
    end

    test "auto stays inline when under both the tool count and char budgets" do
      entries = [server("alpha", [tool("a")])]
      cfg = config(%{catalog_inline_max_tools: 8, catalog_inline_max_chars: 5_000})
      assert CatalogDescription.resolve_mode(entries, cfg) == {:inline, []}
    end
  end

  describe "render_for_entries/2 — lazy rendering" do
    test "lazy lists every configured server (sorted) with catalog_loaded flags" do
      entries = [
        server("zulu", nil),
        server("alpha", [tool("a"), tool("b")])
      ]

      out = CatalogDescription.render_for_entries(entries, config(%{catalog_mode: :lazy}))

      assert out =~ "Upstream discovery snapshot:"
      assert out =~ "(tool/servers)"
      # alpha sorts first; it has 2 loaded tools.
      assert out =~ ~s("name" "alpha")
      assert out =~ ~s("tool_count" 2)
      assert out =~ ~s("catalog_loaded" true)
      # zulu has an unknown catalog → nil count, false flag.
      assert out =~ ~s("name" "zulu")
      assert out =~ ~s("tool_count" nil)
      assert out =~ ~s("catalog_loaded" false)
      # lazy never emits a per-server (dir ...) block or a (doc ...) block.
      refute out =~ "(dir "
      refute out =~ "(doc "
    end
  end

  describe "render_for_entries/2 — inline rendering" do
    test "inline emits a servers snapshot, a per-server dir block, and a doc block" do
      entries = [
        server(
          "search",
          [
            tool("query",
              description: "Run a search",
              input_schema: %{
                "type" => "object",
                "properties" => %{"q" => %{"type" => "string"}},
                "required" => ["q"]
              },
              output_schema: %{"type" => "array", "items" => %{"type" => "string"}}
            )
          ]
        )
      ]

      out = CatalogDescription.render_for_entries(entries, config(%{catalog_mode: :inline}))

      assert out =~ "(tool/servers)"
      assert out =~ ~s[(dir "search" {:limit 20})]
      assert out =~ ~s[(doc "search/query")]
      # The doc block is a JSON-encoded lisp string, so its inner quotes
      # are escaped (`\"`). The call example + Result shape live inside it.
      assert out =~ ~S[(tool/call {:server \"search\" :tool \"query\" :args {:q ...}})]
      assert out =~ "Returns: Result<[string]>"
      assert out =~ "Use `(:value r)` after checking `(:ok r)`."
    end

    test "inline doc block picks the alphabetically-first tool of the first loaded server" do
      entries = [
        server("svc", [
          tool("zebra", input_schema: %{}),
          tool("apple", input_schema: %{})
        ])
      ]

      out = CatalogDescription.render_for_entries(entries, config(%{catalog_mode: :inline}))

      assert out =~ ~s[(doc "svc/apple")]
      refute out =~ ~s[(doc "svc/zebra")]
    end

    test "forced-inline (config :inline) appends sorted unknown-server warnings after the body" do
      entries = [
        server("known", [tool("ok")]),
        server("zeta", nil),
        server("amber", nil)
      ]

      out = CatalogDescription.render_for_entries(entries, config(%{catalog_mode: :inline}))

      assert out =~ ~s(Warning: catalog for "amber" not loaded yet.)
      assert out =~ ~s(Warning: catalog for "zeta" not loaded yet.)
      # Warnings come after the discovery body.
      [body, warnings] = String.split(out, "\n\nWarning:", parts: 2)
      assert body =~ "Upstream discovery snapshot"
      assert warnings =~ "not loaded yet"
    end

    test "a server with an empty tool list renders only in the servers snapshot, no dir block" do
      entries = [server("empty", [])]

      out = CatalogDescription.render_for_entries(entries, config(%{catalog_mode: :inline}))

      assert out =~ ~s("name" "empty")
      assert out =~ ~s("tool_count" 0)
      refute out =~ "(dir "
      refute out =~ "(doc "
    end
  end

  describe "description_mode downgrade (with_descriptions vs signature_only)" do
    test "small budget drops descriptions; signature-only doc block omits Description line" do
      long = String.duplicate("alpha beta gamma ", 20)

      entries = [
        server("svc", [tool("only", description: long, input_schema: %{})])
      ]

      # A char budget large enough to render the signature-only body but
      # too small for the with-descriptions body forces signature-only.
      cfg = config(%{catalog_mode: :inline, catalog_inline_max_chars: 400})
      out = CatalogDescription.render_for_entries(entries, cfg)

      refute out =~ "Description:"
      # Inline tool line shows only the name (no " - <desc>" suffix).
      assert out =~ ~s[(dir "svc" {:limit 20})]
    end

    test "generous budget keeps descriptions on the inline tool line and the doc block" do
      entries = [
        server("svc", [tool("only", description: "Helpful tool", input_schema: %{})])
      ]

      cfg = config(%{catalog_mode: :inline, catalog_inline_max_chars: 5_000})
      out = CatalogDescription.render_for_entries(entries, cfg)

      assert out =~ "only - Helpful tool"
      assert out =~ "Description: Helpful tool"
    end
  end

  describe "render_schema_type / arg rendering" do
    defp doc_text(tool) do
      entries = [server("svc", [tool])]
      cfg = config(%{catalog_mode: :inline, catalog_inline_max_chars: 5_000})
      CatalogDescription.render_for_entries(entries, cfg)
    end

    test "scalar JSON types map to lisp type names" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "s" => %{"type" => "string"},
          "i" => %{"type" => "integer"},
          "f" => %{"type" => "number"},
          "b" => %{"type" => "boolean"}
        },
        "required" => ["s", "i", "f", "b"]
      }

      out = doc_text(tool("t", input_schema: schema))
      # Required keys keep schema order; arrow-renamed keywords.
      assert out =~ "Args: {:s string :i int :f float :b bool}"
    end

    test "array type renders element type and nested arrays" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "xs" => %{"type" => "array", "items" => %{"type" => "integer"}}
        },
        "required" => ["xs"]
      }

      out = doc_text(tool("t", input_schema: schema))
      assert out =~ "Args: {:xs [int]}"
    end

    test "optional properties get a ? suffix and sort after required ones" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "req" => %{"type" => "string"},
          "opt" => %{"type" => "string"}
        },
        "required" => ["req"]
      }

      out = doc_text(tool("t", input_schema: schema))
      assert out =~ "Args: {:req string :opt string?}"
      assert out =~ "Required args: :req"
    end

    test "underscored property names render as hyphenated keywords" do
      schema = %{
        "type" => "object",
        "properties" => %{"max_results" => %{"type" => "integer"}},
        "required" => ["max_results"]
      }

      out = doc_text(tool("t", input_schema: schema))
      assert out =~ ":max-results int"
    end

    test "const renders the inspected literal" do
      schema = %{
        "type" => "object",
        "properties" => %{"k" => %{"const" => "fixed"}},
        "required" => ["k"]
      }

      out = doc_text(tool("t", input_schema: schema))
      # Inside the JSON-encoded doc string the literal quotes are escaped.
      assert out =~ ~S(:k \"fixed\")
    end

    test "enum renders a pipe-joined union of literals" do
      schema = %{
        "type" => "object",
        "properties" => %{"mode" => %{"enum" => ["a", "b"]}},
        "required" => ["mode"]
      }

      out = doc_text(tool("t", input_schema: schema))
      assert out =~ ~S(:mode \"a\"|\"b\")
    end

    test "nullable union type strips null and renders the remaining type" do
      schema = %{
        "type" => "object",
        "properties" => %{"maybe" => %{"type" => ["string", "null"]}},
        "required" => ["maybe"]
      }

      out = doc_text(tool("t", input_schema: schema))
      assert out =~ ":maybe string"
    end

    test "nested object property renders an inline struct shape" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "cfg" => %{
            "type" => "object",
            "properties" => %{"k" => %{"type" => "string"}},
            "required" => ["k"]
          }
        },
        "required" => ["cfg"]
      }

      out = doc_text(tool("t", input_schema: schema))
      assert out =~ ":cfg {:k string}"
    end

    test "object with no properties renders as the bare map type" do
      schema = %{
        "type" => "object",
        "properties" => %{"blob" => %{"type" => "object"}},
        "required" => ["blob"]
      }

      out = doc_text(tool("t", input_schema: schema))
      assert out =~ ":blob map"
    end

    test "empty input schema renders {} args and a {} call placeholder" do
      out = doc_text(tool("t", input_schema: %{}))
      assert out =~ "Args: {}"
      assert out =~ "Required args: none"
      assert out =~ ~s[:args {}]
    end

    test "output schema with no type yields Result<any>" do
      out = doc_text(tool("t", input_schema: %{}, output_schema: %{}))
      assert out =~ "Returns: Result<any>"
    end
  end

  describe "server metadata description" do
    test "server metadata description appears (compacted) in the servers snapshot" do
      entries = [
        server("svc", [tool("a")], %{description: "A   multi-line\n  service  "})
      ]

      out = CatalogDescription.render_for_entries(entries, config(%{catalog_mode: :lazy}))
      # Whitespace is collapsed and the trailing period trimmed.
      assert out =~ ~s("description" "A multi-line service")
    end

    test "string-keyed metadata description is honored too" do
      entries = [
        server("svc", [tool("a")], %{"description" => "String keyed"})
      ]

      out = CatalogDescription.render_for_entries(entries, config(%{catalog_mode: :lazy}))
      assert out =~ ~s("description" "String keyed")
    end
  end

  describe "string-keyed snapshot entries" do
    test "render_for_entries normalizes string-keyed entries the same as atom-keyed" do
      atom_entries = [server("svc", [tool("a")])]
      string_entries = [%{"name" => "svc", "tools" => [tool("a")], "metadata" => %{}}]

      cfg = config(%{catalog_mode: :inline})

      assert CatalogDescription.render_for_entries(atom_entries, cfg) ==
               CatalogDescription.render_for_entries(string_entries, cfg)
    end
  end
end
