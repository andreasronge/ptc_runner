defmodule PtcRunner.TestSupport.ReqLLMGeneration do
  @moduledoc false

  alias PtcRunner.LLM.ReqLLMAdapter
  alias PtcRunner.LLM.ReqLLMPreparedModel

  def generate_text(target, messages, opts \\ []),
    do: ReqLLMAdapter.generate_text(target(target, opts), messages, opts)

  def generate_object(target, messages, schema, opts \\ []),
    do: ReqLLMAdapter.generate_object(target(target, opts), messages, schema, opts)

  def generate_with_tools(target, messages, tools, opts \\ []),
    do: ReqLLMAdapter.generate_with_tools(target(target, opts), messages, tools, opts)

  defp target(%ReqLLMPreparedModel{} = target, _opts), do: target

  # These request-shape tests deliberately exercise unsealed options. Production
  # callers prepare and attest targets before invoking the adapter callback.
  defp target(selector, opts) do
    model =
      if String.starts_with?(selector, ["ollama:", "openai-compat:"]) do
        nil
      else
        case ReqLLM.model(selector) do
          {:ok, model} ->
            model

          {:error, _} ->
            [provider, id] = String.split(selector, ":", parts: 2)
            {:ok, model} = ReqLLM.model(%{provider: String.to_existing_atom(provider), id: id})
            model
        end
      end

    exact_options =
      Map.new(Keyword.take(opts, [:max_tokens, :max_completion_tokens, :max_output_tokens]))

    exact_options =
      case Keyword.get_values(opts, :provider_options) do
        [provider_options] -> Map.put(exact_options, :provider_options, provider_options)
        _missing_or_duplicate -> exact_options
      end

    %ReqLLMPreparedModel{selector: selector, exact_options: exact_options, model: model}
  end
end
