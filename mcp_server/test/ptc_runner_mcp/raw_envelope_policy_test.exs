defmodule PtcRunnerMcp.RawEnvelopePolicyTest do
  @moduledoc """
  Integration tests for raw-envelope policy resolution.

  These drive the REAL production config path: `AggregatorConfig` stores
  config in `:persistent_term`, and `RawEnvelopePolicy.enabled?/2` delegates
  to `AggregatorConfig.raw_envelope_enabled?/2`. We set the persistent_term
  config and assert the policy resolves the documented precedence:
  tool override -> upstream default -> global default -> false.
  """

  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{AggregatorConfig, RawEnvelopePolicy}

  setup do
    # AggregatorConfig is process-global (:persistent_term); reset before and
    # after each test so state never leaks across tests or into siblings.
    AggregatorConfig.set(AggregatorConfig.defaults())

    on_exit(fn ->
      AggregatorConfig.set(AggregatorConfig.defaults())
    end)

    :ok
  end

  describe "enabled?/2 tool-level override" do
    test "tool raw_envelope true wins even when every lower level is false" do
      AggregatorConfig.set(%{
        raw_envelope_default: false,
        upstreams: %{
          "srv" => %{
            raw_envelope: false,
            tools: %{"t" => %{raw_envelope: true}}
          }
        }
      })

      assert RawEnvelopePolicy.enabled?("srv", "t")
    end

    test "tool raw_envelope false wins even when every lower level is true" do
      AggregatorConfig.set(%{
        raw_envelope_default: true,
        upstreams: %{
          "srv" => %{
            raw_envelope: true,
            tools: %{"t" => %{raw_envelope: false}}
          }
        }
      })

      refute RawEnvelopePolicy.enabled?("srv", "t")
    end
  end

  describe "enabled?/2 upstream-level default" do
    test "upstream raw_envelope true beats a false global default" do
      AggregatorConfig.set(%{
        raw_envelope_default: false,
        upstreams: %{"srv" => %{raw_envelope: true}}
      })

      assert RawEnvelopePolicy.enabled?("srv", "t")
    end

    test "upstream raw_envelope false beats a true global default" do
      AggregatorConfig.set(%{
        raw_envelope_default: true,
        upstreams: %{"srv" => %{raw_envelope: false}}
      })

      refute RawEnvelopePolicy.enabled?("srv", "t")
    end

    test "upstream default applies to a tool with no per-tool override" do
      AggregatorConfig.set(%{
        raw_envelope_default: false,
        upstreams: %{
          "srv" => %{
            raw_envelope: true,
            tools: %{"other" => %{raw_envelope: false}}
          }
        }
      })

      # "t" has no tool entry, so falls through to the upstream default.
      assert RawEnvelopePolicy.enabled?("srv", "t")
    end
  end

  describe "enabled?/2 global default" do
    test "global raw_envelope_default true applies when nothing more specific is set" do
      AggregatorConfig.set(%{raw_envelope_default: true})

      assert RawEnvelopePolicy.enabled?("srv", "t")
    end

    test "global raw_envelope_default false applies when nothing more specific is set" do
      AggregatorConfig.set(%{raw_envelope_default: false})

      refute RawEnvelopePolicy.enabled?("srv", "t")
    end

    test "global default applies for an unknown server" do
      AggregatorConfig.set(%{
        raw_envelope_default: true,
        upstreams: %{"known" => %{raw_envelope: false}}
      })

      # "unknown" has no upstream entry, so the global default governs.
      assert RawEnvelopePolicy.enabled?("unknown", "t")
    end
  end

  describe "enabled?/2 fallthrough to false" do
    test "nothing configured resolves to false" do
      # setup already reset to defaults (raw_envelope_default: false).
      refute RawEnvelopePolicy.enabled?("srv", "t")
    end

    test "empty override map resolves to false" do
      AggregatorConfig.set(%{})

      refute RawEnvelopePolicy.enabled?("srv", "t")
    end

    test "upstream present without raw_envelope key falls through to false default" do
      AggregatorConfig.set(%{
        raw_envelope_default: false,
        upstreams: %{"srv" => %{tools: %{"other" => %{raw_envelope: true}}}}
      })

      refute RawEnvelopePolicy.enabled?("srv", "t")
    end
  end
end
