defmodule PtcRunner.CatalogBuiltinsTest do
  @moduledoc """
  Tests for the `catalog/` PTC-Lisp namespace: analyzer dispatch,
  evaluator integration, and non-aggregator-mode programmer faults.

  These tests exercise the catalog builtins through `PtcRunner.Lisp.run/2`
  with a mock `catalog_exec` closure, verifying the full
  analyzer → evaluator → closure pipeline without needing a real Registry.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  # A mock catalog_exec that returns canned data
  defp mock_catalog_exec(overrides \\ %{}) do
    fn operation, args ->
      mock_catalog_result(operation, args, overrides)
    end
  end

  defp mock_catalog_result(:servers, [], overrides),
    do: mock_catalog_result(:list_servers, [], overrides)

  defp mock_catalog_result(:dir, args, overrides),
    do: mock_catalog_result(:list_tools, args, overrides)

  defp mock_catalog_result(:apropos, args, overrides),
    do: mock_catalog_result(:search_tools, args, overrides)

  defp mock_catalog_result(:doc, [ref], overrides),
    do: mock_tool_ref_result(ref, overrides, :describe_tool)

  defp mock_catalog_result(:meta, [ref], overrides),
    do: mock_tool_ref_result(ref, overrides, :tool_meta)

  defp mock_catalog_result(:summary, [], overrides) do
    {:ok,
     Map.get(overrides, :summary, %{
       "mode" => "lazy",
       "servers" => [%{"name" => "github", "tool_count" => 5}],
       "catalogs_loaded" => true
     })}
  end

  defp mock_catalog_result(:list_servers, [], overrides) do
    {:ok,
     Map.get(overrides, :list_servers, [
       %{
         "name" => "github",
         "description" => "GitHub",
         "tool_count" => 5,
         "catalog_loaded" => true
       },
       %{
         "name" => "linear",
         "description" => "Linear",
         "tool_count" => nil,
         "catalog_loaded" => false
       }
     ])}
  end

  defp mock_catalog_result(:list_tools, [server], overrides) do
    case Map.get(overrides, {:list_tools, server}) do
      nil ->
        {:ok,
         [
           mock_tool_summary(server, "search"),
           mock_tool_summary(server, "get", "Get a thing", ["id"])
         ]}

      result ->
        result
    end
  end

  defp mock_catalog_result(:list_tools, [server, _opts], overrides) do
    case Map.get(overrides, {:list_tools, server}) do
      nil -> {:ok, [mock_tool_summary(server, "search")]}
      result -> result
    end
  end

  defp mock_catalog_result(:describe_tool, [server, tool], overrides) do
    case Map.get(overrides, {:describe_tool, server, tool}) do
      nil ->
        {:ok,
         %{
           "server" => server,
           "tool" => tool,
           "summary" => "A tool",
           "description" => "A detailed description",
           "input_schema" => %{"type" => "object"},
           "arg_keys" => ["query"],
           "annotations" => %{},
           "call_example" => "(tool/mcp-call {:server \"#{server}\" :tool \"#{tool}\"})",
           "response_notes" => "Returns content"
         }}

      result ->
        result
    end
  end

  defp mock_catalog_result(:tool_meta, [server, tool], overrides) do
    {:ok,
     Map.get(overrides, {:tool_meta, server, tool}, %{
       kind: "mcp-tool",
       server: server,
       tool: tool,
       description: "A tool",
       input_schema: %{"type" => "object"},
       output_schema: nil,
       annotations: %{},
       call: "(tool/mcp-call {:server \"#{server}\" :tool \"#{tool}\" :args {}})"
     })}
  end

  defp mock_catalog_result(:search_tools, [query | _rest], overrides) do
    {:ok,
     Map.get(overrides, {:search_tools, query}, [
       %{
         "server" => "github",
         "tool" => "search",
         "summary" => "Search things",
         "arg_keys" => ["query"],
         "read_only" => true,
         "catalog_loaded" => true
       }
     ])}
  end

  defp mock_catalog_result(operation, _args, _overrides),
    do: {:programmer_fault, "unknown operation: #{inspect(operation)}"}

  defp mock_tool_ref_result(ref, overrides, operation) do
    case split_ref(ref) do
      {:ok, server, tool} -> mock_catalog_result(operation, [server, tool], overrides)
      {:error, message} -> {:programmer_fault, message}
    end
  end

  defp mock_tool_summary(server, tool, summary \\ "Search things", arg_keys \\ ["query"]) do
    %{
      "server" => server,
      "tool" => tool,
      "summary" => summary,
      "arg_keys" => arg_keys,
      "read_only" => true
    }
  end

  defp split_ref({:symbol_ref, name}), do: split_ref(name)

  defp split_ref(ref) when is_binary(ref) do
    case String.split(ref, "/", parts: 2) do
      [server, tool] when server != "" and tool != "" -> {:ok, server, tool}
      _ -> {:error, "requires tool reference shaped as server/tool"}
    end
  end

  defp split_ref(_), do: {:error, "requires a quoted symbol or string tool reference"}

  # ============================================================
  # Analyzer: catalog/ namespace dispatch
  # ============================================================

  describe "analyzer: catalog/ namespace" do
    test "catalog/summary with no args produces valid CoreAST" do
      {:ok, step} = Lisp.run("(catalog/summary)", catalog_exec: mock_catalog_exec())
      assert is_map(step.return)
      assert step.return["mode"] == "lazy"
    end

    test "catalog/list-servers with no args produces valid CoreAST" do
      {:ok, step} = Lisp.run("(catalog/list-servers)", catalog_exec: mock_catalog_exec())
      assert is_list(step.return)
      assert length(step.return) == 2
    end

    test "catalog/list-tools with 1 arg" do
      {:ok, step} = Lisp.run(~s|(catalog/list-tools "github")|, catalog_exec: mock_catalog_exec())
      assert is_list(step.return)
      assert hd(step.return)["server"] == "github"
    end

    test "catalog/list-tools with 2 args (opts)" do
      {:ok, step} =
        Lisp.run(
          ~s|(catalog/list-tools "github" {:limit 10})|,
          catalog_exec: mock_catalog_exec()
        )

      assert is_list(step.return)
    end

    test "catalog/describe-tool with 2 args" do
      {:ok, step} =
        Lisp.run(
          ~s|(catalog/describe-tool "github" "search")|,
          catalog_exec: mock_catalog_exec()
        )

      assert is_map(step.return)
      assert step.return["server"] == "github"
      assert step.return["tool"] == "search"
    end

    test "catalog/search-tools with 1 arg (query)" do
      {:ok, step} =
        Lisp.run(~s|(catalog/search-tools "github")|, catalog_exec: mock_catalog_exec())

      assert is_list(step.return)
    end

    test "catalog/search-tools with 2 args (query + opts)" do
      {:ok, step} =
        Lisp.run(
          ~s|(catalog/search-tools "github" {:limit 5})|,
          catalog_exec: mock_catalog_exec()
        )

      assert is_list(step.return)
    end

    test "mcp/servers aliases catalog/list-servers" do
      {:ok, step} = Lisp.run("(mcp/servers)", catalog_exec: mock_catalog_exec())
      assert [%{"name" => "github"} | _] = step.return
    end

    test "catalog forms prefer catalog_exec when discovery_exec is also present" do
      catalog_exec = fn
        :summary, [] -> {:ok, %{"source" => "catalog"}}
        operation, _args -> {:programmer_fault, "unexpected catalog op #{operation}"}
      end

      discovery_exec = fn
        :summary, [] -> {:ok, %{"source" => "discovery"}}
        :servers, [] -> {:ok, [%{"name" => "discovery"}]}
        operation, _args -> {:programmer_fault, "unexpected discovery op #{operation}"}
      end

      {:ok, catalog_step} =
        Lisp.run("(catalog/summary)", catalog_exec: catalog_exec, discovery_exec: discovery_exec)

      {:ok, discovery_step} =
        Lisp.run("(mcp/servers)", catalog_exec: catalog_exec, discovery_exec: discovery_exec)

      assert catalog_step.return == %{"source" => "catalog"}
      assert discovery_step.return == [%{"name" => "discovery"}]
    end

    test "mcp/servers is call-position-only" do
      {:error, step} =
        Lisp.run("(let [servers mcp/servers] servers)", catalog_exec: mock_catalog_exec())

      assert step.fail.message =~ "unknown namespace mcp/"
    end

    test "apropos aliases catalog/search-tools" do
      {:ok, step} =
        Lisp.run(~s|(apropos "github" {:limit 5})|, catalog_exec: mock_catalog_exec())

      assert is_list(step.return)
      assert [op] = step.catalog_ops
      assert op.operation == :apropos
      assert op.args == %{query: "github", opts: %{limit: 5}}
    end

    test "dir accepts quoted symbol references" do
      {:ok, step} = Lisp.run("(dir 'github)", catalog_exec: mock_catalog_exec())
      assert hd(step.return)["server"] == "github"
    end

    test "dir treats quoted and string refs equivalently" do
      exec = mock_catalog_exec()

      {:ok, quoted} = Lisp.run("(dir 'github)", catalog_exec: exec)
      {:ok, string} = Lisp.run(~s|(dir "github")|, catalog_exec: exec)

      assert quoted.return == string.return
    end

    test "quote form returns a symbolic reference accepted by dir" do
      {:ok, step} = Lisp.run("(dir (quote github))", catalog_exec: mock_catalog_exec())
      assert hd(step.return)["server"] == "github"
    end

    test "doc accepts quoted tool references" do
      exec =
        mock_catalog_exec(%{
          {:describe_tool, "github", "search"} => {:ok, "github.search(query) - Search things"}
        })

      {:ok, step} = Lisp.run("(doc 'github/search)", catalog_exec: exec)
      assert step.return == "github.search(query) - Search things"
    end

    test "doc treats quoted and string refs equivalently" do
      exec = mock_catalog_exec()

      {:ok, quoted} = Lisp.run("(doc 'github/search)", catalog_exec: exec)
      {:ok, string} = Lisp.run(~s|(doc "github/search")|, catalog_exec: exec)

      assert quoted.return == string.return
    end

    test "meta returns structured MCP tool metadata" do
      {:ok, step} = Lisp.run(~s|(meta "github/search")|, catalog_exec: mock_catalog_exec())
      assert step.return.kind == "mcp-tool"
      assert step.return.server == "github"
      assert step.return.tool == "search"
    end

    test "meta accepts quoted tool refs" do
      {:ok, step} = Lisp.run("(meta 'github/search)", catalog_exec: mock_catalog_exec())
      assert step.return.kind == "mcp-tool"
      assert step.return.server == "github"
      assert step.return.tool == "search"
    end

    test "local bindings can shadow generic discovery forms" do
      for name <- ~w(apropos dir doc meta) do
        {:ok, step} = Lisp.run("(let [#{name} (fn [x] x)] (#{name} 42))")
        assert step.return == 42
      end
    end

    test "generic discovery forms are not runtime-callable values" do
      {:error, step} =
        Lisp.run(~s|(let [refs ["github/search"]] (map doc refs))|,
          catalog_exec: mock_catalog_exec()
        )

      assert step.fail.message =~ "Undefined variable: doc"
    end

    test "doc rejects server-only references" do
      {:error, step} = Lisp.run("(doc 'github)", catalog_exec: mock_catalog_exec())
      assert step.fail.message =~ "server/tool"
    end

    test "catalog/search-tools with 0 args produces arity error" do
      {:error, step} = Lisp.run("(catalog/search-tools)", catalog_exec: mock_catalog_exec())
      assert step.fail.message =~ "catalog/search-tools"
    end

    test "catalog/search-tools with 3 args produces arity error" do
      {:error, step} =
        Lisp.run(
          ~s|(catalog/search-tools "a" "b" "c")|,
          catalog_exec: mock_catalog_exec()
        )

      assert step.fail.message =~ "catalog/search-tools"
    end

    test "unknown catalog member produces error" do
      {:error, step} = Lisp.run("(catalog/foo)", catalog_exec: mock_catalog_exec())
      assert step.fail.message =~ "Unknown catalog function: catalog/foo"
      assert step.fail.message =~ "catalog/summary"
      assert step.fail.message =~ "catalog/search-tools"
    end

    test "catalog/summary with args produces arity error" do
      {:error, step} = Lisp.run(~s|(catalog/summary "extra")|, catalog_exec: mock_catalog_exec())
      assert step.fail.message =~ "takes no arguments"
    end

    test "catalog/list-servers with args produces arity error" do
      {:error, step} =
        Lisp.run(~s|(catalog/list-servers "extra")|, catalog_exec: mock_catalog_exec())

      assert step.fail.message =~ "takes no arguments"
    end

    test "catalog/list-tools with 0 args produces arity error" do
      {:error, step} = Lisp.run("(catalog/list-tools)", catalog_exec: mock_catalog_exec())
      assert step.fail.message =~ "catalog/list-tools"
    end

    test "catalog/list-tools with 3 args produces arity error" do
      {:error, step} =
        Lisp.run(
          ~s|(catalog/list-tools "a" "b" "c")|,
          catalog_exec: mock_catalog_exec()
        )

      assert step.fail.message =~ "catalog/list-tools"
    end

    test "catalog/describe-tool with 1 arg produces arity error" do
      {:error, step} =
        Lisp.run(
          ~s|(catalog/describe-tool "github")|,
          catalog_exec: mock_catalog_exec()
        )

      assert step.fail.message =~ "catalog/describe-tool"
    end

    test "unknown namespace includes catalog/ in available list" do
      {:error, step} = Lisp.run("(bogus/foo)", catalog_exec: mock_catalog_exec())
      assert step.fail.message =~ "catalog/"
    end
  end

  # ============================================================
  # Evaluator: catalog builtins outside aggregator mode
  # ============================================================

  describe "evaluator: catalog builtins without catalog_exec" do
    test "catalog/summary without catalog_exec raises programmer fault" do
      {:error, step} = Lisp.run("(catalog/summary)")
      assert step.fail.message =~ "aggregator mode"
    end

    test "catalog/list-servers without catalog_exec raises programmer fault" do
      {:error, step} = Lisp.run("(catalog/list-servers)")
      assert step.fail.message =~ "aggregator mode"
    end

    test "catalog/list-tools without catalog_exec raises programmer fault" do
      {:error, step} = Lisp.run(~s|(catalog/list-tools "github")|)
      assert step.fail.message =~ "aggregator mode"
    end

    test "catalog/describe-tool without catalog_exec raises programmer fault" do
      {:error, step} = Lisp.run(~s|(catalog/describe-tool "github" "search")|)
      assert step.fail.message =~ "aggregator mode"
    end

    test "catalog/search-tools without catalog_exec raises programmer fault" do
      {:error, step} = Lisp.run(~s|(catalog/search-tools "github")|)
      assert step.fail.message =~ "aggregator mode"
    end

    test "generic discovery forms without discovery_exec raise discovery backend fault" do
      {:error, step} = Lisp.run(~s|(apropos "github")|)
      assert step.fail.message =~ "discovery backend"

      {:error, step} = Lisp.run("(mcp/servers)")
      assert step.fail.message =~ "discovery backend"
    end
  end

  # ============================================================
  # Evaluator: world faults return nil
  # ============================================================

  describe "evaluator: world faults" do
    test "world fault from catalog_exec returns nil" do
      exec = fn _op, _args -> {:world_fault, :upstream_unavailable} end

      {:ok, step} = Lisp.run(~s|(catalog/list-tools "github")|, catalog_exec: exec)
      assert step.return == nil
    end

    test "catalog cap exhaustion returns nil" do
      exec = fn _op, _args -> {:world_fault, :catalog_cap_exhausted} end

      {:ok, step} = Lisp.run("(catalog/summary)", catalog_exec: exec)
      assert step.return == nil
    end
  end

  # ============================================================
  # Evaluator: programmer faults raise errors
  # ============================================================

  describe "evaluator: programmer faults" do
    test "programmer fault from catalog_exec raises runtime error" do
      exec = fn _op, _args -> {:programmer_fault, "no upstream 'nonexistent' configured"} end

      {:error, step} = Lisp.run(~s|(catalog/list-tools "nonexistent")|, catalog_exec: exec)
      assert step.fail.message =~ "no upstream 'nonexistent' configured"
    end
  end

  # ============================================================
  # Integration: catalog results used in program logic
  # ============================================================

  describe "integration: catalog results in program logic" do
    test "catalog/summary result accessible via get" do
      {:ok, step} =
        Lisp.run(
          ~s|(get (catalog/summary) :mode)|,
          catalog_exec: mock_catalog_exec()
        )

      assert step.return == "lazy"
    end

    test "catalog/list-servers result can be filtered" do
      {:ok, step} =
        Lisp.run(
          ~s|(count (filter (fn [s] (= (:catalog_loaded s) true)) (catalog/list-servers)))|,
          catalog_exec: mock_catalog_exec()
        )

      assert step.return == 1
    end

    test "catalog/list-tools result can be mapped" do
      {:ok, step} =
        Lisp.run(
          ~s|(map :tool (catalog/list-tools "github"))|,
          catalog_exec: mock_catalog_exec()
        )

      assert step.return == ["search", "get"]
    end

    test "catalog/search-tools results can be mapped" do
      {:ok, step} =
        Lisp.run(
          ~s|(map :tool (catalog/search-tools "github"))|,
          catalog_exec: mock_catalog_exec()
        )

      assert is_list(step.return)
    end

    test "catalog results survive nil check with or" do
      exec = fn _op, _args -> {:world_fault, :upstream_unavailable} end

      {:ok, step} =
        Lisp.run(
          ~s|(or (catalog/list-tools "github") [])|,
          catalog_exec: exec
        )

      assert step.return == []
    end
  end

  # ============================================================
  # catalog_ops tracing is surfaced on Step (#920)
  # ============================================================

  describe "step.catalog_ops" do
    test "successful op produces one ok record in execution order" do
      {:ok, step} =
        Lisp.run(
          ~s|(catalog/describe-tool "github" "search")|,
          catalog_exec: mock_catalog_exec()
        )

      assert [op] = step.catalog_ops
      assert op.operation == :describe_tool
      assert op.outcome == :ok
      assert op.reason == nil
      assert op.args == %{server: "github", tool: "search"}
      assert is_integer(op.duration_ms) and op.duration_ms >= 0
    end

    test "multiple ops appear in chronological (not reverse) order" do
      {:ok, step} =
        Lisp.run(
          ~s|(do (catalog/list-servers) (catalog/list-tools "github") (catalog/summary))|,
          catalog_exec: mock_catalog_exec()
        )

      assert [op1, op2, op3] = step.catalog_ops
      assert op1.operation == :list_servers
      assert op2.operation == :list_tools
      assert op2.args == %{server: "github"}
      assert op3.operation == :summary
    end

    test "ops before recur in a loop are preserved" do
      {:ok, step} =
        Lisp.run(
          ~s|(loop [i 0] (if (< i 2) (do (catalog/list-tools "github") (recur (inc i))) i))|,
          catalog_exec: mock_catalog_exec()
        )

      assert step.return == 2
      assert [:list_tools, :list_tools] = Enum.map(step.catalog_ops, & &1.operation)
    end

    test "ops before recur in a tail-recursive function are preserved" do
      {:ok, step} =
        Lisp.run(
          ~s|(do (def collect (fn [i] (if (< i 2) (do (catalog/list-tools "github") (recur (inc i))) i))) (collect 0))|,
          catalog_exec: mock_catalog_exec()
        )

      assert step.return == 2
      assert [:list_tools, :list_tools] = Enum.map(step.catalog_ops, & &1.operation)
    end

    test "ops across recurring and terminating iterations stay chronological" do
      {:ok, step} =
        Lisp.run(
          ~s|(loop [i 0] (if (< i 3) (do (catalog/list-tools (str "server-" i)) (recur (inc i))) (do (catalog/summary) i)))|,
          catalog_exec: mock_catalog_exec()
        )

      assert step.return == 3

      assert [
               %{operation: :list_tools, args: %{server: "server-0"}},
               %{operation: :list_tools, args: %{server: "server-1"}},
               %{operation: :list_tools, args: %{server: "server-2"}},
               %{operation: :summary}
             ] = step.catalog_ops
    end

    test "world fault produces :nil_world_fault record with reason" do
      exec = fn _op, _args -> {:world_fault, :upstream_unavailable} end

      {:ok, step} =
        Lisp.run(~s|(or (catalog/list-tools "github") [])|, catalog_exec: exec)

      assert [op] = step.catalog_ops
      assert op.operation == :list_tools
      assert op.outcome == :nil_world_fault
      assert op.reason == :upstream_unavailable
    end

    test "step from a program without catalog calls has empty catalog_ops" do
      {:ok, step} = Lisp.run("(+ 1 2)", catalog_exec: mock_catalog_exec())
      assert step.catalog_ops == []
    end
  end
end
