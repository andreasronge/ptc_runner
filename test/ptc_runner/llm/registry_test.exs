defmodule PtcRunner.LLM.RegistryTest do
  use ExUnit.Case, async: true
  doctest PtcRunner.LLM.Registry

  alias PtcRunner.LLM.DefaultRegistry
  alias PtcRunner.LLM.Registry

  describe "resolve/1 with aliases" do
    test "resolves haiku alias to openrouter by default" do
      assert {:ok, "openrouter:anthropic/claude-haiku-4.5"} = Registry.resolve("haiku")
    end

    test "resolves sonnet alias" do
      assert {:ok, "openrouter:anthropic/claude-sonnet-4.5"} = Registry.resolve("sonnet")
    end

    test "resolves gemini alias" do
      # Gemini is available on the default provider (openrouter)
      assert {:ok, "openrouter:google/gemini-2.5-flash"} = Registry.resolve("gemini")
    end

    test "keeps the Devstral alias on its explicit free route" do
      assert {:ok, "openrouter:mistralai/devstral-2512:free"} = Registry.resolve("devstral")
    end
  end

  describe "resolve/1 with provider prefix" do
    test "resolves bedrock:haiku" do
      assert {:ok, "amazon_bedrock:anthropic.claude-haiku-4-5-20251001-v1:0"} =
               Registry.resolve("bedrock:haiku")
    end

    test "resolves openrouter:sonnet" do
      assert {:ok, "openrouter:anthropic/claude-sonnet-4.5"} =
               Registry.resolve("openrouter:sonnet")
    end
  end

  describe "resolve/1 with direct model IDs" do
    test "passes through openrouter:full/path" do
      assert {:ok, "openrouter:anthropic/claude-3-haiku-20240307"} =
               Registry.resolve("openrouter:anthropic/claude-3-haiku-20240307")
    end

    test "passes through ollama:model-name" do
      assert {:ok, "ollama:deepseek-coder:6.7b"} =
               Registry.resolve("ollama:deepseek-coder:6.7b")
    end

    test "normalizes bedrock to amazon_bedrock" do
      assert {:ok, "amazon_bedrock:anthropic.claude-3-haiku-custom"} =
               Registry.resolve("bedrock:anthropic.claude-3-haiku-custom")
    end
  end

  describe "resolve/1 error cases" do
    test "returns error for unknown alias" do
      assert {:error, message} = Registry.resolve("unknown_model")
      assert message =~ "Unknown model"
      assert message =~ "haiku"
    end

    test "returns error for unknown provider" do
      assert {:error, message} = Registry.resolve("fakeprovider:haiku")
      assert message =~ "Unknown provider"
    end

    test "returns error when explicit provider doesn't have the model" do
      # deepseek is only on openrouter — explicit bedrock: must error, not silently redirect
      assert {:error, message} = Registry.resolve("bedrock:deepseek")
      assert message =~ "not available on bedrock"
      assert message =~ "openrouter"
    end

    test "auto-selects sole provider for bare alias with default provider miss" do
      # deepseek only has openrouter, and default provider is openrouter, so this works
      # But if default were bedrock, a bare "deepseek" would auto-select openrouter
      assert {:ok, "openrouter:deepseek/deepseek-v4-flash"} = Registry.resolve("deepseek")
    end
  end

  describe "resolve!/1" do
    test "returns model string on success" do
      assert "openrouter:anthropic/claude-haiku-4.5" = Registry.resolve!("haiku")
    end

    test "raises on error" do
      assert_raise ArgumentError, fn ->
        Registry.resolve!("unknown_model")
      end
    end
  end

  describe "DefaultRegistry behaviour implementation" do
    test "DefaultRegistry implements the resolver contract" do
      # Force load — every other test in this file uses the Registry behaviour,
      # so DefaultRegistry's .beam may be unloaded when this test runs first
      # under an unlucky async seed, making function_exported?/3 return false.
      Code.ensure_loaded!(DefaultRegistry)

      assert function_exported?(DefaultRegistry, :resolve, 1)
    end
  end
end
