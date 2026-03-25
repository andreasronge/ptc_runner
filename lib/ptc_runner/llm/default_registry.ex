defmodule PtcRunner.LLM.DefaultRegistry do
  @moduledoc """
  Default model registry with built-in aliases for common LLM providers.

  Supports multiple providers with unified aliases:
  - `"haiku"` -> Uses default provider (configurable)
  - `"bedrock:haiku"` -> AWS Bedrock
  - `"openrouter:haiku"` -> OpenRouter

  ## Provider Formats

  - `"alias"` - Use default provider with alias (e.g., `"haiku"`)
  - `"provider:alias"` - Specific provider with alias (e.g., `"bedrock:haiku"`)
  - `"provider:full/path"` - Direct model ID (e.g., `"openrouter:anthropic/claude-haiku-4.5"`)
  - `"ollama:model"` - Local Ollama model

  ## Configuration

      config :ptc_runner, :default_provider, :bedrock

  Or via environment variable:

      export LLM_DEFAULT_PROVIDER=bedrock
  """

  @behaviour PtcRunner.LLM.Registry

  # Model definitions with provider-specific IDs
  @models %{
    "haiku" => %{
      description: "Claude Haiku 4.5 - Fast, cost-effective",
      providers: %{
        openrouter: "anthropic/claude-haiku-4.5",
        bedrock: "anthropic.claude-haiku-4-5-20251001-v1:0",
        anthropic: "claude-haiku-4-5-20251001"
      }
    },
    "sonnet" => %{
      description: "Claude Sonnet 4.5 - Balanced performance",
      providers: %{
        openrouter: "anthropic/claude-sonnet-4.5",
        bedrock: "anthropic.claude-sonnet-4-5-20250929-v1:0",
        anthropic: "claude-sonnet-4-5-20250929"
      }
    },
    "ministral" => %{
      description: "Ministral 3 8B - Mistral's fast edge model via Bedrock",
      providers: %{
        bedrock: "mistral.ministral-3-8b-instruct"
      }
    },
    "nova-micro" => %{
      description: "Amazon Nova Micro - Cheapest Bedrock model, text only",
      providers: %{
        bedrock: "amazon.nova-micro-v1:0"
      }
    },
    "nova-lite" => %{
      description: "Amazon Nova Lite - Fast, low-cost multimodal model",
      providers: %{
        bedrock: "amazon.nova-lite-v1:0"
      }
    },
    "qwen-coder" => %{
      description: "Qwen3 Coder 30B - Code generation via Bedrock",
      providers: %{
        bedrock: "qwen.qwen3-coder-30b-a3b-v1:0"
      }
    },
    "qwen-coder-480b" => %{
      description: "Qwen3 Coder 480B - Large code model via Bedrock",
      providers: %{
        bedrock: "qwen.qwen3-coder-480b-a35b-v1:0"
      }
    },
    "gemini" => %{
      description: "Gemini 2.5 Flash - Google's fast model",
      providers: %{
        openrouter: "google/gemini-2.5-flash",
        google: "gemini-2.5-flash"
      }
    },
    "gemini-flash-lite" => %{
      description: "Gemini 3.1 Flash Lite Preview - Google's lightweight model",
      providers: %{
        openrouter: "google/gemini-3.1-flash-lite-preview"
      }
    },
    "deepseek" => %{
      description: "DeepSeek Chat V3 - Cost-effective reasoning",
      providers: %{
        openrouter: "deepseek/deepseek-chat-v3-0324"
      }
    },
    "devstral" => %{
      description: "Devstral 2512 - Mistral AI code model (free)",
      providers: %{
        openrouter: "mistralai/devstral-2512:free"
      }
    },
    "kimi" => %{
      description: "Kimi K2 - Moonshot AI's model",
      providers: %{
        openrouter: "moonshotai/kimi-k2"
      }
    },
    "gpt" => %{
      description: "GPT-4.1 Mini - OpenAI's efficient model",
      providers: %{
        openrouter: "openai/gpt-4.1-mini",
        openai: "gpt-4.1-mini"
      }
    },
    "gpt-oss" => %{
      description: "GPT-OSS 120B - OpenAI's large open-source model via Groq",
      providers: %{
        groq: "openai/gpt-oss-120b"
      }
    },
    "embed" => %{
      description: "Nomic Embed Text - Local embedding via Ollama (768d)",
      providers: %{
        ollama: "nomic-embed-text"
      }
    },
    "deepseek-local" => %{
      description: "DeepSeek Coder 6.7B - Local via Ollama",
      providers: %{
        ollama: "deepseek-coder:6.7b"
      }
    },
    "qwen-local" => %{
      description: "Qwen 2.5 Coder 7B - Local via Ollama",
      providers: %{
        ollama: "qwen2.5-coder:7b"
      }
    },
    "llama-local" => %{
      description: "Llama 3.2 3B - Local via Ollama (fast)",
      providers: %{
        ollama: "llama3.2:3b"
      }
    }
  }

  @default_model "haiku"
  @default_provider :openrouter

  # Cloud providers that can be used with aliases
  @cloud_providers [:openrouter, :bedrock, :amazon_bedrock, :anthropic, :openai, :google, :groq]

  @impl true
  def default_provider do
    Application.get_env(:ptc_runner, :default_provider) ||
      parse_env_provider() ||
      @default_provider
  end

  defp parse_env_provider do
    case System.get_env("LLM_DEFAULT_PROVIDER") do
      nil -> nil
      provider -> String.to_existing_atom(provider)
    end
  rescue
    ArgumentError -> nil
  end

  @impl true
  def resolve(name) when is_binary(name) do
    case parse_model_spec(name) do
      {:alias_only, alias_name} ->
        resolve_with_provider(alias_name, default_provider(), :default)

      {:provider_alias, provider, alias_name} ->
        resolve_with_provider(alias_name, provider, :explicit)

      {:direct, model_id} ->
        {:ok, model_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_model_spec(name) do
    cond do
      # Known alias without provider prefix
      Map.has_key?(@models, name) ->
        {:alias_only, name}

      # Provider:alias or provider:model format
      String.contains?(name, ":") ->
        [provider_str | rest] = String.split(name, ":", parts: 2)
        model_part = Enum.join(rest, ":")

        # Handle openai-compat specially before atom conversion
        if provider_str == "openai-compat" do
          {:direct, name}
        else
          provider = String.to_existing_atom(provider_str)

          cond do
            # provider:alias (e.g., bedrock:haiku)
            provider in @cloud_providers and Map.has_key?(@models, model_part) ->
              {:provider_alias, provider, model_part}

            # ollama:model-name
            provider == :ollama ->
              {:direct, name}

            # Direct model ID (e.g., openrouter:anthropic/claude-haiku-4.5)
            provider in @cloud_providers ->
              {:direct, normalize_direct_model(provider, model_part, name)}

            true ->
              {:error, unknown_provider_error(provider_str)}
          end
        end

      true ->
        {:error, unknown_model_error(name)}
    end
  rescue
    ArgumentError ->
      # String.to_existing_atom failed - unknown provider
      [provider_str | _] = String.split(name, ":", parts: 2)
      {:error, unknown_provider_error(provider_str)}
  end

  # Normalize bedrock -> amazon_bedrock for ReqLLM compatibility
  defp normalize_direct_model(provider, model_part, _name)
       when provider in [:bedrock, :amazon_bedrock] do
    "amazon_bedrock:#{model_part}"
  end

  defp normalize_direct_model(_provider, _model_part, name), do: name

  defp resolve_with_provider(alias_name, provider, source) do
    model = @models[alias_name]

    case Map.get(model.providers, provider) do
      nil ->
        available = model.providers |> Map.keys() |> Enum.join(", ")

        case {source, Map.to_list(model.providers)} do
          # Bare alias with default provider miss — auto-select sole provider
          {:default, [{sole_provider, model_id}]} ->
            req_llm_provider =
              if sole_provider in [:bedrock, :amazon_bedrock],
                do: :amazon_bedrock,
                else: sole_provider

            {:ok, "#{req_llm_provider}:#{model_id}"}

          # Explicit provider:alias — never silently redirect
          {:explicit, _} ->
            {:error,
             "Model '#{alias_name}' is not available on #{provider}. Available providers: #{available}"}

          # Multiple providers, none match default
          {:default, _} ->
            {:error,
             "Model '#{alias_name}' is not available on #{provider}. Available providers: #{available}"}
        end

      model_id ->
        # Use amazon_bedrock prefix for ReqLLM compatibility
        req_llm_provider =
          if provider in [:bedrock, :amazon_bedrock], do: :amazon_bedrock, else: provider

        {:ok, "#{req_llm_provider}:#{model_id}"}
    end
  end

  @impl true
  def resolve!(name) do
    case resolve(name) do
      {:ok, model_id} -> model_id
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @impl true
  def default_model do
    {:ok, model_id} = resolve(@default_model)
    model_id
  end

  @impl true
  def list_models do
    available_provs = available_providers()

    @models
    |> Enum.map(fn {alias_name, meta} ->
      model_providers = Map.keys(meta.providers)

      %{
        alias: alias_name,
        description: meta.description,
        providers: model_providers,
        available: Enum.any?(model_providers, &(&1 in available_provs))
      }
    end)
    |> Enum.sort_by(& &1.alias)
  end

  @impl true
  def available_providers do
    cloud =
      [
        {:anthropic, "ANTHROPIC_API_KEY"},
        {:openai, "OPENAI_API_KEY"},
        {:google, "GOOGLE_API_KEY"},
        {:openrouter, "OPENROUTER_API_KEY"},
        {:groq, "GROQ_API_KEY"},
        {:bedrock, ["AWS_ACCESS_KEY_ID", "AWS_SESSION_TOKEN"]}
      ]
      |> Enum.filter(fn
        {_p, env_vars} when is_list(env_vars) ->
          Enum.any?(env_vars, &(System.get_env(&1) != nil))

        {_p, env} ->
          System.get_env(env) != nil
      end)
      |> Enum.map(fn {p, _env} -> p end)

    # Skip Ollama check in CI/test (avoid Mix.env() — unavailable in releases)
    if System.get_env("CI") || System.get_env("MIX_ENV") == "test" do
      cloud
    else
      # Check if ollama is available via HTTP
      case check_ollama_available() do
        true -> [:ollama | cloud]
        false -> cloud
      end
    end
  end

  defp check_ollama_available do
    # Simple check - try to connect to ollama's default port
    case :gen_tcp.connect(~c"localhost", 11_434, [], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  @impl true
  def preset_models(provider \\ default_provider()) do
    # Normalize bedrock variants
    lookup_provider = if provider in [:amazon_bedrock, :bedrock], do: :bedrock, else: provider

    output_provider =
      if provider in [:amazon_bedrock, :bedrock], do: :amazon_bedrock, else: provider

    @models
    |> Enum.filter(fn {_alias, meta} -> Map.has_key?(meta.providers, lookup_provider) end)
    |> Map.new(fn {alias_name, meta} ->
      {alias_name, "#{output_provider}:#{meta.providers[lookup_provider]}"}
    end)
  end

  @impl true
  def aliases, do: Map.keys(@models) |> Enum.sort()

  @impl true
  def provider_from_model(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider_str, _rest] ->
        try do
          String.to_existing_atom(provider_str)
        rescue
          ArgumentError -> nil
        end

      _ ->
        nil
    end
  end

  @impl true
  def validate(model_string) do
    case resolve(model_string) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get detailed info for a model by alias name.

  Returns a map with `:alias`, `:description`, and `:providers` keys, or `nil`
  if the alias is not found. This is a plain function on `DefaultRegistry` only —
  not part of the `Registry` behaviour.

  ## Examples

      iex> info = PtcRunner.LLM.DefaultRegistry.get_model_info("haiku")
      iex> info.alias
      "haiku"
      iex> info.description
      "Claude Haiku 4.5 - Fast, cost-effective"
      iex> Map.has_key?(info.providers, :openrouter)
      true

      iex> PtcRunner.LLM.DefaultRegistry.get_model_info("nonexistent")
      nil

  """
  @spec get_model_info(String.t()) :: map() | nil
  def get_model_info(alias_name) do
    case Map.get(@models, alias_name) do
      nil -> nil
      meta -> %{alias: alias_name, description: meta.description, providers: meta.providers}
    end
  end

  defp unknown_model_error(name) do
    aliases_str = aliases() |> Enum.join(", ")

    """
    Unknown model: '#{name}'

    Available aliases: #{aliases_str}

    Or use provider:alias format:
      - bedrock:haiku
      - openrouter:sonnet

    Run with --list-models to see all options.
    """
  end

  defp unknown_provider_error(provider) do
    """
    Unknown provider: '#{provider}'

    Available providers: openrouter, bedrock, anthropic, openai, google, groq, ollama
    """
  end
end
