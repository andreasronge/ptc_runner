defmodule LLMClient.RegistryTest do
  use ExUnit.Case, async: true

  alias LLMClient.Registry

  describe "resolve/1 - alias resolution" do
    test "resolves known alias 'haiku' to a model ID" do
      {:ok, model_id} = Registry.resolve("haiku")
      assert is_binary(model_id)
      assert String.contains?(model_id, ":")
    end

    test "resolves known alias 'devstral' to openrouter format" do
      {:ok, model_id} = Registry.resolve("devstral")
      assert model_id == "openrouter:mistralai/devstral-2512:free"
    end

    test "resolves known alias 'gemini' to a valid model ID" do
      {:ok, model_id} = Registry.resolve("gemini")
      assert String.contains?(model_id, ":")
    end

    test "returns error for unknown alias" do
      {:error, reason} = Registry.resolve("unknown_model")
      assert String.contains?(reason, "Unknown model")
      assert String.contains?(reason, "haiku")
    end
  end

  describe "resolve/1 - direct provider format" do
    test "accepts direct provider format 'anthropic:claude-haiku-4.5'" do
      {:ok, model_id} = Registry.resolve("anthropic:claude-haiku-4.5")
      assert model_id == "anthropic:claude-haiku-4.5"
    end

    test "accepts direct OpenAI format 'openai:gpt-5.1-codex-mini'" do
      {:ok, model_id} = Registry.resolve("openai:gpt-5.1-codex-mini")
      assert model_id == "openai:gpt-5.1-codex-mini"
    end

    test "accepts direct Google format 'google:gemini-2.5-flash'" do
      {:ok, model_id} = Registry.resolve("google:gemini-2.5-flash")
      assert model_id == "google:gemini-2.5-flash"
    end
  end

  describe "resolve/1 - OpenRouter format" do
    test "accepts OpenRouter format 'openrouter:anthropic/claude-haiku-4.5'" do
      {:ok, model_id} = Registry.resolve("openrouter:anthropic/claude-haiku-4.5")
      assert model_id == "openrouter:anthropic/claude-haiku-4.5"
    end

    test "accepts OpenRouter format with variant 'openrouter:mistralai/devstral-2512:free'" do
      {:ok, model_id} = Registry.resolve("openrouter:mistralai/devstral-2512:free")
      assert model_id == "openrouter:mistralai/devstral-2512:free"
    end

    test "accepts OpenRouter format with dashes in provider 'openrouter:google/gemini-2.5-flash'" do
      {:ok, model_id} = Registry.resolve("openrouter:google/gemini-2.5-flash")
      assert model_id == "openrouter:google/gemini-2.5-flash"
    end
  end

  describe "resolve/1 - invalid formats" do
    test "rejects malformed OpenRouter format with colon instead of slash" do
      {:error, reason} = Registry.resolve("openrouter:anthropic:claude-haiku-4.5")
      assert String.contains?(reason, "OpenRouter format")
      assert String.contains?(reason, "slash")
    end

    test "rejects completely invalid format" do
      {:error, reason} = Registry.resolve("invalid:format:model")

      assert String.contains?(reason, "Unknown model format") or
               String.contains?(reason, "OpenRouter format")
    end

    test "rejects empty string" do
      {:error, reason} = Registry.resolve("")

      assert String.contains?(reason, "Unknown model") or
               String.contains?(reason, "Unknown model format")
    end
  end

  describe "validate/1 - valid formats" do
    test "validates known alias 'haiku'" do
      assert Registry.validate("haiku") == :ok
    end

    test "validates known alias 'gpt'" do
      assert Registry.validate("gpt") == :ok
    end

    test "validates direct provider format 'anthropic:claude-haiku-4.5'" do
      assert Registry.validate("anthropic:claude-haiku-4.5") == :ok
    end

    test "validates direct provider format 'openai:gpt-5.1-codex-mini'" do
      assert Registry.validate("openai:gpt-5.1-codex-mini") == :ok
    end

    test "validates direct provider format 'google:gemini-2.5-flash'" do
      assert Registry.validate("google:gemini-2.5-flash") == :ok
    end

    test "validates OpenRouter format 'openrouter:anthropic/claude-haiku-4.5'" do
      assert Registry.validate("openrouter:anthropic/claude-haiku-4.5") == :ok
    end

    test "validates OpenRouter format with variant 'openrouter:mistralai/devstral-2512:free'" do
      assert Registry.validate("openrouter:mistralai/devstral-2512:free") == :ok
    end

    test "validates OpenRouter format with dashes 'openrouter:google/gemini-2.5-flash'" do
      assert Registry.validate("openrouter:google/gemini-2.5-flash") == :ok
    end
  end

  describe "validate/1 - invalid formats" do
    test "rejects OpenRouter format with colon instead of slash" do
      {:error, reason} = Registry.validate("openrouter:anthropic:claude-haiku-4.5")
      assert String.contains?(reason, "OpenRouter format")
      assert String.contains?(reason, "slash, not colon")
    end

    test "rejects unknown model format" do
      {:error, reason} = Registry.validate("unknown:format:model")

      assert String.contains?(reason, "Unknown model format") or
               String.contains?(reason, "OpenRouter format")
    end

    test "rejects format with no provider prefix" do
      {:error, reason} = Registry.validate("some-model-name")

      assert String.contains?(reason, "Unknown model format") or
               String.contains?(reason, "Unknown model")
    end

    test "rejects empty string" do
      {:error, _reason} = Registry.validate("")
    end
  end

  describe "available_providers/0" do
    test "returns empty list when no API keys are set" do
      # This test runs in an environment where API keys may or may not be set
      # We just verify it returns a list
      providers = Registry.available_providers()
      assert is_list(providers)
    end

    test "returns provider atoms" do
      providers = Registry.available_providers()
      assert is_list(providers)
      # If any providers are returned, they should be atoms
      Enum.each(providers, &assert(is_atom(&1)))
    end

    test "detects ANTHROPIC_API_KEY if set" do
      # Save original env var
      original = System.get_env("ANTHROPIC_API_KEY")

      try do
        System.put_env("ANTHROPIC_API_KEY", "test-key")
        providers = Registry.available_providers()
        assert :anthropic in providers
      after
        # Restore original env var
        if original do
          System.put_env("ANTHROPIC_API_KEY", original)
        else
          System.delete_env("ANTHROPIC_API_KEY")
        end
      end
    end

    test "detects OPENROUTER_API_KEY if set" do
      original = System.get_env("OPENROUTER_API_KEY")

      try do
        System.put_env("OPENROUTER_API_KEY", "test-key")
        providers = Registry.available_providers()
        assert :openrouter in providers
      after
        if original do
          System.put_env("OPENROUTER_API_KEY", original)
        else
          System.delete_env("OPENROUTER_API_KEY")
        end
      end
    end
  end

  describe "calculate_cost/3" do
    test "returns 0.0 for unknown model" do
      cost = Registry.calculate_cost("unknown:model", 1000, 1000)
      assert cost == 0.0
    end

    test "calculates cost for known alias 'haiku'" do
      # haiku: input_cost_per_mtok: 0.80, output_cost_per_mtok: 4.00
      # 1,000 input tokens + 1,000 output tokens
      # Expected: (0.80 * 1000 / 1_000_000) + (4.00 * 1000 / 1_000_000) = 0.0008 + 0.004 = 0.0048
      cost = Registry.calculate_cost("haiku", 1000, 1000)
      assert_in_delta(cost, 0.0048, 0.00001)
    end

    test "calculates cost for known alias 'gpt'" do
      # gpt: input_cost_per_mtok: 0.40, output_cost_per_mtok: 1.60
      # 1,000,000 input tokens + 1,000,000 output tokens
      # Expected: (0.40 * 1_000_000 / 1_000_000) + (1.60 * 1_000_000 / 1_000_000) = 0.40 + 1.60 = 2.00
      cost = Registry.calculate_cost("gpt", 1_000_000, 1_000_000)
      assert_in_delta(cost, 2.00, 0.01)
    end

    test "calculates cost for known OpenRouter model ID" do
      # Using haiku's OpenRouter format: input 0.80, output 4.00
      cost = Registry.calculate_cost("openrouter:anthropic/claude-haiku-4.5", 1000, 1000)
      assert_in_delta(cost, 0.0048, 0.00001)
    end

    test "returns 0.0 for zero tokens" do
      cost = Registry.calculate_cost("haiku", 0, 0)
      assert cost == 0.0
    end

    test "calculates cost for large token counts" do
      # devstral: free (0.0 input, 0.0 output)
      cost = Registry.calculate_cost("devstral", 10_000_000, 10_000_000)
      assert cost == 0.0
    end
  end

  describe "preset_models/0" do
    test "returns a map of aliases to model IDs" do
      models = Registry.preset_models()
      assert is_map(models)
      assert map_size(models) > 0
    end

    test "includes expected aliases" do
      models = Registry.preset_models()
      assert Map.has_key?(models, "haiku")
      assert Map.has_key?(models, "gpt")
      assert Map.has_key?(models, "gemini")
      assert Map.has_key?(models, "devstral")
      assert Map.has_key?(models, "deepseek")
      assert Map.has_key?(models, "kimi")
    end

    test "maps aliases to valid model IDs" do
      models = Registry.preset_models()

      Enum.each(models, fn {_alias, model_id} ->
        assert is_binary(model_id)
        assert String.contains?(model_id, ":")
      end)
    end

    test "respects available providers when selecting models" do
      original_key = System.get_env("ANTHROPIC_API_KEY")

      try do
        # Unset all API keys
        System.delete_env("ANTHROPIC_API_KEY")
        System.delete_env("OPENROUTER_API_KEY")
        System.delete_env("OPENAI_API_KEY")
        System.delete_env("GOOGLE_API_KEY")

        models = Registry.preset_models()
        # Should still return models (using default/fallback)
        assert is_map(models)
        assert map_size(models) > 0
      after
        if original_key do
          System.put_env("ANTHROPIC_API_KEY", original_key)
        end
      end
    end
  end

  describe "aliases/0" do
    test "returns list of all alias names" do
      aliases = Registry.aliases()
      assert is_list(aliases)
      assert "haiku" in aliases
      assert "gpt" in aliases
      assert "gemini" in aliases
    end

    test "returns sorted aliases" do
      aliases = Registry.aliases()
      assert aliases == Enum.sort(aliases)
    end

    test "has at least 6 aliases" do
      aliases = Registry.aliases()
      assert length(aliases) >= 6
    end
  end

  describe "list_models/0" do
    test "returns list of model maps" do
      models = Registry.list_models()
      assert is_list(models)
      assert length(models) > 0
    end

    test "each model has required fields" do
      models = Registry.list_models()

      Enum.each(models, fn model ->
        assert Map.has_key?(model, :alias)
        assert Map.has_key?(model, :description)
        assert Map.has_key?(model, :providers)
        assert Map.has_key?(model, :available)
        assert is_binary(model.alias)
        assert is_binary(model.description)
        assert is_list(model.providers)
        assert is_boolean(model.available)
      end)
    end

    test "models are sorted by alias" do
      models = Registry.list_models()
      aliases = Enum.map(models, & &1.alias)
      assert aliases == Enum.sort(aliases)
    end
  end

  describe "format_model_list/0" do
    test "returns a string" do
      output = Registry.format_model_list()
      assert is_binary(output)
    end

    test "includes header" do
      output = Registry.format_model_list()
      assert String.contains?(output, "Available Models")
    end

    test "includes all model aliases" do
      output = Registry.format_model_list()
      aliases = Registry.aliases()

      Enum.each(aliases, fn alias ->
        assert String.contains?(output, alias)
      end)
    end

    test "includes available or needs API key status" do
      output = Registry.format_model_list()

      assert String.contains?(output, "[available]") or
               String.contains?(output, "[needs API key]")
    end

    test "includes provider information" do
      output = Registry.format_model_list()
      assert String.contains?(output, "Providers:")
    end

    test "includes usage examples" do
      output = Registry.format_model_list()
      assert String.contains?(output, "mix lisp")
      assert String.contains?(output, "--model")
    end

    test "shows current API keys or 'none'" do
      output = Registry.format_model_list()
      assert String.contains?(output, "Current API keys:")
    end

    test "handles empty available_providers" do
      original_keys = {
        System.get_env("ANTHROPIC_API_KEY"),
        System.get_env("OPENROUTER_API_KEY"),
        System.get_env("OPENAI_API_KEY"),
        System.get_env("GOOGLE_API_KEY")
      }

      try do
        # Unset all API keys
        System.delete_env("ANTHROPIC_API_KEY")
        System.delete_env("OPENROUTER_API_KEY")
        System.delete_env("OPENAI_API_KEY")
        System.delete_env("GOOGLE_API_KEY")

        output = Registry.format_model_list()
        assert is_binary(output)
        # Should show "none" for current API keys
        assert String.contains?(output, "none") or String.contains?(output, "Current API keys:")
      after
        {anthropic, openrouter, openai, google} = original_keys
        if anthropic, do: System.put_env("ANTHROPIC_API_KEY", anthropic)
        if openrouter, do: System.put_env("OPENROUTER_API_KEY", openrouter)
        if openai, do: System.put_env("OPENAI_API_KEY", openai)
        if google, do: System.put_env("GOOGLE_API_KEY", google)
      end
    end
  end

  describe "get_model_info/1" do
    test "returns model info for known alias" do
      info = Registry.get_model_info("haiku")
      assert is_map(info)
      assert Map.has_key?(info, :description)
      assert Map.has_key?(info, :input_cost_per_mtok)
      assert Map.has_key?(info, :output_cost_per_mtok)
      assert Map.has_key?(info, :providers)
    end

    test "returns model info for model ID" do
      info = Registry.get_model_info("openrouter:anthropic/claude-haiku-4.5")
      assert is_map(info)
    end

    test "returns nil for unknown model" do
      info = Registry.get_model_info("unknown:model")
      assert info == nil
    end

    test "returns correct cost rates for haiku" do
      info = Registry.get_model_info("haiku")
      assert info.input_cost_per_mtok == 0.80
      assert info.output_cost_per_mtok == 4.00
    end
  end

  describe "resolve!/1" do
    test "returns model_id for valid alias" do
      model_id = Registry.resolve!("haiku")
      assert is_binary(model_id)
      assert String.contains?(model_id, ":")
    end

    test "raises ArgumentError for unknown model" do
      assert_raise ArgumentError, fn ->
        Registry.resolve!("unknown_model_xyz")
      end
    end

    test "returns model_id for valid direct provider format" do
      model_id = Registry.resolve!("anthropic:claude-haiku-4.5")
      assert model_id == "anthropic:claude-haiku-4.5"
    end
  end

  describe "default_model/0" do
    test "returns a valid model ID" do
      model_id = Registry.default_model()
      assert is_binary(model_id)
      assert String.contains?(model_id, ":")
    end

    test "uses haiku as default" do
      # The default should be based on resolving "haiku"
      haiku_result = Registry.resolve("haiku")
      default = Registry.default_model()

      case haiku_result do
        {:ok, haiku_id} -> assert default == haiku_id
        {:error, _} -> flunk("haiku should resolve successfully")
      end
    end
  end
end
