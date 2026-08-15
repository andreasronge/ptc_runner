defmodule PtcRunner.Kernel.LimitCatalog do
  @moduledoc """
  Closed metadata authority for Kernel limits.

  Every `PtcRunner.Kernel.Limits` field has exactly one row. A row fixes its
  public name, application scope, compiled and installed defaults, accepted
  range, and effective-identity participation. Host and manifest decoders,
  their generated schemas, and effective-identity projection consume this
  catalog rather than reflecting fields from a struct.

  `:manifest_narrowable` limits may be requested by an application at or below
  the installed ceiling. `:installed_only` limits are host-owned and are copied
  unchanged into effective limits.
  """

  @generic_maximum 2_592_000_000

  @manifest_defaults [
    {:run_duration_ms, 30_000, 300_000},
    {:workflow_timeout_ms, 30_000, 120_000},
    {:evaluation_timeout_ms, 1_000, 60_000},
    {:evaluation_admission_timeout_ms, 10_000, 120_000},
    {:parallel_timeout_ms, 30_000, 300_000},
    {:workflow_heap_words, 8_000_000, 8_000_000},
    {:evaluation_heap_words, 1_250_000, 1_250_000},
    {:provider_heap_words, 5_000_000, 5_000_000},
    {:live_provider_tasks, 8, 8},
    {:workflow_capability_calls, 64, 64},
    {:workflow_capability_calls_per_name, 16, 16},
    {:mission_capability_calls, 128, 128},
    {:mission_capability_calls_per_name, 32, 32},
    {:subordinate_evaluations, 16, 16},
    {:subordinate_source_checks, 16, 16},
    {:protocol_errors, 32, 32},
    {:entry_source_bytes, 262_144, 262_144},
    {:subordinate_source_bytes, 131_072, 131_072},
    {:evaluation_memory_bytes, 2_000_000, 2_000_000},
    {:evaluation_history_bytes, 1_000_000, 1_000_000},
    {:capability_argument_bytes, 262_144, 262_144},
    {:capability_result_bytes, 1_000_000, 1_000_000},
    {:event_payload_bytes, 262_144, 262_144},
    {:terminal_result_bytes, 1_000_000, 1_000_000},
    {:normal_event_count, 256, 256},
    {:normal_event_bytes, 4_000_000, 4_000_000}
  ]

  @installed_only [
    {:provider_cleanup_timeout_ms, 5_000, true},
    {:local_preflight_timeout_ms, 5_000, true},
    {:selection_validation_timeout_ms, 5_000, true},
    {:doctor_connectivity_timeout_ms, 10_000, false}
  ]

  @descriptions %{
    run_duration_ms:
      "Complete ordinary run after optional provider application admission, including active preflight and Kernel execution.",
    workflow_timeout_ms: "One workflow evaluation.",
    evaluation_timeout_ms: "One subordinate mission evaluation.",
    evaluation_admission_timeout_ms:
      "Wait for the single subordinate-evaluation lease before execution begins.",
    parallel_timeout_ms: "One pmap or pcalls operation, clamped by the run deadline.",
    workflow_heap_words: "Heap of the workflow evaluator process.",
    evaluation_heap_words: "Heap of each subordinate evaluator process.",
    provider_heap_words: "Heap of each provider callback process.",
    live_provider_tasks:
      "Concurrent provider callback processes and Kernel-owned parallel Lisp workers.",
    workflow_capability_calls: "Total workflow capability calls in one run.",
    workflow_capability_calls_per_name:
      "Workflow capability calls to any one public name in one run.",
    mission_capability_calls: "Total mission capability calls in one run.",
    mission_capability_calls_per_name:
      "Mission capability calls to any one public name in one run.",
    subordinate_evaluations: "Subordinate mission evaluations in one run.",
    subordinate_source_checks: "Advisory subordinate source checks in one run.",
    protocol_errors: "Recoverable agent protocol errors in one run.",
    entry_source_bytes: "Workflow entry source accepted at the application boundary.",
    subordinate_source_bytes: "Source accepted by one subordinate check or evaluation.",
    evaluation_memory_bytes: "Retained mission definitions across successful turns.",
    evaluation_history_bytes:
      "Each value and the aggregate exact three-value continuation history.",
    capability_argument_bytes: "Encoded arguments crossing a capability boundary.",
    capability_result_bytes: "Encoded result crossing a capability boundary.",
    event_payload_bytes: "One canonical event payload.",
    terminal_result_bytes: "Encoded terminal workflow result.",
    normal_event_count: "Canonical events retained under the normal policy.",
    normal_event_bytes: "Aggregate encoded canonical events retained under the normal policy.",
    provider_cleanup_timeout_ms: "Kernel-owned provider cleanup after execution.",
    local_preflight_timeout_ms: "Whole audited local-preflight phase across selected providers.",
    selection_validation_timeout_ms: "Active validation of selected provider declarations.",
    doctor_connectivity_timeout_ms: "One doctor --connect provider health check."
  }

  @units %{
    run_duration_ms: :milliseconds,
    workflow_timeout_ms: :milliseconds,
    evaluation_timeout_ms: :milliseconds,
    evaluation_admission_timeout_ms: :milliseconds,
    parallel_timeout_ms: :milliseconds,
    workflow_heap_words: :heap_words,
    evaluation_heap_words: :heap_words,
    provider_heap_words: :heap_words,
    live_provider_tasks: :count,
    workflow_capability_calls: :count,
    workflow_capability_calls_per_name: :count,
    mission_capability_calls: :count,
    mission_capability_calls_per_name: :count,
    subordinate_evaluations: :count,
    subordinate_source_checks: :count,
    protocol_errors: :count,
    entry_source_bytes: :bytes,
    subordinate_source_bytes: :bytes,
    evaluation_memory_bytes: :bytes,
    evaluation_history_bytes: :bytes,
    capability_argument_bytes: :bytes,
    capability_result_bytes: :bytes,
    event_payload_bytes: :bytes,
    terminal_result_bytes: :bytes,
    normal_event_count: :count,
    normal_event_bytes: :bytes,
    provider_cleanup_timeout_ms: :milliseconds,
    local_preflight_timeout_ms: :milliseconds,
    selection_validation_timeout_ms: :milliseconds,
    doctor_connectivity_timeout_ms: :milliseconds
  }

  @rows (Enum.map(@manifest_defaults, fn {field, compiled_default, installed_default} ->
           %{
             field: field,
             name: Atom.to_string(field),
             scope: :manifest_narrowable,
             compiled_default: compiled_default,
             installed_default: installed_default,
             minimum: 1,
             maximum: @generic_maximum,
             identity: true,
             unit: Map.fetch!(@units, field),
             description: Map.fetch!(@descriptions, field)
           }
         end) ++
           Enum.map(@installed_only, fn {field, default, identity} ->
             %{
               field: field,
               name: Atom.to_string(field),
               scope: :installed_only,
               compiled_default: default,
               installed_default: default,
               minimum: 100,
               maximum: 30_000,
               identity: identity,
               unit: Map.fetch!(@units, field),
               description: Map.fetch!(@descriptions, field)
             }
           end))
        |> Enum.sort_by(& &1.name)

  @by_name Map.new(@rows, &{&1.name, &1})
  @by_field Map.new(@rows, &{&1.field, &1})

  @type scope :: :manifest_narrowable | :installed_only
  @type row :: %{
          field: atom(),
          name: binary(),
          scope: scope(),
          compiled_default: pos_integer(),
          installed_default: pos_integer(),
          minimum: pos_integer(),
          maximum: pos_integer(),
          identity: boolean(),
          unit: :milliseconds | :heap_words | :bytes | :count,
          description: binary()
        }

  @spec rows() :: [row()]
  @doc "Returns every catalog row in lexical public-name order."
  def rows, do: @rows

  @spec rows(scope()) :: [row()]
  @doc "Returns catalog rows in one scope, preserving lexical order."
  def rows(scope) when scope in [:manifest_narrowable, :installed_only],
    do: Enum.filter(@rows, &(&1.scope == scope))

  @spec names(:all | scope()) :: [binary()]
  @doc "Returns public names for the host or one catalog scope."
  def names(scope \\ :all)
  def names(:all), do: Enum.map(@rows, & &1.name)

  def names(scope) when scope in [:manifest_narrowable, :installed_only],
    do: scope |> rows() |> Enum.map(& &1.name)

  @spec fetch(binary() | atom()) :: {:ok, row()} | :error
  @doc "Looks up a row without converting caller-authored strings to atoms."
  def fetch(name) when is_binary(name), do: Map.fetch(@by_name, name)
  def fetch(field) when is_atom(field), do: Map.fetch(@by_field, field)
  def fetch(_name), do: :error

  @spec defaults(:compiled | :installed) :: %{required(atom()) => pos_integer()}
  @doc "Projects the complete atom-keyed default table from the catalog."
  def defaults(:compiled), do: Map.new(@rows, &{&1.field, &1.compiled_default})
  def defaults(:installed), do: Map.new(@rows, &{&1.field, &1.installed_default})

  @spec valid_value?(row(), term()) :: boolean()
  @doc "Checks one value against its row's inclusive range."
  def valid_value?(%{minimum: minimum, maximum: maximum}, value) when is_integer(value),
    do: value >= minimum and value <= maximum

  def valid_value?(_row, _value), do: false

  @spec valid_values?(map()) :: boolean()
  @doc "Checks a complete atom-keyed value map against every catalog row."
  def valid_values?(values) when is_map(values) do
    MapSet.new(Map.keys(values)) == MapSet.new(Map.keys(@by_field)) and
      Enum.all?(@rows, &valid_value?(&1, Map.get(values, &1.field)))
  end

  def valid_values?(_values), do: false

  @spec validate_fields!([atom()]) :: :ok
  @doc """
  Fails generation when a limits struct and the checked-in catalog diverge.
  """
  def validate_fields!(fields) when is_list(fields) do
    if MapSet.new(fields) == MapSet.new(Map.keys(@by_field)) and
         length(fields) == map_size(@by_field) do
      :ok
    else
      raise ArgumentError, "Limits fields are missing exact LimitCatalog metadata"
    end
  end

  @spec schema_properties(:host | :manifest) :: %{required(binary()) => map()}
  @doc "Generates the scoped integer properties shared by the checked-in schemas."
  def schema_properties(:host), do: Map.new(@rows, &schema_property/1)

  def schema_properties(:manifest),
    do: @rows |> Enum.filter(&(&1.scope == :manifest_narrowable)) |> Map.new(&schema_property/1)

  @spec effective_projection(struct() | map()) :: %{required(binary()) => pos_integer()}
  @doc "Projects exactly the limit rows that participate in effective identity."
  def effective_projection(limits) when is_map(limits) do
    values = if is_struct(limits), do: Map.from_struct(limits), else: limits

    if valid_values?(values) do
      @rows
      |> Enum.filter(& &1.identity)
      |> Map.new(&{&1.name, Map.fetch!(values, &1.field)})
    else
      raise ArgumentError, "invalid limits for effective identity projection"
    end
  end

  def effective_projection(_limits),
    do: raise(ArgumentError, "invalid limits for effective identity projection")

  defp schema_property(row) do
    {row.name,
     %{
       "type" => "integer",
       "minimum" => row.minimum,
       "maximum" => row.maximum
     }}
  end
end
