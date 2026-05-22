defmodule PtcRunnerMcp.ToolsPhase3Test do
  @moduledoc """
  Phase 3 tests for `Tools.tool_entry/0` description in aggregator
  mode.

  Spec: `Plans/ptc-runner-mcp-aggregator.md` §12.5.

  Cases:

    * `:mcp_no_tools` preserves the stable tool contract while prompt
      prose remains independently editable.
    * `:mcp_aggregator` description includes the FROZEN catalog
      string. The catalog is computed once at boot and stored in
      `:persistent_term` via `Catalog.freeze/1`; `tool_entry/0`
      reads it via `Catalog.frozen/0`. Tests prime the freeze
      manually because they don't run the full
      `Upstream.Supervisor.start_link/1` boot path.
    * §12.5 freeze invariant: catalog text is stable across
      post-boot upstream lifecycle changes. The "kill an upstream
      after freeze, re-read tool_entry" test exists to prove the
      freeze defends against drift.
  """
  use ExUnit.Case, async: false

  import PtcRunnerMcp.McpTestHelpers, only: [stop_existing_registry: 1]

  alias PtcRunnerMcp.{
    AggregatorConfig,
    CatalogConfig,
    CatalogDescription,
    PromptRegistry,
    ResponseProfile,
    Tools
  }

  alias PtcRunnerMcp.Upstream.Catalog
  alias PtcRunnerMcp.Upstream.Connection
  alias PtcRunnerMcp.Upstream.Registry, as: UpstreamRegistry

  @registry_name PtcRunnerMcp.Upstream.Registry
  @fixture_path Path.expand("../fixtures/tool_entry_v1.json", __DIR__)

  setup do
    stop_existing_registry(@registry_name)
    Catalog.clear_frozen()

    on_exit(fn ->
      stop_existing_registry(@registry_name)
      Catalog.clear_frozen()
      AggregatorConfig.set(AggregatorConfig.defaults())
      CatalogConfig.set(CatalogConfig.defaults())
    end)

    AggregatorConfig.set(AggregatorConfig.defaults())
    CatalogConfig.set(CatalogConfig.defaults())
    :ok
  end

  describe ":mcp_no_tools regression (Phase 0 fixture)" do
    test "tool_entry/0 preserves stable schema fields when no upstream Registry is running" do
      # No Registry running → `configured_aggregator_mode?/0` is false →
      # `:mcp_no_tools` profile → catalog: nil.
      fixture = Jason.decode!(File.read!(@fixture_path))
      entry = Tools.tool_entry()

      assert entry["name"] == fixture["name"]
      assert entry["inputSchema"] == fixture["inputSchema"]
      assert entry["outputSchema"] == fixture["outputSchema"]
      assert entry["annotations"] == fixture["annotations"]
      assert is_binary(entry["description"])
    end
  end

  describe ":mcp_aggregator description with frozen catalog (§12.5)" do
    test "MCP prompt registry exposes aggregator description metadata" do
      assert [
               %{
                 id: :lisp_eval_with_upstreams_description,
                 dynamic_boundary: :before_dynamic_catalog,
                 trust: :authoritative
               },
               %{
                 id: :mcp_language_reference,
                 dynamic_boundary: :static_card,
                 trust: :authoritative
               },
               %{
                 id: :mcp_dynamic_catalog,
                 dynamic_boundary: :dynamic_catalog,
                 trust: :untrusted_data
               }
             ] = PromptRegistry.profile_metadata(:mcp_aggregator_description)
    end

    test "MCP prompt registry preserves no-tools description contract" do
      description = PromptRegistry.render(:mcp_no_tools_description, [])

      assert is_binary(description)
      assert byte_size(description) > 0

      metadata = PromptRegistry.card_metadata(:lisp_eval_description)
      assert metadata.trust == :authoritative
      assert metadata.dynamic_boundary == :static_card
    end

    test "quick contract is complete in the first 2 KB before lazy catalog text" do
      catalog =
        CatalogDescription.render_for_entries(
          [
            %{
              name: "alpha",
              tools: [%{name: "search", description: "Search indexed records."}],
              metadata: %{description: "Example upstream"}
            }
          ],
          %{PtcRunnerMcp.CatalogConfig.defaults() | catalog_mode: :lazy}
        )

      description = Tools.advertised_description(:mcp_aggregator, catalog: catalog)
      first_2kb = first_bytes(description, 2 * 1024)

      assert_quick_contract_in_first_chunk(first_2kb)

      assert_before(description, "Upstreams:", "Configured upstream MCP servers:")
    end

    test "tool_entry/0 slim response profile preserves quick contract in first 2 KB" do
      {:ok, _pid} = UpstreamRegistry.start_link(name: @registry_name)
      :ok = UpstreamRegistry.put_fake("alpha", fake_tools_config(), @registry_name)
      old_profile = ResponseProfile.current()
      on_exit(fn -> ResponseProfile.set(old_profile) end)

      :ok = ResponseProfile.set(:slim)
      :ok = CatalogConfig.set(%{catalog_mode: :lazy})

      snapshot = Catalog.snapshot(@registry_name)
      :ok = Catalog.freeze(Catalog.render(@registry_name))
      :ok = Catalog.freeze_snapshot(snapshot)

      description = Tools.tool_entry()["description"]
      first_2kb = first_bytes(description, 2 * 1024)

      assert_quick_contract_in_first_chunk(first_2kb)
      assert description =~ "Response profile: slim."
    end

    test "includes the frozen catalog block as a trailing paragraph" do
      {:ok, _pid} = UpstreamRegistry.start_link(name: @registry_name)
      :ok = UpstreamRegistry.put_fake("alpha", fake_tools_config(), @registry_name)

      pid = UpstreamRegistry.connection_for("alpha", @registry_name)
      assert is_pid(pid)
      {:ok, _} = Connection.ensure_started(pid)

      # Production boot freezes both the rendered string and the
      # structured snapshot; tests do the same explicitly because
      # they bypass the full supervisor.
      snapshot = Catalog.snapshot(@registry_name)
      :ok = Catalog.freeze(Catalog.render(@registry_name))
      :ok = Catalog.freeze_snapshot(snapshot)

      entry = Tools.tool_entry()
      description = entry["description"]

      assert is_binary(description)
      assert description =~ "- alpha:"
      assert description =~ "- alpha.ping(msg: string) Ping the upstream"
    end

    test "aggregator-mode tool_entry uses the aggregator outputSchema/annotations" do
      {:ok, _pid} = UpstreamRegistry.start_link(name: @registry_name)
      :ok = UpstreamRegistry.put_fake("alpha", %{tools: %{}}, @registry_name)
      :ok = Catalog.freeze("")

      entry = Tools.tool_entry()

      schemas = entry["outputSchema"]["oneOf"]
      assert Enum.any?(schemas, &Map.has_key?(&1["properties"], "upstream_calls"))

      ann = entry["annotations"]
      assert ann["readOnlyHint"] == false
      assert ann["destructiveHint"] == true
      assert ann["openWorldHint"] == true
    end

    test "aggregator read-only config flips safety annotations for Codex-style clients" do
      {:ok, _pid} = UpstreamRegistry.start_link(name: @registry_name)
      :ok = UpstreamRegistry.put_fake("alpha", %{tools: %{}}, @registry_name)
      :ok = Catalog.freeze("")
      :ok = AggregatorConfig.set(%{read_only: true})

      ann = Tools.tool_entry()["annotations"]
      assert ann["readOnlyHint"] == true
      assert ann["destructiveHint"] == false
      assert ann["idempotentHint"] == false
      assert ann["openWorldHint"] == true
    end

    test "aggregator-mode inputSchema exposes output_schema only" do
      {:ok, _pid} = UpstreamRegistry.start_link(name: @registry_name)
      :ok = UpstreamRegistry.put_fake("alpha", %{tools: %{}}, @registry_name)
      :ok = Catalog.freeze("")

      properties = Tools.tool_entry()["inputSchema"]["properties"]

      assert properties["output_schema"]["description"] =~ "JSON Schema"
      refute Map.has_key?(properties, "signature")
    end

    test "legacy signature argument is rejected" do
      env =
        Tools.call_with_gate(%{
          "program" => "(+ 1 2)",
          "signature" => "any"
        })

      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "args_error"
      assert env["structuredContent"]["message"] =~ "no longer supported"
    end

    test "no upstream catalog block when Registry has zero upstreams" do
      {:ok, _pid} = UpstreamRegistry.start_link(name: @registry_name)

      # configured_count == 0 → :mcp_no_tools profile.
      entry = Tools.tool_entry()
      fixture = Jason.decode!(File.read!(@fixture_path))

      assert entry["name"] == fixture["name"]
      assert entry["inputSchema"] == fixture["inputSchema"]
      assert entry["outputSchema"] == fixture["outputSchema"]
      assert entry["annotations"] == fixture["annotations"]
      assert entry["description"] == PromptRegistry.render(:mcp_no_tools_description, [])
    end

    test "frozen catalog with not-yet-started upstream renders the unavailable placeholder" do
      {:ok, _pid} = UpstreamRegistry.start_link(name: @registry_name)
      # put_fake creates the Connection but does NOT start it.
      # The "frozen at boot" snapshot captures cached_tools=nil for this
      # case — the eager-start branch failed and we still froze.
      :ok = UpstreamRegistry.put_fake("beta", %{tools: %{}}, @registry_name)
      snapshot = Catalog.snapshot(@registry_name)
      :ok = Catalog.freeze(Catalog.render(@registry_name))
      :ok = Catalog.freeze_snapshot(snapshot)

      entry = Tools.tool_entry()
      description = entry["description"]

      assert description =~ "Configured upstream MCP servers: beta"
      assert description =~ "catalog/search-tools"
    end
  end

  describe "freeze invariant (§12.5 'rebuilt only on PtcRunner restart')" do
    test "tool_entry description is stable when an upstream crashes post-boot" do
      {:ok, _pid} = UpstreamRegistry.start_link(name: @registry_name)
      :ok = UpstreamRegistry.put_fake("alpha", fake_tools_config(), @registry_name)
      :ok = UpstreamRegistry.put_fake("beta", fake_tools_config(), @registry_name)

      pid_a = UpstreamRegistry.connection_for("alpha", @registry_name)
      pid_b = UpstreamRegistry.connection_for("beta", @registry_name)
      {:ok, _} = Connection.ensure_started(pid_a)
      {:ok, _} = Connection.ensure_started(pid_b)

      catalog_snapshot = Catalog.snapshot(@registry_name)
      :ok = Catalog.freeze(Catalog.render(@registry_name))
      :ok = Catalog.freeze_snapshot(catalog_snapshot)

      snapshot = Tools.tool_entry()["description"]
      assert snapshot =~ "- alpha:"
      assert snapshot =~ "- beta:"

      # Kill the underlying impl pid for `beta`. Pre-fix: the live
      # `Catalog.render` path would observe `cached_tools = nil` for
      # beta and the description would flip to `(unavailable at
      # startup)`. Post-fix: the frozen string is unchanged.
      %{pid: impl_pid} = Connection.snapshot(pid_b)
      assert is_pid(impl_pid)
      ref = Process.monitor(impl_pid)
      Process.exit(impl_pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^impl_pid, _reason} -> :ok
      after
        2_000 -> flunk("impl process did not die")
      end

      # Wait for the Connection to observe the :DOWN and transition
      # to :not_started. We poll the snapshot bounded by 1s — no
      # Process.sleep, just `receive after` per CLAUDE.md.
      :ok = wait_until_not_started(pid_b, 1_000)

      # Sanity check: a LIVE re-render WOULD differ from the snapshot.
      # (This is not a regression — it confirms the freeze is what's
      # protecting us. If `Catalog.render` happened to be stable for
      # this test setup, the snapshot-equality assertion below would
      # be tautological.)
      live_after_kill = Catalog.render(@registry_name)
      assert live_after_kill =~ "beta:\n  (unavailable at startup)"

      # Frozen description is byte-equal to the pre-kill snapshot.
      assert Tools.tool_entry()["description"] == snapshot
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp fake_tools_config do
    %{
      tools: %{
        "ping" =>
          {%{
             name: "ping",
             input_schema: %{
               "type" => "object",
               "properties" => %{"msg" => %{"type" => "string"}},
               "required" => ["msg"]
             },
             description: "Ping the upstream"
           }, fn _, _ -> {:ok, "pong"} end}
      }
    }
  end

  defp first_bytes(text, max_bytes) do
    binary_part(text, 0, min(byte_size(text), max_bytes))
  end

  defp assert_quick_contract_in_first_chunk(text) do
    for marker <- [
          "(tool/mcp-call",
          "Result<T>",
          "Check `:ok`",
          ":value T",
          ":reason kw",
          ":raw",
          "Unknown result shape"
        ] do
      assert text =~ marker
    end
  end

  defp assert_before(text, earlier, later) do
    assert {earlier_index, _} = :binary.match(text, earlier)
    assert {later_index, _} = :binary.match(text, later)
    assert earlier_index < later_index
  end

  defp wait_until_not_started(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_not_started(pid, deadline)
  end

  defp do_wait_until_not_started(pid, deadline) do
    if Connection.started?(pid) do
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        flunk("Connection still :started after deadline")
      else
        receive do
        after
          5 -> do_wait_until_not_started(pid, deadline)
        end
      end
    else
      :ok
    end
  end
end
