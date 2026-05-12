defmodule PtcRunnerMcp.PayloadMetrics do
  @moduledoc """
  Builds the `ptc_metrics` block decorated onto `ptc_lisp_execute`
  (aggregator mode) and `ptc_task` response envelopes.

  See `Plans/ptc-runner-mcp-payload-reduction.md` §4.2 / §4.3 / §7.
  This is a **pure** module — no I/O — so every honesty invariant
  (§7: denominator guard, oversize/error exclusion, explicit `null`
  ratios, `utf8_bytes_div_4` token estimates, baseline blocks always
  present with `optimistic.available: false`, the `efficiency_note`)
  lives here and is unit-tested directly.

  The headline number is `payload_reduction_ratio` =
  `round(upstream_result_bytes / max(final_result_bytes, 1), 2)`, the
  ratio of "the answer the program produced" to "the upstream
  tool-result material it consumed". It is `null` whenever either side
  is `0`. It is **not** "tokens saved" and **not** the literal MCP
  response-size reduction (the envelope mirrors the whole structured
  payload — `ptc_metrics`, `upstream_calls`, `prints`, `feedback` —
  into `content[0].text`, so the literal reply is larger than
  `final_result_bytes`).
  """

  @schema_version 1
  @token_estimate_method "utf8_bytes_div_4"

  @conservative_note "Σ bytes of successful, non-oversize upstream tool responses the program fetched. Upper bound on the true denominator: a program may fetch data it then discards. Excludes upstream tool schemas/descriptions and any no-PTC orchestration overhead. Not equal to the literal MCP response size: the envelope mirrors the full structured payload (this `ptc_metrics` block, `upstream_calls`, `prints`, `feedback`) into `content[0].text`, so the actual response the client receives is larger than `final_result_bytes`."

  @optimistic_note "What an LLM would have spent doing this task with direct tool calls (incl. tool-schema injection, re-fetching, prompt overhead) is not measurable by the server."

  @efficiency_note "payload_reduction_ratio is answer/result-payload reduction only. It excludes (a) the server-side planner LLM usage in `server_side_llm` (real cost), and (b) the MCP envelope overhead the client also receives — `prints`, `feedback`, the `upstream_calls` list, this `ptc_metrics` block itself — all mirrored into `content[0].text`. Total token/cost efficiency vs a no-PTC workflow is not computed."

  @typedoc """
  Provider-or-estimated planner usage threaded from the agentic
  planner. `provider_reported` is `true` only when the LLM adapter
  surfaced real `usage`; otherwise the `*_tokens` fields are `nil`.
  The `*_bytes` fields are always populated.
  """
  @type server_side_llm_input :: %{
          optional(:provider_reported) => boolean(),
          optional(:planner_calls) => non_neg_integer(),
          optional(:prompt_tokens) => non_neg_integer() | nil,
          optional(:completion_tokens) => non_neg_integer() | nil,
          optional(:total_tokens) => non_neg_integer() | nil,
          optional(:prompt_bytes) => non_neg_integer(),
          optional(:completion_bytes) => non_neg_integer()
        }

  @doc """
  Builds the `ptc_metrics` map (§4.2). With a `:server_side_llm` opt
  carrying a `t:server_side_llm_input/0` map, also includes the
  `server_side_llm` line item and the `efficiency_note` (§4.3).

  - `final_result_bytes` — byte size of the answer returned to the
    client (the `ptc_lisp_execute` `result` field, or for `ptc_task`
    `byte_size(Jason.encode!(%{"answer" => .., "structured_result" => ..}))`).
    `0` on error or empty result.
  - `prints_bytes` — byte size of the serialized `prints` array (`0`
    for `ptc_task`, which has no `prints`).
  - `upstream_calls_entries` — the list of `upstream_calls[]` entries
    (the §4.1 shape, string-keyed) the program produced.
  - `opts` — `:server_side_llm` (a map) to attach the `ptc_task`
    planner-cost block.
  """
  @spec build(non_neg_integer(), non_neg_integer(), [map()], keyword()) :: map()
  def build(final_result_bytes, prints_bytes, upstream_calls_entries, opts \\ [])
      when is_integer(final_result_bytes) and final_result_bytes >= 0 and
             is_integer(prints_bytes) and prints_bytes >= 0 and
             is_list(upstream_calls_entries) and is_list(opts) do
    counts = tally(upstream_calls_entries)
    ratio = reduction_ratio(counts.upstream_result_bytes, final_result_bytes)

    base = %{
      "schema_version" => @schema_version,
      "final_result_bytes" => final_result_bytes,
      "prints_bytes" => prints_bytes,
      "upstream_call_count" => counts.call_count,
      "upstream_ok_count" => counts.ok_count,
      "upstream_error_count" => counts.error_count,
      "upstream_oversize_count" => counts.oversize_count,
      "upstream_result_bytes" => counts.upstream_result_bytes,
      "upstream_error_bytes" => counts.upstream_error_bytes,
      "upstream_oversize_bytes" => counts.upstream_oversize_bytes,
      "payload_reduction_ratio" => ratio,
      "estimated_final_result_tokens" => estimate_tokens(final_result_bytes),
      "estimated_upstream_result_tokens" => estimate_tokens(counts.upstream_result_bytes),
      "token_estimate_method" => @token_estimate_method,
      "baseline" => baseline(counts.upstream_result_bytes, ratio)
    }

    case Keyword.get(opts, :server_side_llm) do
      nil ->
        base

      input when is_map(input) ->
        base
        |> Map.put("server_side_llm", server_side_llm(input))
        |> Map.put("efficiency_note", @efficiency_note)
    end
  end

  # ----------------------------------------------------------------
  # Upstream-call byte accounting (§7 invariants 3, 4)
  # ----------------------------------------------------------------

  defp tally(entries) do
    Enum.reduce(
      entries,
      %{
        call_count: 0,
        ok_count: 0,
        error_count: 0,
        oversize_count: 0,
        upstream_result_bytes: 0,
        upstream_error_bytes: 0,
        upstream_oversize_bytes: 0
      },
      fn entry, acc ->
        acc = %{acc | call_count: acc.call_count + 1}
        bytes = entry_bytes(entry)
        oversize? = entry_oversize?(entry)
        status = entry_status(entry)

        cond do
          oversize? ->
            %{
              acc
              | oversize_count: acc.oversize_count + 1,
                upstream_oversize_bytes: acc.upstream_oversize_bytes + bytes
            }

          status == "ok" ->
            %{
              acc
              | ok_count: acc.ok_count + 1,
                upstream_result_bytes: acc.upstream_result_bytes + bytes
            }

          # status == "error" (or anything not "ok") and not oversize.
          true ->
            %{
              acc
              | error_count: acc.error_count + 1,
                upstream_error_bytes: acc.upstream_error_bytes + bytes
            }
        end
      end
    )
  end

  # `result_bytes` may be a non-negative integer or `null`; `null`
  # contributes 0 to whichever bucket the entry falls in.
  defp entry_bytes(entry) do
    case Map.get(entry, "result_bytes") do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp entry_oversize?(entry), do: Map.get(entry, "oversize") == true

  defp entry_status(entry) do
    case Map.get(entry, "status") do
      s when is_binary(s) -> s
      _ -> "error"
    end
  end

  # ----------------------------------------------------------------
  # Ratio + token estimates (§7 invariants 2, 6)
  # ----------------------------------------------------------------

  @doc """
  `round(upstream_result_bytes / max(final_result_bytes, 1), 2)`, or
  `nil` when either side is `0` (a pure-compute / all-failed / errored
  program). Never `0`, never `∞`, never a sentinel.
  """
  @spec reduction_ratio(non_neg_integer(), non_neg_integer()) :: float() | nil
  def reduction_ratio(upstream_result_bytes, final_result_bytes)
      when is_integer(upstream_result_bytes) and is_integer(final_result_bytes) do
    if upstream_result_bytes <= 0 or final_result_bytes <= 0 do
      nil
    else
      Float.round(upstream_result_bytes / max(final_result_bytes, 1), 2)
    end
  end

  @doc "`ceil(bytes / 4)` — the `utf8_bytes_div_4` token estimate."
  @spec estimate_tokens(non_neg_integer()) :: non_neg_integer()
  def estimate_tokens(bytes) when is_integer(bytes) and bytes >= 0, do: div(bytes + 3, 4)

  # ----------------------------------------------------------------
  # Baseline blocks (§7 invariant 5)
  # ----------------------------------------------------------------

  defp baseline(upstream_result_bytes, ratio) do
    %{
      "conservative" => %{
        "name" => "successful_upstream_results_only",
        "bytes" => upstream_result_bytes,
        "ratio" => ratio,
        "note" => @conservative_note
      },
      "optimistic" => %{
        "name" => "no_ptc_direct_llm_workflow",
        "available" => false,
        "note" => @optimistic_note
      }
    }
  end

  # ----------------------------------------------------------------
  # server_side_llm (§4.3, §7 invariants 6, 7)
  # ----------------------------------------------------------------

  defp server_side_llm(input) do
    provider_reported? = Map.get(input, :provider_reported, false) == true
    prompt_bytes = non_neg_int(Map.get(input, :prompt_bytes))
    completion_bytes = non_neg_int(Map.get(input, :completion_bytes))
    planner_calls = non_neg_int(Map.get(input, :planner_calls))

    {prompt_tokens, completion_tokens, total_tokens} =
      if provider_reported? do
        pt = nilable_non_neg_int(Map.get(input, :prompt_tokens))
        ct = nilable_non_neg_int(Map.get(input, :completion_tokens))

        tt =
          case nilable_non_neg_int(Map.get(input, :total_tokens)) do
            n when is_integer(n) -> n
            nil -> sum_if_both(pt, ct)
          end

        {pt, ct, tt}
      else
        {nil, nil, nil}
      end

    %{
      "planner_calls" => planner_calls,
      "provider_reported" => provider_reported?,
      "prompt_tokens" => prompt_tokens,
      "completion_tokens" => completion_tokens,
      "total_tokens" => total_tokens,
      "prompt_bytes" => prompt_bytes,
      "completion_bytes" => completion_bytes,
      "estimated_prompt_tokens" => estimate_tokens(prompt_bytes),
      "estimated_completion_tokens" => estimate_tokens(completion_bytes),
      "estimate_method" => @token_estimate_method
    }
  end

  defp sum_if_both(a, b) when is_integer(a) and is_integer(b), do: a + b
  defp sum_if_both(_a, _b), do: nil

  defp non_neg_int(n) when is_integer(n) and n >= 0, do: n
  defp non_neg_int(_), do: 0

  defp nilable_non_neg_int(n) when is_integer(n) and n >= 0, do: n
  defp nilable_non_neg_int(_), do: nil
end
