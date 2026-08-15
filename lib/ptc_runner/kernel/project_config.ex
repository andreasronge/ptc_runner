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
  implicitly; callers must name its JSON document.
  """

  alias PtcRunner.Kernel.ConfinedFile
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
  @spec classify(binary()) :: :application | {:project, t()} | {:error, atom()}
  def classify(path) when is_binary(path) do
    case read_document(path) do
      {:ok, _canonical, %{"kind" => "ptc-project"}} ->
        case load(path) do
          {:ok, project} -> {:project, project}
          {:error, _reason} -> {:error, :project_invalid}
        end

      {:ok, _canonical, %{"kind" => _other}} ->
        {:error, :project_invalid}

      {:ok, _canonical, _manifest_without_kind} ->
        :application

      {:error, :project_unavailable} ->
        :application

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
  @spec load(binary()) :: {:ok, t()} | {:error, :project_unavailable | :project_invalid}
  def load(path) when is_binary(path) do
    with {:ok, canonical, decoded} <- read_document(path),
         directory = Path.dirname(canonical),
         {:ok, values} <- decode(decoded),
         {:ok, project} <- build(canonical, directory, values) do
      {:ok, project}
    else
      {:error, :project_unavailable} = error -> error
      _invalid -> {:error, :project_invalid}
    end
  end

  def load(_path), do: {:error, :project_invalid}

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
              "default" => 4123
            },
            "open" => bool,
            "repl" => bool,
            "private" => bool
          })
      }
    }
  end

  defp read_document(path) do
    with {:ok, canonical} <- ConfinedFile.resolve_absolute(Path.expand(path)),
         directory = Path.dirname(canonical),
         {:ok, bytes} <- ConfinedFile.read(directory, Path.basename(canonical), @max_bytes),
         {:ok, decoded} <- StrictJSON.decode_with_locations(bytes) do
      {:ok, canonical, decoded}
    else
      {:error, reason}
      when reason in [:not_found, :not_regular, :invalid_path, :symlink_escape] ->
        {:error, :project_unavailable}

      _invalid ->
        {:error, :project_invalid}
    end
  end

  defp decode(%{} = root) do
    with :ok <- exact_keys(root, @root_keys, ~w(kind version application)),
         :ok <- optional_schema(root),
         "ptc-project" <- Map.get(root, "kind"),
         1 <- Map.get(root, "version"),
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
    case Map.get(map, "port", 4123) do
      value when is_integer(value) and value in 0..65_535 -> {:ok, value}
      _invalid -> {:error, :project_invalid}
    end
  end

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
    do: %{port: 4123, open: false, repl: false, private: false}

  defp object_schema(required, properties) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => required,
      "properties" => properties
    }
  end
end
