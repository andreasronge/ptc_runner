defmodule PtcViewer.ReplAdapter do
  @moduledoc """
  Transport-neutral contract for one server-owned Viewer REPL profile.

  Implementations own their backend resources and return only bounded public
  projections. The Viewer treats backend and session values as opaque and
  never places them in HTTP responses or process diagnostics.
  """

  @type backend :: term()
  @type session :: term()
  @type operation_kind :: :start | :evaluation | :close

  @callback connect(map()) :: {:ok, backend(), map()} | {:error, atom()}
  @callback prepare_operation(backend(), session() | nil, operation_kind(), binary()) ::
              :ok | {:error, atom()}
  @callback start(backend(), binary(), binary()) ::
              {:ok, session(), map()} | {:error, atom()}
  @callback reconcile_start(backend(), binary()) ::
              {:ok, session(), map()} | {:error, atom()}
  @callback evaluate(backend(), session(), binary(), binary()) ::
              {:ok, map()} | {:error, atom()}
  @callback reconcile_evaluate(backend(), session(), binary()) ::
              {:ok, map()} | {:error, atom()}
  @callback template(backend(), session(), :run | :turns, binary()) ::
              {:ok, %{source: binary()}} | {:error, atom()}
  @callback info(backend(), session()) :: {:ok, map()} | {:error, atom()}
  @callback close(backend(), session(), binary()) :: {:ok, map()} | {:error, atom()}
  @callback reconcile_close(backend(), session(), binary()) ::
              {:ok, map()} | {:error, atom()}
  @callback acknowledge_operation(backend(), operation_kind(), binary()) ::
              :ok | {:error, atom()}
  @callback abort(backend(), session(), atom()) :: {:ok, map()} | {:error, atom()}

  @callbacks [
    connect: 1,
    prepare_operation: 4,
    start: 3,
    reconcile_start: 2,
    evaluate: 4,
    reconcile_evaluate: 3,
    template: 4,
    info: 2,
    close: 3,
    reconcile_close: 3,
    acknowledge_operation: 3,
    abort: 3
  ]

  @spec validate(module() | nil) :: :ok | {:error, :invalid_repl_adapter}
  def validate(nil), do: :ok

  def validate(adapter) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and
         Enum.all?(@callbacks, fn {name, arity} -> function_exported?(adapter, name, arity) end),
       do: :ok,
       else: {:error, :invalid_repl_adapter}
  end

  def validate(_adapter), do: {:error, :invalid_repl_adapter}

  @spec validate_features(term()) :: {:ok, map()} | {:error, :invalid_repl_features}
  def validate_features(
        %{
          "enabled" => true,
          "profile_id" => "log-analysis-v2",
          "namespaces" => ["cap", "log", "log.analysis"],
          "source_limit_bytes" => 65_536
        } = features
      )
      when map_size(features) == 4 do
    case Jason.encode(features) do
      {:ok, encoded} when byte_size(encoded) <= 4_096 -> {:ok, features}
      _error -> {:error, :invalid_repl_features}
    end
  end

  def validate_features(_features), do: {:error, :invalid_repl_features}
end
