defmodule PtcRunner.LLM.RegistryTest do
  use ExUnit.Case, async: true

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
      # Gemini isn't on the default provider (openrouter), but has exactly one cloud provider
      # so it auto-selects
      assert {:ok, "openrouter:google/gemini-2.5-flash"} = Registry.resolve("gemini")
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

    test "auto-selects sole provider when requested provider unavailable" do
      # deepseek is only on openrouter - auto-selects that when bedrock requested
      assert {:ok, "openrouter:deepseek/deepseek-chat-v3-0324"} =
               Registry.resolve("bedrock:deepseek")
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

  describe "aliases/0" do
    test "returns sorted list of alias names" do
      aliases = Registry.aliases()
      assert is_list(aliases)
      assert "haiku" in aliases
      assert "sonnet" in aliases
      assert aliases == Enum.sort(aliases)
    end
  end

  describe "default_model/0" do
    test "returns resolved haiku by default" do
      assert Registry.default_model() =~ "haiku"
    end
  end

  describe "default_provider/0" do
    test "returns openrouter by default" do
      # May be overridden by env or config, but default is :openrouter
      provider = Registry.default_provider()
      assert is_atom(provider)
    end
  end

  describe "list_models/0" do
    test "returns list of model maps" do
      models = Registry.list_models()
      assert is_list(models)
      assert models != []

      # Check structure of first model
      model = Enum.find(models, &(&1.alias == "haiku"))
      assert model.description =~ "Claude"
      assert is_list(model.providers)
      assert :openrouter in model.providers
    end
  end

  describe "preset_models/1" do
    test "returns alias to model_id map for openrouter" do
      presets = Registry.preset_models(:openrouter)
      assert is_map(presets)
      assert presets["haiku"] == "openrouter:anthropic/claude-haiku-4.5"
      assert presets["sonnet"] == "openrouter:anthropic/claude-sonnet-4.5"
    end

    test "returns alias to model_id map for bedrock" do
      presets = Registry.preset_models(:bedrock)
      assert is_map(presets)
      assert presets["haiku"] == "amazon_bedrock:anthropic.claude-haiku-4-5-20251001-v1:0"
    end

    test "uses default provider when called with no args" do
      presets = Registry.preset_models()
      assert is_map(presets)
      assert Map.has_key?(presets, "haiku")
    end
  end

  describe "provider_from_model/1" do
    test "extracts provider from model string" do
      assert :openrouter = Registry.provider_from_model("openrouter:anthropic/claude-haiku-4.5")
      assert :amazon_bedrock = Registry.provider_from_model("amazon_bedrock:anthropic.claude-3")
      assert :ollama = Registry.provider_from_model("ollama:llama2")
    end

    test "returns nil for plain alias" do
      assert nil == Registry.provider_from_model("haiku")
    end

    test "returns nil for unknown provider" do
      assert nil == Registry.provider_from_model("unknownprovider:model")
    end
  end

  describe "validate/1" do
    test "returns :ok for valid model strings" do
      assert :ok = Registry.validate("haiku")
      assert :ok = Registry.validate("bedrock:haiku")
      assert :ok = Registry.validate("openrouter:anthropic/claude-haiku-4.5")
    end

    test "returns error tuple for invalid model strings" do
      assert {:error, _} = Registry.validate("unknown_model")
      assert {:error, _} = Registry.validate("fakeprovider:haiku")
    end
  end

  describe "DefaultRegistry behaviour implementation" do
    test "DefaultRegistry implements all callbacks" do
      assert function_exported?(DefaultRegistry, :resolve, 1)
      assert function_exported?(DefaultRegistry, :resolve!, 1)
      assert function_exported?(DefaultRegistry, :default_model, 0)
      assert function_exported?(DefaultRegistry, :default_provider, 0)
      assert function_exported?(DefaultRegistry, :aliases, 0)
      assert function_exported?(DefaultRegistry, :list_models, 0)
      assert function_exported?(DefaultRegistry, :preset_models, 1)
      assert function_exported?(DefaultRegistry, :available_providers, 0)
      assert function_exported?(DefaultRegistry, :provider_from_model, 1)
      assert function_exported?(DefaultRegistry, :validate, 1)
    end
  end
end
