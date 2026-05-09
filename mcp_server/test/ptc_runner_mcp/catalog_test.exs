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
               "github:\n  search_repos(query: string, limit: integer?) - Search repositories"
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

    test "schema with no properties renders as `tool_name() - description`" do
      tools = [
        %{
          name: "ping",
          input_schema: %{},
          description: "Ping the server"
        }
      ]

      output = Catalog.render_entries([%{name: "fs", tools: tools}])

      assert output == "fs:\n  ping() - Ping the server"
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
               "linear:\n  list_tickets(status: enum<string>) - List tickets"
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
  set_mode(mode: const<"fixed">) - Set the fixed mode|
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
      assert output == "u:\n  x(v: enum) - Mixed-type enum"
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

      assert output == "u:\n  short() - Hello world"
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

      assert output == "u:\n  no_desc(x: string)"
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
          search_repos(query: string, limit: integer?) - Search repositories
          get_pr(owner: string, repo: string, number: integer) - Get a pull request

        linear:
          list_tickets(project: string?, status: string?) - List Linear tickets
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

      assert output == "u:\n  x(q: string) - x"
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
               "alpha:\n  ping() - Ping\n\nbeta:\n  (unavailable at startup)"
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
