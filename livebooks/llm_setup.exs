# Shared LLM setup for livebooks
# Usage: Code.require_file("llm_setup.exs", __DIR__)

defmodule LLMSetup do
  @moduledoc false

  @doc """
  Three-cell setup flow for livebooks:

      # Cell 1: load llm_setup.exs, then render provider selector
      setup = LLMSetup.setup()

      # Cell 2: read provider, render model selector
      setup = LLMSetup.choose_provider(setup)

      # Cell 3: read model, return LLM callback
      my_llm = LLMSetup.choose_model(setup)
  """
  def setup do
    provider_input()
  end

  def choose_provider(provider_input) do
    provider = Kino.Input.read(provider_input)
    configure_provider(provider)
    model_input(provider)
  end

  def choose_model(model_input) do
    model = Kino.Input.read(model_input)
    create_llm(model)
  end

  def provider_input do
    Kino.Input.select("Provider", [
      {:openrouter, "OpenRouter (needs API key in Secrets)"},
      {:bedrock, "AWS Bedrock (needs `aws sso login`)"}
    ])
  end

  def configure_provider(provider) do
    case provider do
      :openrouter ->
        api_key = System.get_env("LB_OPENROUTER_API_KEY") || System.get_env("OPENROUTER_API_KEY")
        if api_key, do: System.put_env("OPENROUTER_API_KEY", api_key)

        if(api_key,
          do: "✓ OpenRouter API key configured",
          else: "✗ No API key - add OPENROUTER_API_KEY in Secrets (ss)"
        )

      :bedrock ->
        load_aws_credentials()
    end
  end

  def model_input(provider) do
    options = model_options(provider)
    Kino.Input.select("Model", options)
  end

  def model_options(provider) do
    if Code.ensure_loaded?(LLMClient) do
      # Use LLMClient.presets/1 for available models, filter by availability
      LLMClient.presets(provider)
      |> Enum.map(fn {alias, model_id} ->
        info = LLMClient.get_model_info(alias)
        desc = if info, do: info.description, else: alias
        {model_id, "#{alias} - #{desc}"}
      end)
      |> Enum.sort_by(&elem(&1, 1))
    else
      fallback_models(provider)
    end
  end

  def create_llm(model) do
    if Code.ensure_loaded?(LLMClient) do
      LLMClient.callback(model)
    else
      fn
        %{system: system, messages: messages, output: :text, schema: schema} ->
          full_messages = [%{role: :system, content: system} | messages]

          case ReqLLM.generate_object(model, full_messages, schema, receive_timeout: 60_000) do
            {:ok, r} ->
              {:ok,
               %{
                 content: Jason.encode!(ReqLLM.Response.object(r)),
                 tokens: ReqLLM.Response.usage(r)
               }}

            error ->
              error
          end

        %{system: system, messages: messages} ->
          case ReqLLM.generate_text(model, [%{role: :system, content: system} | messages],
                 receive_timeout: 60_000
               ) do
            {:ok, r} ->
              {:ok, %{content: ReqLLM.Response.text(r), tokens: ReqLLM.Response.usage(r)}}

            error ->
              error
          end
      end
    end
  end

  defp load_aws_credentials do
    case System.cmd("aws", [
           "configure",
           "export-credentials",
           "--profile",
           "sandbox",
           "--format",
           "env"
         ]) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.each(fn line ->
          case Regex.run(~r/^export (\w+)=(.+)$/, line) do
            [_, key, value] -> System.put_env(key, value)
            _ -> :ignore
          end
        end)

        "✓ AWS credentials loaded (#{System.get_env("AWS_ACCESS_KEY_ID") |> String.slice(0, 8)}...)"

      {_, _} ->
        "✗ Failed to load AWS credentials. Run `aws sso login --profile sandbox` first."
    end
  end

  # Fallback when LLMClient not available (standalone livebook usage)
  defp fallback_models(:openrouter) do
    [
      {"openrouter:anthropic/claude-haiku-4.5", "haiku - Claude Haiku 4.5"},
      {"openrouter:google/gemini-2.5-flash", "gemini - Gemini 2.5 Flash"},
      {"openrouter:deepseek/deepseek-chat-v3-0324", "deepseek - DeepSeek V3"}
    ]
  end

  defp fallback_models(:bedrock) do
    [
      {"amazon_bedrock:anthropic.claude-haiku-4-5-20251001-v1:0", "haiku - Claude Haiku 4.5"},
      {"amazon_bedrock:anthropic.claude-sonnet-4-20250514-v1:0", "sonnet - Claude Sonnet 4"}
    ]
  end
end
