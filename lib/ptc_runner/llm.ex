defmodule PtcRunner.LLM do
  @moduledoc """
  Provider-neutral LLM adapter boundary used by trusted Kernel provider builders.

  `callback/2` binds a configured full model identifier into a one-argument
  provider callback. Kernel policy, retries, prompt construction, and protocol
  recovery live in shipped Lisp libraries rather than this transport adapter.
  """

  @type message :: %{role: :system | :user | :assistant | :tool, content: String.t()}

  @typedoc """
  Provider-reported token usage. `:total_cost` is absent when pricing is
  unavailable; a present zero is a measured zero-cost response.
  """
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
  @type catalog_status :: :cataloged | :uncataloged | :unavailable

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
  @callback call(model :: term(), request :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  Stream an LLM response.

  Returns `{:ok, stream}` where stream is an `Enumerable` of chunk maps:
  - `%{delta: "text"}` for content chunks
  - `%{done: true, tokens: %{...}}` for the final chunk
  """
  @callback stream(model :: term(), request :: map()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc """
  Prepares an adapter-owned request target and reports its catalog status.

  Optional. Adapters without an external model catalog may omit this callback;
  PtcRunner then passes the original selector to requests and records the status
  as `:unavailable`.
  """
  @callback prepare_model(model :: String.t()) ::
              {:ok, target :: term(), catalog_status()} | {:error, term()}

  @doc """
  Preload adapter-owned model metadata into a shared, process-independent store
  (e.g. a `:persistent_term`/ETS catalog) so the first per-request provider
  worker does not pay a large one-time load inside its bounded heap.

  Optional. Invoked during selected provider-application admission and again at
  capability-build time for direct embedding paths; implementations must be
  idempotent.
  """
  @callback ensure_ready() :: :ok

  @doc """
  Names the OTP application this adapter needs running to serve `model`.

  Optional. An adapter backed by a dependency the core does not start returns
  that application's name so a host can report an unstarted provider
  application as a host misconfiguration rather than as a retryable transport
  failure. The answer is per model, because one adapter may route some models
  through a dependency and others straight over HTTP. Adapters with no such
  dependency omit the callback or return `nil`.

  Constrained to `:req_llm` because that is the only backing application the
  installation catalog validates and the CLI's ownership selection understands.
  Admitting arbitrary applications means widening those two consumers as well,
  which is a deliberate change rather than a side effect of this callback.
  """
  @callback provider_application(model :: String.t()) :: :req_llm | nil

  @doc """
  Attests that the exact adapter target is safe to publish in canonical traces.

  Optional. Return `{:ok, model}` only when the complete value is public model
  identity. Return `:private` for local, endpoint-bearing, deployment-private,
  or otherwise sensitive targets. PtcRunner rejects altered, malformed, or
  oversized values and treats a missing or raising callback as private.
  """
  @callback public_model(model :: String.t()) :: {:ok, String.t()} | :private

  @optional_callbacks [
    stream: 2,
    prepare_model: 1,
    ensure_ready: 0,
    provider_application: 1,
    public_model: 1
  ]

  alias PtcRunner.LLM.PreparedModel

  @doc false
  @spec attested_public_model(module(), String.t()) :: String.t() | nil
  def attested_public_model(adapter, model) when is_atom(adapter) and is_binary(model) do
    if function_exported?(adapter, :public_model, 1) do
      case adapter.public_model(model) do
        {:ok, ^model}
        when byte_size(model) in 1..256 ->
          if String.valid?(model), do: model

        _private_or_invalid ->
          nil
      end
    end
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  def attested_public_model(_adapter, _model), do: nil

  @doc """
  Resolves a configured selector into an immutable adapter-owned request target.

  Preparation runs adapter warmup and model resolution once. It returns a typed
  error immediately when either operation cannot produce a valid prepared value.
  """
  @spec prepare(String.t(), module()) :: {:ok, PreparedModel.t()} | {:error, term()}
  def prepare(model, adapter \\ adapter!())

  def prepare(model, adapter) when is_binary(model) and is_atom(adapter) do
    if Code.ensure_loaded?(adapter) do
      if function_exported?(adapter, :ensure_ready, 0), do: adapter.ensure_ready()

      result =
        if function_exported?(adapter, :prepare_model, 1),
          do: adapter.prepare_model(model),
          else: {:ok, model, :unavailable}

      case result do
        {:ok, target, status} -> PreparedModel.new(adapter, model, target, status)
        {:error, _reason} = error -> error
        _invalid -> {:error, :invalid_model_preparation}
      end
    else
      {:error, :invalid_model_preparation}
    end
  rescue
    _exception -> {:error, :invalid_model_preparation}
  catch
    _kind, _reason -> {:error, :invalid_model_preparation}
  end

  def prepare(_model, _adapter), do: {:error, :invalid_model_preparation}

  @doc """
  Creates a normalized requester for a configured or prepared model.

  A selector is prepared once while this function constructs the requester. A
  prepared value is bound directly. The optional `:adapter` setting selects a
  transport explicitly; other options are merged into every request.

  Returns `{:ok, requester}` or an error before any request can run. An
  uncataloged selector emits one concise warning while the requester is built.
  """
  @spec callback(String.t() | PreparedModel.t(), keyword()) ::
          {:ok, (map() -> {:ok, map()} | {:error, term()})} | {:error, term()}
  def callback(model, opts \\ []) do
    {adapter_override, opts} = Keyword.pop(opts, :adapter)

    with {:ok, prepared} <- prepared_model(model, adapter_override),
         :ok <- warn_catalog_status(prepared) do
      merged_opts = Map.new(opts)

      {:ok,
       fn req ->
         {stream_fn, clean_req} = Map.pop(req, :stream)
         final_req = if merged_opts == %{}, do: clean_req, else: Map.merge(clean_req, merged_opts)

         if stream_fn && not tool_request?(final_req) &&
              function_exported?(prepared.adapter, :stream, 2) do
           case prepared.adapter.stream(prepared.target, final_req) do
             {:ok, stream} ->
               consume_stream(stream, stream_fn)

             {:error, :streaming_not_supported} ->
               prepared.adapter.call(prepared.target, final_req)

             error ->
               error
           end
         else
           prepared.adapter.call(prepared.target, final_req)
         end
       end}
    end
  end

  defp prepared_model(%PreparedModel{} = prepared, nil) do
    if PreparedModel.valid?(prepared),
      do: {:ok, prepared},
      else: {:error, :invalid_prepared_model}
  end

  defp prepared_model(%PreparedModel{adapter: adapter} = prepared, adapter) do
    if PreparedModel.valid?(prepared),
      do: {:ok, prepared},
      else: {:error, :invalid_prepared_model}
  end

  defp prepared_model(%PreparedModel{}, _different_adapter),
    do: {:error, :invalid_prepared_model}

  defp prepared_model(model, adapter_override) when is_binary(model),
    do: prepare(model, adapter_override || adapter!())

  defp prepared_model(_model, _adapter), do: {:error, :invalid_prepared_model}

  defp warn_catalog_status(%PreparedModel{catalog_status: :uncataloged} = prepared) do
    public_model = attested_public_model(prepared.adapter, prepared.selector)
    identity = if public_model, do: " #{inspect(public_model)}", else: ""

    IO.warn(
      "model_uncataloged: configured model#{identity} is not an exact catalog entry; " <>
        "pricing, limits, token estimation, and capability detection may be incomplete",
      []
    )
  end

  defp warn_catalog_status(%PreparedModel{}), do: :ok

  defp tool_request?(%{tools: tools}) when is_list(tools), do: tools != []
  defp tool_request?(_request), do: false

  defp consume_stream(stream, on_chunk) do
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
    with {:ok, requester} <- callback(model), do: requester.(request)
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
