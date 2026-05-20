defmodule PtcRunnerMcp.Agentic.Ledger do
  @moduledoc """
  Phase 0 contract for the per-`lisp_task` upstream-call ledger.

  The SubAgent-backed `lisp_task` adapter owns this ledger. Generated
  PTC-Lisp never writes ledger entries directly; it only calls the
  MCP-owned `tool/mcp-call` wrapper that records attempts here.

  This module intentionally defines the shape and a small in-memory API
  before the full adapter is wired. Worker D can replace internals without
  changing callers as long as this public contract remains stable.
  """

  @typedoc "Upstream-call effect classification used by the continuation guard."
  @type effect :: :read | :write | :unknown

  @typedoc "Agentic upstream-call status."
  @type status :: :attempted | :ok | :error

  @typedoc "Internal ledger entry. JSON projection happens at the MCP envelope boundary."
  @type entry :: %{
          required(:id) => reference(),
          required(:server) => String.t(),
          required(:tool) => String.t(),
          required(:args_hash) => String.t(),
          required(:status) => status(),
          required(:effect) => effect(),
          required(:turn) => pos_integer(),
          required(:started_at) => DateTime.t(),
          optional(:completed_at) => DateTime.t(),
          optional(:duration_ms) => non_neg_integer(),
          optional(:result_bytes) => non_neg_integer(),
          # `Plans/ptc-runner-mcp-payload-reduction.md` §4.1: `true`
          # iff the upstream response exceeded
          # `--max-upstream-response-bytes` (the program received an
          # error tag, not the data). Defaults to `false` on
          # completion; only the `response_too_large` world-fault sets
          # it `true`.
          optional(:oversize) => boolean(),
          optional(:result_overview) => map(),
          optional(:error_reason) => String.t(),
          optional(:error) => String.t()
        }

  @type t :: pid()

  @doc "Starts an in-memory ledger for one `lisp_task` call."
  @spec start_link(keyword()) :: {:ok, t()}
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> [] end)
  end

  @doc """
  Records an attempted upstream call and returns its internal entry id.

  Attempts are recorded before dispatch once `server`, `tool`, and `effect`
  are known, so interrupted write/unknown calls still block continuation.
  """
  @spec record_attempt(t(), String.t(), String.t(), map(), effect(), pos_integer()) :: reference()
  def record_attempt(ledger, server, tool, args, effect, turn)
      when is_pid(ledger) and is_binary(server) and is_binary(tool) and
             effect in [:read, :write, :unknown] and is_integer(turn) and turn > 0 do
    id = make_ref()

    entry = %{
      id: id,
      server: server,
      tool: tool,
      args_hash: hash_args(args),
      status: :attempted,
      effect: effect,
      turn: turn,
      started_at: DateTime.utc_now()
    }

    Agent.update(ledger, &[entry | &1])
    id
  end

  @doc "Marks a previously attempted call as successful."
  @spec complete_success(t(), reference(), keyword()) :: :ok
  def complete_success(ledger, id, opts \\ []) when is_pid(ledger) and is_reference(id) do
    complete(ledger, id, :ok, opts)
  end

  @doc "Marks a previously attempted call as failed."
  @spec complete_error(t(), reference(), String.t(), String.t(), keyword()) :: :ok
  def complete_error(ledger, id, reason, error, opts \\ [])
      when is_pid(ledger) and is_reference(id) and is_binary(reason) and is_binary(error) do
    complete(ledger, id, :error, Keyword.merge(opts, error_reason: reason, error: error))
  end

  @doc "Returns entries in attempt order."
  @spec entries(t()) :: [entry()]
  def entries(ledger) when is_pid(ledger) do
    ledger
    |> Agent.get(& &1)
    |> Enum.reverse()
  end

  @doc "True when any attempted call may have produced side effects."
  @spec side_effecting_attempted?(t() | [entry()]) :: boolean()
  def side_effecting_attempted?(ledger) when is_pid(ledger) do
    ledger |> entries() |> side_effecting_attempted?()
  end

  def side_effecting_attempted?(entries) when is_list(entries) do
    Enum.any?(entries, &(Map.get(&1, :effect) in [:write, :unknown]))
  end

  defp complete(ledger, id, status, opts) do
    now = DateTime.utc_now()

    Agent.update(ledger, fn entries ->
      Enum.map(entries, fn
        %{id: ^id} = entry ->
          entry
          |> Map.put(:status, status)
          |> Map.put(:completed_at, now)
          |> Map.put(:oversize, Keyword.get(opts, :oversize, false) == true)
          |> maybe_put(:duration_ms, Keyword.get(opts, :duration_ms))
          |> maybe_put(:result_bytes, Keyword.get(opts, :result_bytes))
          |> maybe_put(:result_overview, Keyword.get(opts, :result_overview))
          |> maybe_put(:error_reason, Keyword.get(opts, :error_reason))
          |> maybe_put(:error, Keyword.get(opts, :error))

        entry ->
          entry
      end)
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp hash_args(args) do
    encoded =
      case Jason.encode(args) do
        {:ok, json} -> json
        {:error, _} -> inspect(args)
      end

    :crypto.hash(:sha256, encoded)
    |> Base.encode16(case: :lower)
  end
end
