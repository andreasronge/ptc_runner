defmodule PtcRunner.LLM do
  @moduledoc """
  Provider-neutral LLM adapter boundary used by trusted Kernel provider builders.

  `prepare/2` seals a model selector into an immutable prepared target under a
  closed requirements map. `callback/2` binds that target to a credential and
  cache flag and returns an arity-two requester. Kernel policy, retries, prompt
  construction, and protocol recovery live in shipped Lisp libraries rather than
  this transport adapter.
  """

  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.LLM.Invocation
  alias PtcRunner.LLM.PreparedModel
  alias PtcRunner.LLM.Requirements

  @type message :: %{role: :system | :user | :assistant | :tool, content: String.t()}

  @typedoc """
  Provider-reported token usage. `:total_cost` is absent when pricing is
  unavailable; a present zero-microunit object is a measured zero-cost response.
  Adapter responses may use a non-negative USD number or bounded decimal string;
  the Kernel immediately replaces it with this fixed-point object.
  """
  @type usd_cost :: %{currency: String.t(), microunits: non_neg_integer()}
  @type tokens :: %{
          optional(:input) => non_neg_integer(),
          optional(:output) => non_neg_integer(),
          optional(:cache_creation) => non_neg_integer(),
          optional(:cache_read) => non_neg_integer(),
          optional(:total_cost) => usd_cost() | non_neg_integer() | float() | String.t()
        }

  @type response :: %{
          content: String.t(),
          tokens: tokens()
        }

  @type output_limit_binding ::
          :configured | :adapter_default | :model_output_limit | :remaining_context
  @type output_limit :: %{
          name: :max_tokens,
          value: pos_integer(),
          bindings: [output_limit_binding()]
        }

  @type tool_call_response :: %{
          required(:tool_calls) => [map()],
          required(:content) => String.t() | nil,
          required(:tokens) => tokens(),
          optional(:finish_reason) => atom(),
          optional(:output_limit) => output_limit()
        }

  @type chunk :: %{delta: String.t()} | %{done: true, tokens: tokens()}
  @type catalog_status :: :cataloged | :uncataloged | :unavailable

  @type runtime_binding :: %{
          credential: binary() | nil,
          cache: boolean()
        }

  @type requester_context :: %{llm_request_deadline_ms: integer() | nil}

  @doc """
  Make an LLM call.

  The `request` map contains:
  - `:system` - System prompt string
  - `:messages` - List of message maps
  - `:schema` - JSON Schema map (triggers structured output when the
    sealed installation mode is `json_schema` or `json_object`)
  - `:tools` - Tool definitions (triggers tool calling)
  - `:cache` - Boolean for prompt caching

  Returns `{:ok, response}` or `{:error, reason}`.
  """
  @callback call(model :: term(), invocation :: Invocation.t()) ::
              {:ok, map()} | {:error, ProviderError.t()}

  @doc """
  Prepares an adapter-owned request target and attests the sealed requirements.

  The returned attestation must be exactly the canonical requirements map. An
  adapter that cannot preserve the requested options, mode, reporting
  guarantees, or reservation authority returns `{:error, :unsupported_model_option}`.
  """
  @callback prepare_model(model :: String.t(), requirements :: Requirements.t()) ::
              {:ok, target :: term(), catalog_status(), Requirements.t()} | {:error, term()}

  @callback reservation_bound(
              prepared_target :: term(),
              normalized_request :: map(),
              reservation_tariff :: Requirements.cost_tariff() | nil
            ) :: map()

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
    ensure_ready: 0,
    provider_application: 1,
    public_model: 1,
    reservation_bound: 3
  ]

  @doc false
  @spec reservation_bound(PreparedModel.t(), map(), Requirements.cost_tariff() | nil) ::
          {:ok, map()} | {:error, :reservation_attestation_unavailable}
  def reservation_bound(%PreparedModel{} = prepared, request, tariff)
      when is_map(request) and not is_struct(request) do
    with :ok <- validate_prepared(prepared),
         true <- function_exported?(prepared.adapter, :reservation_bound, 3),
         true <- prepared.requirements.reservation.cost_tariff == tariff do
      {:ok, prepared.adapter.reservation_bound(prepared.target, request, tariff)}
    else
      _unavailable -> {:error, :reservation_attestation_unavailable}
    end
  rescue
    _exception -> {:error, :reservation_attestation_unavailable}
  catch
    _kind, _reason -> {:error, :reservation_attestation_unavailable}
  end

  def reservation_bound(_prepared, _request, _tariff),
    do: {:error, :reservation_attestation_unavailable}

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

  Generated `prepare/2` means `(model, requirements)`. Explicit `prepare/3`
  means `(model, requirements, adapter)`. Preparation runs adapter warmup and
  model resolution once, validates exact requirements/attestation equality, and
  returns a typed error immediately when either operation cannot produce a valid
  prepared value.
  """
  @spec prepare(String.t(), Requirements.t()) :: {:ok, PreparedModel.t()} | {:error, term()}
  @spec prepare(String.t(), Requirements.t(), module()) ::
          {:ok, PreparedModel.t()} | {:error, term()}
  def prepare(model, requirements, adapter \\ adapter!())

  def prepare(model, requirements, adapter)
      when is_binary(model) and is_atom(adapter) do
    with true <- Code.ensure_loaded?(adapter),
         {:ok, canonical} <- Requirements.canonical(requirements) do
      if function_exported?(adapter, :ensure_ready, 0), do: adapter.ensure_ready()

      if function_exported?(adapter, :prepare_model, 2) do
        seal_prepared(adapter, model, canonical, adapter.prepare_model(model, canonical))
      else
        {:error, :invalid_model_preparation}
      end
    else
      :error -> {:error, :invalid_model_preparation}
      false -> {:error, :invalid_model_preparation}
    end
  rescue
    _exception -> {:error, :invalid_model_preparation}
  catch
    _kind, _reason -> {:error, :invalid_model_preparation}
  end

  def prepare(_model, _requirements, _adapter), do: {:error, :invalid_model_preparation}

  @doc """
  Creates a normalized requester for a prepared model.

  The binding is a closed map of `credential` and `cache`. The returned
  requester is arity two: a provider-neutral request plus
  `%{llm_request_deadline_ms: integer() | nil}`. An uncataloged selector emits
  one concise warning while the requester is built.
  """
  @spec callback(PreparedModel.t(), runtime_binding()) ::
          {:ok, (map(), requester_context() -> {:ok, map()} | {:error, ProviderError.t()})}
          | {:error, :invalid_prepared_model | :invalid_llm_binding}
  def callback(%PreparedModel{} = prepared, binding) do
    with :ok <- validate_prepared(prepared),
         {:ok, credential, cache} <- validate_binding(binding),
         :ok <- warn_catalog_status(prepared) do
      {:ok,
       fn request, context ->
         invoke_prepared(prepared, request, credential, cache, context)
       end}
    end
  end

  def callback(_prepared, _binding), do: {:error, :invalid_prepared_model}

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

  defp seal_prepared(adapter, model, canonical, {:ok, target, status, attestation}) do
    case Requirements.canonical(attestation) do
      {:ok, attested} ->
        if Requirements.equal?(canonical, attested) do
          PreparedModel.new(adapter, model, target, status, canonical, attested)
        else
          {:error, :unsupported_model_option}
        end

      :error ->
        {:error, :unsupported_model_option}
    end
  end

  defp seal_prepared(_adapter, _model, _canonical, {:error, :unsupported_model_option}),
    do: {:error, :unsupported_model_option}

  defp seal_prepared(_adapter, _model, _canonical, {:error, _reason} = error), do: error

  defp seal_prepared(_adapter, _model, _canonical, _invalid),
    do: {:error, :invalid_model_preparation}

  defp validate_prepared(prepared) do
    if PreparedModel.valid?(prepared), do: :ok, else: {:error, :invalid_prepared_model}
  end

  defp validate_binding(%{credential: credential, cache: cache} = binding)
       when map_size(binding) == 2 and is_boolean(cache) do
    cond do
      is_nil(credential) ->
        {:ok, credential, cache}

      is_binary(credential) and byte_size(credential) in 1..65_536 ->
        {:ok, credential, cache}

      true ->
        {:error, :invalid_llm_binding}
    end
  end

  defp validate_binding(_binding), do: {:error, :invalid_llm_binding}

  defp invoke_prepared(prepared, request, credential, cache, context) do
    with :ok <- validate_prepared(prepared),
         {:ok, deadline_ms} <- requester_deadline(context),
         {:ok, invocation} <- Invocation.new(request, cache, credential, deadline_ms) do
      prepared.adapter.call(prepared.target, invocation)
    else
      {:error, :invalid_prepared_model} = error -> error
      {:error, :invalid_llm_binding} = error -> error
      :error -> {:error, :invalid_llm_binding}
    end
  end

  defp requester_deadline(%{llm_request_deadline_ms: deadline_ms} = context)
       when map_size(context) == 1 and (is_integer(deadline_ms) or is_nil(deadline_ms)),
       do: {:ok, deadline_ms}

  defp requester_deadline(_context), do: :error

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

  defp raise_no_adapter do
    raise """
    No LLM adapter configured.

    Either:
    1. Add {:req_llm, "~> 1.8"} to your deps for the built-in adapter
    2. Set config :ptc_runner, :llm_adapter, YourAdapter
    """
  end
end
