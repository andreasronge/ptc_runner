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
      case {operation, args} do
        {:summary, []} ->
          {:ok,
           Map.get(overrides, :summary, %{
             "mode" => "lazy",
             "servers" => [%{"name" => "github", "tool_count" => 5}],
             "catalogs_loaded" => true
           })}

        {:list_servers, []} ->
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

        {:list_tools, [server]} ->
          case Map.get(overrides, {:list_tools, server}) do
            nil ->
              {:ok,
               [
                 %{
                   "server" => server,
                   "tool" => "search",
                   "summary" => "Search things",
                   "arg_keys" => ["query"],
                   "read_only" => true
                 },
                 %{
                   "server" => server,
                   "tool" => "get",
                   "summary" => "Get a thing",
                   "arg_keys" => ["id"],
                   "read_only" => true
                 }
               ]}

            result ->
              result
          end

        {:list_tools, [server, _opts]} ->
          case Map.get(overrides, {:list_tools, server}) do
            nil ->
              {:ok,
               [
                 %{
                   "server" => server,
                   "tool" => "search",
                   "summary" => "Search things",
                   "arg_keys" => ["query"],
                   "read_only" => true
                 }
               ]}

            result ->
              result
          end

        {:describe_tool, [server, tool]} ->
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

        {:search_tools, [query | _rest]} ->
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

        _ ->
          {:programmer_fault, "unknown operation: #{inspect(operation)}"}
      end
    end
  end

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
