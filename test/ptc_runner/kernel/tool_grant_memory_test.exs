defmodule PtcRunner.Kernel.ToolGrantMemoryTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Memory smoke test for the sandbox tool grant.

  The grant is copied into the sandbox process on every evaluation, and the
  copy is flat. Its cost is therefore paid per evaluation, and it lands in the
  measured pre-eval baseline where it quietly shrinks the program's heap budget
  until something is killed. Nothing reports it, so it has to be asserted.

  This is deliberately not a soak test. A soak test samples system-wide memory
  across many iterations and catches *growth over time*; this cost is constant
  per evaluation and reclaimed when the sandbox process dies, so it is flat
  across iterations no matter how wrong it is. The two are complementary, and
  only this one runs on every `mix test`.

  Measured in flat heap words, which is what a per-callback capture inflates.
  Referenced refc binaries are excluded on purpose: they are shared rather than
  copied, and `max_heap_size`'s `include_shared_binaries` counts each one once
  however many callbacks reference it.

  Three guards, in order of how well they will outlive today's numbers:

    * **shape** — the grant must not carry the frozen bundle or the granted
      data at all. Exact equality, so it cannot drift.
    * **scaling** — the grant must grow linearly in capability count. Catches
      any future per-callback capture of something every callback shares,
      whatever it is, without naming a size.
    * **budget** — recorded ceilings. Catches absolute creep the first two
      miss: a fatter `Capability`, a new reserved route. A failure here is a
      prompt to re-measure and decide, not automatically a bug.
  """

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.InspectionAnalysisProfile
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.ToolGrant

  # Measured 2026-08-01, OTP 29 64-bit. Ceilings are ~1.5x the measurement so
  # creep is caught while it is still cheap to explain.
  #
  #   inspection-analysis-v2 shape   10 capabilities                    71 KB
  #   MCP-scale                      60 described-schema capabilities  3905 KB
  #
  # Two thirds of the MCP-scale figure is the two discovery routes, which each
  # carry the whole map by necessity. Precomputing `Environment.metadata/1`
  # once would shrink it.
  @profile_budget_bytes 108 * 1024
  @mcp_budget_bytes 5_900 * 1024

  describe "shape" do
    test "the grant carries neither the frozen bundle nor the granted data" do
      capabilities = profile_capabilities()

      bare = grant_bytes(capabilities, %{}, nil)
      with_bundle = grant_bytes(capabilities, %{}, profile_bundle())
      with_data = grant_bytes(capabilities, bulk_data(), nil)

      assert with_bundle == bare
      assert with_data == bare
    end
  end

  describe "scaling" do
    test "the grant grows linearly in capability count, not quadratically" do
      base = 10
      wide = 80
      factor = div(wide, base)

      base_bytes = grant_bytes(mcp_capabilities(base), %{}, nil)
      wide_bytes = grant_bytes(mcp_capabilities(wide), %{}, nil)

      growth = wide_bytes / base_bytes

      # Linear is `factor`; the two fixed discovery routes pull it a little
      # above. Quadratic is `factor²` = 64. Fail well below that so a partial
      # regression is caught too.
      assert growth < factor * 1.5,
             """
             tool grant grew #{Float.round(growth, 1)}x for #{factor}x the capabilities \
             (#{base} -> #{wide}: #{kb(base_bytes)} -> #{kb(wide_bytes)}).
             A callback is capturing something every callback shares.
             """
    end
  end

  describe "budget" do
    test "the shipped and MCP-scale shapes stay within their ceilings" do
      assert_within(@profile_budget_bytes, grant_bytes(profile_capabilities(), %{}, nil))
      assert_within(@mcp_budget_bytes, grant_bytes(mcp_capabilities(60), %{}, nil))
    end
  end

  defp assert_within(budget_bytes, measured_bytes) do
    assert measured_bytes <= budget_bytes,
           """
           tool grant is #{kb(measured_bytes)}, over its #{kb(budget_bytes)} budget.
           Every evaluation pays this copy into the sandbox. Re-measure, then
           either shrink what the callbacks capture or raise the budget in this
           file deliberately.
           """
  end

  # The exact term handed to the sandbox, sized as the flat copy that `spawn`
  # makes of it.
  defp grant_bytes(capabilities, data, bundle) do
    {:ok, limits} = Limits.new()
    {:ok, state} = RunState.start(limits)

    {:ok, environment} =
      MissionEnvironment.new(capabilities: capabilities, data: data, bundle: bundle)

    grant =
      ToolGrant.capability_callbacks(
        state,
        :mission,
        environment,
        limits.evaluation_timeout_ms,
        %{event_sink: nil, inspection_sink: nil, evaluation_id: "evaluation-1"}
      )

    :erts_debug.flat_size(grant) * :erlang.system_info(:wordsize)
  end

  # The real profile's capability names, so its bundle's tool requirements are
  # satisfied and the shape assertion runs against shipped preludes.
  defp profile_capabilities do
    Enum.map(InspectionAnalysisProfile.explicit_capabilities(), &capability(&1, small_schema()))
  end

  defp profile_bundle do
    {:ok, components} = Library.components(InspectionAnalysisProfile.component_ids())
    {:ok, bundle} = Kernel.compile_bundle(components)
    bundle
  end

  defp mcp_capabilities(count) do
    Enum.map(1..count, &capability("fixture-#{&1}", mcp_schema()))
  end

  defp capability(name, schema) do
    {:ok, capability} =
      Capability.new(
        name: name,
        input_schema: schema,
        output_schema: schema,
        effect: :read,
        callback: fn _arguments -> {:ok, %{}} end
      )

    capability
  end

  defp small_schema, do: %{"type" => "object", "additionalProperties" => false}

  # The shape an MCP server's tools arrive as: described properties, not a
  # bare object.
  defp mcp_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" =>
        Map.new(1..12, fn index ->
          {"field_#{index}",
           %{"type" => "string", "description" => String.duplicate("described ", 8)}}
        end),
      "required" => ["field_1"]
    }
  end

  defp bulk_data do
    Map.new(1..4_000, fn index ->
      {"key-#{index}", %{"row" => index, "text" => String.duplicate("payload-", 6)}}
    end)
  end

  defp kb(bytes), do: "#{div(bytes, 1024)} KB"
end
