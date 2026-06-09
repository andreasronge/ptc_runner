defmodule PtcRunner.Upstream.RunContext do
  @moduledoc false

  alias PtcRunner.Upstream.{Collector, Runtime}

  @type t :: %__MODULE__{}

  defstruct [
    :runtime,
    :collector,
    :call_counter,
    :catalog_op_counter,
    :limits,
    :closed
  ]

  @spec new(term(), keyword()) :: {:ok, struct()} | {:error, term()}
  def new(runtime, opts \\ []) do
    with {:ok, collector} <- Collector.start_link() do
      {:ok,
       %__MODULE__{
         runtime: runtime,
         collector: collector,
         call_counter: :atomics.new(1, signed: false),
         catalog_op_counter: :atomics.new(1, signed: false),
         limits: limits(runtime, opts),
         closed: :atomics.new(1, signed: false)
       }}
    end
  end

  @spec ensure_open(struct()) :: :ok | {:error, :run_context_closed}
  def ensure_open(%__MODULE__{closed: closed}) do
    case :atomics.get(closed, 1) do
      0 -> :ok
      _ -> {:error, :run_context_closed}
    end
  end

  @doc false
  @spec mark_closed(struct()) :: :ok
  def mark_closed(%__MODULE__{closed: closed}) do
    :atomics.put(closed, 1, 1)
    :ok
  end

  @spec drain_calls(struct()) :: [map()]
  def drain_calls(%__MODULE__{collector: collector}), do: Collector.drain(collector)

  @spec close(struct()) :: :ok
  def close(%__MODULE__{collector: collector} = context) do
    mark_closed(context)
    Collector.stop(collector)
  end

  @spec record(struct(), map()) :: :ok
  def record(%__MODULE__{collector: collector}, entry), do: Collector.record(collector, entry)

  @spec check_call_cap(struct(), String.t(), String.t()) :: :proceed | :cap_exhausted
  def check_call_cap(
        %__MODULE__{call_counter: counter, limits: %{max_tool_calls: max_calls}} = context,
        server,
        tool
      ) do
    slot = :atomics.add_get(counter, 1, 1)

    if slot <= max_calls do
      :proceed
    else
      record(context, error_entry(server, tool, :cap_exhausted, "cap_exhausted", 0))
      :cap_exhausted
    end
  end

  @spec check_catalog_cap(struct()) :: :proceed | :cap_exhausted
  def check_catalog_cap(%__MODULE__{
        catalog_op_counter: counter,
        limits: %{max_catalog_ops: max_ops}
      }) do
    slot = :atomics.add_get(counter, 1, 1)
    if slot <= max_ops, do: :proceed, else: :cap_exhausted
  end

  @spec success_entry(String.t(), String.t(), non_neg_integer(), keyword()) :: map()
  def success_entry(server, tool, duration_ms, opts \\ []) do
    %{
      "server" => server,
      "tool" => tool,
      "status" => "ok",
      "duration_ms" => duration_ms,
      "result_bytes" => result_bytes(Keyword.get(opts, :result_bytes)),
      "oversize" => false
    }
    |> maybe_put_result_overview(Keyword.get(opts, :result_overview))
  end

  @spec error_entry(String.t(), String.t(), atom(), String.t(), non_neg_integer(), keyword()) ::
          map()
  def error_entry(server, tool, reason, detail, duration_ms, opts \\ []) do
    %{
      "server" => server,
      "tool" => tool,
      "status" => "error",
      "duration_ms" => duration_ms,
      "reason" => Atom.to_string(reason),
      "error" => detail,
      "result_bytes" => result_bytes(Keyword.get(opts, :result_bytes)),
      "oversize" => reason == :response_too_large
    }
  end

  defp maybe_put_result_overview(entry, nil), do: entry

  defp maybe_put_result_overview(entry, overview) when is_map(overview),
    do: Map.put(entry, "result_overview", overview)

  defp maybe_put_result_overview(entry, _overview), do: entry

  defp limits(runtime, opts) do
    defaults = Runtime.defaults(runtime)

    %{
      max_tool_calls: Keyword.get(opts, :max_tool_calls, defaults.max_tool_calls),
      max_catalog_ops: Keyword.get(opts, :max_catalog_ops, defaults.max_catalog_ops),
      call_timeout_ms: Keyword.get(opts, :call_timeout_ms, defaults.call_timeout_ms),
      max_response_bytes: Keyword.get(opts, :max_response_bytes, defaults.max_response_bytes),
      max_catalog_result_bytes:
        Keyword.get(opts, :max_catalog_result_bytes, defaults.max_catalog_result_bytes)
    }
  end

  defp result_bytes(n) when is_integer(n) and n >= 0, do: n
  defp result_bytes(_), do: nil
end
