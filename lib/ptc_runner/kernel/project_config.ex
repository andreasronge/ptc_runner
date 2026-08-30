defmodule PtcRunner.Kernel.ProjectConfig do
  @moduledoc """
  Strict operator-owned launch configuration for a PTC project.

  A project configuration keeps local application, host, environment,
  artifact, and Viewer choices out of the model-authorable application
  manifest. All paths are portable relative paths resolved beneath the
  project document's directory. Loading the project document is bounded and
  does not open any referenced file.

  The V1 discriminator is `"kind": "ptc-project"`. Unknown and duplicate
  keys are rejected at every level. The runtime never discovers a project
  implicitly; callers must name its JSON document. Schema failures retain a
  bounded `PtcRunner.Kernel.SchemaViolation` so command admission can publish
  the rule and a project-schema-authorized path without retaining rejected
  values or filesystem names. A schema worker that times out or exceeds its
  heap bound is reported as unavailable, never as a schema violation.
  """

  alias PtcRunner.Kernel.ConfinedFile
  alias PtcRunner.Kernel.SchemaPath
  alias PtcRunner.Kernel.SchemaViolation
  alias PtcRunner.Kernel.StrictJSON

  @schema_uri "https://ptc-runner.dev/schemas/ptc-project-config.schema.json"
  @max_bytes 262_144
  @max_path_bytes 1_024
  @root_keys ~w($schema kind version application host artifacts viewer)
  @application_keys ~w(path)
  @host_keys ~w(path env_file)
  @env_file_keys ~w(path)
  @artifact_keys ~w(root trace inspection result envelope)
  @viewer_keys ~w(port open repl private)

  @enforce_keys [
    :path,
    :directory,
    :application,
    :host,
    :env_file,
    :artifact_root,
    :artifacts,
    :viewer
  ]
  defstruct @enforce_keys

  @type artifacts :: %{
          trace: boolean(),
          inspection: boolean(),
          result: boolean(),
          envelope: boolean()
        }
  @type viewer :: %{port: 0..65_535, open: boolean(), repl: boolean(), private: boolean()}
  @type t :: %__MODULE__{
          path: binary(),
          directory: binary(),
          application: binary(),
          host: binary() | nil,
          env_file: binary() | nil,
          artifact_root: binary() | nil,
          artifacts: artifacts(),
          viewer: viewer()
        }

  @doc "Classifies an explicitly named JSON document by its `kind` field."
  @spec classify(binary()) :: :application | {:project, t()} | {:error, failure()}
  def classify(path) when is_binary(path) do
    case read_document(path) do
      {:ok, canonical, %{"kind" => "ptc-project"} = decoded} ->
        case load_decoded(canonical, decoded) do
          {:ok, project} -> {:project, project}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _canonical, %{"kind" => _other}} ->
        {:error, {:project_schema_invalid, SchemaViolation.new(:const, [{:property, "kind"}])}}

      {:ok, _canonical, _manifest_without_kind} ->
        :application

      {:error, :project_unavailable} ->
        :application

      {:error, {:project_schema_invalid, %SchemaViolation{}} = reason, :project_document} ->
        {:error, reason}

      {:error, _reason, :project_document} ->
        generic_schema_failure()

      {:error, _reason, :foreign_document} ->
        {:error, {:project_schema_invalid, SchemaViolation.new(:const, [{:property, "kind"}])}}

      {:error, _reason} ->
        :application
    end
  rescue
    _exception -> :application
  catch
    _kind, _reason -> :application
  end

  def classify(_path), do: {:error, :project_invalid}

  @doc "Loads one project document without opening its references."
  @type failure ::
          :project_unavailable
          | :project_invalid
          | {:schema_validation_unavailable, SchemaViolation.unavailable_reason()}
          | {:project_schema_invalid, SchemaViolation.t()}

  @spec load(binary()) :: {:ok, t()} | {:error, failure()}
  def load(path) when is_binary(path) do
    case read_document(path) do
      {:ok, canonical, decoded} ->
        load_decoded(canonical, decoded)

      {:error, :project_unavailable} = error ->
        error

      {:error, :project_invalid} = error ->
        error

      {:error, {:project_schema_invalid, %SchemaViolation{}}} = error ->
        error

      {:error, {:project_schema_invalid, %SchemaViolation{}} = reason, classification}
      when classification in [:project_document, :foreign_document] ->
        {:error, reason}

      _invalid ->
        generic_schema_failure()
    end
  end

  def load(_path), do: {:error, :project_invalid}

  @doc false
  @spec document_digest(binary()) :: {:ok, binary()} | {:error, failure()}
  def document_digest(path) when is_binary(path) do
    case resolve_document_path(path) do
      {:ok, canonical} -> digest_canonical(canonical)
      {:error, _reason} = error -> error
    end
  end

  def document_digest(_path), do: {:error, :project_invalid}

  defp load_decoded(canonical, decoded) do
    with :ok <- validate_schema(decoded),
         directory = Path.dirname(canonical),
         {:ok, values} <- decode(decoded),
         {:ok, project} <- build(canonical, directory, values) do
      {:ok, project}
    else
      {:error, {:project_schema_invalid, %SchemaViolation{}}} = error -> error
      {:error, {:schema_validation_unavailable, _reason}} = error -> error
      _invalid -> generic_schema_failure()
    end
  end

  @doc "Returns the generated JSON Schema for project configuration V1."
  @spec schema() :: map()
  def schema do
    path = %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => @max_path_bytes,
      "pattern" =>
        "^(?!/)(?!.*//)(?!(?:\\.{1,2})(?:/|$))[A-Za-z0-9._-]+(?:/(?!(?:\\.{1,2})(?:/|$))[A-Za-z0-9._-]+)*$"
    }

    bool = %{"type" => "boolean", "default" => false}

    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => @schema_uri,
      "title" => "PTC project configuration",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["kind", "version", "application"],
      "properties" => %{
        "$schema" => %{"const" => @schema_uri},
        "kind" => %{"const" => "ptc-project"},
        "version" => %{"const" => 1},
        "application" => object_schema(["path"], %{"path" => path}),
        "host" =>
          object_schema(["path"], %{
            "path" => path,
            "env_file" => object_schema(["path"], %{"path" => path})
          }),
        "artifacts" =>
          object_schema(["root"], %{
            "root" => path,
            "trace" => bool,
            "inspection" => bool,
            "result" => bool,
            "envelope" => bool
          })
          |> Map.put("allOf", [
            %{
              "if" => %{
                "properties" => %{"inspection" => %{"const" => true}},
                "required" => ["inspection"]
              },
              "then" => %{
                "properties" => %{"trace" => %{"const" => true}},
                "required" => ["trace"]
              }
            }
          ]),
        "viewer" =>
          object_schema([], %{
            "port" => %{
              "type" => "integer",
              "minimum" => 0,
              "maximum" => 65_535,
              "default" => 0
            },
            "open" => bool,
            "repl" => bool,
            "private" => bool
          })
      }
    }
  end

  defp read_document(path) do
    case resolve_document_path(path) do
      {:ok, canonical} -> read_canonical_document(canonical)
      {:error, _reason} = error -> error
    end
  end

  defp resolve_document_path(path) do
    case ConfinedFile.resolve_absolute(Path.expand(path)) do
      {:ok, canonical} ->
        {:ok, canonical}

      {:error, reason}
      when reason in [:not_found, :not_regular, :invalid_path, :symlink_escape] ->
        {:error, :project_unavailable}

      _invalid ->
        {:error, :project_invalid}
    end
  end

  defp digest_canonical(canonical) do
    directory = Path.dirname(canonical)
    name = Path.basename(canonical)

    case ConfinedFile.read_prefix_status(directory, name, @max_bytes) do
      {:ok, bytes, :complete} ->
        {:ok, :crypto.hash(:sha256, bytes)}

      {:ok, _prefix, :truncated} ->
        {:error, :project_invalid}

      {:error, reason}
      when reason in [:not_found, :not_regular, :invalid_path, :symlink_escape] ->
        {:error, :project_unavailable}

      {:error, _reason} ->
        {:error, :project_invalid}
    end
  end

  defp read_canonical_document(canonical) do
    directory = Path.dirname(canonical)
    name = Path.basename(canonical)

    case ConfinedFile.read_prefix_status(directory, name, @max_bytes) do
      {:ok, bytes, :complete} ->
        decode_document(canonical, bytes)

      {:ok, prefix, :truncated} ->
        classify_discriminator_prefix(prefix)

      {:error, reason}
      when reason in [:not_found, :not_regular, :invalid_path, :symlink_escape] ->
        {:error, :project_unavailable}

      {:error, _reason} ->
        {:error, :project_invalid}
    end
  end

  defp classify_discriminator_prefix(prefix) do
    case StrictJSON.root_string_prefix(prefix, "kind") do
      {:ok, "ptc-project"} -> {:error, :project_invalid, :project_document}
      {:ok, _foreign} -> {:error, :project_invalid, :foreign_document}
      :error -> {:error, :project_invalid}
    end
  end

  defp decode_document(canonical, bytes) do
    case StrictJSON.decode_with_locations(bytes) do
      {:ok, decoded} ->
        {:ok, canonical, decoded}

      {:error, {:duplicate_json_key, path}} ->
        reason =
          {:project_schema_invalid,
           SchemaViolation.new(:duplicate_property, safe_project_path(path))}

        classify_decode_failure(bytes, reason)

      _invalid ->
        classify_decode_failure(bytes, :project_invalid)
    end
  end

  defp classify_decode_failure(bytes, reason) do
    case StrictJSON.unique_root_string(bytes, "kind") do
      {:ok, "ptc-project"} -> {:error, reason, :project_document}
      {:ok, _foreign} -> {:error, reason, :foreign_document}
      :error -> {:error, reason}
    end
  end

  defp validate_schema(document) do
    with :ok <- validate_cross_fields(document) do
      case SchemaViolation.validate(document, schema()) do
        :ok -> :ok
        {:error, violation} -> {:error, {:project_schema_invalid, violation}}
        {:unavailable, reason} -> {:error, {:schema_validation_unavailable, reason}}
      end
    end
  end

  defp validate_cross_fields(%{
         "artifacts" => %{"inspection" => true} = artifacts
       }) do
    path = [{:property, "artifacts"}, {:property, "trace"}]

    case Map.fetch(artifacts, "trace") do
      {:ok, true} -> :ok
      :error -> {:error, {:project_schema_invalid, SchemaViolation.new(:required, path)}}
      {:ok, _value} -> {:error, {:project_schema_invalid, SchemaViolation.new(:const, path)}}
    end
  end

  defp validate_cross_fields(_document), do: :ok

  defp safe_project_path(path), do: SchemaPath.explained_prefix(path, schema())

  defp generic_schema_failure,
    do: {:error, {:project_schema_invalid, SchemaViolation.new(:schema, [])}}

  defp decode(%{} = root) do
    with :ok <- exact_keys(root, @root_keys, ~w(kind version application)),
         :ok <- optional_schema(root),
         "ptc-project" <- Map.get(root, "kind"),
         :ok <- version(Map.get(root, "version")),
         {:ok, application} <- path_object(Map.get(root, "application"), @application_keys),
         {:ok, host, env_file} <- host(Map.get(root, "host")),
         {:ok, artifact_root, artifacts} <- artifacts(Map.get(root, "artifacts")),
         {:ok, viewer} <- viewer(Map.get(root, "viewer")) do
      {:ok,
       %{
         application: application,
         host: host,
         env_file: env_file,
         artifact_root: artifact_root,
         artifacts: artifacts,
         viewer: viewer
       }}
    else
      _invalid -> {:error, :project_invalid}
    end
  end

  defp decode(_root), do: {:error, :project_invalid}

  defp optional_schema(root) do
    case Map.fetch(root, "$schema") do
      :error -> :ok
      {:ok, @schema_uri} -> :ok
      _invalid -> {:error, :project_invalid}
    end
  end

  defp host(nil), do: {:ok, nil, nil}

  defp host(%{} = host) do
    with :ok <- exact_keys(host, @host_keys, ["path"]),
         {:ok, path} <- portable_path(Map.get(host, "path")),
         {:ok, env_file} <- optional_path_object(Map.get(host, "env_file"), @env_file_keys) do
      {:ok, path, env_file}
    end
  end

  defp host(_host), do: {:error, :project_invalid}

  defp artifacts(nil), do: {:ok, nil, default_artifacts()}

  defp artifacts(%{} = artifacts) do
    with :ok <- exact_keys(artifacts, @artifact_keys, ["root"]),
         {:ok, root} <- portable_path(Map.get(artifacts, "root")),
         {:ok, trace} <- boolean(artifacts, "trace", false),
         {:ok, inspection} <- boolean(artifacts, "inspection", false),
         {:ok, result} <- boolean(artifacts, "result", false),
         {:ok, envelope} <- boolean(artifacts, "envelope", false),
         true <- not inspection or trace do
      {:ok, root, %{trace: trace, inspection: inspection, result: result, envelope: envelope}}
    else
      _invalid -> {:error, :project_invalid}
    end
  end

  defp artifacts(_artifacts), do: {:error, :project_invalid}

  defp viewer(nil), do: {:ok, default_viewer()}

  defp viewer(%{} = viewer) do
    with :ok <- exact_keys(viewer, @viewer_keys, []),
         {:ok, port} <- port(viewer),
         {:ok, open?} <- boolean(viewer, "open", false),
         {:ok, repl?} <- boolean(viewer, "repl", false),
         {:ok, private?} <- boolean(viewer, "private", false) do
      {:ok, %{port: port, open: open?, repl: repl?, private: private?}}
    end
  end

  defp viewer(_viewer), do: {:error, :project_invalid}

  defp path_object(value, allowed) do
    with %{} = object <- value,
         :ok <- exact_keys(object, allowed, ["path"]),
         do: portable_path(Map.get(object, "path"))
  end

  defp optional_path_object(nil, _allowed), do: {:ok, nil}
  defp optional_path_object(value, allowed), do: path_object(value, allowed)

  defp portable_path(value)
       when is_binary(value) and byte_size(value) in 1..@max_path_bytes do
    segments = Path.split(value)

    valid? =
      String.valid?(value) and not String.contains?(value, [<<0>>, "\\", "//"]) and
        not String.ends_with?(value, "/") and
        Path.type(value) == :relative and segments != [] and
        Enum.all?(segments, fn segment ->
          segment not in ["", ".", ".."] and Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, segment)
        end)

    if valid?, do: {:ok, value}, else: {:error, :project_invalid}
  end

  defp portable_path(_value), do: {:error, :project_invalid}

  defp exact_keys(map, allowed, required) do
    keys = Map.keys(map)

    if keys -- allowed == [] and required -- keys == [],
      do: :ok,
      else: {:error, :project_invalid}
  end

  defp boolean(map, key, default) do
    case Map.fetch(map, key) do
      :error -> {:ok, default}
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _invalid -> {:error, :project_invalid}
    end
  end

  defp port(map) do
    case Map.get(map, "port", 0) do
      value
      when is_number(value) and value >= 0 and value <= 65_535 and value == trunc(value) ->
        {:ok, trunc(value)}

      _invalid ->
        {:error, :project_invalid}
    end
  end

  defp version(value) when value == 1, do: :ok
  defp version(_value), do: {:error, :project_invalid}

  defp build(path, directory, values) do
    {:ok,
     %__MODULE__{
       path: path,
       directory: directory,
       application: resolve(directory, values.application),
       host: resolve(directory, values.host),
       env_file: resolve(directory, values.env_file),
       artifact_root: resolve(directory, values.artifact_root),
       artifacts: values.artifacts,
       viewer: values.viewer
     }}
  end

  defp resolve(_directory, nil), do: nil
  defp resolve(directory, relative), do: Path.expand(relative, directory)

  defp default_artifacts,
    do: %{trace: false, inspection: false, result: false, envelope: false}

  defp default_viewer,
    do: %{port: 0, open: false, repl: false, private: false}

  defp object_schema(required, properties) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => required,
      "properties" => properties
    }
  end
end
