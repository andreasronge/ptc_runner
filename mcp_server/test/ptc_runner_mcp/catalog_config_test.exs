defmodule PtcRunnerMcp.CatalogConfigTest do
  @moduledoc """
  Tests for catalog exposure configuration.

  Covers the `CatalogConfig` persistent_term module and the
  `Application.apply_catalog_config/1` CLI > env > default precedence
  chain per `Plans/ptc-runner-mcp-catalog-exposure.md` §5.
  """

  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{Application, CatalogConfig}

  @env_keys [
    "PTC_RUNNER_MCP_CATALOG_MODE",
    "PTC_RUNNER_MCP_CATALOG_INLINE_MAX_CHARS",
    "PTC_RUNNER_MCP_CATALOG_INLINE_MAX_TOOLS",
    "PTC_RUNNER_MCP_MAX_CATALOG_OPS_PER_PROGRAM",
    "PTC_RUNNER_MCP_MAX_CATALOG_RESULT_BYTES"
  ]

  setup do
    originals = Map.new(@env_keys, fn key -> {key, System.get_env(key)} end)
    Enum.each(@env_keys, &System.delete_env/1)
    CatalogConfig.set(CatalogConfig.defaults())

    on_exit(fn ->
      Enum.each(originals, fn
        {key, nil} -> System.delete_env(key)
        {key, val} -> System.put_env(key, val)
      end)

      CatalogConfig.set(CatalogConfig.defaults())
    end)

    :ok
  end

  describe "CatalogConfig defaults" do
    test "returns expected default values" do
      defaults = CatalogConfig.defaults()

      assert defaults.catalog_mode == :auto
      assert defaults.catalog_inline_max_chars == 800
      assert defaults.catalog_inline_max_tools == 8
      assert defaults.max_catalog_ops_per_program == 25
      assert defaults.max_catalog_result_bytes == 262_144
    end
  end

  describe "CatalogConfig set/get" do
    test "set stores and get retrieves overrides" do
      CatalogConfig.set(%{catalog_mode: :lazy, catalog_inline_max_chars: 5000})
      config = CatalogConfig.get()

      assert config.catalog_mode == :lazy
      assert config.catalog_inline_max_chars == 5000
      assert config.catalog_inline_max_tools == 8
    end

    test "unknown keys are ignored" do
      CatalogConfig.set(%{catalog_mode: :inline, bogus_key: 999})
      config = CatalogConfig.get()

      assert config.catalog_mode == :inline
      refute Map.has_key?(config, :bogus_key)
    end
  end

  describe "CatalogConfig.parse_mode/1" do
    test "valid modes" do
      assert {:ok, :auto} = CatalogConfig.parse_mode("auto")
      assert {:ok, :inline} = CatalogConfig.parse_mode("inline")
      assert {:ok, :lazy} = CatalogConfig.parse_mode("lazy")
    end

    test "invalid mode returns :error" do
      assert :error = CatalogConfig.parse_mode("full")
      assert :error = CatalogConfig.parse_mode("")
    end
  end

  describe "parse_args/1 catalog flags" do
    test "accepts --catalog-mode" do
      args = Application.parse_args(["--catalog-mode", "lazy"])
      assert args[:catalog_mode] == "lazy"
    end

    test "accepts --catalog-inline-max-chars" do
      args = Application.parse_args(["--catalog-inline-max-chars", "8000"])
      assert args[:catalog_inline_max_chars] == 8000
    end

    test "accepts --catalog-inline-max-tools" do
      args = Application.parse_args(["--catalog-inline-max-tools", "20"])
      assert args[:catalog_inline_max_tools] == 20
    end

    test "accepts --max-catalog-ops-per-program" do
      args = Application.parse_args(["--max-catalog-ops-per-program", "50"])
      assert args[:max_catalog_ops_per_program] == 50
    end

    test "accepts --max-catalog-result-bytes" do
      args = Application.parse_args(["--max-catalog-result-bytes", "131072"])
      assert args[:max_catalog_result_bytes] == 131_072
    end
  end

  describe "apply_catalog_config/1 precedence" do
    test "defaults when no CLI or env" do
      Application.apply_catalog_config(%{})
      config = CatalogConfig.get()

      assert config.catalog_mode == :auto
      assert config.catalog_inline_max_chars == 800
    end

    test "env var sets catalog_mode" do
      System.put_env("PTC_RUNNER_MCP_CATALOG_MODE", "inline")
      Application.apply_catalog_config(%{})

      assert CatalogConfig.get().catalog_mode == :inline
    end

    test "CLI flag wins over env var for catalog_mode" do
      System.put_env("PTC_RUNNER_MCP_CATALOG_MODE", "inline")
      args = Application.parse_args(["--catalog-mode", "lazy"])

      Application.apply_catalog_config(args)
      assert CatalogConfig.get().catalog_mode == :lazy
    end

    test "env var sets integer config" do
      System.put_env("PTC_RUNNER_MCP_CATALOG_INLINE_MAX_CHARS", "9000")
      Application.apply_catalog_config(%{})

      assert CatalogConfig.get().catalog_inline_max_chars == 9000
    end

    test "CLI flag wins over env var for integer config" do
      System.put_env("PTC_RUNNER_MCP_CATALOG_INLINE_MAX_CHARS", "9000")
      args = Application.parse_args(["--catalog-inline-max-chars", "5000"])

      Application.apply_catalog_config(args)
      assert CatalogConfig.get().catalog_inline_max_chars == 5000
    end

    test "invalid catalog_mode falls back to :auto with warning" do
      System.put_env("PTC_RUNNER_MCP_CATALOG_MODE", "bogus")
      Application.apply_catalog_config(%{})

      assert CatalogConfig.get().catalog_mode == :auto
    end

    test "non-positive integer config raises" do
      System.put_env("PTC_RUNNER_MCP_CATALOG_INLINE_MAX_CHARS", "0")

      assert_raise RuntimeError,
                   ~r/--catalog-inline-max-chars .* must be a positive integer/,
                   fn ->
                     Application.apply_catalog_config(%{})
                   end
    end

    test "non-integer string config raises" do
      System.put_env("PTC_RUNNER_MCP_MAX_CATALOG_RESULT_BYTES", "abc")

      assert_raise RuntimeError,
                   ~r/--max-catalog-result-bytes .* must be a positive integer/,
                   fn ->
                     Application.apply_catalog_config(%{})
                   end
    end
  end
end
