defmodule LLMClient.FallbackAdapter do
  @moduledoc false
  # Standalone fallback when PtcRunner.LLM.ReqLLMAdapter is not available.
  # Used only when llm_client is compiled independently (e.g., `cd llm_client && mix test`).
  # The canonical implementation lives in PtcRunner.LLM.ReqLLMAdapter.

  require Logger

  @default_timeout 120_000
  @ollama_base_url "http://localhost:11434"

  def call(model, %{schema: schema} = req) when is_map(schema) do
    messages = build_messages(req)

    case generate_object(model, messages, schema, cache: req[:cache] || false) do
      {:ok, %{object: object, tokens: tokens}} ->
        {:ok, %{content: Jason.encode!(object), tokens: tokens}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def call(model, %{tools: tools} = req) when is_list(tools) and tools != [] do
    messages = build_messages(req)
    generate_with_tools(model, messages, tools, cache: req[:cache] || false)
  end

  def call(model, req) do
    messages = build_messages(req)
    generate_text(model, messages, cache: req[:cache] || false)
  end

  def generate_text(model, messages, opts \\ []) do
    case parse_provider(model) do
      {:ollama, model_name} ->
        call_ollama(model_name, messages, opts)

      {:openai_compat, base_url, model_name} ->
        call_openai_compat(base_url, model_name, messages, opts)

      {:req_llm, model_id} ->
        call_req_llm(model_id, messages, opts)
    end
  end

  def generate_text!(model, messages, opts \\ []) do
    case generate_text(model, messages, opts) do
      {:ok, response} -> response
      {:error, reason} -> raise "LLM error: #{inspect(reason)}"
    end
  end

  def generate_object(model, messages, schema, opts \\ []) do
    case parse_provider(model) do
      {:ollama, _} -> {:error, :structured_output_not_supported}
      {:openai_compat, _, _} -> {:error, :structured_output_not_supported}
      {:req_llm, model_id} -> call_req_llm_object(model_id, messages, schema, opts)
    end
  end

  def generate_object!(model, messages, schema, opts \\ []) do
    case generate_object(model, messages, schema, opts) do
      {:ok, response} -> response
      {:error, reason} -> raise "LLM structured output error: #{inspect(reason)}"
    end
  end

  def generate_with_tools(model, messages, tools, opts \\ []) do
    case parse_provider(model) do
      {:ollama, _} -> {:error, :tool_calling_not_supported}
      {:openai_compat, _, _} -> {:error, :tool_calling_not_supported}
      {:req_llm, model_id} -> call_req_llm_with_tools(model_id, messages, tools, opts)
    end
  end

  def embed(model, input, opts \\ []) do
    case parse_provider(model) do
      {:ollama, model_name} ->
        call_ollama_embed(model_name, input, opts)

      {:openai_compat, base_url, model_name} ->
        call_openai_compat_embed(base_url, model_name, input, opts)

      {:req_llm, model_id} ->
        ReqLLM.Embedding.embed(model_id, input, opts)
    end
  end

  def embed!(model, input, opts \\ []) do
    case embed(model, input, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise "Embedding error: #{inspect(reason)}"
    end
  end

  def available?(model) do
    case parse_provider(model) do
      {:ollama, _} -> check_ollama_available()
      {:openai_compat, base_url, _} -> check_openai_compat_available(base_url)
      {:req_llm, model_id} -> check_req_llm_available(model_id)
    end
  end

  def requires_api_key?(model) do
    case parse_provider(model) do
      {:ollama, _} -> false
      {:openai_compat, _, _} -> false
      {:req_llm, _} -> true
    end
  end

  # --- Private ---

  defp build_messages(req) do
    system_msgs =
      if sys = req[:system], do: [%{role: :system, content: sys}], else: []

    user_msgs =
      Enum.map(req.messages, fn
        %{role: :tool} = msg ->
          %ReqLLM.Message{
            role: :tool,
            content: [ReqLLM.Message.ContentPart.text(msg.content)],
            tool_call_id: msg[:tool_call_id]
          }

        %{role: role, content: content, tool_calls: tool_calls} when is_list(tool_calls) ->
          req_llm_tool_calls =
            Enum.map(tool_calls, fn tc ->
              %ReqLLM.ToolCall{
                id: tc[:id] || tc["id"],
                type: "function",
                function: tc[:function] || tc["function"]
              }
            end)

          %ReqLLM.Message{
            role: role,
            content: if(content, do: [ReqLLM.Message.ContentPart.text(content)], else: []),
            tool_calls: req_llm_tool_calls
          }

        %{role: role, content: content} when is_binary(content) ->
          %{role: role, content: content}

        msg ->
          msg
      end)

    system_msgs ++ user_msgs
  end

  defp parse_provider("ollama:" <> model_name), do: {:ollama, model_name}

  defp parse_provider("openai-compat:" <> rest) do
    case String.split(rest, "|", parts: 2) do
      [base_url, model] -> {:openai_compat, base_url, model}
      [base_url] -> {:openai_compat, base_url, "default"}
    end
  end

  defp parse_provider(model), do: {:req_llm, model}

  defp call_ollama(model, messages, opts) do
    base_url = Keyword.get(opts, :ollama_base_url, @ollama_base_url)
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)
    prompt = format_messages_as_prompt(messages)

    Logger.debug("Calling Ollama: #{model}")

    case Req.post("#{base_url}/api/generate",
           json: %{model: model, prompt: prompt, stream: false},
           receive_timeout: timeout
         ) do
      {:ok, %{status: 200, body: %{"response" => text} = body}} ->
        tokens = %{
          input: body["prompt_eval_count"] || 0,
          output: body["eval_count"] || 0,
          cache_creation: 0,
          cache_read: 0
        }

        {:ok, %{content: text, tokens: tokens}}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, %{reason: :econnrefused}} ->
        {:error, "Ollama not running at #{base_url}. Start with: ollama serve"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_openai_compat(base_url, model, messages, opts) do
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)

    formatted_messages =
      Enum.map(messages, fn msg ->
        %{"role" => to_string(msg.role), "content" => msg.content}
      end)

    Logger.debug("Calling OpenAI-compatible API: #{base_url} with #{model}")

    case Req.post("#{base_url}/chat/completions",
           json: %{model: model, messages: formatted_messages},
           receive_timeout: timeout
         ) do
      {:ok, %{status: 200, body: body}} ->
        text = get_in(body, ["choices", Access.at(0), "message", "content"]) || ""
        usage = body["usage"] || %{}

        tokens = %{
          input: usage["prompt_tokens"] || 0,
          output: usage["completion_tokens"] || 0,
          cache_creation: 0,
          cache_read: 0
        }

        {:ok, %{content: text, tokens: tokens}}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_req_llm(model, messages, opts) do
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)
    http_opts = Keyword.get(opts, :req_http_options, [])
    req_opts = [receive_timeout: timeout, req_http_options: http_opts]

    case ReqLLM.generate_text(model, messages, req_opts) do
      {:ok, response} ->
        text = ReqLLM.Response.text(response) || ""
        usage = ReqLLM.Response.usage(response) || %{}

        tokens = %{
          input: usage[:input_tokens] || 0,
          output: usage[:output_tokens] || 0,
          cache_creation: 0,
          cache_read: 0
        }

        {:ok, %{content: text, tokens: tokens}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_req_llm_object(model, messages, schema, opts) do
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)
    http_opts = Keyword.get(opts, :req_http_options, [])
    req_opts = [receive_timeout: timeout, req_http_options: http_opts]

    case ReqLLM.generate_object(model, messages, schema, req_opts) do
      {:ok, response} ->
        usage = ReqLLM.Response.usage(response) || %{}

        tokens = %{
          input: usage[:input_tokens] || 0,
          output: usage[:output_tokens] || 0,
          cache_creation: 0,
          cache_read: 0
        }

        {:ok, %{object: response.object, tokens: tokens}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_req_llm_with_tools(model, messages, tools, opts) do
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)
    http_opts = Keyword.get(opts, :req_http_options, [])

    req_llm_tools =
      Enum.map(tools, fn %{"type" => "function", "function" => func} ->
        {:ok, tool} =
          ReqLLM.Tool.new(
            name: func["name"],
            description: func["description"] || "",
            parameter_schema: func["parameters"],
            callback: fn _args -> nil end
          )

        tool
      end)

    req_opts = [receive_timeout: timeout, req_http_options: http_opts, tools: req_llm_tools]

    case ReqLLM.generate_text(model, messages, req_opts) do
      {:ok, response} ->
        text = ReqLLM.Response.text(response)
        usage = ReqLLM.Response.usage(response) || %{}

        tokens = %{
          input: usage[:input_tokens] || 0,
          output: usage[:output_tokens] || 0,
          cache_creation: 0,
          cache_read: 0
        }

        raw_tool_calls = ReqLLM.Response.tool_calls(response)

        if raw_tool_calls != [] do
          normalized_tc =
            Enum.map(raw_tool_calls, fn tc ->
              {args, args_error} =
                case Jason.decode(tc.function.arguments || "{}") do
                  {:ok, parsed} -> {parsed, nil}
                  {:error, _} -> {%{}, "Invalid JSON arguments: #{tc.function.arguments}"}
                end

              entry = %{id: tc.id, name: tc.function.name, args: args}
              if args_error, do: Map.put(entry, :args_error, args_error), else: entry
            end)

          {:ok, %{tool_calls: normalized_tc, content: text, tokens: tokens}}
        else
          {:ok, %{content: text || "", tokens: tokens}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_ollama_embed(model, input, opts) do
    base_url = Keyword.get(opts, :ollama_base_url, @ollama_base_url)
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)

    case Req.post("#{base_url}/api/embed",
           json: %{model: model, input: input},
           receive_timeout: timeout
         ) do
      {:ok, %{status: 200, body: %{"embeddings" => [embedding]}}} when is_binary(input) ->
        {:ok, embedding}

      {:ok, %{status: 200, body: %{"embeddings" => embeddings}}} ->
        {:ok, embeddings}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, %{reason: :econnrefused}} ->
        {:error, "Ollama not running at #{base_url}. Start with: ollama serve"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_openai_compat_embed(base_url, model, input, opts) do
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)

    case Req.post("#{base_url}/embeddings",
           json: %{model: model, input: input},
           receive_timeout: timeout
         ) do
      {:ok, %{status: 200, body: %{"data" => [%{"embedding" => embedding}]}}}
      when is_binary(input) ->
        {:ok, embedding}

      {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
        embeddings = data |> Enum.sort_by(& &1["index"]) |> Enum.map(& &1["embedding"])
        {:ok, embeddings}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_messages_as_prompt(messages) do
    messages
    |> Enum.map(fn
      %{role: :system, content: content} -> "System: #{content}"
      %{role: :user, content: content} -> "User: #{content}"
      %{role: :assistant, content: content} -> "Assistant: #{content}"
    end)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n\nAssistant:")
  end

  defp check_ollama_available do
    case Req.get("#{@ollama_base_url}/api/tags", receive_timeout: 2_000) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  defp check_openai_compat_available(base_url) do
    case Req.get("#{base_url}/models", receive_timeout: 2_000) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  defp check_req_llm_available(model) do
    cond do
      String.starts_with?(model, "openrouter:") ->
        System.get_env("OPENROUTER_API_KEY") != nil

      String.starts_with?(model, "anthropic:") ->
        System.get_env("ANTHROPIC_API_KEY") != nil

      String.starts_with?(model, "openai:") ->
        System.get_env("OPENAI_API_KEY") != nil

      String.starts_with?(model, "google:") ->
        System.get_env("GOOGLE_API_KEY") != nil

      String.starts_with?(model, "groq:") ->
        System.get_env("GROQ_API_KEY") != nil

      String.starts_with?(model, "bedrock:") or String.starts_with?(model, "amazon_bedrock:") ->
        System.get_env("AWS_ACCESS_KEY_ID") != nil or System.get_env("AWS_SESSION_TOKEN") != nil

      true ->
        true
    end
  end
end
