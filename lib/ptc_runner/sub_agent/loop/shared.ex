defmodule PtcRunner.SubAgent.Loop.Shared do
  @moduledoc """
  Helpers shared across the loop drivers (`Loop`, `TextMode`, `PtcToolCall`,
  `JsonHandler`, `StepAssembler`).

  These functions used to be copy-pasted into each driver and had begun to
  drift. Keeping a single definition here guarantees the drivers agree on
  memory accounting, error classification, final-text parsing, collected-message
  assembly, and schema usage metrics.
  """

  # ----------------------------------------------------------------
  # Memory accounting
  # ----------------------------------------------------------------

  @doc "Approximate in-memory byte size of the agent memory map."
  @spec memory_size(map()) :: non_neg_integer()
  def memory_size(memory) when is_map(memory), do: :erlang.external_size(memory)

  @doc """
  Check whether `memory` exceeds `limit` bytes.

  Returns `{:ok, size}` when within the limit (or when `limit` is `nil`), and
  `{:error, :memory_limit_exceeded, size}` when exceeded.
  """
  @spec check_memory_limit(map(), non_neg_integer() | nil) ::
          {:ok, non_neg_integer()} | {:error, :memory_limit_exceeded, non_neg_integer()}
  def check_memory_limit(memory, limit) when is_integer(limit) do
    size = memory_size(memory)
    if size > limit, do: {:error, :memory_limit_exceeded, size}, else: {:ok, size}
  end

  def check_memory_limit(_memory, nil), do: {:ok, 0}

  # ----------------------------------------------------------------
  # Lisp error classification
  # ----------------------------------------------------------------

  @doc """
  Map a `Step.fail` map onto a coarse error reason atom
  (`:parse_error`, `:timeout`, `:memory_limit`, or `:runtime_error`).

  `reason` may be an atom or a string (`t:PtcRunner.Step.fail/0` allows both).
  No `@spec` is declared on purpose: the callers pass `lisp_step.fail`, whose
  type is `fail | nil`, and dialyzer's success-typing narrowing constrains it
  to the non-nil map here — which keeps the subsequent `fail.message` access
  safe. A narrower explicit contract would break that narrowing.
  """
  def classify_lisp_error(%{reason: reason})
      when reason in [:parse_error, :timeout, :memory_limit] do
    reason
  end

  def classify_lisp_error(%{reason: reason}) do
    reason_str = to_string(reason)

    cond do
      String.contains?(reason_str, "parse") -> :parse_error
      String.contains?(reason_str, "timeout") -> :timeout
      String.contains?(reason_str, "memory") -> :memory_limit
      true -> :runtime_error
    end
  end

  @doc """
  Whether a `Lisp.run` failure must terminate the SubAgent run rather than become
  a recoverable retry turn — consulted by every Lisp-running transport (`:content`
  and `:tool_call`).

  A `:prelude_attach_failed` means a public capability-prelude export's required
  upstream backing is missing. That is not a program error the LLM can repair by
  rewriting, and feeding it back as a retry turn would let earlier side-effecting
  turns stand. Failing closed here preserves the prelude guarantee on every
  multi-turn path (plan §3.5 #2).
  """
  @spec terminal_lisp_failure?(map() | nil) :: boolean()
  def terminal_lisp_failure?(%{reason: :prelude_attach_failed}), do: true
  def terminal_lisp_failure?(_fail), do: false

  # ----------------------------------------------------------------
  # Final-text parsing
  # ----------------------------------------------------------------

  @doc """
  Parse a piece of final text into a value of the expected return type.

  `:datetime` accepts both JSON-quoted ISO-8601 (`"\\"2026-05-06T...\\""`) and a
  bare ISO-8601 string. All other types parse via `Jason.decode/1`.
  """
  @spec parse_for_type(binary(), term()) :: {:ok, term()} | {:error, binary()}
  def parse_for_type(content, :datetime) do
    case Jason.decode(content) do
      {:ok, val} ->
        {:ok, val}

      {:error, _} ->
        case DateTime.from_iso8601(content) do
          {:ok, _dt, _offset} -> {:ok, content}
          {:error, _} -> {:error, "Could not parse datetime from response: #{inspect(content)}"}
        end
    end
  end

  def parse_for_type(content, _type) do
    case Jason.decode(content) do
      {:ok, val} -> {:ok, val}
      {:error, _} -> {:error, "Could not parse JSON from response."}
    end
  end

  # ----------------------------------------------------------------
  # Collected messages / schema metrics
  # ----------------------------------------------------------------

  @doc """
  Build the optional collected-message list returned to callers that requested
  `collect_messages: true`. Prepends the current system prompt; returns `nil`
  when collection is disabled.
  """
  @spec build_collected_messages(map(), list() | nil) :: list() | nil
  def build_collected_messages(%{collect_messages: false}, _messages), do: nil

  def build_collected_messages(%{collect_messages: true} = state, messages) do
    system_prompt = state.current_system_prompt || ""
    [%{role: :system, content: system_prompt} | messages]
  end

  @doc """
  Annotate a usage map with schema-usage metrics (`:schema_used` and, when a
  schema map is present, `:schema_bytes`).
  """
  @spec add_schema_metrics(map(), term()) :: map()
  def add_schema_metrics(usage, schema) when is_map(schema) do
    schema_json = Jason.encode!(schema)

    usage
    |> Map.put(:schema_used, true)
    |> Map.put(:schema_bytes, byte_size(schema_json))
  end

  def add_schema_metrics(usage, _), do: Map.put(usage, :schema_used, false)
end
