defmodule Mix.Tasks.Ptc.GenSemanticRevision do
  @shortdoc "Generate the stable Kernel semantic-build projection"
  @moduledoc """
  Generates the checked-in build half of the Kernel semantic revision.

      mix ptc.gen_semantic_revision
      mix ptc.gen_semantic_revision --check

  The inventory owns semantic source boundaries, explicit semantic files,
  conditionally compiled semantic modules, runtime dependency roots and
  publisher dependency closure, and local path-dependency content. The check
  fails on source drift, dependency-closure drift, missing classifications, or
  a stale projection.
  """
  use Mix.Task

  alias Mix.Dep.Lock
  alias PtcRunner.Kernel.DeterministicJSON

  @inventory_path "priv/semantic_build_inventory.exs"
  @projection_path "priv/semantic_build_projection.json"
  @source_domain <<"ptc.semantic-source-closure.v1", 0>>
  @path_dependency_domain <<"ptc.semantic-path-dependency.v1", 0>>
  @lock_domain <<"ptc.semantic-lock-entry.v1", 0>>

  @impl Mix.Task
  def run(args) do
    check? = "--check" in args
    inventory = load_inventory!()
    validate_inventory!(inventory)
    projection = projection!(inventory)
    {:ok, encoded} = DeterministicJSON.encode(projection)
    content = encoded <> "\n"

    if check? do
      case File.read(@projection_path) do
        {:ok, ^content} -> Mix.shell().info("semantic build projection is current")
        _stale -> Mix.raise("#{@projection_path} is stale; run mix ptc.gen_semantic_revision")
      end
    else
      File.write!(@projection_path, content)
      Mix.shell().info("generated #{@projection_path}")
    end
  end

  defp load_inventory! do
    case Code.eval_file(@inventory_path) do
      {%{} = inventory, _binding} -> inventory
      _invalid -> Mix.raise("#{@inventory_path} must evaluate to a map")
    end
  end

  defp validate_inventory!(inventory) do
    roots = fetch_list!(inventory, :semantic_roots)
    explicit = fetch_list!(inventory, :semantic_files)
    conditional_modules = fetch_list!(inventory, :conditional_semantic_modules)
    dependency_roots = fetch_list!(inventory, :runtime_dependency_roots)
    dependencies = fetch_list!(inventory, :runtime_dependencies)
    path_dependencies = Map.fetch!(inventory, :path_dependencies)

    validate_root_specs!(roots)
    Enum.each(explicit, &ensure_file!/1)

    Enum.each(path_dependencies, fn {_name, spec} ->
      ensure_directory!(Map.fetch!(spec, :root))
      validate_root_specs!(Map.fetch!(spec, :semantic_roots))
    end)

    ensure_unique!("semantic roots", Enum.map(roots, & &1.root))
    ensure_unique!("semantic files", explicit)
    ensure_unique!("conditional semantic modules", conditional_modules)
    ensure_unique!("runtime dependency roots", dependency_roots)
    ensure_unique!("runtime dependencies", dependencies)

    if not Enum.all?(conditional_modules, &conditional_module?/1) do
      Mix.raise("conditional semantic modules must be Elixir module atoms")
    end

    actual_roots = runtime_dependency_roots!()
    actual_dependencies = runtime_dependency_names!()

    if Enum.sort(dependency_roots) != actual_roots do
      Mix.raise(
        "runtime dependency root inventory drift: expected #{inspect(actual_roots)}, " <>
          "found #{inspect(Enum.sort(dependency_roots))}"
      )
    end

    if Enum.sort(dependencies) != actual_dependencies do
      Mix.raise(
        "runtime dependency inventory drift: expected #{inspect(actual_dependencies)}, " <>
          "found #{inspect(Enum.sort(dependencies))}"
      )
    end
  end

  defp projection!(inventory) do
    source_projection = source_projection(inventory)

    dependencies =
      inventory.runtime_dependencies
      |> Enum.sort()
      |> Enum.map(&dependency_projection!(&1, inventory.path_dependencies))

    source_projection
    |> Map.put(
      "conditional_semantic_modules",
      inventory.conditional_semantic_modules
      |> Enum.sort()
      |> Enum.map(&Atom.to_string/1)
    )
    |> Map.put(
      "runtime_dependency_roots",
      inventory.runtime_dependency_roots
      |> Enum.sort()
      |> Enum.map(&Atom.to_string/1)
    )
    |> Map.put("runtime_dependencies", dependencies)
  end

  @doc false
  @spec source_projection(map(), binary()) :: map()
  def source_projection(inventory, base_directory \\ ".") do
    source_files =
      inventory
      |> semantic_files(base_directory)
      |> Enum.map(&file_projection(&1, base_directory))

    %{
      "source_closure_hash" => framed_file_hash(@source_domain, source_files, base_directory),
      "sources" => source_files
    }
  end

  defp semantic_files(inventory, base_directory \\ ".") do
    rooted =
      Enum.flat_map(inventory.semantic_roots, fn %{root: root, exclusions: exclusions} ->
        base_directory
        |> Path.join(root)
        |> Path.join("**/*")
        |> Path.wildcard(match_dot: true)
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.relative_to(&1, base_directory))
        |> Enum.reject(&excluded?(&1, exclusions))
      end)

    files = Enum.sort(Enum.uniq(rooted ++ inventory.semantic_files))
    ensure_unique!("classified semantic paths", files)
    files
  end

  defp file_projection(path, base_directory \\ ".") do
    bytes = base_directory |> Path.join(path) |> File.read!()

    %{
      "path" => path,
      "sha256" => sha256(bytes),
      "bytes" => byte_size(bytes)
    }
  end

  defp dependency_projection!(name, path_dependencies) do
    case Map.fetch(path_dependencies, name) do
      {:ok, spec} ->
        files =
          %{semantic_roots: spec.semantic_roots, semantic_files: []}
          |> semantic_files()
          |> Enum.map(&file_projection/1)

        %{
          "name" => Atom.to_string(name),
          "version" => path_dependency_version!(spec),
          "content_identity" => framed_file_hash(@path_dependency_domain, files, ".")
        }

      :error ->
        lock = Lock.read()
        entry = Map.fetch!(lock, name)

        %{
          "name" => Atom.to_string(name),
          "version" => lock_version!(entry),
          "content_identity" =>
            domain_hash(@lock_domain, :erlang.term_to_binary(entry, [:deterministic]))
        }
    end
  end

  defp framed_file_hash(domain, files, base_directory) do
    records =
      Enum.map(files, fn file ->
        path = file["path"]
        bytes = base_directory |> Path.join(path) |> File.read!()
        [<<byte_size(path)::unsigned-big-32>>, path, <<byte_size(bytes)::unsigned-big-64>>, bytes]
      end)

    :crypto.hash(:sha256, [domain, <<length(files)::unsigned-big-32>>, records])
    |> Base.encode16(case: :lower)
  end

  defp domain_hash(domain, bytes) do
    :crypto.hash(:sha256, [domain, <<byte_size(bytes)::unsigned-big-64>>, bytes])
    |> Base.encode16(case: :lower)
  end

  defp runtime_dependency_names! do
    dependencies = Map.new(Mix.Dep.cached(), &{&1.app, &1})

    runtime_dependency_roots!()
    |> Enum.reduce(MapSet.new(), &collect_dependency(&1, dependencies, &2))
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp runtime_dependency_roots! do
    Mix.Project.config()
    |> Keyword.fetch!(:deps)
    |> Enum.map(&direct_dependency/1)
    |> Enum.filter(fn {_name, opts} -> production_dependency?(opts, true) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp collect_dependency(name, dependencies, seen) do
    if MapSet.member?(seen, name) do
      seen
    else
      dependency = Map.fetch!(dependencies, name)
      seen = MapSet.put(seen, name)

      Enum.reduce(dependency.deps, seen, fn child, acc ->
        if production_dependency?(child.opts, false),
          do: collect_dependency(child.app, dependencies, acc),
          else: acc
      end)
    end
  end

  defp direct_dependency({name, opts}) when is_atom(name) and is_list(opts), do: {name, opts}
  defp direct_dependency({name, _requirement}) when is_atom(name), do: {name, []}

  defp direct_dependency({name, _requirement, opts}) when is_atom(name) and is_list(opts),
    do: {name, opts}

  defp production_dependency?(opts, direct?) do
    only = Keyword.get(opts, :only)
    runtime? = Keyword.get(opts, :runtime, true)
    optional? = Keyword.get(opts, :optional, false)

    runtime? and (is_nil(only) or :prod in List.wrap(only)) and
      (direct? or not optional?)
  end

  defp path_dependency_version!(spec) do
    case Code.eval_file(Map.fetch!(spec, :version_file)) do
      {%{version: version}, _binding} when is_binary(version) -> version
      _invalid -> Mix.raise("cannot determine version for path dependency #{spec.root}")
    end
  end

  defp lock_version!({:hex, _package, version, _checksum, _managers, _deps, _repo, _outer})
       when is_binary(version),
       do: version

  defp lock_version!(entry),
    do: Mix.raise("unsupported runtime dependency lock: #{inspect(entry)}")

  defp fetch_list!(inventory, key) do
    case Map.fetch(inventory, key) do
      {:ok, values} when is_list(values) -> values
      _invalid -> Mix.raise("#{key} must be a list in #{@inventory_path}")
    end
  end

  defp conditional_module?(module) when is_atom(module),
    do: module |> Atom.to_string() |> String.starts_with?("Elixir.")

  defp conditional_module?(_module), do: false

  defp ensure_file!(path) do
    if not File.regular?(path), do: Mix.raise("missing classified semantic file: #{path}")
  end

  defp ensure_directory!(path) do
    if not File.dir?(path), do: Mix.raise("missing classified semantic directory: #{path}")
  end

  defp validate_root_specs!(roots) do
    Enum.each(roots, fn
      %{root: root, exclusions: exclusions} = spec
      when is_binary(root) and is_list(exclusions) and map_size(spec) == 2 ->
        ensure_directory!(root)
        ensure_unique!("semantic exclusions for #{root}", exclusions)

        Enum.each(exclusions, fn exclusion ->
          if not is_binary(exclusion) or
               (exclusion != root and not String.starts_with?(exclusion, root <> "/")) do
            Mix.raise("semantic exclusion #{inspect(exclusion)} is outside #{root}")
          end
        end)

      invalid ->
        Mix.raise(
          "semantic root must contain exactly :root and :exclusions, got: #{inspect(invalid)}"
        )
    end)
  end

  defp excluded?(path, exclusions) do
    Enum.any?(exclusions, fn exclusion ->
      path == exclusion or String.starts_with?(path, exclusion <> "/") or
        wildcard_match?(path, exclusion)
    end)
  end

  defp wildcard_match?(path, exclusion) do
    if String.contains?(exclusion, "*") do
      pattern =
        exclusion
        |> String.split("*")
        |> Enum.map_join(".*", &Regex.escape/1)

      Regex.match?(Regex.compile!("\\A" <> pattern <> "\\z"), path)
    else
      false
    end
  end

  defp ensure_unique!(label, values) do
    if length(values) != MapSet.size(MapSet.new(values)),
      do: Mix.raise("#{label} contains duplicates")
  end

  defp sha256(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
