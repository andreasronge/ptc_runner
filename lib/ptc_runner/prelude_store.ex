defmodule PtcRunner.PreludeStore do
  @moduledoc """
  In-memory versioned store for source-bearing capability preludes.

  V1 is deliberately prelude-specific and volatile: it provides `list/1`,
  `history/2`, `read/2`, compile-on-write `write/4`, and explicit
  `set_default/4` over a small handle backed by a single owner process and ETS
  rows. Filesystem persistence remains a later plan chunk.

  Bounds are fail-closed. `:max_versions` is the retained version window per
  id, not a lifetime write count; version numbers remain monotonic while old
  superseded rows may be pruned. A version selected with `set_default/4` is
  retained alongside the latest-version window.
  `:max_ids`, `:max_total_bytes`, and `:max_metadata_bytes` cap node-lifetime
  store growth.
  """

  alias PtcRunner.Lisp.Discovery
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Lisp.Prelude.ValidationError
  alias PtcRunner.Lisp.ProtectedNamespaces
  alias PtcRunner.PreludeCandidate
  alias PtcRunner.PreludeStore.FormEdit
  alias PtcRunner.PreludeStore.Server
  alias PtcRunner.Sandbox

  @default_max_source_bytes 1_000_000
  @default_max_metadata_bytes 8 * 1024
  @default_max_ids 1_000
  @default_max_total_bytes 10 * 1024 * 1024
  @default_compile_timeout 5_000
  @default_compile_max_heap 1_250_000
  @reserved_store_ids ~w(prelude)

  @type t :: %__MODULE__{
          pid: GenServer.server(),
          opts: keyword()
        }

  defstruct [:pid, opts: []]

  @doc "Starts a volatile in-memory prelude store and returns its handle."
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ []) do
    with :ok <- validate_opts(opts) do
      Server.start_link(opts)
    end
  end

  @doc false
  @spec validate_opts(keyword()) :: :ok | {:error, map()}
  def validate_opts(opts) when is_list(opts) do
    [
      {:max_source_bytes, @default_max_source_bytes},
      {:max_versions, 1_000},
      {:max_ids, @default_max_ids},
      {:max_total_bytes, @default_max_total_bytes},
      {:max_metadata_bytes, @default_max_metadata_bytes},
      {:compile_timeout, @default_compile_timeout},
      {:compile_max_heap, @default_compile_max_heap}
    ]
    |> Enum.reduce_while(:ok, fn {key, default}, :ok ->
      case validate_positive_integer(opts, key, default) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def validate_opts(_opts),
    do: {:error, error(:invalid_config, "PreludeStore options must be a keyword list")}

  @doc "Returns one bounded current row per prelude id, sorted by id."
  @spec list(t()) :: [map()]
  def list(%__MODULE__{} = store), do: Server.list(store)

  @doc """
  Returns an exact host/operator snapshot of retained store state.

  Unlike `PreludeCandidate.public_view/2`, this format is for restore and
  auditing. It keeps exact source text and full operational metadata.
  """
  @spec snapshot(t()) :: {:ok, map()}
  def snapshot(%__MODULE__{} = store), do: {:ok, Server.snapshot(store)}

  @doc """
  Restores a fresh volatile store from a snapshot produced by `snapshot/1`.
  """
  @spec restore(map(), keyword()) :: {:ok, t()} | {:error, map()}
  def restore(snapshot, opts \\ [])

  def restore(snapshot, opts) when is_map(snapshot) and is_list(opts) do
    with :ok <- validate_snapshot_version(snapshot),
         {:ok, store} <- new(opts) do
      case restore_into(snapshot, store) do
        :ok ->
          {:ok, store}

        {:error, _} = error ->
          stop_restore_store(store)
          error
      end
    end
  end

  def restore(_snapshot, _opts), do: {:error, error(:invalid_snapshot, "invalid snapshot")}

  @doc """
  Diffs two snapshots, or a snapshot and a live store.
  """
  @spec diff(map() | t(), map() | t()) :: map()
  def diff(left, right) do
    left = snapshot_map!(left)
    right = snapshot_map!(right)

    left_ids = snapshot_ids(left)
    right_ids = snapshot_ids(right)
    all_ids = (left_ids ++ right_ids) |> Enum.uniq() |> Enum.sort()

    changes =
      Enum.reduce(all_ids, %{added: [], removed: [], changed: []}, fn id, acc ->
        l = snapshot_entry(left, id)
        r = snapshot_entry(right, id)

        cond do
          l == nil ->
            %{acc | added: [id | acc.added]}

          r == nil ->
            %{acc | removed: [id | acc.removed]}

          l != r ->
            %{acc | changed: [diff_id(id, l, r) | acc.changed]}

          true ->
            acc
        end
      end)

    %{
      added: Enum.reverse(changes.added),
      removed: Enum.reverse(changes.removed),
      changed: Enum.reverse(changes.changed)
    }
  end

  @doc """
  Exports current store sources to a seed-compatible directory.
  """
  @spec export(t(), Path.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def export(%__MODULE__{} = store, dir, opts \\ []) when is_binary(dir) and is_list(opts) do
    store
    |> do_export(dir, opts)
    |> normalize_export_result()
  end

  defp do_export(%__MODULE__{} = store, dir, opts) do
    with {:ok, snapshot} <- snapshot(store),
         :ok <- File.mkdir_p(dir),
         {:ok, manifest_entries} <-
           export_current_versions(snapshot, Map.fetch!(snapshot, "current"), dir) do
      manifest =
        manifest_entries
        |> export_manifest()
        |> Map.put("store_fingerprint", store_fingerprint(snapshot))

      manifest_path =
        Path.join(dir, Keyword.get(opts, :manifest_name, "prelude_store_manifest.json"))

      with {:ok, manifest_json} <- Jason.encode(manifest, pretty: true),
           :ok <- File.write(manifest_path, manifest_json) do
        {:ok, manifest}
      end
    end
  end

  defp normalize_export_result({:ok, _} = ok), do: ok

  defp normalize_export_result({:error, %{reason: reason}} = error) when is_atom(reason),
    do: error

  defp normalize_export_result({:error, %Jason.EncodeError{} = reason}) do
    {:error,
     error(:export_failed, "failed to export prelude store: #{Exception.message(reason)}")}
  end

  defp normalize_export_result({:error, reason}) do
    {:error, error(:export_failed, "failed to export prelude store: #{inspect(reason)}")}
  end

  defp normalize_export_result(other) do
    {:error, error(:export_failed, "failed to export prelude store: #{inspect(other)}")}
  end

  @doc """
  Returns a seed-compatible current-source export as data.

  The bundle mirrors `export/3`: source files are named `<id>.clj`, dependent
  preludes get plain `<id>.deps` sidecars containing one seed dependency per
  line, and the manifest describes the exported current entries.
  """
  @spec export_bundle(t()) :: {:ok, map()} | {:error, map()}
  def export_bundle(%__MODULE__{} = store) do
    with {:ok, snapshot} <- snapshot(store),
         {:ok, current_rows} <- export_current_rows(snapshot) do
      current = Map.fetch!(snapshot, "current")
      manifest_entries = Enum.map(current_rows, &manifest_entry(&1, current))

      manifest =
        manifest_entries
        |> export_manifest()
        |> Map.put("store_fingerprint", store_fingerprint(snapshot))

      {:ok,
       %{
         "schema_version" => 1,
         "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
         "store_fingerprint" => manifest["store_fingerprint"],
         "manifest" => manifest,
         "files" => export_files(current_rows)
       }}
    end
  end

  @doc """
  Returns a stable fingerprint over the current id/version/checksum set.
  """
  @spec store_fingerprint(t() | map()) :: String.t()
  def store_fingerprint(%__MODULE__{} = store) do
    {:ok, snapshot} = snapshot(store)
    store_fingerprint(snapshot)
  end

  def store_fingerprint(%{"versions" => versions, "current" => current})
      when is_list(versions) and is_map(current) do
    %{"versions" => versions}
    |> current_version_rows(current)
    |> Enum.map_join("\n", fn %{"id" => id, "version" => version, "checksum" => checksum} ->
      "#{id}\t#{version}\t#{checksum}"
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end

  defp restore_into(snapshot, store) do
    with {:ok, importable} <- compile_snapshot(snapshot, store.opts),
         :ok <- Server.import_snapshot(store, importable) do
      verify_restored(snapshot, store)
    end
  end

  defp stop_restore_store(%__MODULE__{pid: pid}) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, 1_000)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp export_current_versions(snapshot, current, dir)
       when is_map(snapshot) and is_map(current) and is_binary(dir) do
    with {:ok, current_rows} <- export_current_rows(snapshot) do
      current_rows
      |> Enum.reduce_while({:ok, []}, fn version, {:ok, acc} ->
        file = source_file(version)
        path = Path.join(dir, file)

        with :ok <- File.write(path, version["source"]),
             :ok <- write_deps_sidecar(dir, file, version) do
          {:cont, {:ok, [manifest_entry(version, current) | acc]}}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        {:error, _} = error -> error
      end
    end
  rescue
    _ -> {:error, error(:invalid_snapshot, "invalid prelude store snapshot")}
  end

  defp export_current_versions(_snapshot, _current, _dir) do
    {:error, error(:invalid_snapshot, "invalid prelude store snapshot")}
  end

  defp export_current_rows(%{"current" => current} = snapshot)
       when is_map(snapshot) and is_map(current) do
    rows = current_version_rows(snapshot, current)

    with :ok <- validate_current_dep_pins(rows) do
      {:ok, rows}
    end
  rescue
    _ -> {:error, error(:invalid_snapshot, "invalid prelude store snapshot")}
  end

  defp export_current_rows(_snapshot),
    do: {:error, error(:invalid_snapshot, "invalid prelude store snapshot")}

  defp current_version_rows(%{"versions" => versions}, current)
       when is_list(versions) and is_map(current) do
    versions
    |> Enum.filter(fn version ->
      get_in(current, [version["id"], "version"]) == version["version"]
    end)
    |> Enum.sort_by(& &1["id"])
  end

  defp validate_current_dep_pins(current_rows) do
    by_id = Map.new(current_rows, &{&1["id"], &1})

    Enum.reduce_while(current_rows, :ok, fn version, :ok ->
      case non_current_dep_pin(version, by_id) do
        nil -> {:cont, :ok}
        error -> {:halt, {:error, error}}
      end
    end)
  end

  defp non_current_dep_pin(version, by_id) do
    version
    |> Map.get("metadata", %{})
    |> PreludeCandidate.dep_pins()
    |> Enum.find_value(fn pin ->
      pin_id = pin.id
      pin_version = pin.version
      pin_checksum = pin.checksum

      case Map.get(by_id, pin_id) do
        %{"version" => current_version, "checksum" => current_checksum}
        when current_version == pin_version and current_checksum == pin_checksum ->
          nil

        %{"version" => current_version, "checksum" => current_checksum} ->
          error(
            :non_current_dependency_pin,
            "cannot export current-source seed: #{version["id"]}@#{version["version"]} " <>
              "pins #{pin_id}@#{pin_version}/#{pin_checksum}, but current #{pin_id} is " <>
              "@#{current_version}/#{current_checksum}; use snapshot/restore for exact retained state"
          )

        nil ->
          error(
            :non_current_dependency_pin,
            "cannot export current-source seed: #{version["id"]}@#{version["version"]} " <>
              "pins missing current dependency #{pin_id}@#{pin_version}; use snapshot/restore"
          )
      end
    end)
  end

  defp source_file(version), do: "#{version["id"]}.clj"

  defp manifest_entry(version, current) do
    %{
      "id" => version["id"],
      "version" => version["version"],
      "checksum" => version["checksum"],
      "file" => source_file(version),
      "deps" => dep_refs(version),
      "seed_deps" => seed_dep_refs(version),
      "metadata" => version["metadata"],
      "default_metadata" => get_in(current, [version["id"], "metadata"]) || %{}
    }
  end

  defp export_manifest(manifest_entries) do
    %{
      "schema_version" => 1,
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "entries" => Enum.sort_by(manifest_entries, & &1["id"])
    }
  end

  defp export_files(current_rows) do
    current_rows
    |> Enum.flat_map(fn version ->
      file = source_file(version)
      source = version["source"]
      source_file = %{"path" => file, "source" => source}
      seed_deps = seed_dep_refs(version)

      case seed_deps do
        [] ->
          [source_file]

        deps ->
          sidecar = %{
            "path" => Path.rootname(file, ".clj") <> ".deps",
            "source" => Enum.join(deps, "\n") <> "\n"
          }

          [source_file, sidecar]
      end
    end)
  end

  @doc "Returns bounded summary rows for retained versions of one prelude id."
  @spec history(t(), String.t()) :: {:ok, [map()]} | {:error, map()}
  def history(%__MODULE__{} = store, id) do
    with :ok <- validate_id(id) do
      Server.history(store, id)
    end
  end

  @doc """
  Reads a candidate by bare id, `id@version`, or `%{id, version, checksum}` ref.
  """
  @spec read(t(), String.t() | map()) :: {:ok, PreludeCandidate.t()} | {:error, map()}
  def read(%__MODULE__{} = store, ref) do
    with {:ok, parsed} <- parse_ref(ref) do
      Server.read(store, parsed)
    end
  end

  @doc """
  Compiles and appends a new prelude version.

  The compiled namespace list must be exactly `[id]`. Stored source and metadata
  are untrusted; public projections bound and filter them.
  """
  @spec write(t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, map()}
  def write(store, id, source, metadata \\ %{})

  def write(%__MODULE__{} = store, id, source, metadata)
      when is_binary(id) and is_binary(source) and is_map(metadata) do
    opts = store.opts

    with :ok <- validate_id(id),
         :ok <-
           check_source_bound(
             source,
             Keyword.get(opts, :max_source_bytes, @default_max_source_bytes)
           ),
         :ok <-
           check_metadata_bound(
             metadata,
             Keyword.get(opts, :max_metadata_bytes, @default_max_metadata_bytes)
           ),
         {:ok, parent_checksum} <- parent_checksum(metadata),
         {:ok, parent_version} <- parent_version(metadata),
         :ok <- check_parent(store, id, parent_checksum, parent_version),
         {:ok, declared_refs} <- declared_dep_refs(id, metadata),
         {:ok, dep_candidates} <- resolve_deps(store, declared_refs),
         :ok <- validate_dep_closure(store, id, dep_candidates),
         final_metadata = put_dep_metadata(metadata, declared_refs, dep_candidates),
         # The bound must hold for what is STORED, not just what the caller
         # sent: computed pins add ~100 bytes per dep (a 64-hex checksum
         # each), so re-check after enrichment (skipped when nothing was
         # added — the caller metadata was already checked above).
         :ok <-
           check_enriched_metadata_bound(
             final_metadata,
             dep_candidates,
             Keyword.get(opts, :max_metadata_bytes, @default_max_metadata_bytes)
           ),
         {:ok, compiled} <- compile_bounded(source, opts, id, dep_candidates),
         :ok <- validate_compiled_namespace(id, compiled) do
      candidate = %PreludeCandidate{
        id: id,
        version: 0,
        source: source,
        compiled: compiled,
        origin: Keyword.get(opts, :origin, {:memory, store.pid}),
        metadata: final_metadata,
        created_at: DateTime.utc_now()
      }

      Server.append(store, candidate, %{checksum: parent_checksum, version: parent_version})
    end
  end

  def write(%__MODULE__{}, _id, _source, _metadata) do
    {:error,
     error(:invalid_argument, "write/4 requires string id, string source, and map metadata")}
  end

  @doc """
  Applies a form-keyed edit batch (`PtcRunner.PreludeStore.FormEdit`) to the
  current candidate for `id` and writes the spliced result as a new version.

  Reads the CURRENT (bare-id) candidate as the base, splices `edits` via
  `FormEdit.apply/2` against its exact source text, then writes through the
  ordinary `write/4` compile-and-append path with `parent_checksum` forced
  to the base's own checksum (any caller-supplied `parent_checksum` in
  `metadata` is overridden). `edit/3,4` performs no concurrency control of
  its own: a write landing between this read and this write is rejected as
  `:stale_base` by the SAME check `write/4` already has — editing a
  non-current base is unsupported, exactly like `write/4`.

  On success, returns `write/4`'s result map plus `base_version` and
  `parent_checksum` (the base this edit was applied against), `forms`
  (`FormEdit.apply/2`'s replaced/added/removed/ns_doc_set summary), and
  `public_surface` (`%{added:, removed:, changed:}`, diffing the OLD and NEW
  compiled `form_graph` — not `exports` alone, since a private definition
  has no `Export` record at all: a `defn` -> `defn-` visibility flip would
  otherwise silently disappear from an exports-only diff instead of
  surfacing as a change).
  """
  @spec edit(t(), String.t(), [map()], map()) :: {:ok, map()} | {:error, map()}
  def edit(store, id, edits, metadata \\ %{})

  def edit(%__MODULE__{} = store, id, edits, metadata)
      when is_binary(id) and is_list(edits) and is_map(metadata) do
    with :ok <- validate_id(id),
         {:ok, base} <- read(store, id) do
      base_checksum = PreludeCandidate.checksum(base)

      write_metadata =
        metadata
        |> Map.merge(%{"parent_checksum" => base_checksum, "parent_version" => base.version})
        |> inherit_dep_declaration(base)

      max_source_bytes =
        Keyword.get(store.opts, :max_source_bytes, @default_max_source_bytes)

      with {:ok, new_source, forms_summary} <-
             FormEdit.apply(base.source, edits, max_source_bytes: max_source_bytes),
           {:ok, result} <- write(store, id, new_source, write_metadata),
           {:ok, new_candidate} <-
             read(store, %{id: id, version: result.version, checksum: result.checksum}) do
        {:ok,
         result
         |> Map.put(:base_version, base.version)
         |> Map.put(:parent_checksum, base_checksum)
         |> Map.put(:forms, forms_summary)
         |> Map.put(
           :public_surface,
           public_surface_diff(base.compiled, new_candidate.compiled, id)
         )}
      end
    end
  end

  def edit(%__MODULE__{}, _id, _edits, _metadata) do
    {:error, error(:invalid_argument, "edit/4 requires string id, list edits, and map metadata")}
  end

  @doc """
  Moves the bare-id default/current pointer to an existing version.

  `id` + `version` is the preferred explicit form. `id@version` or a
  `%{id, version, checksum}` ref are also accepted for checksum-pinned default
  changes.
  """
  @spec set_default(t(), String.t() | map()) :: {:ok, map()} | {:error, map()}
  def set_default(store, ref), do: set_default(store, ref, %{})

  @spec set_default(t(), String.t(), pos_integer()) :: {:ok, map()} | {:error, map()}
  def set_default(%__MODULE__{} = store, id, version)
      when is_binary(id) and is_integer(version) and version > 0,
      do: set_default(store, id, version, %{})

  @spec set_default(t(), String.t() | map(), map()) :: {:ok, map()} | {:error, map()}
  def set_default(%__MODULE__{} = store, ref, metadata) when is_map(metadata) do
    with :ok <-
           check_metadata_bound(
             metadata,
             Keyword.get(store.opts, :max_metadata_bytes, @default_max_metadata_bytes)
           ) do
      case parse_ref(ref) do
        {:ok, %{version: version} = parsed} when is_integer(version) ->
          Server.set_default(store, parsed, metadata)

        {:ok, %{id: id}} ->
          {:error, error(:invalid_ref, "set_default requires an explicit version for `#{id}`")}

        {:error, _} = error ->
          error
      end
    end
  end

  def set_default(%__MODULE__{}, _ref, _metadata) do
    {:error, error(:invalid_argument, "set_default/3 requires map metadata")}
  end

  @spec set_default(t(), String.t(), pos_integer(), map()) :: {:ok, map()} | {:error, map()}
  def set_default(%__MODULE__{} = store, id, version, metadata)
      when is_binary(id) and is_integer(version) and version > 0 and is_map(metadata) do
    with :ok <- validate_id(id),
         :ok <-
           check_metadata_bound(
             metadata,
             Keyword.get(store.opts, :max_metadata_bytes, @default_max_metadata_bytes)
           ) do
      Server.set_default(store, %{id: id, version: version}, metadata)
    end
  end

  def set_default(%__MODULE__{}, _id, _version, _metadata) do
    {:error,
     error(
       :invalid_argument,
       "set_default/4 requires string id, positive integer version, and map metadata"
     )}
  end

  defp validate_snapshot_version(%{"schema_version" => 1}), do: :ok

  defp validate_snapshot_version(_snapshot) do
    {:error, error(:invalid_snapshot, "unsupported prelude store snapshot schema")}
  end

  defp compile_snapshot(%{"versions" => versions} = snapshot, opts) when is_list(versions) do
    by_ref = Map.new(versions, &{{&1["id"], &1["version"]}, &1})

    with :ok <- validate_snapshot_refs(snapshot, by_ref),
         {:ok, compiled_by_ref} <- compile_snapshot_versions(by_ref, opts) do
      import_versions =
        versions
        |> Enum.map(fn version ->
          Map.put(
            version,
            "candidate",
            Map.fetch!(compiled_by_ref, {version["id"], version["version"]})
          )
        end)

      {:ok, Map.put(snapshot, "versions", import_versions)}
    end
  rescue
    _ -> {:error, error(:invalid_snapshot, "invalid prelude store snapshot")}
  end

  defp compile_snapshot(_snapshot, _opts),
    do: {:error, error(:invalid_snapshot, "invalid snapshot")}

  defp validate_snapshot_refs(
         %{"versions" => versions, "current" => current, "latest" => latest},
         by_ref
       )
       when is_list(versions) and is_map(current) and is_map(latest) do
    versions_by_id = snapshot_versions_by_id(versions)

    with :ok <- validate_snapshot_version_rows(versions, by_ref),
         :ok <- validate_snapshot_control_id_sets(current, latest),
         :ok <- validate_snapshot_current_refs(current, by_ref),
         :ok <- validate_snapshot_latest_refs(latest, by_ref),
         :ok <- validate_snapshot_current_not_after_latest(current, latest) do
      validate_snapshot_latest_is_max(latest, versions_by_id)
    end
  end

  defp validate_snapshot_refs(_snapshot, _by_ref),
    do: {:error, error(:invalid_snapshot, "invalid prelude store snapshot")}

  defp validate_snapshot_version_rows(versions, by_ref) do
    if Enum.all?(versions, &snapshot_version_row?/1) and map_size(by_ref) == length(versions) do
      :ok
    else
      {:error, error(:invalid_snapshot, "invalid prelude store snapshot version rows")}
    end
  end

  defp snapshot_version_row?(%{"id" => id, "version" => version})
       when is_binary(id) and is_integer(version) and version > 0,
       do: true

  defp snapshot_version_row?(_version), do: false

  defp snapshot_versions_by_id(versions) do
    Enum.reduce(versions, %{}, fn
      %{"id" => id, "version" => version}, acc when is_binary(id) and is_integer(version) ->
        Map.update(acc, id, [version], &[version | &1])

      _version, acc ->
        acc
    end)
  end

  defp validate_snapshot_control_id_sets(current, latest) do
    current_ids = current |> Map.keys() |> Enum.sort()
    latest_ids = latest |> Map.keys() |> Enum.sort()

    if current_ids == latest_ids and Enum.all?(current_ids, &is_binary/1) do
      :ok
    else
      {:error, error(:invalid_snapshot, "snapshot current/latest ids are inconsistent")}
    end
  end

  defp validate_snapshot_latest_is_max(latest, versions_by_id) do
    Enum.reduce_while(latest, :ok, fn {id, latest_version}, :ok ->
      case Map.get(versions_by_id, id, []) do
        [] ->
          {:halt, missing_snapshot_control_ref(id, latest_version)}

        versions ->
          if latest_version == Enum.max(versions) do
            {:cont, :ok}
          else
            {:halt,
             {:error, error(:invalid_snapshot, "snapshot latest pointer is not retained max")}}
          end
      end
    end)
  end

  defp validate_snapshot_current_not_after_latest(current, latest) do
    Enum.reduce_while(current, :ok, fn
      {id, %{"version" => version}}, :ok ->
        latest_version = Map.get(latest, id)

        if is_integer(version) and is_integer(latest_version) and version <= latest_version do
          {:cont, :ok}
        else
          {:halt, {:error, error(:invalid_snapshot, "snapshot current pointer is after latest")}}
        end

      {_id, _entry}, :ok ->
        {:halt, {:error, error(:invalid_snapshot, "invalid snapshot current pointer")}}
    end)
  end

  defp validate_snapshot_current_refs(current, by_ref) do
    Enum.reduce_while(current, :ok, fn
      {id, %{"version" => version}}, :ok when is_integer(version) and version > 0 ->
        if Map.has_key?(by_ref, {id, version}) do
          {:cont, :ok}
        else
          {:halt, missing_snapshot_control_ref(id, version)}
        end

      {_id, _entry}, :ok ->
        {:halt, {:error, error(:invalid_snapshot, "invalid snapshot current pointer")}}
    end)
  end

  defp validate_snapshot_latest_refs(latest, by_ref) do
    Enum.reduce_while(latest, :ok, fn
      {id, version}, :ok when is_integer(version) and version > 0 ->
        if Map.has_key?(by_ref, {id, version}) do
          {:cont, :ok}
        else
          {:halt, missing_snapshot_control_ref(id, version)}
        end

      {_id, _version}, :ok ->
        {:halt, {:error, error(:invalid_snapshot, "invalid snapshot latest pointer")}}
    end)
  end

  defp missing_snapshot_control_ref(id, version) do
    {:error,
     error(:invalid_snapshot, "snapshot control pointer #{inspect({id, version})} not found")}
  end

  defp compile_snapshot_versions(by_ref, opts) do
    by_ref
    |> Map.keys()
    |> Enum.reduce_while({:ok, %{}}, fn ref, {:ok, compiled} ->
      case compile_snapshot_ref(ref, by_ref, compiled, MapSet.new(), opts) do
        {:ok, compiled} -> {:cont, {:ok, compiled}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp compile_snapshot_ref(ref, by_ref, compiled, visiting, opts) do
    cond do
      Map.has_key?(compiled, ref) ->
        {:ok, compiled}

      MapSet.member?(visiting, ref) ->
        {:error, error(:dependency_cycle, "snapshot contains a dependency cycle")}

      true ->
        with {:ok, version} <- fetch_snapshot_version(by_ref, ref),
             {:ok, compiled} <-
               compile_snapshot_deps(version, by_ref, compiled, MapSet.put(visiting, ref), opts),
             {:ok, candidate} <- compile_snapshot_candidate(version, compiled, opts) do
          {:ok, Map.put(compiled, ref, candidate)}
        end
    end
  end

  defp fetch_snapshot_version(by_ref, ref) do
    case Map.fetch(by_ref, ref) do
      {:ok, version} ->
        {:ok, version}

      :error ->
        {:error, error(:unknown_dependency, "snapshot dependency #{inspect(ref)} not found")}
    end
  end

  defp compile_snapshot_deps(version, by_ref, compiled, visiting, opts) do
    version
    |> Map.get("metadata", %{})
    |> PreludeCandidate.dep_pins()
    |> Enum.reduce_while({:ok, compiled}, fn pin, {:ok, acc} ->
      case compile_snapshot_dep_pin(pin, by_ref, acc, visiting, opts) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp compile_snapshot_dep_pin(pin, by_ref, compiled, visiting, opts) do
    with {:ok, dep_version} <- fetch_snapshot_version(by_ref, {pin.id, pin.version}),
         :ok <- verify_snapshot_pin_checksum(pin, dep_version) do
      compile_snapshot_ref({pin.id, pin.version}, by_ref, compiled, visiting, opts)
    end
  end

  defp verify_snapshot_pin_checksum(%{checksum: checksum}, %{"checksum" => checksum}), do: :ok

  defp verify_snapshot_pin_checksum(pin, version) do
    {:error,
     error(
       :checksum_mismatch,
       "snapshot dependency checksum mismatch for #{pin.id}@#{pin.version}: " <>
         "pin has #{pin.checksum}, version has #{Map.get(version, "checksum")}"
     )}
  end

  defp compile_snapshot_candidate(version, compiled_by_ref, opts) do
    id = version["id"]
    source = version["source"]
    metadata = version["metadata"] || %{}

    dep_candidates =
      metadata
      |> PreludeCandidate.dep_pins()
      |> Enum.map(&Map.fetch!(compiled_by_ref, {&1.id, &1.version}))

    with :ok <- validate_id(id),
         {:ok, compiled} <- compile_bounded(source, opts, id, dep_candidates),
         :ok <- validate_compiled_namespace(id, compiled) do
      candidate = %PreludeCandidate{
        id: id,
        version: version["version"],
        source: source,
        compiled: compiled,
        origin: {:memory, "snapshot"},
        metadata: metadata,
        created_at: parse_snapshot_datetime(version["created_at"])
      }

      if PreludeCandidate.checksum(candidate) == version["checksum"] do
        {:ok, candidate}
      else
        {:error,
         error(:checksum_mismatch, "snapshot checksum mismatch for #{id}@#{candidate.version}")}
      end
    end
  end

  defp verify_restored(original, store) do
    restored = Server.snapshot(store)

    if comparable_snapshot(original) == comparable_snapshot(restored) do
      :ok
    else
      {:error, error(:restore_mismatch, "restored prelude store does not match snapshot")}
    end
  end

  defp comparable_snapshot(snapshot) do
    snapshot
    |> Map.take(["limits", "versions", "current", "latest", "current_checksum_reused"])
    |> update_in(["versions"], fn versions ->
      versions
      |> Enum.map(&Map.drop(&1, ["candidate", "origin"]))
      |> Enum.sort_by(&{&1["id"], &1["version"]})
    end)
  end

  defp snapshot_map!(%__MODULE__{} = store) do
    {:ok, snapshot} = snapshot(store)
    snapshot
  end

  defp snapshot_map!(snapshot) when is_map(snapshot), do: snapshot

  defp snapshot_ids(snapshot) do
    snapshot
    |> Map.get("latest", %{})
    |> Map.keys()
  end

  defp snapshot_entry(snapshot, id) do
    versions =
      snapshot
      |> Map.get("versions", [])
      |> Enum.filter(&(&1["id"] == id))
      |> Enum.map(&Map.drop(&1, ["origin", "candidate"]))

    case versions do
      [] ->
        nil

      versions ->
        %{
          "latest" => get_in(snapshot, ["latest", id]),
          "current" => get_in(snapshot, ["current", id]),
          "versions" => Enum.sort_by(versions, & &1["version"])
        }
    end
  end

  defp diff_id(id, before, after_) do
    %{
      id: id,
      before: before,
      after: after_,
      current_changed: before["current"] != after_["current"],
      latest_changed: before["latest"] != after_["latest"],
      versions_changed: before["versions"] != after_["versions"]
    }
  end

  defp parse_snapshot_datetime(nil), do: DateTime.utc_now()
  defp parse_snapshot_datetime(%DateTime{} = datetime), do: datetime

  defp parse_snapshot_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> DateTime.utc_now()
    end
  end

  defp write_deps_sidecar(dir, file, version) do
    refs = seed_dep_refs(version)
    sidecar = Path.join(dir, Path.rootname(file, ".clj") <> ".deps")

    case refs do
      [] -> if File.exists?(sidecar), do: File.rm(sidecar), else: :ok
      refs -> File.write(sidecar, Enum.join(refs, "\n") <> "\n")
    end
  end

  defp dep_refs(version) do
    version
    |> Map.get("metadata", %{})
    |> PreludeCandidate.dep_pins()
    |> Enum.map(&"#{&1.id}@#{&1.version}")
  end

  defp seed_dep_refs(version) do
    version
    |> Map.get("metadata", %{})
    |> PreludeCandidate.dep_pins()
    |> Enum.map(& &1.id)
  end

  @doc false
  @spec validate_id(String.t()) :: :ok | {:error, map()}
  def validate_id(id) when is_binary(id) do
    cond do
      id == "" or String.contains?(id, "@") or String.contains?(id, "/") ->
        invalid_id(id)

      not Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_.-]*\z/, id) ->
        invalid_id(id)

      protected_or_curated?(id) ->
        namespace_violation(
          "prelude id `#{id}` collides with a reserved or curated namespace",
          id
        )

      true ->
        :ok
    end
  end

  def validate_id(_), do: invalid_id("non-string")

  defp validate_positive_integer(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0 do
      :ok
    else
      {:error, error(:invalid_config, "#{key} must be a positive integer, got #{inspect(value)}")}
    end
  end

  defp invalid_id(id) do
    namespace_violation(
      "invalid prelude id `#{id}`; ids must be namespace ids and may not contain @ or /"
    )
  end

  defp check_source_bound(source, max_bytes) when byte_size(source) <= max_bytes, do: :ok

  defp check_source_bound(source, max_bytes) do
    {:error,
     %{
       reason: :source_too_large,
       message: "prelude source is #{byte_size(source)} bytes; limit is #{max_bytes}",
       limit_bytes: max_bytes
     }}
  end

  defp check_metadata_bound(metadata, max_bytes) do
    bytes = :erlang.external_size(metadata)

    if bytes <= max_bytes do
      :ok
    else
      {:error,
       %{
         reason: :metadata_too_large,
         message: "prelude metadata is #{bytes} bytes; limit is #{max_bytes}",
         limit_bytes: max_bytes
       }}
    end
  end

  defp parent_checksum(metadata) do
    case Map.get(metadata, "parent_checksum") || Map.get(metadata, :parent_checksum) do
      nil ->
        {:ok, nil}

      checksum when is_binary(checksum) ->
        {:ok, checksum}

      other ->
        {:error,
         error(:invalid_metadata, "parent_checksum must be a string, got #{inspect(other)}")}
    end
  end

  # The checksum is the SOURCE hash, so two versions differing only in dep
  # pins share one checksum — `parent_version` (optional, enforced when
  # supplied; `edit/4` always supplies it) disambiguates staleness for
  # pin-only rewrites.
  defp parent_version(metadata) do
    case Map.get(metadata, "parent_version") || Map.get(metadata, :parent_version) do
      nil ->
        {:ok, nil}

      version when is_integer(version) and version > 0 ->
        {:ok, version}

      other ->
        {:error,
         error(
           :invalid_metadata,
           "parent_version must be a positive integer, got #{inspect(other)}"
         )}
    end
  end

  defp check_parent(_store, _id, nil, _parent_version), do: :ok

  defp check_parent(store, id, checksum, parent_version) do
    case read(store, id) do
      {:ok, candidate} ->
        actual = PreludeCandidate.checksum(candidate)

        cond do
          actual != checksum ->
            stale_base(checksum, actual)

          parent_version != nil and candidate.version != parent_version ->
            stale_base(checksum, actual)

          true ->
            :ok
        end

      {:error, %{reason: :not_found}} ->
        stale_base(checksum, nil)

      {:error, _} = error ->
        error
    end
  end

  # ============================================================
  # Declared prelude-to-prelude dependencies (docs/plans/prelude-deps.md §2)
  # ============================================================

  # An edit inherits the base version's RESOLVED PINS (`id@version`), not the
  # raw declaration: re-resolving a bare-id declaration to a newer current
  # version would be float-at-attach through the back door. An explicit
  # caller-supplied `requires_preludes` (including `[]` to drop deps)
  # overrides.
  defp inherit_dep_declaration(metadata, base) do
    if Map.has_key?(metadata, "requires_preludes") or
         Map.has_key?(metadata, :requires_preludes) do
      metadata
    else
      case PreludeCandidate.dep_pins(base) do
        [] -> metadata
        pins -> Map.put(metadata, "requires_preludes", Enum.map(pins, &"#{&1.id}@#{&1.version}"))
      end
    end
  end

  # The declaration travels in metadata under `"requires_preludes"` (the
  # `parent_checksum` precedent for metadata-carried protocol keys): a list
  # of `"id"` / `"id@<version>"` strings. A bare id resolves to the CURRENT
  # version at write time; either way the result is an explicit pin.
  defp declared_dep_refs(id, metadata) do
    case Map.get(metadata, "requires_preludes") || Map.get(metadata, :requires_preludes) do
      nil ->
        {:ok, []}

      refs when is_list(refs) ->
        refs
        |> Enum.reduce_while({:ok, []}, fn ref, {:ok, acc} ->
          case parse_dep_ref(ref) do
            {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, parsed} -> validate_dep_refs(id, Enum.reverse(parsed))
          {:error, _} = error -> error
        end

      other ->
        {:error,
         error(
           :invalid_metadata,
           "requires_preludes must be a list of id or id@version strings, " <>
             "got #{inspect(other, limit: 5)}"
         )}
    end
  end

  defp parse_dep_ref(ref) when is_binary(ref) do
    case String.split(ref, "@", parts: 2) do
      [dep_id] when dep_id != "" ->
        {:ok, %{ref: ref, id: dep_id, version: nil}}

      [dep_id, version] when dep_id != "" ->
        case Integer.parse(version) do
          {v, ""} when v > 0 -> {:ok, %{ref: ref, id: dep_id, version: v}}
          _ -> invalid_dep_ref(ref)
        end

      _ ->
        invalid_dep_ref(ref)
    end
  end

  defp parse_dep_ref(ref), do: invalid_dep_ref(ref)

  defp invalid_dep_ref(ref) do
    {:error,
     error(
       :invalid_metadata,
       "invalid requires_preludes entry #{inspect(ref, limit: 3)}; " <>
         "expected \"id\" or \"id@<positive version>\""
     )}
  end

  defp validate_dep_refs(id, parsed) do
    cond do
      Enum.any?(parsed, &(&1.id == id)) ->
        {:error,
         error(:invalid_metadata, "prelude `#{id}` cannot declare itself as a dependency")}

      (dup = parsed |> Enum.frequencies_by(& &1.id) |> Enum.find(fn {_, n} -> n > 1 end)) != nil ->
        {dup_id, _} = dup
        {:error, error(:invalid_metadata, "duplicate dependency declaration for `#{dup_id}`")}

      true ->
        {:ok, parsed}
    end
  end

  # Version-level pins are acyclic (a dep is always written before its
  # dependent), but the ID-level graph can still fold back through history:
  # `a@1`, then `b@1 -> a@1`, then `a@2` declaring `b` persists
  # `a@2 -> b@1 -> a@1` — written successfully yet never attachable, since
  # selection resolves by id and fails the a@2/a@1 conflict. Walk the
  # declared deps' transitive pin closure and reject (1) any path back to
  # the id being written and (2) conflicting versions of a shared dep, so
  # "written" keeps implying "attachable alone" (codex review finding).
  defp validate_dep_closure(_store, _id, []), do: :ok

  defp validate_dep_closure(store, id, dep_candidates) do
    dep_candidates
    |> Enum.reduce_while({:ok, %{}}, fn candidate, {:ok, seen} ->
      case closure_walk(store, id, candidate, seen) do
        {:ok, seen2} -> {:cont, {:ok, seen2}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, _} = error -> error
    end
  end

  defp closure_walk(store, root_id, %PreludeCandidate{} = candidate, seen) do
    cond do
      candidate.id == root_id ->
        {:error,
         error(
           :dependency_cycle,
           "declared dependencies reach back to `#{root_id}` " <>
             "(the closure pins `#{candidate.id}@#{candidate.version}`); " <>
             "a prelude cannot depend on itself, even transitively"
         )}

      Map.get(seen, candidate.id, candidate.version) != candidate.version ->
        {:error,
         error(
           :dependency_conflict,
           "declared dependencies pin conflicting versions of `#{candidate.id}` " <>
             "(@#{Map.get(seen, candidate.id)} and @#{candidate.version}); " <>
             "no session could attach both — align the dependency pins"
         )}

      Map.has_key?(seen, candidate.id) ->
        {:ok, seen}

      true ->
        seen = Map.put(seen, candidate.id, candidate.version)
        walk_pins(store, root_id, PreludeCandidate.dep_pins(candidate), seen)
    end
  end

  defp walk_pins(store, root_id, pins, seen) do
    Enum.reduce_while(pins, {:ok, seen}, fn pin, {:ok, acc} ->
      with {:ok, dep} <-
             read(store, %{id: pin.id, version: pin.version, checksum: pin.checksum}),
           {:ok, acc2} <- closure_walk(store, root_id, dep, acc) do
        {:cont, {:ok, acc2}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp check_enriched_metadata_bound(_metadata, [], _max_bytes), do: :ok

  defp check_enriched_metadata_bound(metadata, _dep_candidates, max_bytes),
    do: check_metadata_bound(metadata, max_bytes)

  defp resolve_deps(_store, []), do: {:ok, []}

  defp resolve_deps(store, refs) do
    refs
    |> Enum.reduce_while({:ok, []}, fn %{ref: ref}, {:ok, acc} ->
      case read(store, ref) do
        {:ok, candidate} ->
          {:cont, {:ok, [candidate | acc]}}

        {:error, %{reason: :not_found}} ->
          {:halt,
           {:error,
            error(
              :unknown_dependency,
              "dependency `#{ref}` not found in the prelude store " <>
                "(a dependency must be written before its dependents)"
            )}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, candidates} -> {:ok, Enum.reverse(candidates)}
      {:error, _} = error -> error
    end
  end

  # Resolved pins are COMPUTED by the store and override any caller-supplied
  # value under the reserved `"prelude_deps"` key (metadata is untrusted).
  # The normalized declaration is also re-stored string-keyed so `edit/4`
  # inheritance has one shape to read.
  defp put_dep_metadata(metadata, declared_refs, dep_candidates) do
    metadata = Map.drop(metadata, ["prelude_deps", :prelude_deps, :requires_preludes])

    case dep_candidates do
      [] ->
        Map.delete(metadata, "requires_preludes")

      candidates ->
        pins =
          Enum.map(candidates, fn candidate ->
            %{
              "id" => candidate.id,
              "version" => candidate.version,
              "checksum" => PreludeCandidate.checksum(candidate)
            }
          end)

        metadata
        |> Map.put("requires_preludes", Enum.map(declared_refs, & &1.ref))
        |> Map.put("prelude_deps", pins)
    end
  end

  defp compile_bounded(source, opts, id, dep_candidates) do
    compile_opts =
      case dep_candidates do
        [] ->
          []

        candidates ->
          [
            deps: Enum.map(candidates, & &1.compiled),
            namespace_deps: %{id => Enum.map(candidates, & &1.id)}
          ]
      end

    case Sandbox.run_bounded(fn -> Compiler.compile(source, compile_opts) end,
           timeout: Keyword.get(opts, :compile_timeout, @default_compile_timeout),
           max_heap: Keyword.get(opts, :compile_max_heap, @default_compile_max_heap)
         ) do
      {:ok, {:ok, %Prelude{} = compiled}} ->
        {:ok, compiled}

      {:ok, {:error, %ValidationError{} = error}} ->
        {:error,
         %{
           reason: :prelude_compile_error,
           message: error.message,
           compile_reason: error.reason,
           namespace: error.namespace,
           ref: error.ref
         }}

      {:error, {:timeout, timeout}} ->
        {:error, %{reason: :compile_timeout, message: "prelude compile exceeded #{timeout}ms"}}

      {:error, {:memory_exceeded, bytes}} ->
        {:error,
         %{reason: :compile_memory_exceeded, message: "prelude compile exceeded #{bytes} bytes"}}

      {:error, {:execution_error, message}} ->
        {:error,
         %{reason: :prelude_compile_error, message: message, compile_reason: :compile_error}}
    end
  end

  # Diffs two compiled %Prelude{}s' `form_graph` entries for namespace `id`
  # (NOT `exports` alone — private definitions have no `Export` record, so a
  # `defn`/`defn-` visibility flip would vanish instead of landing in
  # `changed`). The compared view includes each form's authority — transitive
  # `requires`/`tool_refs`, overlaid with the compiled export's own fields
  # for public names (see `surface_view/3`): an edit that swaps a helper's
  # `tool/call` from `upstream:a/x` to `upstream:a/y`, or that only touches
  # explicit export metadata, changes real capability while leaving
  # visibility/kind/arity equal — omitting authority would return
  # `changed: []` for exactly the class of change the human gate most needs
  # to see.
  defp public_surface_diff(%Prelude{} = old_compiled, %Prelude{} = new_compiled, id) do
    old_graph = Map.get(old_compiled.form_graph, id, %{})
    new_graph = Map.get(new_compiled.form_graph, id, %{})
    old_exports = Map.new(old_compiled.exports, &{&1.symbol, &1})
    new_exports = Map.new(new_compiled.exports, &{&1.symbol, &1})

    old_names = Map.keys(old_graph)
    new_names = Map.keys(new_graph)

    added_names = Enum.filter(new_names, &(&1 not in old_names))
    removed_names = Enum.filter(old_names, &(&1 not in new_names))
    common_names = Enum.filter(new_names, &(&1 in old_names))

    added =
      added_names
      |> Enum.map(&surface_entry(&1, new_graph, new_exports))
      |> Enum.sort_by(& &1.name)

    removed =
      removed_names
      |> Enum.map(&surface_entry(&1, old_graph, old_exports))
      |> Enum.sort_by(& &1.name)

    changed =
      common_names
      |> Enum.map(fn name ->
        {name, surface_view(name, old_graph, old_exports),
         surface_view(name, new_graph, new_exports)}
      end)
      |> Enum.filter(fn {_name, before, after_} -> before != after_ end)
      |> Enum.map(fn {name, before, after_} -> %{name: name, before: before, after: after_} end)
      |> Enum.sort_by(& &1.name)

    %{added: added, removed: removed, changed: changed}
  end

  defp surface_entry(name, graph, exports),
    do: Map.put(surface_view(name, graph, exports), :name, name)

  # For a PUBLIC name the compiled `%Export{}` is authoritative for authority
  # and prompt surface: its `requires` is the UNION of body-inferred and
  # explicit `{:requires [...]}` metadata, and it alone carries
  # `provider_ref` and the :prompt/:discoverable visibility — a
  # metadata-only replace (explicit requires, provider-ref, or a
  # prompt->discoverable flip) must land in `changed`, not compare equal on
  # graph-derived fields. Privates have no export; their graph-transitive
  # view is the whole story.
  defp surface_view(name, graph, exports) do
    entry = Map.fetch!(graph, name)
    export = Map.get(exports, name)

    %{
      visibility: entry.visibility,
      kind: entry.kind,
      arity: entry.arity,
      effect: export && export.effect,
      export_visibility: export && export.visibility,
      provider_ref: export && export.provider_ref,
      requires: if(export, do: export.requires, else: entry.requires.transitive),
      tool_refs: entry.tool_refs.transitive
    }
  end

  defp validate_compiled_namespace(id, %Prelude{namespaces: [id]}) do
    if protected_or_curated?(id) do
      namespace_violation(
        "prelude namespace `#{id}` collides with a reserved or curated namespace",
        id
      )
    else
      :ok
    end
  end

  defp validate_compiled_namespace(id, %Prelude{namespaces: namespaces}) do
    namespace_violation(
      "compiled namespaces must be exactly #{inspect([id])}, got #{inspect(namespaces)}",
      List.first(namespaces)
    )
  end

  defp protected_or_curated?(id) do
    id in @reserved_store_ids or ProtectedNamespaces.reserved?(id) or
      id in Discovery.reserved_namespace_names()
  end

  defp parse_ref(id) when is_binary(id) do
    case String.split(id, "@", parts: 2) do
      [bare] ->
        with :ok <- validate_id(bare), do: {:ok, %{id: bare}}

      [bare, version] ->
        with :ok <- validate_id(bare),
             {int, ""} when int > 0 <- Integer.parse(version) do
          {:ok, %{id: bare, version: int}}
        else
          _ -> {:error, error(:invalid_ref, "invalid prelude ref `#{id}`")}
        end
    end
  end

  defp parse_ref(ref) when is_map(ref) do
    id = Map.get(ref, :id) || Map.get(ref, "id")
    version = Map.get(ref, :version) || Map.get(ref, "version")
    checksum = Map.get(ref, :checksum) || Map.get(ref, "checksum")

    with true <- is_binary(id),
         :ok <- validate_id(id),
         true <- is_integer(version) and version > 0,
         true <- is_nil(checksum) or is_binary(checksum) do
      {:ok, %{id: id, version: version, checksum: checksum}}
    else
      _ -> {:error, error(:invalid_ref, "invalid prelude ref #{inspect(ref, limit: 5)}")}
    end
  end

  defp parse_ref(ref), do: {:error, error(:invalid_ref, "invalid prelude ref #{inspect(ref)}")}

  defp namespace_violation(message, namespace \\ nil) do
    {:error, %{reason: :prelude_namespace_violation, message: message, namespace: namespace}}
  end

  defp stale_base(expected, actual) do
    {:error,
     %{
       reason: :stale_base,
       message: "parent_checksum does not match current prelude checksum",
       expected_parent_checksum: expected,
       actual_parent_checksum: actual
     }}
  end

  defp error(reason, message), do: %{reason: reason, message: message}
end
