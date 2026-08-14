defmodule PtcRunner.Kernel.RunAnalysis do
  @moduledoc """
  Small bounded navigation API over one immutable run-evidence capture.

  The prompt-facing contract has three operations: `runs` discovers runs,
  `open` returns singular metadata and a collection catalog, and `read`
  delegates one bounded collection page to its trace or private-inspection
  snapshot owner. Collection names, filters, authority, and order come from one
  closed registry. No operation diagnoses evidence or aggregates primitive
  pages before returning to Lisp.

  Public captures expose only canonical `activity`. Private captures add exact
  exchanges, reconstructed turns, generated source with static prelude-call
  facts, effective prelude source, and workflow execution diagnostics. The
  catalog identifies snapshot and sequence domains, identifier locations, and
  raw collections whose items carry an explicit completeness field. Private
  error and source items carry typed relationships that package exact follow-up
  reads without performing them or diagnosing their evidence.
  """

  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.TraceSnapshot

  @operations [:runs, :open, :read]
  @max_limit 100
  @collect_page_limit 100
  @max_collect_pages 1_000

  @collections [
    %{
      name: "activity",
      authority: :public,
      snapshot: :traces,
      operation: :list_turns,
      filters: ~w(status evaluation_id parent_evaluation_id capability mission_name),
      order: "sequence_asc",
      sequence_domain: "canonical_trace",
      identifier_locations: %{
        "evaluation_id" => "data.evaluation_id",
        "parent_evaluation_id" => "data.parent_evaluation_id",
        "sequence" => "sequence"
      }
    },
    %{
      name: "turns",
      authority: :private,
      snapshot: :inspection,
      operation: :turns,
      filters:
        ~w(stream_id capability_id evaluation_id parent_evaluation_id prelude_call prelude_component),
      order: "stream_turn_asc",
      sequence_domain: "reconstructed_stream",
      identifier_locations: %{
        "capability_id" => "capability_id",
        "evaluation_id" => "generated[].evaluation_id",
        "parent_evaluation_id" => "generated[].parent_evaluation_id",
        "request_sequence" => "request_sequence",
        "response_sequence" => "response_sequence",
        "stream_id" => "stream_id",
        "turn" => "turn"
      }
    },
    %{
      name: "model_exchanges",
      authority: :private,
      snapshot: :inspection,
      operation: :model_exchanges,
      filters: ~w(capability_id input_sequence),
      order: "input_sequence_asc",
      sequence_domain: "private_inspection",
      identifier_locations: %{
        "capability_id" => "capability_id",
        "input_sequence" => "input_sequence",
        "output_sequence" => "output_sequence"
      },
      item_completeness_field: "complete?"
    },
    %{
      name: "capability_calls",
      authority: :private,
      snapshot: :inspection,
      operation: :capability_calls,
      filters: ~w(capability_id mission_name name),
      order: "input_sequence_asc",
      sequence_domain: "private_inspection",
      identifier_locations: %{
        "capability_id" => "capability_id",
        "input_sequence" => "input_sequence",
        "output_sequence" => "output_sequence"
      },
      item_completeness_field: "complete?"
    },
    %{
      name: "provider_exchanges",
      authority: :private,
      snapshot: :inspection,
      operation: :provider_exchanges,
      filters: ~w(capability_id mission_name request_id),
      order: "request_sequence_asc",
      sequence_domain: "private_inspection",
      identifier_locations: %{
        "capability_id" => "capability_id",
        "request_id" => "request_id",
        "request_sequence" => "request_sequence",
        "response_sequence" => "response_sequence"
      }
    },
    %{
      name: "generated_sources",
      authority: :private,
      snapshot: :inspection,
      operation: :generated_sources,
      filters: ~w(evaluation_id parent_evaluation_id mission_name prelude_call prelude_component),
      order: "sequence_asc",
      sequence_domain: "private_inspection",
      identifier_locations: %{
        "evaluation_id" => "evaluation_id",
        "parent_evaluation_id" => "parent_evaluation_id",
        "sequence" => "sequence"
      }
    },
    %{
      name: "prelude_sources",
      authority: :private,
      snapshot: :inspection,
      operation: :effective_preludes,
      filters: ~w(component_id environment mission_name),
      order: "sequence_asc",
      sequence_domain: "private_inspection",
      identifier_locations: %{"component_id" => "component_id", "sequence" => "sequence"}
    },
    %{
      name: "execution_prints",
      authority: :private,
      snapshot: :inspection,
      operation: :execution_prints,
      filters: ~w(evaluation_id),
      order: "sequence_asc",
      sequence_domain: "private_inspection",
      identifier_locations: %{"evaluation_id" => "evaluation_id", "sequence" => "sequence"}
    },
    %{
      name: "execution_errors",
      authority: :private,
      snapshot: :inspection,
      operation: :execution_errors,
      filters: ~w(evaluation_id),
      order: "sequence_asc",
      sequence_domain: "private_inspection",
      identifier_locations: %{"evaluation_id" => "evaluation_id", "sequence" => "sequence"}
    }
  ]

  @collections_by_name Map.new(@collections, &{&1.name, &1})

  @enforce_keys [:traces, :max_result_bytes]
  defstruct [:traces, :inspection, :max_result_bytes]

  @opaque t :: %__MODULE__{
            traces: TraceSnapshot.t(),
            inspection: InspectionSnapshot.t() | nil,
            max_result_bytes: pos_integer()
          }

  @type operation :: :runs | :open | :read

  @doc false
  @spec operations() :: [operation()]
  def operations, do: @operations

  @doc false
  @spec collections() :: [map()]
  def collections, do: @collections

  @doc false
  @spec new(TraceSnapshot.t(), InspectionSnapshot.t() | nil) ::
          {:ok, t()} | {:error, :invalid_run_analysis}
  def new(traces, inspection \\ nil)

  def new(traces, inspection) do
    with true <- TraceSnapshot.valid?(traces),
         true <- is_nil(inspection) or InspectionSnapshot.valid?(inspection),
         {:ok, source} <- TraceSnapshot.source(traces),
         {:ok, trace_info} <- TraceSnapshot.info(traces),
         {:ok, inspection_info} <- inspection_info(inspection),
         true <- valid_pair?(source, trace_info, inspection_info),
         {:ok, trace_limit} <- TraceSnapshot.result_limit(traces),
         {:ok, inspection_limit} <- inspection_limit(inspection) do
      {:ok,
       %__MODULE__{
         traces: traces,
         inspection: inspection,
         max_result_bytes: min(trace_limit, inspection_limit)
       }}
    else
      _other -> {:error, :invalid_run_analysis}
    end
  end

  @spec query(t(), operation(), map()) :: {:ok, map()} | {:error, atom()}
  def query(%__MODULE__{} = analysis, operation, arguments)
      when operation in @operations and is_map(arguments),
      do: execute(analysis, operation, arguments)

  def query(_analysis, _operation, _arguments), do: {:error, :invalid_query}

  @doc false
  @spec collect(t(), binary(), binary(), pos_integer()) :: {:ok, map()} | {:error, atom()}
  def collect(%__MODULE__{} = analysis, run_id, collection, max_items)
      when is_binary(run_id) and is_binary(collection) and is_integer(max_items) and
             max_items > 0 do
    collect_pages(analysis, run_id, collection, max_items, nil, [], nil, {%{}, 0})
  end

  def collect(_analysis, _run_id, _collection, _max_items), do: {:error, :invalid_query}

  defp execute(analysis, :runs, arguments) do
    with :ok <-
           validate_keys(
             arguments,
             ~w(limit cursor status run_id trace_id tags name bundle model provider from to)
           ),
         :ok <- validate_limit(arguments) do
      TraceSnapshot.query(analysis.traces, :list_runs, arguments)
    end
  end

  defp execute(analysis, :open, %{"run_id" => run_id} = arguments) do
    with :ok <- validate_keys(arguments, ["run_id"]),
         true <- valid_string?(run_id),
         {:ok, run} <- TraceSnapshot.query(analysis.traces, :get_run, arguments),
         {:ok, inspection} <- inspection_run(analysis.inspection, run_id),
         {:ok, result} <- inspection_result(analysis.inspection, run_id) do
      private_available? = inspection["available?"] == true

      bounded_result(analysis, %{
        "run" => run,
        "inspection" => inspection,
        "result" => result,
        "collections" => collection_catalog(private_available?)
      })
    else
      false -> {:error, :invalid_query}
      {:error, _reason} = error -> error
    end
  end

  defp execute(_analysis, :open, _arguments), do: {:error, :invalid_query}

  defp execute(analysis, :read, %{"run_id" => run_id, "collection" => name} = arguments) do
    with true <- valid_string?(run_id) and is_binary(name),
         {:ok, collection} <- fetch_collection(name),
         :ok <- validate_read_arguments(arguments, collection),
         {:ok, _run} <- TraceSnapshot.query(analysis.traces, :get_run, %{"run_id" => run_id}),
         :ok <- authorize_collection(analysis, collection) do
      query = Map.drop(arguments, ["collection"])
      read_collection(analysis, collection, query)
    else
      false -> {:error, :invalid_query}
      {:error, _reason} = error -> error
    end
  end

  defp execute(_analysis, :read, _arguments), do: {:error, :invalid_query}

  defp fetch_collection(name) do
    case Map.fetch(@collections_by_name, name) do
      {:ok, collection} -> {:ok, collection}
      :error -> {:error, :invalid_query}
    end
  end

  defp authorize_collection(_analysis, %{authority: :public}), do: :ok

  defp authorize_collection(%{inspection: nil}, %{authority: :private}),
    do: {:error, :evidence_unavailable}

  defp authorize_collection(%{inspection: inspection}, %{authority: :private}) do
    if InspectionSnapshot.valid?(inspection), do: :ok, else: {:error, :evidence_unavailable}
  end

  defp read_collection(analysis, %{snapshot: :traces, operation: operation}, query),
    do: TraceSnapshot.query(analysis.traces, operation, query)

  defp read_collection(analysis, %{snapshot: :inspection, operation: operation}, query) do
    case InspectionSnapshot.query(analysis.inspection, operation, query) do
      {:error, :not_found} -> {:error, :evidence_unavailable}
      result -> result
    end
  end

  defp validate_read_arguments(arguments, collection) do
    allowed = ["run_id", "collection", "limit", "cursor" | collection.filters]

    case validate_keys(arguments, allowed) do
      :ok -> validate_limit(arguments)
      {:error, _reason} = error -> error
    end
  end

  defp collection_catalog(private_available?) do
    Enum.map(@collections, fn collection ->
      %{
        "name" => collection.name,
        "authority" => Atom.to_string(collection.authority),
        "available?" => collection.authority == :public or private_available?,
        "filters" => collection.filters,
        "order" => collection.order,
        "snapshot_domain" => snapshot_domain(collection.snapshot),
        "sequence_domain" => collection.sequence_domain,
        "identifier_locations" => collection.identifier_locations
      }
      |> put_catalog_option(collection, :item_completeness_field)
    end)
  end

  defp put_catalog_option(catalog, collection, key) do
    case Map.fetch(collection, key) do
      {:ok, value} -> Map.put(catalog, Atom.to_string(key), value)
      :error -> catalog
    end
  end

  defp snapshot_domain(:traces), do: "canonical_trace"
  defp snapshot_domain(:inspection), do: "private_inspection"

  defp inspection_run(nil, _run_id), do: {:ok, %{"available?" => false}}

  defp inspection_run(inspection, run_id) do
    case InspectionSnapshot.query(inspection, :get_run, %{"run_id" => run_id}) do
      {:ok, run} -> {:ok, Map.put(run, "available?", true)}
      {:error, :not_found} -> {:ok, %{"available?" => false}}
      {:error, _reason} = error -> error
    end
  end

  defp inspection_result(nil, _run_id), do: {:ok, %{"available?" => false}}

  defp inspection_result(inspection, run_id) do
    case InspectionSnapshot.query(inspection, :result, %{"run_id" => run_id}) do
      {:ok, result} ->
        {:ok, Map.put(result, "available?", true)}

      {:error, reason} when reason in [:not_found, :result_not_found] ->
        {:ok, %{"available?" => false}}

      {:error, _reason} = error ->
        error
    end
  end

  defp collect_pages(
         _analysis,
         _run_id,
         _collection,
         _max_items,
         _cursor,
         _items,
         _hash,
         {_metadata, @max_collect_pages}
       ),
       do: {:error, :result_limit_exceeded}

  defp collect_pages(
         analysis,
         run_id,
         collection,
         max_items,
         cursor,
         items,
         hash,
         {metadata, pages}
       ) do
    remaining = max_items - length(items)

    if remaining <= 0 do
      {:error, :result_limit_exceeded}
    else
      arguments = %{
        "run_id" => run_id,
        "collection" => collection,
        "limit" => min(remaining, @collect_page_limit)
      }

      arguments = if cursor, do: Map.put(arguments, "cursor", cursor), else: arguments

      with {:ok, page} <- query(analysis, :read, arguments),
           next_items = items ++ page["items"],
           true <- length(next_items) <= max_items do
        next_metadata =
          page
          |> Map.drop(~w(items next_cursor truncated omitted_count snapshot_hash))
          |> Map.merge(metadata)

        collected =
          Map.merge(next_metadata, %{
            "items" => next_items,
            "next_cursor" => nil,
            "truncated" => false,
            "omitted_count" => 0,
            "snapshot_hash" => hash || page["snapshot_hash"]
          })

        continue_collection(
          bounded_result(analysis, collected),
          page["next_cursor"],
          {
            analysis,
            run_id,
            collection,
            max_items,
            next_items,
            hash || page["snapshot_hash"],
            {next_metadata, pages + 1}
          }
        )
      else
        false -> {:error, :result_limit_exceeded}
        {:error, _reason} = error -> error
      end
    end
  end

  defp continue_collection({:ok, collected}, nil, _context),
    do: {:ok, collected}

  defp continue_collection(
         {:ok, _collected},
         cursor,
         {analysis, run_id, collection, max_items, items, hash, state}
       ),
       do: collect_pages(analysis, run_id, collection, max_items, cursor, items, hash, state)

  defp continue_collection({:error, _reason} = error, _cursor, _context),
    do: error

  defp valid_pair?(source, _trace_info, nil)
       when source in [:ptc_trace_snapshot, :ptc_private_trace_snapshot],
       do: true

  defp valid_pair?(source, trace_info, inspection_info)
       when source in [:ptc_trace_snapshot, :ptc_private_trace_snapshot],
       do: trace_info.capture_id == inspection_info.trace_capture_id

  defp valid_pair?(_source, _trace_info, _inspection_info), do: false

  defp inspection_info(nil), do: {:ok, nil}
  defp inspection_info(inspection), do: InspectionSnapshot.info(inspection)

  defp inspection_limit(nil), do: {:ok, 1_000_000}
  defp inspection_limit(inspection), do: InspectionSnapshot.result_limit(inspection)

  defp validate_keys(arguments, allowed) do
    if Map.keys(arguments) -- allowed == [], do: :ok, else: {:error, :invalid_query}
  end

  defp validate_limit(%{"limit" => limit}) when limit in 1..@max_limit, do: :ok
  defp validate_limit(arguments) when not is_map_key(arguments, "limit"), do: :ok
  defp validate_limit(_arguments), do: {:error, :invalid_query}

  defp valid_string?(value),
    do: is_binary(value) and byte_size(value) in 1..4_096 and String.valid?(value)

  defp bounded_result(%__MODULE__{max_result_bytes: max_result_bytes}, result) do
    if byte_size(Jason.encode!(result)) <= max_result_bytes,
      do: {:ok, result},
      else: {:error, :result_limit_exceeded}
  end
end
