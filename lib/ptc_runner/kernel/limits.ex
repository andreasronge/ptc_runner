defmodule PtcRunner.Kernel.Limits do
  @moduledoc """
  Normalized positive hard ceilings for one Kernel run.

  Every field, default, accepted range, scope, and identity rule comes from
  `PtcRunner.Kernel.LimitCatalog`. There is no disabled or infinite form.
  `new/1` accepts only cataloged fields and overlays them on `defaults/0`.

  The generated [Kernel limits reference](kernel-limits-reference.md) lists the
  meaning, unit, defaults, installed ceilings, range, and scope of every row.

  The installed-only timeouts are cataloged and sealed in this boundary before
  the later provider-lifecycle and doctor phases begin consuming them. Merely
  constructing a `Limits` value does not enforce those future operations.

  `defaults/0` are the effective limits used when a manifest does not request
  narrower values. `installed_defaults/0` are the larger host-controlled
  ceilings used by manifest-backed frontends. A host may supply another
  complete `Limits` value as its installation ceiling. Manifests can narrow
  only catalog rows scoped `:manifest_narrowable` or
  `:optional_manifest_narrowable`; installed-only values are copied from the
  host unchanged.

  Catalog validation covers each field independently, including the minimum
  event payload needed by a complete maximum bounded `run-stopped` payload.
  Manifest loading also validates the normal trace fields together after
  host/application resolution: the effective count must retain one ordinary
  event plus the two terminal events, and the byte budget must retain one
  complete maximum-size `run-started` event in addition to
  `PtcRunner.Kernel.EventSink`'s measured terminal reserve. Private trace
  policy keeps its zero-reserve fail-closed behavior.
  """

  alias PtcRunner.Kernel.LimitCatalog

  @defaults LimitCatalog.defaults(:compiled)
  @installed_defaults LimitCatalog.defaults(:installed)
  @fields @defaults |> Map.keys() |> Enum.sort()
  :ok = LimitCatalog.validate_fields!(@fields)
  @enforce_keys Map.keys(@defaults)
  defstruct Map.to_list(@defaults)

  @type t :: %__MODULE__{
          run_duration_ms: pos_integer(),
          workflow_timeout_ms: pos_integer(),
          evaluation_timeout_ms: pos_integer(),
          evaluation_admission_timeout_ms: pos_integer(),
          parallel_timeout_ms: pos_integer(),
          workflow_heap_words: pos_integer(),
          evaluation_heap_words: pos_integer(),
          provider_heap_words: pos_integer(),
          live_provider_tasks: pos_integer(),
          llm_request_output_tokens: pos_integer(),
          llm_request_timeout_ms: pos_integer(),
          llm_total_tokens: pos_integer() | nil,
          llm_cost_microusd: pos_integer() | nil,
          workflow_capability_calls: pos_integer(),
          workflow_capability_calls_per_name: pos_integer(),
          mission_capability_calls: pos_integer(),
          mission_capability_calls_per_name: pos_integer(),
          subordinate_evaluations: pos_integer(),
          subordinate_source_checks: pos_integer(),
          protocol_errors: pos_integer(),
          entry_source_bytes: pos_integer(),
          subordinate_source_bytes: pos_integer(),
          evaluation_memory_bytes: pos_integer(),
          evaluation_history_bytes: pos_integer(),
          capability_argument_bytes: pos_integer(),
          capability_result_bytes: pos_integer(),
          event_payload_bytes: pos_integer(),
          terminal_result_bytes: pos_integer(),
          normal_event_count: pos_integer(),
          normal_event_bytes: pos_integer(),
          provider_cleanup_timeout_ms: pos_integer(),
          local_preflight_timeout_ms: pos_integer(),
          selection_validation_timeout_ms: pos_integer(),
          doctor_connectivity_timeout_ms: pos_integer()
        }
  @spec defaults() :: t()
  @doc "Returns the complete application-independent default limit set."
  def defaults, do: struct!(__MODULE__, @defaults)

  @spec installed_defaults() :: t()
  @doc "Returns practical host ceilings for manifest-backed model and connector runs."
  def installed_defaults, do: struct!(__MODULE__, @installed_defaults)

  @spec valid?(term()) :: boolean()
  @doc "Checks that a complete limits struct contains only positive integer ceilings."
  def valid?(%__MODULE__{} = limits) do
    values = Map.from_struct(limits)

    Enum.sort(Map.keys(values)) == @fields and
      LimitCatalog.valid_values?(values)
  end

  def valid?(_limits), do: false

  @spec names() :: [binary()]
  @doc "Returns every public limit name, sorted, for operator-facing validation."
  def names, do: LimitCatalog.names()

  @spec name(term()) :: {:ok, atom()} | :error
  @doc "Resolves one public limit name to its field, or `:error` when unknown."
  def name(value) do
    case LimitCatalog.fetch(value) do
      {:ok, row} -> {:ok, row.field}
      :error -> :error
    end
  end

  @spec fetch(t(), binary() | atom()) :: {:ok, pos_integer() | nil} | :error
  @doc "Reads one cataloged field from a valid limits value."
  def fetch(%__MODULE__{} = limits, name) do
    with true <- valid?(limits),
         {:ok, row} <- LimitCatalog.fetch(name) do
      Map.fetch(limits, row.field)
    else
      _invalid -> :error
    end
  end

  def fetch(_limits, _name), do: :error

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, :invalid_limits}
  @doc """
  Builds a complete limit set by applying atom-keyed overrides to the defaults.

  Unknown fields and values outside their cataloged inclusive range are
  rejected.
  """
  def new(overrides \\ %{}) do
    build(@defaults, overrides)
  end

  @spec installed(map() | keyword()) :: {:ok, t()} | {:error, :invalid_limits}
  @doc "Builds complete host-installed ceilings from the catalog's installed defaults."
  def installed(overrides \\ %{}) do
    build(@installed_defaults, overrides)
  end

  defp build(base, overrides) do
    with {:ok, overrides} <- normalize_overrides(overrides),
         values = Map.merge(base, overrides),
         true <- LimitCatalog.valid_values?(values) do
      {:ok, struct!(__MODULE__, values)}
    else
      _ -> {:error, :invalid_limits}
    end
  end

  defp normalize_overrides(overrides) when is_map(overrides), do: {:ok, overrides}

  defp normalize_overrides(overrides) when is_list(overrides) do
    if Keyword.keyword?(overrides) and
         length(overrides) == MapSet.size(MapSet.new(Keyword.keys(overrides))) do
      {:ok, Map.new(overrides)}
    else
      {:error, :invalid_limits}
    end
  end

  defp normalize_overrides(_overrides), do: {:error, :invalid_limits}
end
