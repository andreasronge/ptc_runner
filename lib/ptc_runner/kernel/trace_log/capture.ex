defmodule PtcRunner.Kernel.TraceLog.Capture do
  @moduledoc "Immutable canonical file and directory capture, inventory and admission."

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.TraceDirectoryAdmission
  alias PtcRunner.Kernel.TraceLog.Query

  import PtcRunner.Kernel.TraceLog.Source,
    only: [decode_jsonl: 1, validate_loaded: 2, digest: 1, private_path?: 1, reserved_path?: 1]

  @default_source_bytes 8_000_000
  @default_capture_directory_entries 4_096
  @default_capture_trace_files 1_024
  @capture_listing_timeout_ms 5_000
  @capture_listing_heap_words 1_000_000

  @doc false
  @spec capture_directory(binary(), keyword()) ::
          {:ok,
           %{
             events: [map()],
             run_sources: %{binary() => :sanitized | :private},
             source_id: binary(),
             source_bytes: non_neg_integer(),
             file_count: non_neg_integer(),
             excluded_trace_files: %{optional(binary()) => pos_integer()}
           }}
          | {:error, atom()}
  def capture_directory(directory, opts \\ [])

  def capture_directory(directory, opts) when is_binary(directory) and is_list(opts) do
    with true <-
           Keyword.keys(opts) --
             [
               :max_source_bytes,
               :max_directory_entries,
               :max_trace_files,
               :source_kind,
               :include_sanitized,
               :capture_hook,
               :listing_hook
             ] == [],
         true <- String.valid?(directory),
         max_source_bytes when max_source_bytes in 1..@default_source_bytes <-
           Keyword.get(opts, :max_source_bytes, @default_source_bytes),
         max_directory_entries
         when max_directory_entries in 1..@default_capture_directory_entries <-
           Keyword.get(
             opts,
             :max_directory_entries,
             @default_capture_directory_entries
           ),
         max_trace_files when max_trace_files in 1..@default_capture_trace_files <-
           Keyword.get(opts, :max_trace_files, @default_capture_trace_files),
         source_kind when source_kind in [:sanitized, :private] <-
           Keyword.get(opts, :source_kind, :sanitized),
         include_sanitized when is_boolean(include_sanitized) <-
           Keyword.get(opts, :include_sanitized, source_kind == :private),
         capture_hook when is_nil(capture_hook) or is_function(capture_hook, 0) <-
           Keyword.get(opts, :capture_hook),
         listing_hook when is_nil(listing_hook) or is_function(listing_hook, 0) <-
           Keyword.get(opts, :listing_hook),
         {:ok, capture} <-
           capture_directory_files(
             Path.expand(directory),
             source_kind,
             max_source_bytes,
             max_directory_entries,
             max_trace_files,
             include_sanitized,
             capture_hook,
             listing_hook
           ) do
      {:ok, capture}
    else
      false -> {:error, :invalid_trace_log}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_trace_log}
    end
  rescue
    _exception -> {:error, :source_unavailable}
  end

  def capture_directory(_directory, _opts), do: {:error, :invalid_trace_log}

  @doc false
  @spec capture_file(binary(), keyword()) ::
          {:ok,
           %{
             events: [map()],
             run_sources: %{binary() => :sanitized | :private},
             source_id: binary(),
             source_bytes: non_neg_integer(),
             file_count: 1,
             excluded_trace_files: %{optional(binary()) => pos_integer()}
           }}
          | {:error, atom()}
  def capture_file(path, opts \\ [])

  def capture_file(path, opts) when is_binary(path) and is_list(opts) do
    with true <-
           Keyword.keys(opts) -- [:max_source_bytes, :source_kind, :capture_hook] == [],
         true <- String.valid?(path),
         max_source_bytes when max_source_bytes in 1..@default_source_bytes <-
           Keyword.get(opts, :max_source_bytes, @default_source_bytes),
         source_kind when source_kind in [:sanitized, :private] <-
           Keyword.get(opts, :source_kind, :sanitized),
         capture_hook when is_nil(capture_hook) or is_function(capture_hook, 0) <-
           Keyword.get(opts, :capture_hook),
         path = Path.expand(path),
         {:ok, before_inventory} <- file_inventory(path, source_kind) do
      capture_inventory(
        Path.dirname(path),
        before_inventory,
        max_source_bytes,
        capture_hook,
        fn -> changed_file_inventory(path, source_kind) end
      )
    else
      false -> {:error, :invalid_trace_log}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_trace_log}
    end
  rescue
    _exception -> {:error, :source_unavailable}
  end

  def capture_file(_path, _opts), do: {:error, :invalid_trace_log}

  @doc false
  @spec capture_selected([map()], keyword()) :: {:ok, map()} | {:error, atom()}
  def capture_selected(selected, opts \\ [])

  def capture_selected(selected, opts) when is_list(selected) and is_list(opts) do
    with true <- Keyword.keys(opts) -- [:max_source_bytes, :capture_hook] == [],
         max_source_bytes when max_source_bytes in 1..@default_source_bytes <-
           Keyword.get(opts, :max_source_bytes, @default_source_bytes),
         capture_hook when is_nil(capture_hook) or is_function(capture_hook, 0) <-
           Keyword.get(opts, :capture_hook),
         {:ok, directory, before_inventory} <- selected_inventory(selected) do
      capture_directory_inventory(
        directory,
        before_inventory,
        max_source_bytes,
        capture_hook,
        fn -> changed_selected_inventory(selected) end,
        :selected_private_authorized
      )
    else
      false -> {:error, :invalid_trace_log}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_trace_log}
    end
  rescue
    _exception -> {:error, :source_unavailable}
  end

  def capture_selected(_selected, _opts), do: {:error, :invalid_trace_log}

  # One trace directory holds both sanitized and private artifacts, and one
  # query boundary reads exactly one kind. Staying silent about the other kind
  # made an all-private project answer an empty run listing, so name the files
  # this source kind refused to read. The count is advisory and deliberately
  # outside `source_id`: a concurrent write to the kind this boundary does not
  # read must not invalidate the evidence it does read.
  defp excluded_trace_files(listed, accepted, source_kind) do
    accepted = MapSet.new(accepted)

    case Enum.count(listed, &(trace_file_name?(&1) and not MapSet.member?(accepted, &1))) do
      0 -> %{}
      excluded -> %{exclusion_key(source_kind) => excluded}
    end
  end

  defp exclusion_key(:sanitized), do: "excluded_private_trace_files"
  defp exclusion_key(:private), do: "excluded_sanitized_trace_files"

  defp trace_file_name?(name) do
    TraceDirectoryAdmission.source_kind(name) in [:sanitized, :private]
  end

  defp capture_directory_files(
         directory,
         source_kind,
         max_source_bytes,
         max_directory_entries,
         max_trace_files,
         include_sanitized,
         capture_hook,
         listing_hook
       ) do
    with {:ok, before_inventory, _initial_excluded} <-
           directory_inventory(
             directory,
             source_kind,
             max_directory_entries,
             max_trace_files,
             include_sanitized,
             listing_hook
           ) do
      capture_directory_inventory(
        directory,
        before_inventory,
        max_source_bytes,
        capture_hook,
        fn ->
          changed_inventory(
            directory,
            source_kind,
            max_directory_entries,
            max_trace_files,
            include_sanitized,
            listing_hook
          )
        end,
        directory_grant_class(source_kind, include_sanitized)
      )
    end
  end

  defp directory_grant_class(:sanitized, _include_sanitized), do: :sanitized
  defp directory_grant_class(:private, false), do: :private
  defp directory_grant_class(:private, true), do: :mixed_private_authorized

  defp capture_directory_inventory(
         directory,
         before_inventory,
         max_source_bytes,
         capture_hook,
         refresh_inventory,
         grant_class
       ) do
    with {:ok, captured_sources, source_bytes} <-
           read_directory_inventory(directory, before_inventory.files, max_source_bytes),
         :ok <- run_capture_hook(capture_hook),
         {:ok, after_read_inventory, _after_read_excluded} <- refresh_inventory.(),
         :ok <- same_inventory(before_inventory, after_read_inventory),
         :ok <- verify_directory_sources(directory, after_read_inventory.files, captured_sources),
         {:ok, after_verify_inventory, final_excluded} <- refresh_inventory.(),
         :ok <- same_inventory(after_read_inventory, after_verify_inventory),
         :ok <-
           verify_directory_sources(directory, after_verify_inventory.files, captured_sources),
         {:ok, evidence, source_proofs} <- directory_evidence(captured_sources),
         {:ok, classification} <- TraceDirectoryAdmission.classify(evidence) do
      build_directory_admission(
        grant_class,
        classification,
        source_proofs,
        source_bytes,
        final_excluded
      )
    end
  end

  defp build_directory_admission(
         grant_class,
         classification,
         source_proofs,
         source_bytes,
         excluded_trace_files
       ) do
    events = Enum.flat_map(classification.admitted, & &1.events)

    run_sources =
      Map.new(classification.admitted, fn evidence ->
        [run_id] = evidence.embedded_run_claims
        {run_id, evidence.source_kind}
      end)

    analysis = Query.compile_analysis(events, run_sources)

    identity = %{
      version: :directory_admission_v1,
      grant_class: grant_class,
      sources: directory_identity_sources(source_proofs, classification.components),
      events: events,
      run_sources: run_sources,
      isolated_components: classification.isolated
    }

    admission = %{
      version: :directory_admission_v1,
      grant_class: grant_class,
      events: events,
      run_sources: run_sources,
      analysis: analysis,
      source_id: digest(identity),
      source_bytes: source_bytes,
      file_count: length(source_proofs),
      excluded_trace_files: excluded_trace_files,
      source_proofs: source_proofs,
      components: classification.components,
      isolated_components: classification.isolated,
      known_isolated_run_ids: classification.known_isolated_run_ids
    }

    {:ok, admission}
  end

  defp directory_identity_sources(source_proofs, components) do
    classifications =
      components
      |> Enum.flat_map(& &1.sources)
      |> Map.new(&{&1.raw_name, &1})

    Enum.map(source_proofs, fn proof ->
      evidence = Map.fetch!(classifications, proof.raw_name)

      %{
        raw_name: proof.raw_name,
        source_kind: proof.source_kind,
        byte_length: proof.byte_length,
        content_digest: proof.content_digest,
        status: evidence.status,
        filename_run_claim: evidence.filename_run_claim,
        embedded_run_claims: evidence.embedded_run_claims,
        embedded_trace_claims: evidence.embedded_trace_claims,
        reasons: evidence.reasons
      }
    end)
  end

  defp capture_inventory(
         directory,
         before_inventory,
         max_source_bytes,
         capture_hook,
         refresh_inventory
       ) do
    with true <- is_function(refresh_inventory, 0),
         {:ok, sources, source_bytes} <-
           read_inventory(directory, before_inventory.files, max_source_bytes),
         :ok <- run_capture_hook(capture_hook),
         {:ok, after_read_inventory} <- refresh_inventory.(),
         :ok <- same_inventory(before_inventory, after_read_inventory),
         :ok <- verify_sources(directory, after_read_inventory.files, sources),
         {:ok, after_verify_inventory} <- refresh_inventory.(),
         :ok <- same_inventory(after_read_inventory, after_verify_inventory),
         :ok <- verify_sources(directory, after_verify_inventory.files, sources),
         {:ok, events, run_sources} <- decode_capture_sources(sources),
         {:ok, events, _event_source_id} <- validate_loaded(events, max_source_bytes) do
      source_id = digest({events, run_sources})

      {:ok,
       %{
         events: events,
         run_sources: run_sources,
         source_id: source_id,
         source_bytes: source_bytes,
         file_count: length(after_verify_inventory.files),
         excluded_trace_files: %{}
       }}
    end
  end

  defp file_inventory(path, source_kind) do
    name = Path.basename(path)

    with true <- capture_file_name?(name, source_kind),
         {:ok, %File.Stat{type: :regular} = stat} <- File.lstat(path, time: :posix) do
      {:ok, %{files: [{name, stat_identity(stat)}]}}
    else
      false -> {:error, :invalid_trace_log}
      {:ok, %File.Stat{}} -> {:error, :malformed_source}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp selected_inventory([%{path: first_path} | _rest] = selected) do
    directory = first_path |> Path.expand() |> Path.dirname()

    with true <-
           Enum.all?(selected, fn
             %{path: path, run_ref: run_ref, source_kind: source_kind}
             when is_binary(path) and is_binary(run_ref) and
                    source_kind in [:sanitized, :private] ->
               expanded = Path.expand(path)

               Path.dirname(expanded) == directory and
                 capture_file_name?(Path.basename(expanded), source_kind)

             _invalid ->
               false
           end),
         names <- Enum.map(selected, &Path.basename(&1.path)),
         true <- names == Enum.sort(names) and names == Enum.uniq(names),
         {:ok, files} <- inventory_selected_files(directory, names) do
      {:ok, directory, %{files: files}}
    else
      false -> {:error, :invalid_trace_log}
      {:error, _reason} = error -> error
    end
  end

  defp selected_inventory(_selected), do: {:error, :invalid_trace_log}

  defp changed_selected_inventory(selected) do
    case selected_inventory(selected) do
      {:ok, _directory, inventory} -> {:ok, inventory, %{}}
      {:error, _reason} -> {:error, :source_changed}
    end
  end

  defp inventory_selected_files(directory, names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, files} ->
      case File.lstat(Path.join(directory, name), time: :posix) do
        {:ok, %File.Stat{type: :regular} = stat} ->
          {:cont, {:ok, [{name, stat_identity(stat)} | files]}}

        {:ok, %File.Stat{}} ->
          {:halt, {:error, :selected_trace_not_regular}}

        {:error, _reason} ->
          {:halt, {:error, :source_unavailable}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, _reason} = error -> error
    end
  end

  defp changed_file_inventory(path, source_kind) do
    case file_inventory(path, source_kind) do
      {:ok, inventory} -> {:ok, inventory}
      {:error, _reason} -> {:error, :source_changed}
    end
  end

  defp directory_inventory(
         directory,
         source_kind,
         max_directory_entries,
         max_trace_files,
         include_sanitized,
         listing_hook
       ) do
    with {:ok, %File.Stat{type: :directory} = directory_stat} <-
           File.lstat(directory, time: :posix),
         {:ok, listed} <- bounded_directory_names(directory, max_directory_entries, listing_hook),
         {:ok, names} <-
           bounded_capture_names(listed, source_kind, include_sanitized, max_trace_files),
         {:ok, files} <- inventory_files(directory, names) do
      {:ok, %{directory: directory_root_identity(directory_stat), files: files},
       excluded_trace_files(listed, names, source_kind)}
    else
      {:ok, %File.Stat{}} -> {:error, :malformed_source}
      {:error, :source_limit_exceeded} = error -> error
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp changed_inventory(
         directory,
         source_kind,
         max_directory_entries,
         max_trace_files,
         include_sanitized,
         listing_hook
       ) do
    case directory_inventory(
           directory,
           source_kind,
           max_directory_entries,
           max_trace_files,
           include_sanitized,
           listing_hook
         ) do
      {:ok, inventory, excluded} -> {:ok, inventory, excluded}
      {:error, :source_limit_exceeded} = error -> error
      {:error, _reason} -> {:error, :source_changed}
    end
  end

  defp bounded_directory_names(directory, max_directory_entries, listing_hook) do
    case BoundedWorker.run(
           fn ->
             if listing_hook, do: listing_hook.()

             with {:ok, names} <- File.ls(directory),
                  true <- length(names) <= max_directory_entries do
               {:ok, names}
             else
               false -> {:error, :source_limit_exceeded}
               {:error, _reason} -> {:error, :source_unavailable}
             end
           end,
           timeout_ms: @capture_listing_timeout_ms,
           max_heap_words: @capture_listing_heap_words,
           cancel_with_caller: true
         ) do
      {:ok, result} -> result
      {:error, :heap_exceeded} -> {:error, :source_limit_exceeded}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp bounded_capture_names(names, source_kind, include_sanitized, max_trace_files) do
    supported = Enum.filter(names, &capture_name?(&1, source_kind, include_sanitized))

    if length(supported) <= max_trace_files,
      do: {:ok, Enum.sort(supported)},
      else: {:error, :source_limit_exceeded}
  end

  defp capture_name?(name, :sanitized, _include_sanitized),
    do: TraceDirectoryAdmission.source_kind(name) == :sanitized

  defp capture_name?(name, :private, true),
    do: TraceDirectoryAdmission.source_kind(name) in [:sanitized, :private]

  defp capture_name?(name, :private, false),
    do: TraceDirectoryAdmission.source_kind(name) == :private

  defp capture_file_name?(name, :sanitized),
    do: Path.basename(name) == name and not reserved_path?(name)

  defp capture_file_name?(name, :private),
    do: Path.basename(name) == name and private_path?(name)

  defp inventory_files(directory, names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, files} ->
      case File.lstat(directory_member_path(directory, name), time: :posix) do
        {:ok, %File.Stat{} = stat} ->
          {:cont, {:ok, [{name, stat_identity(stat)} | files]}}

        {:error, _reason} ->
          {:halt, {:error, :source_unavailable}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, _reason} = error -> error
    end
  end

  defp read_directory_inventory(directory, files, max_source_bytes) do
    source_bytes =
      Enum.reduce(files, 0, fn
        {_name, %{type: :regular, size: size}}, bytes -> bytes + size
        {_name, _identity}, bytes -> bytes
      end)

    if source_bytes <= max_source_bytes do
      Enum.reduce_while(files, {:ok, []}, fn {name, expected}, {:ok, sources} ->
        case read_directory_member(directory, name, expected) do
          {:ok, status} ->
            source = %{raw_name: name, stat_identity: expected, read_status: status}
            {:cont, {:ok, [source | sources]}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, sources} -> {:ok, Enum.reverse(sources), source_bytes}
        {:error, _reason} = error -> error
      end
    else
      {:error, :source_limit_exceeded}
    end
  end

  defp read_directory_member(directory, name, %{type: type} = expected) when type != :regular do
    path = directory_member_path(directory, name)

    with {:ok, %File.Stat{} = current} <- File.lstat(path, time: :posix),
         :ok <- same_stat_identity(expected, stat_identity(current)) do
      {:ok, :not_regular}
    else
      _changed -> {:error, :source_changed}
    end
  end

  defp read_directory_member(directory, name, expected) do
    path = directory_member_path(directory, name)

    with {:ok, %File.Stat{type: :regular} = current} <- File.lstat(path, time: :posix),
         :ok <- same_stat_identity(expected, stat_identity(current)) do
      case :file.open(path, [:read, :binary, :raw]) do
        {:ok, device} ->
          try do
            case read_inventory_device(device, expected) do
              {:ok, source} -> {:ok, {:read, source}}
              {:error, _reason} = error -> error
            end
          after
            :file.close(device)
          end

        {:error, reason} when reason in [:eacces, :eperm] ->
          confirm_unreadable_member(path, expected)

        {:error, _reason} ->
          confirm_open_failure(path, expected)
      end
    else
      {:ok, %File.Stat{}} -> {:error, :source_changed}
      {:error, :source_changed} = error -> error
      {:error, _reason} -> {:error, :source_changed}
    end
  end

  defp confirm_unreadable_member(path, expected) do
    with {:ok, %File.Stat{type: :regular} = current} <- File.lstat(path, time: :posix),
         :ok <- same_stat_identity(expected, stat_identity(current)) do
      {:ok, :unreadable}
    else
      _changed -> {:error, :source_changed}
    end
  end

  defp confirm_open_failure(path, expected) do
    with {:ok, %File.Stat{type: :regular} = current} <- File.lstat(path, time: :posix),
         :ok <- same_stat_identity(expected, stat_identity(current)) do
      {:error, :source_unavailable}
    else
      _changed -> {:error, :source_changed}
    end
  end

  defp verify_directory_sources(directory, files, captured_sources) do
    expected_sources = Map.new(captured_sources, &{&1.raw_name, &1})

    Enum.reduce_while(files, :ok, fn {name, expected}, :ok ->
      captured = Map.fetch!(expected_sources, name)

      case verify_directory_source(directory, name, expected, captured.read_status) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp verify_directory_source(directory, name, expected, expected_status) do
    case read_directory_member(directory, name, expected) do
      {:ok, ^expected_status} -> :ok
      {:ok, _changed_status} -> {:error, :source_changed}
      {:error, :source_unavailable} = error -> error
      {:error, _reason} -> {:error, :source_changed}
    end
  end

  defp directory_evidence(captured_sources) do
    Enum.reduce_while(captured_sources, {:ok, [], []}, fn source, {:ok, evidence, proofs} ->
      with {:ok, status, digest} <- directory_evidence_status(source.read_status),
           source_kind when source_kind in [:sanitized, :private] <-
             TraceDirectoryAdmission.source_kind(source.raw_name),
           {:ok, file_evidence} <-
             TraceDirectoryAdmission.evidence(source.raw_name, source_kind, status) do
        proof = %{
          raw_name: source.raw_name,
          source_kind: source_kind,
          byte_length: source.stat_identity.size,
          content_digest: digest,
          stat_identity: source.stat_identity
        }

        {:cont, {:ok, [file_evidence | evidence], [proof | proofs]}}
      else
        _invalid -> {:halt, {:error, :source_unavailable}}
      end
    end)
    |> case do
      {:ok, evidence, proofs} -> {:ok, Enum.reverse(evidence), Enum.reverse(proofs)}
      {:error, _reason} = error -> error
    end
  end

  defp directory_evidence_status(:not_regular), do: {:ok, :not_regular, nil}
  defp directory_evidence_status(:unreadable), do: {:ok, :unreadable, nil}

  defp directory_evidence_status({:read, source}) do
    digest = :crypto.hash(:sha256, source)

    case decode_jsonl(source) do
      {:ok, events} -> {:ok, {:decoded, events}, digest}
      {:error, :malformed_source} -> {:ok, :malformed_jsonl, digest}
    end
  end

  defp read_inventory(directory, files, max_source_bytes) do
    source_bytes = Enum.reduce(files, 0, fn {_name, stat}, bytes -> bytes + stat.size end)

    if source_bytes <= max_source_bytes do
      Enum.reduce_while(files, {:ok, []}, fn {name, expected}, {:ok, sources} ->
        case read_inventory_file(Path.join(directory, name), expected) do
          {:ok, source} -> {:cont, {:ok, [{name, source} | sources]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, sources} -> {:ok, Enum.reverse(sources), source_bytes}
        {:error, _reason} = error -> error
      end
    else
      {:error, :source_limit_exceeded}
    end
  end

  defp read_inventory_file(path, expected) do
    with {:ok, %File.Stat{type: :regular} = current} <- File.lstat(path, time: :posix),
         :ok <- same_stat_identity(expected, stat_identity(current)),
         {:ok, device} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        read_inventory_device(device, expected)
      after
        :file.close(device)
      end
    else
      {:ok, %File.Stat{}} -> {:error, :source_changed}
      {:error, :source_changed} = error -> error
      {:error, _reason} -> {:error, :source_changed}
    end
  end

  defp read_inventory_device(device, expected) do
    with {:ok, before_info} <- :file.read_file_info(device, time: :posix),
         :ok <-
           same_stat_identity(expected, before_info |> File.Stat.from_record() |> stat_identity()),
         {:ok, source} <- read_exact_source(device, expected.size),
         {:ok, after_info} <- :file.read_file_info(device, time: :posix),
         :ok <-
           same_stat_identity(expected, after_info |> File.Stat.from_record() |> stat_identity()) do
      {:ok, source}
    else
      {:error, :source_changed} = error -> error
      {:error, _reason} -> {:error, :source_changed}
    end
  end

  defp read_exact_source(device, 0) do
    case :file.read(device, 1) do
      :eof -> {:ok, ""}
      _ -> {:error, :source_changed}
    end
  end

  defp read_exact_source(device, expected_size) do
    case :file.read(device, expected_size + 1) do
      {:ok, source} when byte_size(source) == expected_size -> {:ok, source}
      _ -> {:error, :source_changed}
    end
  end

  defp verify_sources(directory, files, sources) do
    expected_sources = Map.new(sources)

    Enum.reduce_while(files, :ok, fn {name, expected}, :ok ->
      with {:ok, source} <- read_inventory_file(Path.join(directory, name), expected),
           true <- source == Map.fetch!(expected_sources, name) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :source_changed}}
      end
    end)
  end

  defp decode_capture_sources(sources) do
    Enum.reduce_while(sources, {:ok, [], %{}}, fn {name, source},
                                                  {:ok, event_groups, run_sources} ->
      case decode_jsonl(source) do
        {:ok, events} ->
          case put_run_sources(run_sources, events, filename_source_kind(name), name) do
            {:ok, run_sources} -> {:cont, {:ok, [events | event_groups], run_sources}}
            {:error, _reason} = error -> {:halt, error}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, event_groups, run_sources} ->
        source_kinds = Map.new(run_sources, fn {run_id, {kind, _name}} -> {run_id, kind} end)
        {:ok, event_groups |> Enum.reverse() |> List.flatten(), source_kinds}

      {:error, _reason} = error ->
        error
    end
  end

  defp put_run_sources(run_sources, events, source_kind, source_name) do
    Enum.reduce_while(events, {:ok, run_sources}, fn
      %{"run_id" => run_id}, {:ok, sources} ->
        case Map.get(sources, run_id) do
          nil -> {:cont, {:ok, Map.put(sources, run_id, {source_kind, source_name})}}
          {^source_kind, ^source_name} -> {:cont, {:ok, sources}}
          _conflicting -> {:halt, {:error, :malformed_source}}
        end

      _invalid_event, _acc ->
        {:halt, {:error, :malformed_source}}
    end)
  end

  defp filename_source_kind(name), do: if(private_path?(name), do: :private, else: :sanitized)

  defp same_inventory(inventory, inventory), do: :ok
  defp same_inventory(_before, _after), do: {:error, :source_changed}

  defp same_stat_identity(identity, identity), do: :ok
  defp same_stat_identity(_expected, _current), do: {:error, :source_changed}

  defp directory_root_identity(%File.Stat{} = stat) do
    %{
      major_device: stat.major_device,
      minor_device: stat.minor_device,
      inode: stat.inode,
      type: stat.type
    }
  end

  defp directory_member_path(directory, raw_name), do: directory <> "/" <> raw_name

  # ex_dna:disable-for-next-line — TraceLog keeps its source identity contract independent from inspection snapshots.
  defp stat_identity(%File.Stat{} = stat) do
    %{
      major_device: stat.major_device,
      minor_device: stat.minor_device,
      inode: stat.inode,
      type: stat.type,
      size: stat.size,
      mode: stat.mode,
      mtime: stat.mtime,
      ctime: stat.ctime
    }
  end

  # ex_dna:disable-for-next-line — TraceLog keeps its capture-hook contract independent from inspection snapshots.
  defp run_capture_hook(nil), do: :ok

  defp run_capture_hook(capture_hook) do
    case capture_hook.() do
      :ok -> :ok
      _other -> {:error, :source_unavailable}
    end
  rescue
    _exception -> {:error, :source_unavailable}
  catch
    _kind, _reason -> {:error, :source_unavailable}
  end
end
