defmodule PtcRunner.LLM do
  @moduledoc """
  Provider-neutral LLM adapter boundary used by trusted Kernel provider builders.

  `callback/2` resolves a configured model and returns a one-argument provider
  callback. Kernel policy, retries, prompt construction, and protocol recovery
  live in shipped Lisp libraries rather than this transport adapter.
  """

  @type message :: %{role: :system | :user | :assistant | :tool, content: String.t()}

  @type tokens :: %{
          optional(:input) => non_neg_integer(),
          optional(:output) => non_neg_integer(),
          optional(:cache_creation) => non_neg_integer(),
          optional(:cache_read) => non_neg_integer(),
          optional(:total_cost) => float()
        }

  @type response :: %{
          content: String.t(),
          tokens: tokens()
        }

  @type tool_call_response :: %{
          tool_calls: [map()],
          content: String.t() | nil,
          tokens: tokens()
        }

  @type chunk :: %{delta: String.t()} | %{done: true, tokens: tokens()}

  @doc """
  Make an LLM call.

  The `request` map contains:
  - `:system` - System prompt string
  - `:messages` - List of message maps
  - `:schema` - JSON Schema map (triggers structured output)
  - `:tools` - Tool definitions (triggers tool calling)
  - `:cache` - Boolean for prompt caching

  Returns `{:ok, response}` or `{:error, reason}`.
  """
  @callback call(model :: String.t(), request :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  Stream an LLM response.

  Returns `{:ok, stream}` where stream is an `Enumerable` of chunk maps:
  - `%{delta: "text"}` for content chunks
  - `%{done: true, tokens: %{...}}` for the final chunk
  """
  @callback stream(model :: String.t(), request :: map()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @optional_callbacks [stream: 2]

  @doc """
  Creates a normalized callback for a configured model.

  Model aliases are resolved through `PtcRunner.LLM.Registry`. The optional
  `:adapter` setting selects a transport explicitly; other options are merged
  into every request.
  """
  @spec callback(String.t(), keyword()) :: (map() -> {:ok, map()} | {:error, term()})
  def callback(model, opts \\ []) do
    {adapter_override, opts} = Keyword.pop(opts, :adapter)
    adapter = adapter_override || adapter!()
    model = PtcRunner.LLM.Registry.resolve!(model)
    merged_opts = Map.new(opts)

    fn req ->
      {stream_fn, clean_req} = Map.pop(req, :stream)
      final_req = if merged_opts == %{}, do: clean_req, else: Map.merge(clean_req, merged_opts)

      if stream_fn && function_exported?(adapter, :stream, 2) do
        case adapter.stream(model, final_req) do
          {:ok, stream} -> consume_stream(stream, stream_fn)
          {:error, :streaming_not_supported} -> adapter.call(model, final_req)
          error -> error
        end
      else
        adapter.call(model, final_req)
      end
    end
  end

  @doc false
  def consume_stream(stream, on_chunk) do
    {content, tokens} =
      Enum.reduce(stream, {"", nil}, fn
        %{delta: text}, {acc, tok} ->
          on_chunk.(%{delta: text})
          {acc <> text, tok}

        %{done: true, tokens: tokens}, {acc, _tok} ->
          {acc, tokens}

        _other, acc ->
          acc
      end)

    {:ok, %{content: content, tokens: tokens || %{}}}
  rescue
    e -> {:error, {:stream_error, e}}
  end

  @doc """
  Make a direct LLM call using the configured adapter.

  ## Examples

      {:ok, response} = PtcRunner.LLM.call("amazon_bedrock:anthropic.claude-haiku-4-5-20251001-v1:0", %{
        system: "You are helpful.",
        messages: [%{role: :user, content: "Hello"}]
      })
  """
  @spec call(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(model, request) do
    adapter!().call(model, request)
  end

  @doc """
  Stream an LLM response using the configured adapter.

  Returns `{:ok, stream}` where stream emits `%{delta: text}` and `%{done: true, tokens: map()}`.

  ## Examples

      {:ok, stream} = PtcRunner.LLM.stream("openrouter:anthropic/claude-haiku-4.5", %{
        system: "You are helpful.",
        messages: [%{role: :user, content: "Tell me a story"}]
      })
      stream |> Stream.each(fn
        %{delta: text} -> IO.write(text)
        %{done: true} -> IO.puts("")
      end) |> Stream.run()
  """
  @spec stream(String.t(), map()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(model, request) do
    adapter = adapter!()

    if function_exported?(adapter, :stream, 2) do
      adapter.stream(model, request)
    else
      {:error, :streaming_not_supported}
    end
  end

  @doc """
  Returns the configured LLM adapter module.

  Resolution order:
  1. `config :ptc_runner, :llm_adapter, MyAdapter`
  2. `PtcRunner.LLM.ReqLLMAdapter` if `req_llm` is available
  3. Raises if no adapter found
  """
  @spec adapter!() :: module()
  def adapter! do
    case Application.get_env(:ptc_runner, :llm_adapter) do
      nil ->
        raise_no_adapter()

      mod ->
        if Code.ensure_loaded?(mod),
          do: mod,
          else:
            raise(
              "LLM adapter #{inspect(mod)} could not be loaded. " <>
                "If you intended to use the built-in adapter, add {:req_llm, \"~> 1.8\"} to your deps; " <>
                "otherwise verify that #{inspect(mod)} exists and is compiled, or set config :ptc_runner, :llm_adapter to a valid module."
            )
    end
  end

  defp raise_no_adapter do
    raise """
    No LLM adapter configured.

    Either:
    1. Add {:req_llm, "~> 1.8"} to your deps for the built-in adapter
    2. Set config :ptc_runner, :llm_adapter, YourAdapter
    """
  end
end
