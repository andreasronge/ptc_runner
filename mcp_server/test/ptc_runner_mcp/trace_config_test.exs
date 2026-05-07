defmodule PtcRunnerMcp.TraceConfigTest do
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.TraceConfig

  setup do
    # Save & restore so async: false tests don't bleed state.
    original = TraceConfig.get()
    on_exit(fn -> TraceConfig.set(original) end)
    :ok
  end

  describe "defaults/0" do
    test "trace_dir nil, payloads :summary, max_files 1000" do
      assert TraceConfig.defaults() == %{
               trace_dir: nil,
               trace_payloads: :summary,
               trace_max_files: 1000
             }
    end
  end

  describe "set/1 + get/0" do
    test "round-trips a full override" do
      :ok = TraceConfig.set(%{trace_dir: "/tmp/x", trace_payloads: :full, trace_max_files: 5})
      cfg = TraceConfig.get()
      assert cfg.trace_dir == "/tmp/x"
      assert cfg.trace_payloads == :full
      assert cfg.trace_max_files == 5
    end

    test "invalid payload level falls back to :summary" do
      :ok = TraceConfig.set(%{trace_payloads: :bogus})
      assert TraceConfig.trace_payloads() == :summary
    end

    test "non-positive max_files falls back to default" do
      :ok = TraceConfig.set(%{trace_max_files: 0})
      assert TraceConfig.trace_max_files() == 1000

      :ok = TraceConfig.set(%{trace_max_files: -10})
      assert TraceConfig.trace_max_files() == 1000
    end
  end

  describe "enabled?/0" do
    test "false when trace_dir is nil" do
      :ok = TraceConfig.set(%{trace_dir: nil})
      refute TraceConfig.enabled?()
    end

    test "true when trace_dir is set" do
      :ok = TraceConfig.set(%{trace_dir: "/tmp/x"})
      assert TraceConfig.enabled?()
    end
  end

  describe "parse_payloads/1" do
    test "accepts valid atoms" do
      assert TraceConfig.parse_payloads(:none) == {:ok, :none}
      assert TraceConfig.parse_payloads(:summary) == {:ok, :summary}
      assert TraceConfig.parse_payloads(:full) == {:ok, :full}
    end

    test "accepts case-insensitive strings" do
      assert TraceConfig.parse_payloads("NONE") == {:ok, :none}
      assert TraceConfig.parse_payloads("Summary") == {:ok, :summary}
      assert TraceConfig.parse_payloads("full") == {:ok, :full}
    end

    test "rejects garbage" do
      assert TraceConfig.parse_payloads("bogus") == :error
      assert TraceConfig.parse_payloads(123) == :error
      assert TraceConfig.parse_payloads(nil) == :error
    end
  end
end
