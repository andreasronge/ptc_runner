defmodule PtcRunner.Kernel.ApplicationPackage do
  @moduledoc """
  Immutable, path-free application semantics and captured source closure.

  Directory and memory adapters feed the same manifest decoder and bounded
  document source. The resulting package contains portable logical names,
  effective component bytes, compiled contracts, safe override identities,
  aggregate accounting, a semantic-runtime revision, and the canonical
  `application_content_digest`; it contains no application directory, file
  descriptor, reader callback, selected input, or input name.

  Directory acquisition caches every referenced byte exactly once. Compilation
  never reopens a captured path. This prevents time-of-check/time-of-use drift
  within one acquired record, but it is not a transactional multi-file
  snapshot: trusted deployments must keep the application directory quiescent
  while its closure is acquired.

  Content identity is SHA-256 over
  `"ptc.application-content.v2\\0"`, a big-endian `u32` record count, and
  records sorted by kind byte then UTF-8 logical name. Each record is
  `kind || u32(name-bytes) || name || u64(payload-bytes) || payload`.
  The closed kinds are projected-manifest `0x01`, effective-local-source
  `0x02`, shipped-library-source `0x03`, input-contract `0x04`,
  result-contract `0x05`, direct-dependencies `0x06`, and verified-override
  identity `0x07`. Component records use `workflow/<id>` or
  `mission/<mission-name>/<id>`;
  contract names are `input` and `result`. Duplicate kind/name pairs are
  invalid. Manifest, dependency, and override payloads use
  `PtcRunner.Kernel.TypedCanonicalJSON`; source and contract payloads retain
  their exact captured UTF-8 bytes. The complete framed projection is capped
  at 8 MiB, so selecting the same captured source under multiple component IDs
  charges its bytes for every semantic occurrence instead of amplifying one
  cached document without bound.
  """

  alias PtcRunner.Kernel.ApplicationSource
  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.ConfinedFile
  alias PtcRunner.Kernel.ExecutionInput
  alias PtcRunner.Kernel.ExecutionPolicy
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.Manifest
  alias PtcRunner.Kernel.ModelContract
  alias PtcRunner.Kernel.ReplLimitProfile
  alias PtcRunner.Kernel.RunRequest
  alias PtcRunner.Kernel.SemanticRevision
  alias PtcRunner.Kernel.StrictJSON
  alias PtcRunner.Kernel.TypedCanonicalJSON
  alias PtcRunner.Kernel.ValueContract

  @content_domain <<"ptc.application-content.v3", 0>>
  @max_records 512
  @max_bytes 8_388_608
  @max_input_bytes 2_000_000
  @input_marker %{"$ptc_input" => "excluded"}
  @common_acquisition_options [:installed_limits, :input_authority, :input]
  @directory_acquisition_options @common_acquisition_options ++
                                   [:component_override_descriptor]
  @memory_acquisition_options @common_acquisition_options ++ [:component_override]
  @directory_request_options @directory_acquisition_options ++
                               [:inspection_capture, :result_projection, :event_identity]
  @memory_request_options @memory_acquisition_options ++
                            [:inspection_capture, :result_projection, :event_identity]

  @enforce_keys [
    :manifest,
    :workflow_components,
    :workflow_component_kinds,
    :entry,
    :contracts,
    :contract_sources,
    :missions,
    :providers,
    :limits,
    :installed_limits,
    :events,
    :labels,
    :component_overrides,
    :contract_behavior_hashes,
    :contract_prompt_projections,
    :contract_prompt_hashes,
    :application_content_digest,
    :document_count,
    :document_bytes,
    :ptc_semantic_revision
  ]
  defstruct @enforce_keys ++ [attestation: nil]
  @field_keys Enum.sort([:__struct__, :attestation | @enforce_keys])

  @type t :: %__MODULE__{
          manifest: map(),
          workflow_components: [PtcRunner.Kernel.Component.t()],
          workflow_component_kinds: %{binary() => :local | :library},
          entry: binary(),
          contracts: %{input: ValueContract.t() | nil, result: ValueContract.t() | nil},
          contract_sources: %{input: binary() | nil, result: binary() | nil},
          missions: map(),
          providers: %{workflow: [map()], mission: [map()]},
          limits: Limits.t(),
          installed_limits: Limits.t(),
          events: map(),
          labels: map(),
          component_overrides: [map()],
          contract_behavior_hashes: %{input: binary() | nil, result: binary() | nil},
          contract_prompt_projections: %{result: term() | nil, phase_returns: map()},
          contract_prompt_hashes: %{result: binary() | nil, phase_returns: map()},
          application_content_digest: binary(),
          document_count: non_neg_integer(),
          document_bytes: non_neg_integer(),
          ptc_semantic_revision: binary(),
          attestation: binary() | nil
        }

  @spec acquire_directory(binary(), keyword()) ::
          {:ok, t(), ExecutionInput.t()} | {:error, term()}
  @doc """
  Acquires one confined-directory application into a path-free package.

  Options are exactly `:installed_limits`, `:input_authority`, `:input`, and
  `:component_override_descriptor`. Unknown and duplicate options fail before
  the application source is opened.
  """
  def acquire_directory(path, opts \\ [])

  def acquire_directory(path, opts) when is_binary(path) and is_list(opts) do
    with :ok <- validate_options(opts, @directory_acquisition_options),
         do: do_acquire_directory(path, opts)
  end

  def acquire_directory(_path, _opts), do: {:error, :invalid_application_source}

  @spec acquire_memory(binary(), %{binary() => binary()}, keyword()) ::
          {:ok, t(), ExecutionInput.t()} | {:error, term()}
  @doc """
  Acquires one trusted in-memory logical-name/bytes application.

  Options are exactly `:installed_limits`, `:input_authority`, `:input`, and
  `:component_override`. Unknown and duplicate options fail before the
  application source is opened.
  """
  def acquire_memory(manifest_name, documents, opts \\ [])

  def acquire_memory(manifest_name, documents, opts)
      when is_binary(manifest_name) and is_map(documents) and is_list(opts) do
    with :ok <- validate_options(opts, @memory_acquisition_options),
         do: do_acquire_memory(manifest_name, documents, opts)
  end

  def acquire_memory(_manifest_name, _documents, _opts),
    do: {:error, :invalid_application_source}

  @spec request_directory(binary(), keyword()) :: {:ok, RunRequest.t()} | {:error, term()}
  @doc """
  Acquires and seals one complete directory-backed run request.

  In addition to the directory-acquisition options, accepts exactly
  `:inspection_capture`, `:result_projection`, and `:event_identity`. The
  latter fixes both event IDs and is rejected when the manifest already owns
  either identity.
  """
  def request_directory(path, opts \\ [])

  def request_directory(path, opts) when is_binary(path) and is_list(opts) do
    with :ok <- validate_options(opts, @directory_request_options),
         do: request_directory_with_profile(path, opts, false)
  end

  def request_directory(_path, _opts), do: {:error, :invalid_application_source}

  @doc false
  @spec request_repl_directory(binary(), keyword(), boolean()) ::
          {:ok, RunRequest.t()} | {:error, term()}
  def request_repl_directory(path, opts, interactive_loop?)
      when is_binary(path) and is_list(opts) and is_boolean(interactive_loop?) do
    with :ok <- validate_options(opts, @directory_request_options),
         do: request_directory_with_profile(path, opts, interactive_loop?)
  end

  def request_repl_directory(_path, _opts, _interactive_loop?),
    do: {:error, :invalid_application_source}

  defp request_directory_with_profile(path, opts, interactive_loop?) do
    acquisition_opts = Keyword.put(opts, :repl_interactive_loop, interactive_loop?)

    with {:ok, package, input} <- do_acquire_directory(path, acquisition_opts),
         {:ok, policy} <- execution_policy(package, opts),
         do: RunRequest.new(package, input, policy)
  end

  @spec request_memory(binary(), %{binary() => binary()}, keyword()) ::
          {:ok, RunRequest.t()} | {:error, term()}
  @doc """
  Acquires and seals one complete memory-backed run request.

  In addition to the memory-acquisition options, accepts exactly
  `:inspection_capture`, `:result_projection`, and `:event_identity`. The
  latter fixes both event IDs and is rejected when the manifest already owns
  either identity.
  """
  def request_memory(manifest_name, documents, opts \\ [])

  def request_memory(manifest_name, documents, opts)
      when is_binary(manifest_name) and is_map(documents) and is_list(opts) do
    with :ok <- validate_options(opts, @memory_request_options),
         {:ok, package, input} <- do_acquire_memory(manifest_name, documents, opts),
         {:ok, policy} <- execution_policy(package, opts),
         do: RunRequest.new(package, input, policy)
  end

  def request_memory(_manifest_name, _documents, _opts),
    do: {:error, :invalid_application_source}

  @spec valid?(term()) :: boolean()
  @doc "Checks the package's in-VM construction attestation."
  def valid?(%__MODULE__{attestation: attestation} = package),
    do:
      Enum.sort(Map.keys(package)) == @field_keys and
        package.ptc_semantic_revision == SemanticRevision.current() and
        Attestation.valid?(__MODULE__, payload(package), attestation)

  def valid?(_package), do: false

  defp do_acquire_directory(path, opts) do
    with {:ok, source} <- ApplicationSource.open_directory(path) do
      acquire_source(source, directory_override(source, opts), opts)
    end
  end

  defp do_acquire_memory(manifest_name, documents, opts) do
    with {:ok, source} <- ApplicationSource.open_memory(manifest_name, documents) do
      acquire_source(source, memory_override(source, opts), opts)
    end
  end

  defp validate_options(opts, allowed) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      cond do
        keys -- allowed != [] or length(keys) != MapSet.size(MapSet.new(keys)) ->
          {:error, :invalid_application_options}

        not valid_optional_installed_limits?(opts) ->
          {:error, :invalid_installed_limits}

        true ->
          :ok
      end
    else
      {:error, :invalid_application_options}
    end
  end

  defp valid_optional_installed_limits?(opts) do
    case Keyword.fetch(opts, :installed_limits) do
      {:ok, limits} -> Limits.valid?(limits)
      :error -> true
    end
  end

  defp acquire_source(source, override_result, opts) do
    installed_limits = Keyword.get(opts, :installed_limits, Limits.installed_defaults())

    try do
      with true <- Limits.valid?(installed_limits),
           {:ok, manifest} <-
             Manifest.load_source(source, installed_limits, materialize_input: false),
           {:ok, manifest} <-
             ReplLimitProfile.apply_manifest(
               manifest,
               Keyword.get(opts, :repl_interactive_loop, false)
             ),
           {:ok, input} <- select_input(source, manifest, opts),
           {:ok, override} <- override_result,
           {:ok, effective, identities} <- apply_override(manifest, override),
           {:ok, accounting} <- ApplicationSource.finish(source),
           {:ok, package} <- build(effective, identities, accounting) do
        {:ok, package, input}
      else
        false -> {:error, :invalid_installed_limits}
        {:error, _reason} = error -> error
        _invalid -> {:error, :invalid_application_package}
      end
    after
      ApplicationSource.close(source)
    end
  end

  defp select_input(source, manifest, opts) do
    authority = Keyword.get(opts, :input_authority, :normal)

    case Keyword.get(opts, :input) do
      nil ->
        select_declared_input(source, manifest, authority)

      path when is_binary(path) ->
        result =
          with {:ok, raw} <- read_selected_input(source, path),
               {:ok, value} <- StrictJSON.decode(raw) do
            ExecutionInput.new(value, authority, manifest.contracts.input)
          end

        source_error(result, :external_input)

      _invalid ->
        {:error, :invalid_input}
    end
  end

  # CLI `--input` / `--private-input` are host authority, like component
  # overrides: try an application-relative logical name first, then an absolute
  # or process-cwd path for directory sources only. Memory acquisition stays
  # logical-name-only so an API caller cannot silently pull bytes from the host
  # filesystem. Application-relative names win when the same spelling exists
  # both under the application and under the process working directory.
  defp read_selected_input(source, path) do
    if ApplicationSource.valid_name?(path) do
      case ApplicationSource.read_reference(source, path, @max_input_bytes) do
        {:ok, _raw} = ok ->
          ok

        {:error, reason} when reason in [:reference_missing, :invalid_logical_name] ->
          # Directory resolve_reference maps a missing application document to
          # `:invalid_logical_name`; treat both as a miss so a cwd/absolute host
          # path with the same spelling can still load.
          read_expanded_or_host_input(source, path)

        {:error, _reason} = error ->
          error
      end
    else
      read_expanded_or_host_input(source, path)
    end
  end

  defp read_expanded_or_host_input(source, path) do
    case ApplicationSource.logical_name(source, path) do
      {:ok, name} ->
        ApplicationSource.read_reference(source, name, @max_input_bytes)

      {:error, _reason} ->
        read_host_input_if_directory(source, path)
    end
  end

  defp read_host_input_if_directory(source, path) do
    if ApplicationSource.directory?(source) do
      read_host_input(path)
    else
      {:error, :reference_missing}
    end
  end

  defp read_host_input(path) do
    with {:ok, canonical} <- ConfinedFile.resolve_absolute(Path.expand(path)),
         directory = Path.dirname(canonical),
         {:ok, bytes} <-
           ConfinedFile.read(directory, Path.basename(canonical), @max_input_bytes) do
      {:ok, bytes}
    else
      {:error, :too_large} ->
        {:error, :document_limit_exceeded}

      {:error, _reason} ->
        {:error, :reference_missing}
    end
  end

  defp select_declared_input(source, manifest, authority) do
    case manifest.input_declaration do
      %{"value" => value} ->
        ExecutionInput.new(value, authority, manifest.contracts.input)

      %{"path" => name} ->
        with {:ok, raw} <- ApplicationSource.read_reference(source, name, @max_input_bytes),
             {:ok, value} <- StrictJSON.decode(raw) do
          ExecutionInput.new(value, authority, manifest.contracts.input)
        end
    end
  end

  defp directory_override(source, opts) do
    case Keyword.get(opts, :component_override_descriptor) do
      nil ->
        {:ok, nil}

      path ->
        case ApplicationSource.logical_name(source, path) do
          {:ok, descriptor_name} ->
            ComponentOverride.load_application(source, descriptor_name)
            |> case do
              {:ok, override} -> {:ok, {override, :captured}}
              {:error, _reason} = error -> source_error(error, :component_override)
            end

          {:error, :outside_application_source} ->
            ComponentOverride.load(path)
            |> case do
              {:ok, override} -> {:ok, {override, :external}}
              {:error, _reason} = error -> source_error(error, :component_override)
            end

          {:error, :invalid_logical_name} ->
            source_error({:error, :invalid_override_descriptor}, :component_override)
        end
    end
  end

  defp memory_override(source, opts) do
    case Keyword.get(opts, :component_override) do
      nil ->
        {:ok, nil}

      {descriptor_name, candidate_name}
      when is_binary(descriptor_name) and is_binary(candidate_name) ->
        ComponentOverride.load_application(source, descriptor_name, candidate_name)
        |> case do
          {:ok, override} -> {:ok, {override, :captured}}
          {:error, _reason} = error -> source_error(error, :component_override)
        end

      _invalid ->
        source_error({:error, :invalid_override_descriptor}, :component_override)
    end
  end

  defp apply_override(manifest, nil), do: {:ok, manifest, []}

  defp apply_override(manifest, {%ComponentOverride{} = override, accounting})
       when accounting in [:captured, :external] do
    result =
      with {:ok, workflow, missions} <- apply_qualified_override(manifest, override) do
        effective = %{manifest | workflow_components: workflow, missions: missions}
        identity = ComponentOverride.identity(override)
        {:ok, effective, [{identity, override, accounting}]}
      end

    source_error(result, :component_override)
  end

  defp source_error({:ok, _value} = success, _role), do: success
  defp source_error({:ok, _first, _second} = success, _role), do: success

  defp source_error({:error, reason}, role)
       when role in [:external_input, :component_override],
       do: {:error, {:source_role, role, reason}}

  defp apply_qualified_override(
         manifest,
         %ComponentOverride{target: %{"environment" => "workflow"}} = override
       ) do
    case ComponentOverride.apply(manifest.workflow_components, override) do
      {:ok, components, true} -> {:ok, components, manifest.missions}
      {:ok, _components, false} -> {:error, :override_component_not_selected}
      {:error, _reason} = error -> error
    end
  end

  defp apply_qualified_override(
         manifest,
         %ComponentOverride{target: %{"environment" => "mission", "mission" => name}} = override
       ) do
    with {:ok, mission} <- Map.fetch(manifest.missions, name),
         {:ok, components, true} <- ComponentOverride.apply(mission.components, override) do
      {:ok, manifest.workflow_components,
       Map.put(manifest.missions, name, %{mission | components: components})}
    else
      :error -> {:error, :override_component_not_selected}
      {:ok, _components, false} -> {:error, :override_component_not_selected}
      {:error, _reason} = error -> error
    end
  end

  defp build(manifest, override_pairs, accounting) do
    # The package-facing projection keeps the resolved environment and adds
    # operator-asserted authorship, so an artifact names both the base and the
    # candidate and where the substitution landed. Content records are built
    # separately in `override_records/1` from the same pairs and must not gain
    # either: their name already encodes the environment, and authorship claims
    # are not content, so `application_content_digest` stays content-derived.
    identities =
      Enum.map(override_pairs, fn {identity, override, _accounting} ->
        Map.merge(identity, ComponentOverride.attribution(override))
      end)

    with {:ok, records} <- content_records(manifest, override_pairs),
         {:ok, contract_behavior_hashes} <- contract_behavior_hashes(manifest.contracts),
         {:ok, contract_prompt_projections, contract_prompt_hashes} <-
           contract_prompt_data(manifest.contracts),
         {:ok, document_count, document_bytes} <-
           complete_accounting(manifest, override_pairs, accounting),
         {:ok, digest} <- content_digest(records) do
      package = %__MODULE__{
        manifest: Map.put(manifest.document, "input", @input_marker),
        workflow_components: manifest.workflow_components,
        workflow_component_kinds: manifest.workflow_component_kinds,
        entry: manifest.entry,
        contracts: manifest.contracts,
        contract_sources: manifest.contract_sources,
        missions: manifest.missions,
        providers: manifest.providers,
        limits: manifest.limits,
        installed_limits: manifest.installed_limits,
        events: manifest.events,
        labels: manifest.labels,
        component_overrides: identities,
        contract_behavior_hashes: contract_behavior_hashes,
        contract_prompt_projections: contract_prompt_projections,
        contract_prompt_hashes: contract_prompt_hashes,
        application_content_digest: digest,
        document_count: document_count,
        document_bytes: document_bytes,
        ptc_semantic_revision: SemanticRevision.current()
      }

      {:ok, %{package | attestation: Attestation.attest(__MODULE__, payload(package))}}
    end
  end

  defp content_records(manifest, override_pairs) do
    with {:ok, projected_manifest} <-
           manifest.document
           |> Map.put("input", @input_marker)
           |> TypedCanonicalJSON.encode(),
         {:ok, workflow} <-
           component_records(
             "workflow",
             manifest.workflow_components,
             manifest.workflow_component_kinds
           ),
         {:ok, mission} <- mission_component_records(manifest.missions),
         {:ok, contracts} <- contract_records(manifest),
         {:ok, overrides} <- override_records(override_pairs) do
      records = [{0x01, "", projected_manifest} | workflow ++ mission ++ contracts ++ overrides]

      if unique_records?(records),
        do: {:ok, records},
        else: {:error, :duplicate_application_record}
    end
  end

  defp mission_component_records(missions) do
    Enum.reduce_while(missions, {:ok, []}, fn {name, mission}, {:ok, records} ->
      case component_records("mission/" <> name, mission.components, mission.kinds) do
        {:ok, next} -> {:cont, {:ok, records ++ next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp component_records(environment, components, kinds) do
    Enum.reduce_while(components, {:ok, []}, fn component, {:ok, records} ->
      name = environment <> "/" <> component.id
      source_kind = if Map.fetch!(kinds, component.id) == :local, do: 0x02, else: 0x03

      case TypedCanonicalJSON.encode(component.dependencies) do
        {:ok, dependencies} ->
          {:cont,
           {:ok,
            [
              {0x06, name, dependencies},
              {source_kind, name, component.source}
              | records
            ]}}

        {:error, _reason} ->
          {:halt, {:error, :invalid_application_package}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, _reason} = error -> error
    end
  end

  defp contract_records(manifest) do
    records =
      ([
         contract_record(0x04, "input", manifest.contract_sources.input),
         contract_record(0x05, "result", manifest.contract_sources.result)
       ] ++
         Enum.map(manifest.contract_sources.phase_returns, fn {name, source} ->
           contract_record(0x08, name, source)
         end))
      |> Enum.reject(&is_nil/1)

    {:ok, records}
  end

  defp contract_record(_kind, _name, nil), do: nil
  defp contract_record(kind, name, source), do: {kind, name, source}

  defp contract_behavior_hashes(contracts) do
    with {:ok, input} <- contract_behavior_hash(contracts.input),
         {:ok, result} <- contract_behavior_hash(contracts.result),
         {:ok, phase_returns} <-
           map_contract_hashes(contracts.phase_returns, &contract_behavior_hash/1) do
      {:ok, %{input: input, result: result, phase_returns: phase_returns}}
    end
  end

  defp contract_behavior_hash(nil), do: {:ok, nil}

  defp contract_behavior_hash(%ValueContract{} = contract),
    do: {:ok, ValueContract.behavior_hash(contract)}

  defp contract_behavior_hash(_contract), do: {:error, :invalid_application_package}

  defp contract_prompt_data(%{result: result, phase_returns: phase_returns}) do
    bindings = [{:result, result} | Enum.sort_by(phase_returns, &elem(&1, 0))]

    Enum.reduce_while(bindings, {:ok, %{}, %{}, 0}, fn {name, contract},
                                                       {:ok, projections, hashes, aggregate} ->
      case contract_prompt_binding(contract) do
        {:ok, projection, hash, bytes} when aggregate + bytes <= 1_048_576 ->
          {:cont,
           {:ok, Map.put(projections, name, projection), Map.put(hashes, name, hash),
            aggregate + bytes}}

        _overflow ->
          {:halt, {:error, :contract_projection_limit_exceeded}}
      end
    end)
    |> case do
      {:ok, projections, hashes, _bytes} ->
        {:ok,
         %{
           result: Map.get(projections, :result),
           phase_returns: Map.delete(projections, :result)
         }, %{result: Map.get(hashes, :result), phase_returns: Map.delete(hashes, :result)}}

      {:error, _reason} = error ->
        error
    end
  end

  defp contract_prompt_data(_contracts), do: {:error, :invalid_application_package}

  defp contract_prompt_binding(nil), do: {:ok, nil, nil, 0}

  defp contract_prompt_binding(%ValueContract{} = contract) do
    with {:ok, projection} <- ModelContract.value_contract(contract),
         {:ok, json} <- PtcRunner.Kernel.DeterministicJSON.encode(projection),
         {:ok, value} <- Jason.decode(json),
         {:ok, encoded} <- TypedCanonicalJSON.encode(value),
         true <- byte_size(encoded) <= 262_144,
         {:ok, hash} <- ModelContract.projection_hash(projection) do
      {:ok, projection, hash, byte_size(encoded)}
    else
      _unsupported -> {:error, :contract_projection_limit_exceeded}
    end
  end

  defp map_contract_hashes(contracts, mapper) do
    Enum.reduce_while(contracts, {:ok, %{}}, fn {name, contract}, {:ok, hashes} ->
      case mapper.(contract) do
        {:ok, hash} -> {:cont, {:ok, Map.put(hashes, name, hash)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp override_records(pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn {identity, _override, _accounting}, {:ok, records} ->
      name = override_target_name(identity["target"]) <> "/" <> identity["component_id"]
      safe = identity

      case TypedCanonicalJSON.encode(safe) do
        {:ok, encoded} -> {:cont, {:ok, [{0x07, name, encoded} | records]}}
        {:error, _reason} -> {:halt, {:error, :invalid_application_package}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, _reason} = error -> error
    end
  end

  defp override_target_name(%{"environment" => "workflow"}), do: "workflow"

  defp override_target_name(%{"environment" => "mission", "mission" => name}),
    do: "mission/" <> name

  defp unique_records?(records) do
    identities = Enum.map(records, fn {kind, name, _payload} -> {kind, name} end)
    identities == Enum.uniq(identities)
  end

  defp content_digest(records) do
    records = Enum.sort_by(records, fn {kind, name, _payload} -> {kind, name} end)

    if framed_content_bytes(records) <= @max_bytes do
      framed =
        [
          @content_domain,
          <<length(records)::unsigned-big-32>>,
          Enum.map(records, fn {kind, name, record_payload} ->
            [
              <<kind>>,
              <<byte_size(name)::unsigned-big-32>>,
              name,
              <<byte_size(record_payload)::unsigned-big-64>>,
              record_payload
            ]
          end)
        ]

      {:ok, :crypto.hash(:sha256, framed) |> Base.encode16(case: :lower)}
    else
      {:error, :document_limit_exceeded}
    end
  end

  defp framed_content_bytes(records) do
    Enum.reduce(records, byte_size(@content_domain) + 4, fn {_kind, name, payload}, total ->
      total + 1 + 4 + byte_size(name) + 8 + byte_size(payload)
    end)
  end

  defp complete_accounting(manifest, override_pairs, accounting) do
    with {:ok, library_components} <- original_library_components(manifest) do
      inline_input =
        case manifest.document["input"] do
          %{"value" => value} ->
            {:ok, encoded} = TypedCanonicalJSON.encode(value)
            [{:input, encoded}]

          _path ->
            []
        end

      override_documents =
        Enum.flat_map(override_pairs, fn
          {_identity, override, :external} ->
            [
              {:component_override, :override_descriptor, override.descriptor_bytes},
              {:component_override, :override_source, byte_size(override.source)}
            ]

          {_identity, _override, :captured} ->
            []
        end)

      added =
        Enum.map(library_components, &{nil, :library, byte_size(&1.source)}) ++
          Enum.map(inline_input, fn {kind, bytes} -> {nil, kind, byte_size(bytes)} end) ++
          override_documents

      account_documents(added, accounting)
    end
  end

  defp account_documents(documents, accounting) do
    initial = {:ok, accounting.document_count, accounting.document_bytes}
    Enum.reduce_while(documents, initial, &account_document/2)
  end

  defp account_document({role, _kind, byte_count}, {:ok, count, bytes}) do
    next_count = count + 1
    next_bytes = bytes + byte_count

    if next_count <= @max_records and next_bytes <= @max_bytes,
      do: {:cont, {:ok, next_count, next_bytes}},
      else: {:halt, document_limit_error(role)}
  end

  defp document_limit_error(nil), do: {:error, :document_limit_exceeded}

  defp document_limit_error(role),
    do: {:error, {:source_role, role, :document_limit_exceeded}}

  defp original_library_components(manifest) do
    ids =
      library_component_ids(
        manifest.workflow_components,
        manifest.workflow_component_kinds
      ) ++
        Enum.flat_map(manifest.missions, fn {_name, mission} ->
          library_component_ids(mission.components, mission.kinds)
        end)

    ids
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, components} ->
      case Library.component(id) do
        {:ok, component} -> {:cont, {:ok, [component | components]}}
        {:error, _reason} -> {:halt, {:error, :invalid_application_package}}
      end
    end)
    |> case do
      {:ok, components} -> {:ok, Enum.reverse(components)}
      {:error, _reason} = error -> error
    end
  end

  defp library_component_ids(components, kinds),
    do:
      for(component <- components, Map.fetch!(kinds, component.id) == :library, do: component.id)

  defp execution_policy(package, opts) do
    with {:ok, run_id, trace_id} <- event_identity(package.events, opts) do
      ExecutionPolicy.new(
        event_policy: package.events.policy,
        run_id: run_id,
        trace_id: trace_id,
        inspection_capture: Keyword.get(opts, :inspection_capture, false),
        result_projection: Keyword.get(opts, :result_projection, :native)
      )
    end
  end

  defp event_identity(events, opts) do
    case Keyword.fetch(opts, :event_identity) do
      :error ->
        {:ok, events.run_id, events.trace_id}

      {:ok, identity} when is_nil(events.run_id) and is_nil(events.trace_id) ->
        {:ok, identity, identity}

      {:ok, _identity} ->
        {:error, :event_identity_conflict}
    end
  end

  defp payload(package) do
    package
    |> Map.from_struct()
    |> Map.delete(:attestation)
  end
end
