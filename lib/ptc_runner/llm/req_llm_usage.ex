if Code.ensure_loaded?(ReqLLM) do
  defmodule PtcRunner.LLM.ReqLLMUsage do
    @moduledoc false

    @usage_observation_key :ptc_runner_usage_observation
    @reported_total_cost_key :ptc_runner_reported_total_cost
    @raw_input_usage_keys [
      :input,
      "input",
      :prompt_tokens,
      "prompt_tokens",
      :input_tokens,
      "input_tokens"
    ]
    @raw_output_usage_keys [
      :output,
      "output",
      :completion_tokens,
      "completion_tokens",
      :output_tokens,
      "output_tokens"
    ]
    # ReqLLM's OpenAI decoder turns absent or partial usage into zero counts.
    # Capture provider-specific raw usage before that decoder runs, then attach
    # only the closed observation marker to the final response. A request step
    # registers the projection step after the provider has assembled its own
    # response pipeline, while the capture step remains before that pipeline.
    def observed_usage_http_options(opts, model) do
      plugin = usage_observation_plugin(model)

      opts
      |> Keyword.get(:req_http_options, [])
      |> Keyword.update(:plugins, [plugin], fn plugins -> [plugin | List.wrap(plugins)] end)
    end

    defp usage_observation_plugin(model) do
      fn request ->
        request
        |> Req.Request.append_response_steps(
          ptc_runner_capture_usage: fn request_response ->
            capture_raw_usage(request_response, model)
          end
        )
        |> Req.Request.append_request_steps(
          ptc_runner_register_usage_projection: &register_usage_projection/1
        )
      end
    end

    defp capture_raw_usage({request, response}, model) do
      {observation, total_cost} = raw_usage_observation(response.body, model)

      private =
        response.private
        |> Map.put(@usage_observation_key, observation)
        |> maybe_put_reported_total_cost(total_cost)

      {request, %{response | private: private}}
    end

    defp register_usage_projection(request) do
      Req.Request.append_response_steps(
        request,
        ptc_runner_project_usage: &project_usage_observation/1
      )
    end

    defp project_usage_observation({request, %{body: %ReqLLM.Response{} = body} = response}) do
      observation = Map.get(response.private, @usage_observation_key, :missing)

      provider_meta =
        body.provider_meta
        |> Map.put(@usage_observation_key, observation)
        |> maybe_put_reported_total_cost(Map.get(response.private, @reported_total_cost_key))

      {request, %{response | body: %{body | provider_meta: provider_meta}}}
    end

    defp project_usage_observation(request_response), do: request_response

    defp raw_usage_observation(body, model) do
      with {:ok, provider} <- ReqLLM.provider(model.provider),
           true <- function_exported?(provider, :extract_usage, 2),
           {:ok, usage} when is_map(usage) <- provider.extract_usage(body, model) do
        observation = if raw_token_pair?(usage), do: :reported, else: :missing
        {observation, provider_reported_total_cost(model.provider, usage)}
      else
        _missing_or_invalid -> {:missing, nil}
      end
    rescue
      _exception -> {:missing, nil}
    catch
      _kind, _reason -> {:missing, nil}
    end

    # OpenRouter's chat-completions response reports the charged USD amount as
    # `usage.cost`. ReqLLM's normalized response currently preserves only a
    # field already named `total_cost`, so retain this bounded provider fact
    # before decoding and project it under PtcRunner's canonical name.
    defp provider_reported_total_cost(:openrouter, usage) do
      case fetch_usage(usage, :cost, "cost") do
        {:ok, cost} when is_integer(cost) or is_float(cost) -> cost
        {:ok, cost} when is_binary(cost) and byte_size(cost) <= 64 -> cost
        _missing_or_invalid -> nil
      end
    end

    defp provider_reported_total_cost(_provider, _usage), do: nil

    defp maybe_put_reported_total_cost(map, nil), do: map

    defp maybe_put_reported_total_cost(map, total_cost),
      do: Map.put(map, @reported_total_cost_key, total_cost)

    defp raw_token_pair?(usage) do
      Enum.any?(@raw_input_usage_keys, &Map.has_key?(usage, &1)) and
        Enum.any?(@raw_output_usage_keys, &Map.has_key?(usage, &1))
    end

    def extract_ollama_tokens(body) do
      %{}
      |> maybe_put_usage_field(:input, body, "prompt_eval_count")
      |> maybe_put_usage_field(:output, body, "eval_count")
    end

    def maybe_put_usage_field(tokens, target_key, source, source_key) do
      case Map.fetch(source, source_key) do
        {:ok, value} -> Map.put(tokens, target_key, value)
        :error -> tokens
      end
    end

    def add_cache_fields(tokens) do
      Map.merge(tokens, %{cache_creation: 0, cache_read: 0})
    end

    @doc false
    def build_tokens_from_req_llm_response(usage, provider_meta) do
      cache_write_from_meta = extract_cache_write_tokens(provider_meta)

      cache_read =
        usage[:cache_read_input_tokens] || usage[:cached_tokens] ||
          usage["cache_read_input_tokens"] || usage["cached_tokens"] || 0

      cache_creation =
        usage[:cache_creation_input_tokens] || usage[:cache_creation_tokens] ||
          usage["cache_creation_input_tokens"] || usage["cache_creation_tokens"] ||
          cache_write_from_meta

      %{
        cache_creation: cache_creation,
        cache_read: cache_read
      }
      |> maybe_put_observed_token_usage(usage, provider_meta)
      |> maybe_put_total_cost(usage, provider_meta)
    end

    defp maybe_put_observed_token_usage(tokens, usage, provider_meta) do
      if observed_token_usage?(provider_meta) do
        tokens
        |> maybe_put_req_llm_usage(:input, usage, :input_tokens, "input_tokens")
        |> maybe_put_req_llm_usage(:output, usage, :output_tokens, "output_tokens")
      else
        tokens
      end
    end

    defp observed_token_usage?(provider_meta) do
      Map.get(provider_meta, @usage_observation_key) == :reported or
        Map.get(provider_meta, :response_cache_hit) == true or
        Map.get(provider_meta, "response_cache_hit") == true
    end

    defp maybe_put_total_cost(tokens, usage, provider_meta) do
      case Map.fetch(provider_meta, @reported_total_cost_key) do
        {:ok, total_cost} ->
          Map.put(tokens, :total_cost, total_cost)

        :error ->
          case fetch_usage(usage, :total_cost, "total_cost") do
            {:ok, total_cost} -> Map.put(tokens, :total_cost, total_cost)
            :error -> tokens
          end
      end
    end

    defp maybe_put_req_llm_usage(tokens, target_key, usage, atom_key, string_key) do
      case fetch_usage(usage, atom_key, string_key) do
        {:ok, value} -> Map.put(tokens, target_key, value)
        :error -> tokens
      end
    end

    defp fetch_usage(usage, atom_key, string_key) do
      case Map.fetch(usage, atom_key) do
        {:ok, value} -> {:ok, value}
        :error -> Map.fetch(usage, string_key)
      end
    end

    defp extract_cache_write_tokens(%{} = meta) do
      get_in(meta, ["usage", "prompt_tokens_details", "cache_write_tokens"]) ||
        get_in(meta, [:usage, :prompt_tokens_details, :cache_write_tokens]) ||
        get_in(meta, ["prompt_tokens_details", "cache_write_tokens"]) ||
        0
    end
  end
end
