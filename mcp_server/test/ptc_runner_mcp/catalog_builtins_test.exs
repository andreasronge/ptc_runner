defmodule PtcRunnerMcp.CatalogBuiltinsTest do
  @moduledoc """
  Tests for `PtcRunnerMcp.CatalogBuiltins` — the discovery executor
  closure builder for PTC-Lisp REPL discovery forms.

  Each test starts its own isolated `Upstream.Registry` so tests run
  in parallel without colliding on the global registry name.
  """
  use ExUnit.Case, async: false

  import PtcRunnerMcp.McpTestHelpers, only: [stop_existing_registry: 1]

  alias PtcRunnerMcp.{CatalogBuiltins, CatalogConfig, UpstreamCalls}
  alias PtcRunnerMcp.Upstream.Registry

  @registry_name PtcRunnerMcp.CatalogBuiltinsTestRegistry

  setup do
    stop_existing_registry(@registry_name)

    {:ok, _pid} = Registry.start_link(name: @registry_name)
    CatalogConfig.set(CatalogConfig.defaults())

    on_exit(fn ->
      stop_existing_registry(@registry_name)
      CatalogConfig.set(CatalogConfig.defaults())
    end)

    :ok
  end

  defp tools_config(tools) do
    %{
      tools:
        Map.new(tools, fn {n, fun} ->
          schema = %{
            name: n,
            description: "Tool #{n}",
            input_schema: %{
              "type" => "object",
              "properties" => %{"query" => %{"type" => "string"}},
              "required" => ["query"]
            }
          }

          {n, {schema, fun}}
        end)
    }
  end

  defp put_fake(name, tools, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    map = Map.new(tools)
    config = Map.merge(tools_config(map), %{metadata: metadata})
    :ok = Registry.put_fake(name, config, @registry_name)
    {:ok, _} = Registry.ensure_started(name, @registry_name)
  end

  defp build_exec(call_context_opts \\ []) do
    call_context =
      UpstreamCalls.new_call_context(
        Keyword.merge(
          [
            collector_pid: self(),
            collector_ref: make_ref(),
            max_calls: 100,
            call_timeout_ms: 5000,
            max_response_bytes: 1_000_000
          ],
          call_context_opts
        )
      )

    exec =
      CatalogBuiltins.build(call_context,
        registry: @registry_name,
        catalog_config: CatalogConfig.get()
      )

    {exec, call_context}
  end

  defp tool_names_from_lines(lines) do
    Enum.map(lines, fn line ->
      [_, name] = Regex.run(~r/^(?:[^.]+\.|)([^\s(-]+)/, line)
      name
    end)
  end

  # ============================================================
  # mcp/servers
  # ============================================================

  describe "servers" do
    test "returns server summaries" do
      put_fake("github", [{"search", fn _ -> "ok" end}], metadata: %{description: "GitHub"})

      put_fake("linear", [{"create_issue", fn _ -> "ok" end}], metadata: %{description: "Linear"})

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:servers, [])

      assert is_list(result)
      assert length(result) == 2

      names = Enum.map(result, & &1["name"])
      assert "github" in names
      assert "linear" in names

      github = Enum.find(result, &(&1["name"] == "github"))
      assert github["description"] == "GitHub"
      assert github["tool_count"] == 1
      assert github["catalog_loaded"] == true
    end
  end

  # ============================================================
  # dir
  # ============================================================

  describe "dir" do
    test "returns sorted tool summaries for a server" do
      put_fake("github", [
        {"search_issues", fn _ -> "ok" end},
        {"get_pr", fn _ -> "ok" end}
      ])

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:dir, ["github"])

      assert is_list(result)
      assert length(result) == 2

      tool_names = tool_names_from_lines(result)
      assert tool_names == Enum.sort(tool_names)
    end

    test "returns compact tool description strings" do
      put_fake("github", [{"search", fn _ -> "ok" end}])

      {exec, _ctx} = build_exec()
      {:ok, [tool]} = exec.(:dir, ["github"])

      assert tool =~ "search"
      assert tool =~ " - Tool search"
    end

    test "omits return type when upstream does not provide output_schema" do
      schema = %{
        name: "search",
        description: "Search things",
        input_schema: %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}},
          "required" => ["query"]
        }
      }

      config = %{tools: %{"search" => {schema, fn _ -> "ok" end}}, metadata: %{}}
      :ok = Registry.put_fake("github", config, @registry_name)
      {:ok, _} = Registry.ensure_started("github", @registry_name)

      {exec, _ctx} = build_exec()
      {:ok, [tool]} = exec.(:dir, ["github"])

      assert tool == "search - Search things"
      refute tool =~ " -> "
    end

    test "dir omits return type even when upstream provides output_schema" do
      schema = %{
        name: "search",
        description: "Search things",
        input_schema: %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}},
          "required" => ["query"]
        },
        output_schema: %{
          "type" => "object",
          "properties" => %{"items" => %{"type" => "array"}, "next" => %{"type" => "string"}},
          "required" => ["items"]
        }
      }

      config = %{tools: %{"search" => {schema, fn _ -> "ok" end}}, metadata: %{}}
      :ok = Registry.put_fake("github", config, @registry_name)
      {:ok, _} = Registry.ensure_started("github", @registry_name)

      {exec, _ctx} = build_exec()
      {:ok, [tool]} = exec.(:dir, ["github"])

      assert tool == "search - Search things"
    end

    test "unknown server is programmer fault" do
      {exec, _ctx} = build_exec()
      assert {:programmer_fault, msg} = exec.(:dir, ["nonexistent"])
      assert msg =~ "no upstream 'nonexistent' configured"
    end

    test "respects :limit option" do
      tools = Enum.map(1..10, fn i -> {"tool_#{i}", fn _ -> "ok" end} end)
      put_fake("big", tools)

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:dir, ["big", %{limit: 3}])
      assert length(result) == 3
    end

    test "respects :offset option" do
      tools =
        Enum.map(1..5, fn i ->
          name = "tool_#{String.pad_leading(to_string(i), 2, "0")}"
          {name, fn _ -> "ok" end}
        end)

      put_fake("srv", tools)

      {exec, _ctx} = build_exec()
      {:ok, all} = exec.(:dir, ["srv"])
      {:ok, offset} = exec.(:dir, ["srv", %{offset: 2}])

      assert length(offset) == 3
      assert tool_names_from_lines(offset) == tool_names_from_lines(Enum.drop(all, 2))
    end

    test "invalid limit is programmer fault" do
      put_fake("srv", [{"t", fn _ -> "ok" end}])
      {exec, _ctx} = build_exec()

      assert {:programmer_fault, msg} = exec.(:dir, ["srv", %{limit: 999}])
      assert msg =~ "limit"

      assert {:programmer_fault, _} = exec.(:dir, ["srv", %{limit: -1}])
      assert {:programmer_fault, _} = exec.(:dir, ["srv", %{limit: "five"}])
    end

    test "invalid offset is programmer fault" do
      put_fake("srv", [{"t", fn _ -> "ok" end}])
      {exec, _ctx} = build_exec()

      assert {:programmer_fault, msg} = exec.(:dir, ["srv", %{offset: -1}])
      assert msg =~ "offset"
    end

    test "0-tool server returns empty list" do
      put_fake("empty", [])
      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:dir, ["empty"])
      assert result == []
    end
  end

  # ============================================================
  # apropos
  # ============================================================

  describe "apropos" do
    test "returns tool-level matches for loaded servers" do
      put_fake("github", [
        {"search_issues", fn _ -> "ok" end},
        {"search_repos", fn _ -> "ok" end},
        {"get_issue", fn _ -> "ok" end}
      ])

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:apropos, ["search"])

      assert is_list(result)
      assert length(result) >= 2

      tool_names = tool_names_from_lines(result)
      assert "search_issues" in tool_names
      assert "search_repos" in tool_names
    end

    test "deterministic ordering: same query always produces same order" do
      put_fake("alpha", [
        {"find_items", fn _ -> "ok" end},
        {"find_users", fn _ -> "ok" end}
      ])

      put_fake("beta", [
        {"find_records", fn _ -> "ok" end}
      ])

      {exec, _ctx} = build_exec()

      {:ok, result1} = exec.(:apropos, ["find"])
      {:ok, result2} = exec.(:apropos, ["find"])

      assert result1 == result2
    end

    test "exact match scores higher than substring" do
      put_fake("srv", [
        {"search", fn _ -> "ok" end},
        {"research_data", fn _ -> "ok" end}
      ])

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:apropos, ["search"])

      assert [first | _] = result
      assert first =~ "srv.search"
    end

    test "tool name matches rank higher than description-only matches" do
      put_fake(
        "srv",
        [
          {"list_users", fn _ -> "ok" end},
          {"get_data", fn _ -> "ok" end}
        ],
        metadata: %{description: "Server for users"}
      )

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:apropos, ["users"])

      assert [first | _] = result
      assert first =~ "srv.list_users"
    end

    test "empty query is programmer fault" do
      put_fake("srv", [{"t", fn _ -> "ok" end}])
      {exec, _ctx} = build_exec()

      assert {:programmer_fault, msg} = exec.(:apropos, [""])
      assert msg =~ "non-empty string"
    end

    test "whitespace-only query is programmer fault" do
      put_fake("srv", [{"t", fn _ -> "ok" end}])
      {exec, _ctx} = build_exec()

      assert {:programmer_fault, msg} = exec.(:apropos, ["   "])
      assert msg =~ "non-empty string"
    end

    test "invalid limit is programmer fault" do
      put_fake("srv", [{"t", fn _ -> "ok" end}])
      {exec, _ctx} = build_exec()

      assert {:programmer_fault, _} = exec.(:apropos, ["q", %{limit: 100}])
      assert {:programmer_fault, _} = exec.(:apropos, ["q", %{limit: 0}])
      assert {:programmer_fault, _} = exec.(:apropos, ["q", %{limit: "five"}])
    end

    test "invalid load option is programmer fault" do
      put_fake("srv", [{"t", fn _ -> "ok" end}])
      {exec, _ctx} = build_exec()

      assert {:programmer_fault, msg} = exec.(:apropos, ["q", %{load: "yes"}])
      assert msg =~ ":load must be a boolean"
    end

    test "respects :limit option" do
      tools = Enum.map(1..20, fn i -> {"tool_#{i}", fn _ -> "ok" end} end)
      put_fake("big", tools)

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:apropos, ["tool", %{limit: 3}])
      assert length(result) <= 3
    end

    test "no matching results returns empty list" do
      put_fake("srv", [{"alpha", fn _ -> "ok" end}])

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:apropos, ["zzzznonexistent"])
      assert result == []
    end

    test "server-level matches for unloaded upstreams" do
      config = tools_config(%{"t" => fn _ -> "ok" end})

      :ok =
        Registry.put_fake(
          "github",
          Map.put(config, :metadata, %{description: "GitHub API"}),
          @registry_name
        )

      # Don't ensure_started — stays unloaded

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:apropos, ["github"])

      assert [_ | _] = result
      server_match = Enum.find(result, &String.starts_with?(&1, "github:"))
      assert server_match != nil
      assert server_match =~ "Catalog not loaded"
      assert server_match =~ ~s|dir "github"|
    end

    test "server-level matches escape non-symbol-safe server names in hints" do
      config = tools_config(%{"t" => fn _ -> "ok" end})

      :ok =
        Registry.put_fake(
          "my server/one",
          Map.put(config, :metadata, %{description: "special server"}),
          @registry_name
        )

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:apropos, ["special"])

      assert [server_match] = Enum.filter(result, &String.starts_with?(&1, "my server/one:"))
      assert server_match =~ ~s|Use (dir "my server/one" {:limit 20}).|
    end

    test ":load true loads catalogs and returns tool-level matches" do
      config = tools_config(%{"search_issues" => fn _ -> "ok" end})

      :ok =
        Registry.put_fake(
          "github",
          Map.put(config, :metadata, %{description: "GitHub"}),
          @registry_name
        )

      # Don't ensure_started — stays unloaded until :load true

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:apropos, ["search", %{load: true}])

      assert [_ | _] = result
      tool_match = Enum.find(result, &String.starts_with?(&1, "github.search_issues"))
      assert tool_match != nil
    end

    test "multi-server search returns results from all loaded servers" do
      put_fake("github", [{"search_issues", fn _ -> "ok" end}])
      put_fake("linear", [{"search_tickets", fn _ -> "ok" end}])

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:apropos, ["search"])

      assert Enum.any?(result, &String.starts_with?(&1, "github.search_issues"))
      assert Enum.any?(result, &String.starts_with?(&1, "linear.search_tickets"))
    end

    test "result includes server and tool name in the display string" do
      put_fake("srv", [{"tool_a", fn _ -> "ok" end}])

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:apropos, ["tool"])

      assert [first | _] = result
      assert first =~ "srv.tool_a"
    end

    test "result-size truncation via max_catalog_result_bytes" do
      tools = Enum.map(1..20, fn i -> {"search_tool_#{i}", fn _ -> "ok" end} end)
      put_fake("big", tools)

      CatalogConfig.set(%{max_catalog_result_bytes: 120})
      {exec, _ctx} = build_exec()
      result = exec.(:apropos, ["search"])

      case result do
        {:ok, items} ->
          assert length(items) < 20
          assert List.last(items) =~ "shown"

        {:world_fault, :catalog_result_too_large} ->
          :ok
      end
    end

    # Regression for issue #944 finding #4: a query that matches the server
    # description but NOT any individual tool's name/args/own-description
    # should not pull in arbitrary tools from that server. Reporter saw
    # fs/create_directory, fs/directory_tree, fs/edit_file rank for query
    # "search" purely because the fs server's description mentioned search.
    test "tools without a tool-specific match are not pulled in by server-desc tokens" do
      config = %{
        tools:
          Map.new(
            %{
              "search_files" => %{
                name: "search_files",
                description: "Recursively search for files matching a pattern",
                input_schema: %{"properties" => %{"pattern" => %{}}, "required" => ["pattern"]}
              },
              "create_directory" => %{
                name: "create_directory",
                description: "Create a new directory",
                input_schema: %{"properties" => %{"path" => %{}}, "required" => ["path"]}
              },
              "directory_tree" => %{
                name: "directory_tree",
                description: "Get a recursive tree view of files and directories",
                input_schema: %{"properties" => %{"path" => %{}}, "required" => ["path"]}
              },
              "edit_file" => %{
                name: "edit_file",
                description: "Make line-based edits to a text file",
                input_schema: %{"properties" => %{"path" => %{}}, "required" => ["path"]}
              }
            },
            fn {n, schema} -> {n, {schema, fn _ -> "ok" end}} end
          )
      }

      :ok =
        Registry.put_fake(
          "fs",
          Map.put(config, :metadata, %{
            description: "Filesystem access with read, write, and search capability"
          }),
          @registry_name
        )

      {:ok, _} = Registry.ensure_started("fs", @registry_name)

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:apropos, ["search", %{limit: 5}])

      names = tool_names_from_lines(result)

      # The actually-search-related tool must be present.
      assert "search_files" in names

      # Tools whose name/description/args don't mention "search" must
      # not be pulled in by the server-description boost alone.
      refute "create_directory" in names
      refute "directory_tree" in names
      refute "edit_file" in names
    end

    # Codex review caught a remaining gap in the #4 fix: when the query
    # matches ONLY the server description and no tool, the relative filter
    # falls back to "keep all tools" — which reproduces the original noise.
    # Server-NAME matches are legitimate fallback ("I asked about server X")
    # but server-description/capability matches are not.
    test "server-description-only match drops tools (codex edge case)" do
      config = %{
        tools:
          Map.new(
            %{
              "create_directory" => %{
                name: "create_directory",
                description: "Create a new directory",
                input_schema: %{"properties" => %{"path" => %{}}}
              },
              "edit_file" => %{
                name: "edit_file",
                description: "Make line-based edits to a text file",
                input_schema: %{"properties" => %{"path" => %{}}}
              }
            },
            fn {n, schema} -> {n, {schema, fn _ -> "ok" end}} end
          )
      }

      :ok =
        Registry.put_fake(
          "fs",
          Map.put(config, :metadata, %{
            description: "Filesystem with search capability"
          }),
          @registry_name
        )

      {:ok, _} = Registry.ensure_started("fs", @registry_name)

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:apropos, ["search", %{limit: 5}])

      # No tool matches "search" specifically, and the server NAME doesn't
      # match either — so no results should be returned. The description
      # mention alone isn't a license to dump every tool from the server.
      assert result == []
    end

    test "query matching server name returns all tools on that server" do
      config = %{
        tools:
          Map.new(
            %{
              "tool_a" => %{name: "tool_a", description: "first tool", input_schema: %{}},
              "tool_b" => %{name: "tool_b", description: "second tool", input_schema: %{}}
            },
            fn {n, schema} -> {n, {schema, fn _ -> "ok" end}} end
          )
      }

      :ok =
        Registry.put_fake(
          "warehouse",
          Map.put(config, :metadata, %{description: "Warehouse inventory"}),
          @registry_name
        )

      {:ok, _} = Registry.ensure_started("warehouse", @registry_name)

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:apropos, ["warehouse", %{limit: 5}])

      names = tool_names_from_lines(result)
      assert "tool_a" in names
      assert "tool_b" in names
    end

    test "camelCase tool names are tokenized correctly" do
      put_fake("srv", [
        {"getIssueComments", fn _ -> "ok" end},
        {"listPullRequests", fn _ -> "ok" end}
      ])

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:apropos, ["issue"])

      assert [first | _] = result
      assert first =~ "srv.getIssueComments"
    end
  end

  # ============================================================
  # doc
  # ============================================================

  describe "doc" do
    test "returns detailed tool entry" do
      put_fake("github", [{"search", fn _ -> "ok" end}])

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:doc, ["github/search"])

      assert is_binary(result)
      assert result =~ "github/search"
      assert result =~ "Args: {:query string}"
      assert result =~ "Required args: :query"
      assert result =~ "Call:"
      assert result =~ ~s|(tool/mcp-call {:server "github" :tool "search" :args {:query ...}})|
      assert result =~ "Returns: Result<any>"
      assert result =~ "Use `(:value r)` after checking `(:ok r)`."
    end

    test "call_example surfaces required args with :args clause" do
      put_fake("github", [{"search", fn _ -> "ok" end}])

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:doc, ["github/search"])

      assert result =~
               ~s|(tool/mcp-call {:server "github" :tool "search" :args {:query ...}})|
    end

    test "call_example includes empty :args clause when tool has no properties" do
      schema = %{
        name: "ping",
        description: "no-arg tool",
        input_schema: %{"type" => "object", "properties" => %{}}
      }

      config = %{tools: %{"ping" => {schema, fn _ -> "pong" end}}, metadata: %{}}
      :ok = Registry.put_fake("util", config, @registry_name)
      {:ok, _} = Registry.ensure_started("util", @registry_name)

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:doc, ["util/ping"])

      assert result =~ "util/ping"
      assert result =~ "Args: {}"
      assert result =~ "Required args: none"
      assert result =~ ~s|(tool/mcp-call {:server "util" :tool "ping" :args {}})|
    end

    test "call_example escapes string-sensitive server and tool names" do
      schema = %{
        name: ~s|say"hi|,
        description: "quoted tool",
        input_schema: %{"type" => "object", "properties" => %{}}
      }

      config = %{tools: %{~s|say"hi| => {schema, fn _ -> "ok" end}}, metadata: %{}}
      :ok = Registry.put_fake(~s|srv"quoted|, config, @registry_name)
      {:ok, _} = Registry.ensure_started(~s|srv"quoted|, @registry_name)

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:doc, [~s|srv"quoted/say"hi|])

      assert result =~
               ~S|(tool/mcp-call {:server "srv\"quoted" :tool "say\"hi" :args {}})|
    end

    test "tool refs can address configured upstream names containing slash" do
      schema = %{
        name: "search",
        description: "slash server tool",
        input_schema: %{"type" => "object", "properties" => %{}}
      }

      config = %{tools: %{"search" => {schema, fn _ -> "ok" end}}, metadata: %{}}
      :ok = Registry.put_fake("my server/one", config, @registry_name)
      {:ok, _} = Registry.ensure_started("my server/one", @registry_name)

      {exec, _ctx} = build_exec()
      assert {:ok, result} = exec.(:doc, ["my server/one/search"])

      assert result =~ "my server/one/search"
      assert result =~ ~s|:server "my server/one"|
    end

    test "required args line prevents inferring trace_id from result payloads" do
      schema = %{
        name: "get_trace",
        description: "Get a single trace whose returned payload includes trace_id.",
        input_schema: %{
          "type" => "object",
          "properties" => %{"id" => %{"type" => "string"}},
          "required" => ["id"]
        },
        output_schema: %{
          "type" => "object",
          "properties" => %{
            "trace_id" => %{"type" => "string"},
            "duration_ms" => %{"type" => "integer"}
          },
          "required" => ["trace_id"]
        }
      }

      config = %{tools: %{"get_trace" => {schema, fn _ -> "ok" end}}, metadata: %{}}
      :ok = Registry.put_fake("observatory", config, @registry_name)
      {:ok, _} = Registry.ensure_started("observatory", @registry_name)

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:doc, ["observatory/get_trace"])

      assert result =~ "observatory/get_trace"
      assert result =~ "Args: {:id string}"
      assert result =~ "Required args: :id"
      assert result =~ ~s|:args {:id ...}|
      assert result =~ "Returns: Result<{:trace-id string :duration-ms int?}>"
      refute result =~ ":trace_id ..."
    end

    test "doc surfaces input_schema fields for upstream-normalized tools" do
      schema = %{
        name: "read_text_file",
        description: "read a file",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string"},
            "head" => %{"type" => "integer"},
            "tail" => %{"type" => "integer"}
          },
          "required" => ["path"]
        }
      }

      config = %{tools: %{"read_text_file" => {schema, fn _ -> "ok" end}}, metadata: %{}}
      :ok = Registry.put_fake("fs", config, @registry_name)
      {:ok, _} = Registry.ensure_started("fs", @registry_name)

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:doc, ["fs/read_text_file"])

      assert result =~ "fs/read_text_file"
      assert result =~ "Args: {:path string :head int? :tail int?}"
      assert result =~ ":args {:path ...}"
    end

    test "unknown tool is programmer fault" do
      put_fake("github", [{"search", fn _ -> "ok" end}])

      {exec, _ctx} = build_exec()
      assert {:programmer_fault, msg} = exec.(:doc, ["github/nonexistent"])
      assert msg =~ "no tool 'nonexistent'"
    end

    test "unknown server is programmer fault" do
      {exec, _ctx} = build_exec()
      assert {:programmer_fault, msg} = exec.(:doc, ["nonexistent/tool"])
      assert msg =~ "no upstream 'nonexistent' configured"
    end

    test "non-string reference is programmer fault" do
      {exec, _ctx} = build_exec()
      assert {:programmer_fault, msg} = exec.(:doc, [123])
      assert msg =~ "quoted symbol or string tool reference"
    end
  end

  describe "meta" do
    test "returns structured MCP tool metadata" do
      schema = %{
        name: "search",
        description: "Search repositories",
        input_schema: %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}},
          "required" => ["query"]
        },
        output_schema: %{"type" => "object"},
        annotations: %{"readOnlyHint" => true}
      }

      config = %{tools: %{"search" => {schema, fn _ -> "ok" end}}, metadata: %{}}
      :ok = Registry.put_fake("github", config, @registry_name)
      {:ok, _} = Registry.ensure_started("github", @registry_name)

      {exec, _ctx} = build_exec()
      assert {:ok, result} = exec.(:meta, ["github/search"])

      assert result.kind == "mcp-tool"
      assert result.server == "github"
      assert result.tool == "search"
      assert result.description == "Search repositories"
      assert result.input_schema["required"] == ["query"]
      assert result.output_schema == %{"type" => "object"}
      assert result.annotations == %{"readOnlyHint" => true}

      assert result.call ==
               ~s|(tool/mcp-call {:server "github" :tool "search" :args {:query ...}})|
    end

    test "call form escapes string-sensitive server and tool names" do
      schema = %{
        name: ~s|say"hi|,
        description: "quoted tool",
        input_schema: %{"type" => "object", "properties" => %{}}
      }

      config = %{tools: %{~s|say"hi| => {schema, fn _ -> "ok" end}}, metadata: %{}}
      :ok = Registry.put_fake(~s|srv"quoted|, config, @registry_name)
      {:ok, _} = Registry.ensure_started(~s|srv"quoted|, @registry_name)

      {exec, _ctx} = build_exec()
      assert {:ok, result} = exec.(:meta, [~s|srv"quoted/say"hi|])

      assert result.call ==
               ~S|(tool/mcp-call {:server "srv\"quoted" :tool "say\"hi" :args {}})|
    end

    test "tool refs with slash-containing upstream names work for meta" do
      schema = %{
        name: "search",
        description: "slash server tool",
        input_schema: %{"type" => "object", "properties" => %{}}
      }

      config = %{tools: %{"search" => {schema, fn _ -> "ok" end}}, metadata: %{}}
      :ok = Registry.put_fake("my server/one", config, @registry_name)
      {:ok, _} = Registry.ensure_started("my server/one", @registry_name)

      {exec, _ctx} = build_exec()
      assert {:ok, result} = exec.(:meta, ["my server/one/search"])

      assert result.server == "my server/one"
      assert result.tool == "search"
    end

    test "unknown tool is programmer fault" do
      put_fake("github", [{"search", fn _ -> "ok" end}])

      {exec, _ctx} = build_exec()
      assert {:programmer_fault, msg} = exec.(:meta, ["github/missing"])
      assert msg =~ "no tool 'missing'"
    end
  end

  describe "generic discovery operations" do
    test "servers, apropos, dir, doc, and meta dispatch to MCP catalog backend" do
      put_fake("github", [{"search", fn _ -> "ok" end}])

      {exec, _ctx} = build_exec()

      assert {:ok, [%{"name" => "github"}]} = exec.(:servers, [])
      assert {:ok, [_]} = exec.(:apropos, ["search"])
      assert {:ok, [_]} = exec.(:dir, ["github"])
      assert {:ok, doc} = exec.(:doc, [{:symbol_ref, "github/search"}])
      assert doc =~ "github/search"
      assert {:ok, meta} = exec.(:meta, ["github/search"])
      assert meta.kind == "mcp-tool"
    end

    test "doc rejects non MCP-shaped refs in the MCP backend" do
      {exec, _ctx} = build_exec()
      assert {:programmer_fault, msg} = exec.(:doc, [{:symbol_ref, "map"}])
      assert msg =~ "server/tool"
    end

    test "apropos and dir reject non-map options" do
      put_fake("github", [{"search", fn _ -> "ok" end}])

      {exec, _ctx} = build_exec()

      assert {:programmer_fault, apropos_msg} = exec.(:apropos, ["search", 123])
      assert apropos_msg =~ "options must be a map"
      assert apropos_msg =~ "123"

      assert {:programmer_fault, dir_msg} = exec.(:dir, ["github", 123])
      assert dir_msg =~ "options must be a map"
      assert dir_msg =~ "123"
    end
  end

  # ============================================================
  # Budget: catalog ops separate from upstream calls
  # ============================================================

  describe "catalog op budget" do
    test "budget exhaustion returns world fault" do
      put_fake("srv", [{"t", fn _ -> "ok" end}])

      {exec, _ctx} = build_exec(max_catalog_ops: 2)

      assert {:ok, _} = exec.(:servers, [])
      assert {:ok, _} = exec.(:servers, [])
      assert {:world_fault, :catalog_cap_exhausted} = exec.(:servers, [])
    end

    test "catalog budget is separate from upstream call budget" do
      put_fake("srv", [{"t", fn _ -> "ok" end}])

      call_context =
        UpstreamCalls.new_call_context(
          collector_pid: self(),
          collector_ref: make_ref(),
          max_calls: 1,
          max_catalog_ops: 100,
          call_timeout_ms: 5000,
          max_response_bytes: 1_000_000
        )

      exec =
        CatalogBuiltins.build(call_context,
          registry: @registry_name,
          catalog_config: CatalogConfig.get()
        )

      # Exhaust upstream call budget
      :atomics.add(call_context.call_counter, 1, 1)

      # Discovery ops should still work
      assert {:ok, _} = exec.(:servers, [])
      assert {:ok, _} = exec.(:servers, [])
    end
  end

  # ============================================================
  # Shared ensure coordination
  # ============================================================

  describe "shared ensure coordination" do
    test "catalog and tool/mcp-call share failure cache" do
      # Register upstream but DON'T ensure_started — cached_tools stays nil
      config = tools_config(%{"t" => fn _ -> "ok" end})
      :ok = Registry.put_fake("srv", config, @registry_name)

      call_context =
        UpstreamCalls.new_call_context(
          collector_pid: self(),
          collector_ref: make_ref(),
          max_calls: 100,
          call_timeout_ms: 5000,
          max_response_bytes: 1_000_000
        )

      # Simulate a failure cached by tool/mcp-call for "srv"
      UpstreamCalls.mark_failure(call_context, "srv", :upstream_unavailable, "boom")

      exec =
        CatalogBuiltins.build(call_context,
          registry: @registry_name,
          catalog_config: CatalogConfig.get()
        )

      # cached_tools is nil → ensure path → checks failure cache → world_fault
      assert {:world_fault, :upstream_unavailable} = exec.(:dir, ["srv"])
    end
  end

  # ============================================================
  # Result size cap
  # ============================================================

  describe "result size cap" do
    test "oversized doc result returns world fault" do
      put_fake("big", [{"huge_tool", fn _ -> "ok" end}])

      CatalogConfig.set(%{max_catalog_result_bytes: 10})
      {exec, _ctx} = build_exec()

      assert {:world_fault, :catalog_result_too_large} =
               exec.(:doc, ["big/huge_tool"])
    end

    test "dir truncates to fit" do
      tools = Enum.map(1..20, fn i -> {"tool_#{i}", fn _ -> "ok" end} end)
      put_fake("big", tools)

      CatalogConfig.set(%{max_catalog_result_bytes: 80})
      {exec, _ctx} = build_exec()
      result = exec.(:dir, ["big"])

      case result do
        {:ok, items} ->
          assert length(items) < 20

        {:world_fault, :catalog_result_too_large} ->
          :ok
      end
    end
  end
end
