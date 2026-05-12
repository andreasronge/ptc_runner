defmodule PtcRunnerMcp.CatalogTest do
  @moduledoc """
  Pure rendering tests for `PtcRunnerMcp.Upstream.Catalog`.

  Spec: `Plans/ptc-runner-mcp-aggregator.md` §12.5.1.

  These tests exercise `render_entries/1` directly so the rendering
  rules are pinned without spinning up a Registry. The Registry-driven
  path (`render/1`) is exercised by `tools_phase3_test.exs` and
  `upstream_supervisor_phase3_test.exs`.
  """
  # `async: false` because the freeze-at-boot tests below mutate
  # the global `:persistent_term` slot read by every other test
  # that exercises `Tools.tool_entry/0` in aggregator mode. The
  # render-only tests are pure and async-safe; running the whole
  # module serially avoids cross-test state leaks for the freeze
  # tests at modest cost (16+5 tests, all in-memory, ~50ms total).
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Upstream.Catalog

  setup do
    Catalog.clear_frozen()

    on_exit(fn ->
      Catalog.clear_frozen()
    end)

    :ok
  end

  describe "render_entries/1 — empty inputs" do
    test "empty list → empty string" do
      assert Catalog.render_entries([]) == ""
    end

    test "upstream with no cached tools yet (boot failure) → '(unavailable at startup)'" do
      output = Catalog.render_entries([%{name: "github", tools: nil}])

      assert output == "github:\n  (unavailable at startup)"
    end

    test "upstream with empty tool list → '(no tools advertised)'" do
      output = Catalog.render_entries([%{name: "github", tools: []}])

      assert output == "github:\n  (no tools advertised)"
    end
  end

  describe "structured frozen snapshot" do
    test "freezes and clears a structured snapshot independently of rendered text" do
      entries = [%{name: "github", tools: [], impl: PtcRunnerMcp.Upstream.Http}]

      Catalog.freeze("rendered")
      Catalog.freeze_snapshot(entries)

      assert Catalog.frozen() == "rendered"
      assert Catalog.frozen_snapshot() == entries

      Catalog.clear_frozen()

      assert Catalog.frozen() == ""
      assert Catalog.frozen_snapshot() == []
    end
  end

  describe "render_entries/1 — argument types and required/optional" do
    test "renders required args without `?` and optional args with `?`" do
      tools = [
        %{
          name: "search_repos",
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "query" => %{"type" => "string"},
              "limit" => %{"type" => "integer"}
            },
            "required" => ["query"]
          },
          description: "Search repositories"
        }
      ]

      output = Catalog.render_entries([%{name: "github", tools: tools}])

      assert output ==
               "github:\n  search_repos(query: string, limit: integer?) -> :unknown_content - Search repositories"
    end

    test "all-required args render with no `?`" do
      tools = [
        %{
          name: "get_pr",
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "owner" => %{"type" => "string"},
              "repo" => %{"type" => "string"},
              "number" => %{"type" => "integer"}
            },
            "required" => ["owner", "repo", "number"]
          },
          description: "Get a pull request"
        }
      ]

      output = Catalog.render_entries([%{name: "github", tools: tools}])

      assert output =~ "get_pr(owner: string, repo: string, number: integer)"
      refute output =~ "?"
    end

    test "all-optional args render with `?` on every arg, alphabetical" do
      tools = [
        %{
          name: "list_tickets",
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "status" => %{"type" => "string"},
              "project" => %{"type" => "string"}
            }
          },
          description: "List Linear tickets"
        }
      ]

      output = Catalog.render_entries([%{name: "linear", tools: tools}])

      # Optional-only args render alphabetically: project before status.
      # This is the renderer's deterministic order rule documented in
      # `Catalog.render_args/1` — required-array order preserves
      # required args, but no source can preserve "properties insertion
      # order" reliably across Jason-decoded maps, so we sort optional.
      assert output =~ "list_tickets(project: string?, status: string?)"
    end

    test "complex types (object, array) render as bare type names" do
      tools = [
        %{
          name: "create_issue",
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "labels" => %{"type" => "array"},
              "metadata" => %{"type" => "object"}
            },
            "required" => ["labels"]
          },
          description: "Open an issue"
        }
      ]

      output = Catalog.render_entries([%{name: "github", tools: tools}])

      assert output =~ "create_issue(labels: array, metadata: object?)"
      # The full schema body MUST NOT leak into the catalog — only
      # the bare type label.
      refute output =~ "items"
      refute output =~ "additionalProperties"
    end

    test "schema with no `type` infers from structural keys" do
      tools = [
        %{
          name: "x",
          input_schema: %{
            "properties" => %{
              "obj" => %{"properties" => %{"a" => %{"type" => "string"}}},
              "lst" => %{"items" => %{"type" => "string"}}
            },
            "required" => []
          },
          description: ""
        }
      ]

      output = Catalog.render_entries([%{name: "fs", tools: tools}])

      assert output =~ "obj: object?"
      assert output =~ "lst: array?"
    end

    test "schema with no properties renders as `tool_name() -> :unknown_content - description`" do
      tools = [
        %{
          name: "ping",
          input_schema: %{},
          description: "Ping the server"
        }
      ]

      output = Catalog.render_entries([%{name: "fs", tools: tools}])

      assert output == "fs:\n  ping() -> :unknown_content - Ping the server"
    end

    test "renders compact PTC-Lisp output hints when output_schema is available" do
      tools = [
        %{
          name: "list_entries",
          input_schema: %{
            "type" => "object",
            "properties" => %{"path" => %{"type" => "string"}},
            "required" => ["path"]
          },
          output_schema: %{
            "type" => "object",
            "properties" => %{
              "entries" => %{"type" => "array", "items" => %{"type" => "string"}},
              "truncated" => %{"type" => "boolean"}
            },
            "required" => ["entries"]
          },
          description: "List entries"
        }
      ]

      output = Catalog.render_entries([%{name: "fs", tools: tools}])

      assert output ==
               "fs:\n  list_entries(path: string) -> {entries [:string], truncated :bool?} - List entries"
    end

    test "marks unknown content when output_schema is absent" do
      tools = [
        %{
          name: "list_directory",
          input_schema: %{
            "type" => "object",
            "properties" => %{"path" => %{"type" => "string"}},
            "required" => ["path"]
          },
          description: "Results use [FILE] and [DIR] prefixes"
        }
      ]

      output = Catalog.render_entries([%{name: "fs", tools: tools}])

      assert output ==
               "fs:\n  list_directory(path: string) -> :unknown_content - Results use [FILE] and [DIR] prefixes"
    end

    test "marks nil or malformed output schemas as unknown content" do
      tools = [
        %{
          name: "nil_schema",
          input_schema: %{},
          output_schema: nil,
          description: ""
        },
        %{
          name: "string_schema",
          input_schema: %{},
          output_schema: "not-a-schema",
          description: ""
        }
      ]

      output = Catalog.render_entries([%{name: "fs", tools: tools}])

      assert output =~ "nil_schema() -> :unknown_content"
      assert output =~ "string_schema() -> :unknown_content"
    end

    test "empty output schema remains a schema-backed unknown type" do
      tools = [
        %{
          name: "empty_schema",
          input_schema: %{},
          output_schema: %{},
          description: ""
        }
      ]

      output = Catalog.render_entries([%{name: "fs", tools: tools}])

      assert output == "fs:\n  empty_schema() -> :any"
    end
  end

  describe "render_entries/1 — enum / const constraints take priority over `type`" do
    # The catalog's job is to give the LLM enough info to write correct
    # `(tool/mcp-call ...)` programs. Constrained args are exactly where
    # the LLM needs the hint most — a real-world Linear `list_tickets`
    # tool whose `:status` arg is `{type: "string", enum: ["open",
    # "closed"]}` MUST render `enum<string>`, not `string`, otherwise
    # the model loses the constraint and is more likely to send an
    # invalid value.

    test "schema with type+enum renders as `enum<type>` (homogeneous values)" do
      tools = [
        %{
          name: "list_tickets",
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "status" => %{
                "type" => "string",
                "enum" => ["open", "closed", "merged"]
              }
            },
            "required" => ["status"]
          },
          description: "List tickets"
        }
      ]

      output = Catalog.render_entries([%{name: "linear", tools: tools}])

      assert output ==
               "linear:\n  list_tickets(status: enum<string>) -> :unknown_content - List tickets"
    end

    test "schema with type+const renders as `const<json-encoded-value>`" do
      tools = [
        %{
          name: "set_mode",
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "mode" => %{"type" => "string", "const" => "fixed"}
            },
            "required" => ["mode"]
          },
          description: "Set the fixed mode"
        }
      ]

      output = Catalog.render_entries([%{name: "fs", tools: tools}])

      # Jason encodes string consts with quotes, so the label is
      # `const<"fixed">` — the quotes communicate "this is a string
      # literal" to the LLM, distinguishing string consts from
      # number / boolean consts that render bare.
      assert output ==
               ~S|fs:
  set_mode(mode: const<"fixed">) -> :unknown_content - Set the fixed mode|
    end

    test "heterogeneous enum renders as bare `enum` (no `<type>` subscript)" do
      tools = [
        %{
          name: "x",
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "v" => %{"enum" => ["a", 1, true]}
            },
            "required" => ["v"]
          },
          description: "Mixed-type enum"
        }
      ]

      output = Catalog.render_entries([%{name: "u", tools: tools}])

      # Mixed-type enum cannot be summarized with one primitive
      # subscript without lying. Bare `enum` is the honest label.
      assert output == "u:\n  x(v: enum) -> :unknown_content - Mixed-type enum"
    end

    test "enum constraint without an explicit `type` field still renders as `enum<type>`" do
      tools = [
        %{
          name: "x",
          input_schema: %{
            "properties" => %{
              "choice" => %{"enum" => ["a", "b"]}
            },
            "required" => []
          },
          description: ""
        }
      ]

      output = Catalog.render_entries([%{name: "u", tools: tools}])

      assert output =~ "choice: enum<string>?"
    end

    test "homogeneous integer enum renders as `enum<integer>`" do
      tools = [
        %{
          name: "x",
          input_schema: %{
            "properties" => %{
              "n" => %{"type" => "integer", "enum" => [1, 2, 3]}
            },
            "required" => ["n"]
          },
          description: ""
        }
      ]

      output = Catalog.render_entries([%{name: "u", tools: tools}])

      assert output =~ "n: enum<integer>"
    end

    test "const with a non-string value renders the encoded primitive" do
      tools = [
        %{
          name: "x",
          input_schema: %{
            "properties" => %{
              "n" => %{"type" => "integer", "const" => 42}
            },
            "required" => ["n"]
          },
          description: ""
        }
      ]

      output = Catalog.render_entries([%{name: "u", tools: tools}])

      assert output =~ "n: const<42>"
    end

    # Regression: `{"const": <falsy>}` schemas. A truthy-binding cond
    # in `render_type/1` would skip the const branch entirely for any
    # falsy value (`false`, `null`, `0`, `""`) and render the schema
    # as the primitive type instead, dropping the constraint label.
    test "const: false renders as `const<false>`, not as `boolean`" do
      tools = [
        %{
          name: "x",
          input_schema: %{
            "properties" => %{"flag" => %{"type" => "boolean", "const" => false}},
            "required" => ["flag"]
          },
          description: ""
        }
      ]

      output = Catalog.render_entries([%{name: "u", tools: tools}])

      assert output =~ "flag: const<false>"
      refute output =~ "flag: boolean"
    end

    test "const: null renders as `const<null>`, not as primitive type" do
      tools = [
        %{
          name: "x",
          input_schema: %{
            "properties" => %{"v" => %{"type" => "null", "const" => nil}},
            "required" => ["v"]
          },
          description: ""
        }
      ]

      output = Catalog.render_entries([%{name: "u", tools: tools}])

      assert output =~ "v: const<null>"
    end

    test "const: 0 renders as `const<0>`, not as `integer`" do
      tools = [
        %{
          name: "x",
          input_schema: %{
            "properties" => %{"n" => %{"type" => "integer", "const" => 0}},
            "required" => ["n"]
          },
          description: ""
        }
      ]

      output = Catalog.render_entries([%{name: "u", tools: tools}])

      assert output =~ "n: const<0>"
      refute output =~ "n: integer"
    end

    test ~s|const: "" renders as `const<"">`, not as `string`| do
      tools = [
        %{
          name: "x",
          input_schema: %{
            "properties" => %{"s" => %{"type" => "string", "const" => ""}},
            "required" => ["s"]
          },
          description: ""
        }
      ]

      output = Catalog.render_entries([%{name: "u", tools: tools}])

      assert output =~ ~s|s: const<"">|
      refute output =~ "s: string"
    end
  end

  describe "render_entries/1 — description handling" do
    test "description shorter than 80 chars renders verbatim" do
      tools = [
        %{
          name: "short",
          input_schema: %{},
          description: "Hello world"
        }
      ]

      output = Catalog.render_entries([%{name: "u", tools: tools}])

      assert output == "u:\n  short() -> :unknown_content - Hello world"
    end

    test "description longer than 80 chars hard-truncates with ellipsis suffix" do
      long = String.duplicate("a", 100)

      tools = [
        %{
          name: "long",
          input_schema: %{},
          description: long
        }
      ]

      output = Catalog.render_entries([%{name: "u", tools: tools}])

      # 80-char cap, with "..." occupying the last 3 chars.
      [_, line] = String.split(output, "\n")
      [_, desc] = String.split(line, " - ")

      assert String.length(desc) == 80
      assert String.ends_with?(desc, "...")
    end

    test "multi-line description collapses internal whitespace into single spaces" do
      tools = [
        %{
          name: "wrap",
          input_schema: %{},
          description: "Line one.\n\nLine two.\n  Indented continuation."
        }
      ]

      output = Catalog.render_entries([%{name: "u", tools: tools}])

      # No newlines or runs of whitespace in the rendered description.
      [_, line] = String.split(output, "\n")
      [_, desc] = String.split(line, " - ")
      assert desc == "Line one. Line two. Indented continuation."
    end

    test "missing description renders without the ` - <desc>` suffix" do
      tools = [
        %{
          name: "no_desc",
          input_schema: %{
            "type" => "object",
            "properties" => %{"x" => %{"type" => "string"}},
            "required" => ["x"]
          }
        }
      ]

      output = Catalog.render_entries([%{name: "u", tools: tools}])

      assert output == "u:\n  no_desc(x: string) -> :unknown_content"
    end
  end

  describe "render_entries/1 — multiple upstreams + spec example" do
    test "matches the §12.5 worked example" do
      entries = [
        %{
          name: "github",
          tools: [
            %{
              name: "search_repos",
              input_schema: %{
                "type" => "object",
                "properties" => %{
                  "query" => %{"type" => "string"},
                  "limit" => %{"type" => "integer"}
                },
                "required" => ["query"]
              },
              description: "Search repositories"
            },
            %{
              name: "get_pr",
              input_schema: %{
                "type" => "object",
                "properties" => %{
                  "owner" => %{"type" => "string"},
                  "repo" => %{"type" => "string"},
                  "number" => %{"type" => "integer"}
                },
                "required" => ["owner", "repo", "number"]
              },
              description: "Get a pull request"
            }
          ]
        },
        %{
          name: "linear",
          tools: [
            %{
              name: "list_tickets",
              input_schema: %{
                "type" => "object",
                "properties" => %{
                  "status" => %{"type" => "string"},
                  "project" => %{"type" => "string"}
                }
              },
              description: "List Linear tickets"
            }
          ]
        }
      ]

      # Renderer-deterministic ordering: required args in `required`-array
      # order; optional args alphabetical. The §12.5 illustrative example
      # has `list_tickets(status, project)`; both args are optional so
      # we render `project, status`.
      expected =
        """
        github:
          search_repos(query: string, limit: integer?) -> :unknown_content - Search repositories
          get_pr(owner: string, repo: string, number: integer) -> :unknown_content - Get a pull request

        linear:
          list_tickets(project: string?, status: string?) -> :unknown_content - List Linear tickets
        """
        |> String.trim_trailing()

      assert Catalog.render_entries(entries) == expected
    end

    test "atom-keyed schemas (Elixir-side fixtures) render the same as string-keyed" do
      tools = [
        %{
          name: "x",
          input_schema: %{
            type: "object",
            properties: %{q: %{type: "string"}},
            required: [:q]
          },
          description: "x"
        }
      ]

      output = Catalog.render_entries([%{name: "u", tools: tools}])

      assert output == "u:\n  x(q: string) -> :unknown_content - x"
    end

    test "empty cached_tools mixes with populated ones — placeholder only for the bad upstream" do
      entries = [
        %{
          name: "alpha",
          tools: [
            %{name: "ping", input_schema: %{}, description: "Ping"}
          ]
        },
        %{name: "beta", tools: nil}
      ]

      output = Catalog.render_entries(entries)

      assert output ==
               "alpha:\n  ping() -> :unknown_content - Ping\n\nbeta:\n  (unavailable at startup)"
    end
  end

  describe "render_entries/1 — `[transport: …]` header annotation (§9.1)" do
    # Per `Plans/http-transport-credentials.md` §9.1 the per-server
    # header gains an optional `[transport: stdio|http]` tag derived
    # from the upstream's `:impl` module. The tag exists so the LLM
    # can see which servers are local-only vs network-dependent
    # without inflating the catalog meaningfully. Only the two real
    # transports (`Stdio` / `Http`) get a tag; `Fake` and unknown
    # impls render with the pre-§9.1 `name:` header so existing
    # Fake-driven Registry tests stay byte-equal.

    test "stdio + http upstreams render side-by-side with their transport tags" do
      tools = [%{name: "ping", input_schema: %{}, description: "Ping"}]

      entries = [
        %{name: "fs", tools: tools, impl: PtcRunnerMcp.Upstream.Stdio},
        %{name: "github", tools: tools, impl: PtcRunnerMcp.Upstream.Http}
      ]

      output = Catalog.render_entries(entries)

      assert output =~ "fs [transport: stdio]:"
      assert output =~ "github [transport: http]:"
    end

    test "single stdio upstream gets `[transport: stdio]`" do
      tools = [%{name: "ping", input_schema: %{}, description: "Ping"}]

      output =
        Catalog.render_entries([
          %{name: "fs", tools: tools, impl: PtcRunnerMcp.Upstream.Stdio}
        ])

      assert output =~ "fs [transport: stdio]:"
      assert output =~ "ping() -> :unknown_content - Ping"
    end

    test "single http upstream gets `[transport: http]`" do
      tools = [%{name: "search_repos", input_schema: %{}, description: "Search"}]

      output =
        Catalog.render_entries([
          %{name: "github", tools: tools, impl: PtcRunnerMcp.Upstream.Http}
        ])

      assert output =~ "github [transport: http]:"
      assert output =~ "search_repos() -> :unknown_content - Search"
    end

    test "Fake impl renders WITHOUT a transport tag" do
      # Fake is in-process and only used in tests; emitting
      # `[transport: fake]` would (a) leak test machinery into the
      # advertised description if a misconfigured production deploy
      # ended up wired to Fake, and (b) break every existing Registry-
      # driven catalog test (they assert `=~ "name:"`). The
      # conservative choice is to render Fake the same as a missing
      # impl: bare `name:` header.
      tools = [%{name: "ping", input_schema: %{}, description: "Ping"}]

      output =
        Catalog.render_entries([
          %{name: "u", tools: tools, impl: PtcRunnerMcp.Upstream.Fake}
        ])

      assert output == "u:\n  ping() -> :unknown_content - Ping"
      refute output =~ "[transport:"
    end

    test "missing :impl key renders WITHOUT a transport tag (back-compat)" do
      # The pre-§9.1 entry shape has no `:impl` key at all. The
      # render_entries/1 typespec marks `:impl` as optional; absent
      # means "no annotation," preserving every existing test that
      # doesn't supply an impl.
      tools = [%{name: "ping", input_schema: %{}, description: "Ping"}]

      output = Catalog.render_entries([%{name: "u", tools: tools}])

      assert output == "u:\n  ping() -> :unknown_content - Ping"
    end

    test "explicit nil :impl renders WITHOUT a transport tag" do
      tools = [%{name: "ping", input_schema: %{}, description: "Ping"}]

      output =
        Catalog.render_entries([%{name: "u", tools: tools, impl: nil}])

      assert output == "u:\n  ping() -> :unknown_content - Ping"
    end

    test "unknown impl module renders WITHOUT a transport tag" do
      tools = [%{name: "ping", input_schema: %{}, description: "Ping"}]

      output =
        Catalog.render_entries([%{name: "u", tools: tools, impl: SomeOther.Module}])

      assert output == "u:\n  ping() -> :unknown_content - Ping"
    end

    test "transport tag appears ONLY on the per-server header — not on tool description lines" do
      tools = [
        %{
          name: "search_repos",
          input_schema: %{
            "type" => "object",
            "properties" => %{"query" => %{"type" => "string"}},
            "required" => ["query"]
          },
          description: "Search repositories"
        },
        %{
          name: "get_pr",
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "owner" => %{"type" => "string"},
              "repo" => %{"type" => "string"},
              "number" => %{"type" => "integer"}
            },
            "required" => ["owner", "repo", "number"]
          },
          description: "Get a pull request"
        }
      ]

      output =
        Catalog.render_entries([
          %{name: "github", tools: tools, impl: PtcRunnerMcp.Upstream.Http}
        ])

      [header_line | tool_lines] = String.split(output, "\n")

      # Header carries the tag.
      assert header_line == "github [transport: http]:"

      # Tool description lines MUST NOT carry the tag — exactly one
      # `[transport: …]` substring in the whole output.
      for line <- tool_lines do
        refute line =~ "[transport:"
      end

      assert length(Regex.scan(~r/\[transport:/, output)) == 1
    end

    test "transport tag appears on `(unavailable at startup)` placeholder header too" do
      # An upstream whose eager-start failed renders with the
      # placeholder body, but the header is still derived from the
      # configured impl — the LLM still benefits from knowing whether
      # the broken upstream is HTTP or stdio.
      output =
        Catalog.render_entries([
          %{name: "github", tools: nil, impl: PtcRunnerMcp.Upstream.Http}
        ])

      assert output == "github [transport: http]:\n  (unavailable at startup)"
    end

    test "transport tag appears on `(no tools advertised)` placeholder header too" do
      output =
        Catalog.render_entries([
          %{name: "fs", tools: [], impl: PtcRunnerMcp.Upstream.Stdio}
        ])

      assert output == "fs [transport: stdio]:\n  (no tools advertised)"
    end
  end

  describe "outputSchema (§9.3) — auth + http_status optional fields" do
    # Plan §9.3: the aggregator-mode `outputSchema`'s upstream_calls
    # entry schema gains two optional fields — `auth` (object) and
    # `http_status` (integer). Strict validators on the consumer side
    # MUST accept HTTP-augmented entries as valid §8.5 records.

    alias PtcRunnerMcp.Tools

    test "upstream_calls items.properties contains both `auth` (object) and `http_status` (integer)" do
      schema = Tools.output_schema_for(:mcp_aggregator)

      # The aggregator schema is `{type: object, oneOf: [...]}`; each
      # branch's `properties.upstream_calls` carries the entry-shape.
      branches = schema["oneOf"]
      assert is_list(branches) and branches != []

      for branch <- branches do
        upstream_calls = get_in(branch, ["properties", "upstream_calls"])
        assert upstream_calls["type"] == "array"

        item_props = get_in(upstream_calls, ["items", "properties"])
        assert is_map(item_props)

        # `auth` is an object with required {scheme, binding}.
        auth = item_props["auth"]
        assert auth["type"] == "object"
        assert auth["required"] == ["scheme", "binding"]
        assert get_in(auth, ["properties", "scheme", "type"]) == "string"
        assert get_in(auth, ["properties", "binding", "type"]) == "string"

        # `http_status` is an integer (HTTP status range).
        http_status = item_props["http_status"]
        assert http_status["type"] == "integer"

        # Both MUST be optional (not in the items.required array).
        required = get_in(upstream_calls, ["items", "required"])
        refute "auth" in required
        refute "http_status" in required
      end
    end

    test "stdio profile (`:mcp_no_tools`) does NOT carry upstream_calls (and therefore not auth/http_status)" do
      # Sanity guard: the new optional fields belong to the aggregator
      # profile only. The base v1 outputSchema MUST stay byte-for-byte
      # unchanged so non-aggregator deploys aren't paying for HTTP
      # fields they can't produce.
      schema = Tools.output_schema_for(:mcp_no_tools)

      for branch <- schema["oneOf"] do
        refute Map.has_key?(branch["properties"], "upstream_calls")
      end
    end
  end

  describe "frozen/0 + freeze/1 + clear_frozen/0 (§12.5 freeze-at-boot)" do
    # These tests share the global `:persistent_term` slot, so they
    # MUST clear on entry and exit to avoid leaking state across the
    # test suite (other test files read `frozen/0` via
    # `Tools.tool_entry/0`).
    setup do
      prior = Catalog.frozen()
      Catalog.clear_frozen()

      on_exit(fn ->
        Catalog.clear_frozen()

        if prior != "" do
          Catalog.freeze(prior)
        end
      end)

      :ok
    end

    test ~S|frozen/0 returns "" when nothing has been frozen| do
      assert Catalog.frozen() == ""
    end

    test "freeze/1 stores a string that frozen/0 returns verbatim" do
      catalog = "github:\n  search_repos(query: string) - Search repositories"

      assert :ok = Catalog.freeze(catalog)
      assert Catalog.frozen() == catalog
    end

    test "freeze/1 overwrites a prior freeze (idempotent re-freeze)" do
      :ok = Catalog.freeze("first")
      :ok = Catalog.freeze("second")
      assert Catalog.frozen() == "second"
    end

    test "clear_frozen/0 returns frozen/0 to the empty default" do
      :ok = Catalog.freeze("anything")
      assert Catalog.frozen() == "anything"

      :ok = Catalog.clear_frozen()
      assert Catalog.frozen() == ""
    end
  end
end
