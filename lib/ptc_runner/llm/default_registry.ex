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
      providers: %{
        openrouter: "anthropic/claude-haiku-4.5",
        bedrock: "anthropic.claude-haiku-4-5-20251001-v1:0",
        anthropic: "claude-haiku-4-5-20251001"
      }
    },
    "sonnet" => %{
      providers: %{
        openrouter: "anthropic/claude-sonnet-4.5",
        bedrock: "anthropic.claude-sonnet-4-5-20250929-v1:0",
        anthropic: "claude-sonnet-4-5-20250929"
      }
    },
    "ministral" => %{
      providers: %{
        bedrock: "mistral.ministral-3-8b-instruct"
      }
    },
    "nova-micro" => %{
      providers: %{
        bedrock: "amazon.nova-micro-v1:0"
      }
    },
    "nova-lite" => %{
      providers: %{
        bedrock: "amazon.nova-lite-v1:0"
      }
    },
    "qwen-coder" => %{
      providers: %{
        bedrock: "qwen.qwen3-coder-30b-a3b-v1:0"
      }
    },
    "qwen-coder-480b" => %{
      providers: %{
        bedrock: "qwen.qwen3-coder-480b-a35b-v1:0"
      }
    },
    "gemini" => %{
      providers: %{
        openrouter: "google/gemini-2.5-flash",
        google: "gemini-2.5-flash"
      }
    },
    "gemini-flash-lite" => %{
      providers: %{
        openrouter: "google/gemini-3.1-flash-lite"
      }
    },
    "deepseek" => %{
      providers: %{
        openrouter: "deepseek/deepseek-v4-flash"
      }
    },
    "devstral" => %{
      providers: %{
        openrouter: "mistralai/devstral-2512:free"
      }
    },
    "kimi" => %{
      providers: %{
        openrouter: "moonshotai/kimi-k2"
      }
    },
    "gpt" => %{
      providers: %{
        openrouter: "openai/gpt-4.1-mini",
        openai: "gpt-4.1-mini"
      }
    },
    "gpt-nano" => %{
      providers: %{
        openrouter: "openai/gpt-5.4-nano"
      }
    },
    "gpt-oss" => %{
      providers: %{
        groq: "openai/gpt-oss-120b"
      }
    },
    "embed" => %{
      providers: %{
        ollama: "nomic-embed-text"
      }
    },
    "deepseek-local" => %{
      providers: %{
        ollama: "deepseek-coder:6.7b"
      }
    },
    "qwen-local" => %{
      providers: %{
        ollama: "qwen2.5-coder:7b"
      }
    },
    "llama-local" => %{
      providers: %{
        ollama: "llama3.2:3b"
      }
    }
  }

  @default_provider :openrouter

  # Cloud providers that can be used with aliases
  @cloud_providers [:openrouter, :bedrock, :amazon_bedrock, :anthropic, :openai, :google, :groq]

  defp default_provider do
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

  defp unknown_model_error(name) do
    aliases_str = @models |> Map.keys() |> Enum.sort() |> Enum.join(", ")

    """
    Unknown model: '#{name}'

    Available aliases: #{aliases_str}

    Or use provider:alias format:
      - bedrock:haiku
      - openrouter:sonnet

    """
  end

  defp unknown_provider_error(provider) do
    """
    Unknown provider: '#{provider}'

    Available providers: openrouter, bedrock, anthropic, openai, google, groq, ollama
    """
  end
end
