defmodule PtcRunnerMcp.CatalogBuiltinsTest do
  @moduledoc """
  Tests for `PtcRunnerMcp.CatalogBuiltins` — the catalog executor
  closure builder for `catalog/` PTC-Lisp builtins.

  Each test starts its own isolated `Upstream.Registry` so tests run
  in parallel without colliding on the global registry name.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{CatalogBuiltins, CatalogConfig, UpstreamCalls}
  alias PtcRunnerMcp.Upstream.Registry

  @registry_name PtcRunnerMcp.CatalogBuiltinsTestRegistry

  setup do
    stop_existing_registry()

    {:ok, _pid} = Registry.start_link(name: @registry_name)
    CatalogConfig.set(CatalogConfig.defaults())

    on_exit(fn ->
      stop_existing_registry()
      CatalogConfig.set(CatalogConfig.defaults())
    end)

    :ok
  end

  defp stop_existing_registry do
    case Process.whereis(@registry_name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end
    end
  end

  defp tools_config(tools) do
    %{
      tools:
        Map.new(tools, fn {n, fun} ->
          schema = %{
            name: n,
            description: "Tool #{n}",
            inputSchema: %{
              "type" => "object",
              "properties" => %{"query" => %{"type" => "string"}}
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

  # ============================================================
  # catalog/summary
  # ============================================================

  describe "summary" do
    test "returns mode, servers, and catalogs_loaded" do
      put_fake("github", [{"search", fn _ -> "ok" end}],
        metadata: %{description: "GitHub MCP", capabilities: ["issues", "prs"]}
      )

      {exec, _ctx} = build_exec()
      assert {:ok, result} = exec.(:summary, [])

      assert result["mode"] == "auto"
      assert is_list(result["servers"])

      server = hd(result["servers"])
      assert server["name"] == "github"
      assert server["description"] == "GitHub MCP"
      assert server["tool_count"] == 1
      assert server["capabilities"] == ["issues", "prs"]
      assert result["catalogs_loaded"] == true
    end

    test "catalogs_loaded is false when an upstream is not started" do
      # Register upstream without ensure_started so cached_tools stays nil
      config = tools_config(%{"tool_a" => fn _ -> "ok" end})
      :ok = Registry.put_fake("alpha", config, @registry_name)

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:summary, [])
      assert result["catalogs_loaded"] == false
    end
  end

  # ============================================================
  # catalog/list-servers
  # ============================================================

  describe "list_servers" do
    test "returns server summaries" do
      put_fake("github", [{"search", fn _ -> "ok" end}], metadata: %{description: "GitHub"})

      put_fake("linear", [{"create_issue", fn _ -> "ok" end}], metadata: %{description: "Linear"})

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:list_servers, [])

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
  # catalog/list-tools
  # ============================================================

  describe "list_tools" do
    test "returns sorted tool summaries for a server" do
      put_fake("github", [
        {"search_issues", fn _ -> "ok" end},
        {"get_pr", fn _ -> "ok" end}
      ])

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:list_tools, ["github"])

      assert is_list(result)
      assert length(result) == 2

      tool_names = Enum.map(result, & &1["tool"])
      assert tool_names == Enum.sort(tool_names)
    end

    test "returns compact tool entry shape" do
      put_fake("github", [{"search", fn _ -> "ok" end}])

      {exec, _ctx} = build_exec()
      {:ok, [tool]} = exec.(:list_tools, ["github"])

      assert tool["server"] == "github"
      assert tool["tool"] == "search"
      assert is_binary(tool["summary"])
      assert is_list(tool["arg_keys"])
      assert is_boolean(tool["read_only"])
    end

    test "unknown server is programmer fault" do
      {exec, _ctx} = build_exec()
      assert {:programmer_fault, msg} = exec.(:list_tools, ["nonexistent"])
      assert msg =~ "no upstream 'nonexistent' configured"
    end

    test "respects :limit option" do
      tools = Enum.map(1..10, fn i -> {"tool_#{i}", fn _ -> "ok" end} end)
      put_fake("big", tools)

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:list_tools, ["big", %{limit: 3}])
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
      {:ok, all} = exec.(:list_tools, ["srv"])
      {:ok, offset} = exec.(:list_tools, ["srv", %{offset: 2}])

      assert length(offset) == 3
      assert Enum.map(offset, & &1["tool"]) == Enum.map(Enum.drop(all, 2), & &1["tool"])
    end

    test "invalid limit is programmer fault" do
      put_fake("srv", [{"t", fn _ -> "ok" end}])
      {exec, _ctx} = build_exec()

      assert {:programmer_fault, msg} = exec.(:list_tools, ["srv", %{limit: 999}])
      assert msg =~ "limit"

      assert {:programmer_fault, _} = exec.(:list_tools, ["srv", %{limit: -1}])
      assert {:programmer_fault, _} = exec.(:list_tools, ["srv", %{limit: "five"}])
    end

    test "invalid offset is programmer fault" do
      put_fake("srv", [{"t", fn _ -> "ok" end}])
      {exec, _ctx} = build_exec()

      assert {:programmer_fault, msg} = exec.(:list_tools, ["srv", %{offset: -1}])
      assert msg =~ "offset"
    end

    test "0-tool server returns empty list" do
      put_fake("empty", [])
      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:list_tools, ["empty"])
      assert result == []
    end
  end

  # ============================================================
  # catalog/describe-tool
  # ============================================================

  describe "describe_tool" do
    test "returns detailed tool entry" do
      put_fake("github", [{"search", fn _ -> "ok" end}])

      {exec, _ctx} = build_exec()
      {:ok, result} = exec.(:describe_tool, ["github", "search"])

      assert result["server"] == "github"
      assert result["tool"] == "search"
      assert is_binary(result["summary"])
      assert is_map(result["input_schema"])
      assert is_list(result["arg_keys"])
      assert is_binary(result["call_example"])
      assert result["call_example"] =~ "tool/mcp-call"
      assert is_binary(result["response_notes"])
    end

    test "unknown tool is programmer fault" do
      put_fake("github", [{"search", fn _ -> "ok" end}])

      {exec, _ctx} = build_exec()
      assert {:programmer_fault, msg} = exec.(:describe_tool, ["github", "nonexistent"])
      assert msg =~ "no tool 'nonexistent'"
    end

    test "unknown server is programmer fault" do
      {exec, _ctx} = build_exec()
      assert {:programmer_fault, msg} = exec.(:describe_tool, ["nonexistent", "tool"])
      assert msg =~ "no upstream 'nonexistent' configured"
    end

    test "non-string server is programmer fault" do
      {exec, _ctx} = build_exec()
      assert {:programmer_fault, msg} = exec.(:describe_tool, [123, "tool"])
      assert msg =~ "non-empty string"
    end
  end

  # ============================================================
  # Budget: catalog ops separate from upstream calls
  # ============================================================

  describe "catalog op budget" do
    test "budget exhaustion returns world fault" do
      put_fake("srv", [{"t", fn _ -> "ok" end}])

      {exec, _ctx} = build_exec(max_catalog_ops: 2)

      assert {:ok, _} = exec.(:summary, [])
      assert {:ok, _} = exec.(:list_servers, [])
      assert {:world_fault, :catalog_cap_exhausted} = exec.(:summary, [])
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

      # Catalog ops should still work
      assert {:ok, _} = exec.(:summary, [])
      assert {:ok, _} = exec.(:list_servers, [])
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
      assert {:world_fault, :upstream_unavailable} = exec.(:list_tools, ["srv"])
    end
  end

  # ============================================================
  # Result size cap
  # ============================================================

  describe "result size cap" do
    test "oversized describe-tool result returns world fault" do
      put_fake("big", [{"huge_tool", fn _ -> "ok" end}])

      CatalogConfig.set(%{max_catalog_result_bytes: 10})
      {exec, _ctx} = build_exec()

      assert {:world_fault, :catalog_result_too_large} =
               exec.(:describe_tool, ["big", "huge_tool"])
    end

    test "list-tools truncates to fit" do
      tools = Enum.map(1..20, fn i -> {"tool_#{i}", fn _ -> "ok" end} end)
      put_fake("big", tools)

      CatalogConfig.set(%{max_catalog_result_bytes: 500})
      {exec, _ctx} = build_exec()
      result = exec.(:list_tools, ["big"])

      case result do
        {:ok, items} ->
          assert length(items) < 20

        {:world_fault, :catalog_result_too_large} ->
          :ok
      end
    end
  end
end
