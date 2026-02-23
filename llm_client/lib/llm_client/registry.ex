defmodule LLMClient.Registry do
  @moduledoc """
  Provider-aware model registry for LLM providers.

  Supports multiple providers with unified aliases:
  - `openrouter:haiku` → OpenRouter's Claude Haiku
  - `bedrock:haiku` → AWS Bedrock's Claude Haiku
  - `haiku` → Uses default provider (configurable)

  ## Provider Formats

  - `provider:alias` - Use specific provider with alias (e.g., `bedrock:haiku`)
  - `alias` - Use default provider with alias (e.g., `haiku`)
  - `provider:full/model/id` - Direct model ID (e.g., `openrouter:anthropic/claude-haiku-4.5`)
  - `ollama:model-name` - Local Ollama model

  ## Configuration

      # In config.exs or runtime.exs
      config :llm_client, :default_provider, :openrouter

  Or via environment variable:

      export LLM_DEFAULT_PROVIDER=bedrock

  ## Usage

      # Using default provider
      {:ok, model_id} = LLMClient.Registry.resolve("haiku")

      # Using specific provider
      {:ok, model_id} = LLMClient.Registry.resolve("bedrock:haiku")

      # Direct model ID (passes through)
      {:ok, model_id} = LLMClient.Registry.resolve("openrouter:anthropic/claude-haiku-4.5")
  """

  # Model definitions with provider-specific IDs
  # Each alias maps to available providers and their specific model IDs
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
        # Not available on Bedrock
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
    # Embedding models
    "embed" => %{
      description: "Nomic Embed Text - Local embedding via Ollama (768d)",
      providers: %{
        ollama: "nomic-embed-text"
      }
    },
    # Local models (Ollama only)
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
  # Note: :bedrock is user-facing alias, maps to :amazon_bedrock for ReqLLM
  @cloud_providers [:openrouter, :bedrock, :amazon_bedrock, :anthropic, :openai, :google, :groq]

  @doc """
  Get the default provider.

  Checks in order:
  1. Application config `:llm_client, :default_provider`
  2. Environment variable `LLM_DEFAULT_PROVIDER`
  3. Falls back to `:openrouter`
  """
  @spec default_provider() :: atom()
  def default_provider do
    Application.get_env(:llm_client, :default_provider) ||
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

  @doc """
  Resolve a model name to a full model ID.

  ## Formats

  - `"provider:alias"` - Specific provider with alias (e.g., `"bedrock:haiku"`)
  - `"alias"` - Default provider with alias (e.g., `"haiku"`)
  - `"provider:full/path"` - Direct model ID (passes through)
  - `"ollama:model"` - Local Ollama model

  ## Examples

      iex> LLMClient.Registry.resolve("haiku")
      {:ok, "openrouter:anthropic/claude-haiku-4.5"}

      iex> LLMClient.Registry.resolve("bedrock:haiku")
      {:ok, "amazon_bedrock:anthropic.claude-haiku-4-5-20251001-v1:0"}

      iex> LLMClient.Registry.resolve("bedrock:gemini")
      {:error, "Model 'gemini' is not available on bedrock. Available providers: openrouter, google"}
  """
  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(name) when is_binary(name) do
    case parse_model_spec(name) do
      {:alias_only, alias_name} ->
        resolve_with_provider(alias_name, default_provider())

      {:provider_alias, provider, alias_name} ->
        resolve_with_provider(alias_name, provider)

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
        # (the atom may not exist yet)
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
              # Normalize bedrock → amazon_bedrock for ReqLLM compatibility
              if provider in [:bedrock, :amazon_bedrock] do
                {:direct, "amazon_bedrock:#{model_part}"}
              else
                {:direct, name}
              end

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

  defp resolve_with_provider(alias_name, provider) do
    model = @models[alias_name]

    case Map.get(model.providers, provider) do
      nil ->
        # If the model has exactly one provider, use it automatically
        case Map.to_list(model.providers) do
          [{sole_provider, model_id}] ->
            req_llm_provider =
              if sole_provider in [:bedrock, :amazon_bedrock],
                do: :amazon_bedrock,
                else: sole_provider

            {:ok, "#{req_llm_provider}:#{model_id}"}

          _ ->
            available = model.providers |> Map.keys() |> Enum.join(", ")

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

  @doc """
  Resolve a model name, raising on error.
  """
  @spec resolve!(String.t()) :: String.t()
  def resolve!(name) do
    case resolve(name) do
      {:ok, model_id} -> model_id
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc """
  Get the default model using the default provider.
  """
  @spec default_model() :: String.t()
  def default_model do
    {:ok, model_id} = resolve(@default_model)
    model_id
  end

  @doc """
  List all available model aliases with status.
  """
  @spec list_models() :: [map()]
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

  @doc """
  Get all available providers based on environment variables and services.
  """
  @spec available_providers() :: [atom()]
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

    # Skip Ollama check in CI/test
    if System.get_env("CI") || Mix.env() == :test do
      cloud
    else
      if LLMClient.Providers.available?("ollama:test"), do: [:ollama | cloud], else: cloud
    end
  end

  @doc """
  Get detailed info for a model by alias.
  """
  @spec get_model_info(String.t()) :: map() | nil
  def get_model_info(alias_name) do
    case Map.get(@models, alias_name) do
      nil -> nil
      meta -> build_model_info(alias_name, meta)
    end
  end

  defp build_model_info(alias_name, meta) do
    %{
      alias: alias_name,
      description: meta.description,
      providers: Map.keys(meta.providers),
      provider_models: meta.providers
    }
  end

  @doc """
  Format models for CLI --list-models output.
  """
  @spec format_model_list() :: String.t()
  def format_model_list do
    default_prov = default_provider()

    {cloud_models, local_models} =
      list_models()
      |> Enum.split_with(fn m ->
        Enum.any?(
          [:openrouter, :anthropic, :openai, :google, :bedrock, :groq],
          &(&1 in m.providers)
        )
      end)

    header = """
    Available Models
    ================
    Default provider: #{default_prov}

    Cloud Models:
    """

    cloud_section =
      cloud_models
      |> Enum.map(fn model ->
        status = if model.available, do: "[available]", else: "[needs API key]"
        providers_str = model.providers |> Enum.map(&to_string/1) |> Enum.join(", ")

        "  #{String.pad_trailing(model.alias, 12)} #{String.pad_trailing(status, 16)} #{model.description}\n" <>
          "               Providers: #{providers_str}"
      end)
      |> Enum.join("\n\n")

    local_header = """

    Local Models (via Ollama):
    """

    local_section =
      local_models
      |> Enum.map(fn model ->
        status = if model.available, do: "[available]", else: "[needs Ollama]"

        "  #{String.pad_trailing(model.alias, 12)} #{String.pad_trailing(status, 16)} #{model.description}"
      end)
      |> Enum.join("\n")

    footer = """


    Usage:
      mix lisp --model=haiku                    # Uses default provider (#{default_prov})
      mix lisp --model=bedrock:haiku            # Explicit provider
      mix lisp --model=openrouter:haiku         # Explicit provider
      mix lisp --model=deepseek-local           # Local Ollama

    Environment:
      LLM_DEFAULT_PROVIDER=bedrock              # Change default provider
    """

    header <> cloud_section <> local_header <> local_section <> footer
  end

  @doc """
  Validate a model string format.
  """
  @spec validate(String.t()) :: :ok | {:error, String.t()}
  def validate(model_string) do
    case resolve(model_string) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get all aliases as a map (for CLI /model command).
  Returns alias -> provider:model_id for the given provider.

  ## Examples

      iex> LLMClient.Registry.preset_models(:openrouter) |> Map.get("haiku")
      "openrouter:anthropic/claude-haiku-4.5"

      iex> LLMClient.Registry.preset_models(:bedrock) |> Map.get("haiku")
      "amazon_bedrock:anthropic.claude-haiku-4-5-20251001-v1:0"
  """
  @spec preset_models(atom()) :: %{String.t() => String.t()}
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

  @doc """
  Get list of all alias names.
  """
  @spec aliases() :: [String.t()]
  def aliases, do: Map.keys(@models) |> Enum.sort()

  @doc """
  Extract the provider atom from a model string.

  ## Examples

      iex> LLMClient.Registry.provider_from_model("openrouter:anthropic/claude-haiku-4.5")
      :openrouter

      iex> LLMClient.Registry.provider_from_model("amazon_bedrock:anthropic.claude-3-haiku")
      :amazon_bedrock

      iex> LLMClient.Registry.provider_from_model("haiku")
      nil
  """
  @spec provider_from_model(String.t()) :: atom() | nil
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
