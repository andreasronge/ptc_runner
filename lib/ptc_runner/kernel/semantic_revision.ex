defmodule PtcRunner.Kernel.SemanticRevision do
  @moduledoc """
  Conservative code-owned PTC execution-semantics revision.

  The generated build projection covers the checked-in semantic source
  inventory and publisher dependency lock identities. Starting from audited
  runtime roots, the runtime projection follows required, included, and
  optional application metadata and adds the exact Elixir, OTP, ERTS, BEAM
  architecture, conditionally compiled semantic-module presence, and resolved
  regular-file artifact identities, including executable classification. The
  final revision is deliberately stricter than observed behavioral
  equivalence.
  """

  alias PtcRunner.Kernel.TypedCanonicalJSON
  alias PtcRunner.Lisp.Eval.Context

  @projection_path Path.expand("../../../priv/semantic_build_projection.json", __DIR__)
  @external_resource @projection_path
  @build_projection @projection_path |> File.read!() |> Jason.decode!()
  @build_identity :crypto.hash(:sha256, File.read!(@projection_path))
  @actual_dependency_roots (@build_projection["runtime_dependency_roots"] ||
                              Enum.map(
                                @build_projection["runtime_dependencies"],
                                &Map.fetch!(&1, "name")
                              ))
                           |> Enum.map(&String.to_atom/1)
  @conditional_semantic_modules (@build_projection["conditional_semantic_modules"] || [])
                                |> Enum.map(&String.to_atom/1)
  @domain <<"ptc.semantic-revision.v1", 0>>
  @dependency_domain <<"ptc.runtime-dependency-artifacts.v1", 0>>
  @artifact_chunk_bytes 65_536

  @spec current() :: binary()
  @doc "Returns the semantic revision for this build and running BEAM."
  def current do
    runtime_identity = runtime_identity()
    storage_key = {__MODULE__, :current, @build_identity, runtime_identity}

    case :persistent_term.get(storage_key, :missing) do
      :missing ->
        :global.trans({storage_key, self()}, fn ->
          case :persistent_term.get(storage_key, :missing) do
            :missing ->
              revision = revision_for(@build_projection, runtime_projection(runtime_identity))
              :persistent_term.put(storage_key, revision)
              revision

            revision ->
              revision
          end
        end)

      revision ->
        revision
    end
  end

  @spec revision_for(map(), map()) :: binary()
  @doc false
  def revision_for(build, runtime) when is_map(build) and is_map(runtime) do
    projection = %{
      "build" => build,
      "runtime" => runtime
    }

    {:ok, encoded} = TypedCanonicalJSON.encode(projection)
    "sem1-" <> TypedCanonicalJSON.sha256(@domain, encoded)
  end

  @spec actual_dependency_projection(
          [atom()],
          (atom() -> {:ok, binary(), [atom()]} | :absent)
        ) :: [map()]
  @doc false
  def actual_dependency_projection(roots, resolver \\ &resolve_dependency/1)

  def actual_dependency_projection(roots, resolver)
      when is_list(roots) and is_function(resolver, 1) do
    roots
    |> Enum.sort()
    |> Enum.reduce(%{}, &collect_dependency(&1, resolver, &2))
    |> Map.values()
    |> Enum.sort_by(&Map.fetch!(&1, "name"))
  end

  @spec actual_compile_feature_projection([module()], (module() -> boolean())) :: [map()]
  @doc false
  def actual_compile_feature_projection(
        modules,
        resolver \\ &Code.ensure_loaded?/1
      )

  def actual_compile_feature_projection(modules, resolver)
      when is_list(modules) and is_function(resolver, 1) do
    modules
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn module ->
      %{
        "module" => Atom.to_string(module),
        "presence" => if(resolver.(module), do: "present", else: "absent")
      }
    end)
  end

  defp runtime_identity do
    {
      System.version(),
      :erlang.system_info(:version) |> to_string(),
      :erlang.system_info(:otp_release) |> to_string(),
      :erlang.system_info(:system_architecture) |> to_string(),
      Context.default_pmap_max_concurrency()
    }
  end

  defp runtime_projection(
         {elixir, erts, otp_release, system_architecture, compiled_pmap_max_concurrency}
       ) do
    %{
      "actual_runtime_dependencies" => actual_dependency_projection(@actual_dependency_roots),
      "compiled_pmap_max_concurrency" => compiled_pmap_max_concurrency,
      "compiled_semantic_features" =>
        actual_compile_feature_projection(@conditional_semantic_modules),
      "elixir" => elixir,
      "erts" => erts,
      "otp_release" => otp_release,
      "system_architecture" => system_architecture
    }
  end

  defp collect_dependency(app, resolver, dependencies) do
    if Map.has_key?(dependencies, app) do
      dependencies
    else
      name = Atom.to_string(app)

      case resolver.(app) do
        {:ok, root, children}
        when is_binary(root) and is_list(children) ->
          dependencies =
            Map.put(dependencies, app, %{
              "name" => name,
              "presence" => "present",
              "content_identity" => dependency_content_identity(root)
            })

          children
          |> Enum.filter(&is_atom/1)
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.reduce(dependencies, &collect_dependency(&1, resolver, &2))

        :absent ->
          Map.put(dependencies, app, %{"name" => name, "presence" => "absent"})
      end
    end
  end

  defp resolve_dependency(app) do
    case :code.lib_dir(app) do
      path when is_list(path) ->
        root = List.to_string(path)
        {:ok, root, dependency_children(app, root)}

      {:error, :bad_name} ->
        :absent
    end
  end

  defp dependency_children(app, root) do
    app_file = Path.join([root, "ebin", "#{app}.app"])

    case :file.consult(String.to_charlist(app_file)) do
      {:ok, [{:application, ^app, properties}]} ->
        [:applications, :included_applications, :optional_applications]
        |> Enum.flat_map(&List.wrap(Keyword.get(properties, &1, [])))
        |> Enum.filter(&is_atom/1)
        |> Enum.uniq()

      _missing_or_invalid ->
        []
    end
  end

  defp dependency_content_identity(root) do
    files =
      ["ebin", "priv"]
      |> Enum.flat_map(fn child ->
        root
        |> Path.join(child)
        |> Path.join("**/*")
        |> Path.wildcard(match_dot: true)
      end)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.uniq()
      |> Enum.sort()

    :sha256
    |> :crypto.hash_init()
    |> :crypto.hash_update([@dependency_domain, <<length(files)::unsigned-big-32>>])
    |> hash_dependency_files(root, files)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp hash_dependency_files(context, root, files) do
    Enum.reduce(files, context, fn relative, context ->
      path = Path.join(root, relative)
      stat = File.stat!(path)
      execute_mask = Bitwise.band(stat.mode, 0o111)

      context =
        :crypto.hash_update(context, [
          <<0x01, execute_mask>>,
          <<byte_size(relative)::unsigned-big-32>>,
          relative,
          <<stat.size::unsigned-big-64>>
        ])

      hash_dependency_file(context, path)
    end)
  end

  defp hash_dependency_file(context, path) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, file} ->
        try do
          hash_dependency_chunks(context, file, path)
        after
          :file.close(file)
        end

      {:error, reason} ->
        raise File.Error, reason: reason, action: "stream", path: path
    end
  end

  defp hash_dependency_chunks(context, file, path) do
    case :file.read(file, @artifact_chunk_bytes) do
      {:ok, chunk} ->
        context
        |> :crypto.hash_update(chunk)
        |> hash_dependency_chunks(file, path)

      :eof ->
        context

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read", path: path
    end
  end

  @spec build_projection() :: map()
  @doc false
  def build_projection, do: @build_projection
end
