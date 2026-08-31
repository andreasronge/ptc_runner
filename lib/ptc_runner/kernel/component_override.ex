defmodule PtcRunner.Kernel.ComponentOverride do
  @moduledoc """
  Replaces one already-selected component with trusted candidate source.

  This is host CLI authority, not manifest authority. A manifest cannot name an
  override, and a generated program cannot produce one: the descriptor arrives
  only through `--component-override-descriptor`, and its source is read from a
  path confined to the descriptor's own directory. Evaluating a candidate is a
  deliberate operator act, so the candidate bytes must not be reachable through
  anything a run can influence.

  The descriptor carries a required `target` naming either the workflow or one
  exact mission, plus `component_id`, `base_source_hash`, `source_hash`, and
  `path`. An optional closed `provenance` object records who authored the
  candidate. Provenance is operator-asserted and verified by nothing here: a
  `run_id` is a claim about origin, not evidence of it. It is kept out of
  `identity/1` so content identity stays derived from content. Verification of
  the candidate itself is deliberately two-sided. The
  candidate `source_hash` proves the operator is compiling the bytes they
  believe they extracted; `base_source_hash` proves those bytes were derived
  from the component that is actually installed now, so a candidate written
  against a since-changed base is rejected instead of evaluated against the
  wrong baseline. Both are checked before the source reaches the compiler.

  The source is opened once and the bytes that were hashed are the bytes that
  are compiled. The path is never reopened, so a file replaced between
  verification and compilation cannot substitute different source; the run
  either used the verified bytes or failed. Normal dependency, export,
  signature, and capability validation still applies afterwards, because an
  override changes which source compiles, never what compilation permits.
  A workflow override of the shipped `agent.core` retains only its fixed
  private diagnostic routes. That grant follows the verified shipped-library
  base identity; copying the same source into a local component does not gain
  it.

  Nothing here writes. Materializing a candidate is a separate trusted host
  step, and promotion stays an explicit human decision.
  """

  alias PtcRunner.Kernel.ApplicationSource
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.ConfinedFile
  alias PtcRunner.Kernel.SchemaPath
  alias PtcRunner.Kernel.StrictJSON

  @max_descriptor_bytes 65_536
  @max_source_bytes 1_048_576
  @required_keys ~w(target component_id base_source_hash source_hash path)
  @optional_keys ~w(provenance)
  @keys @required_keys ++ @optional_keys
  @provenance_keys ~w(run_id prompt_hash authored_at accept_widened_effect)
  @hash ~r/\Asha256:[0-9a-f]{64}\z/
  @component_id ~r/\A[a-z][a-z0-9._-]{0,127}\z/
  @run_id ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/
  @descriptor_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => @required_keys,
    "properties" => %{
      "component_id" => %{"type" => "string", "pattern" => "^[a-z][a-z0-9._-]{0,127}$"},
      "target" => %{
        "oneOf" => [
          %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["environment"],
            "properties" => %{"environment" => %{"const" => "workflow"}}
          },
          %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["environment", "mission"],
            "properties" => %{
              "environment" => %{"const" => "mission"},
              "mission" => %{"type" => "string", "pattern" => "^[a-z][a-z0-9._-]{0,127}$"}
            }
          }
        ]
      },
      "base_source_hash" => %{"type" => "string", "pattern" => "^sha256:[0-9a-f]{64}$"},
      "source_hash" => %{"type" => "string", "pattern" => "^sha256:[0-9a-f]{64}$"},
      "path" => %{"type" => "string"},
      "provenance" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "run_id" => %{"type" => "string", "pattern" => "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"},
          "prompt_hash" => %{"type" => "string", "pattern" => "^sha256:[0-9a-f]{64}$"},
          "authored_at" => %{"type" => "string"},
          "accept_widened_effect" => %{"type" => "boolean"}
        }
      }
    }
  }

  @enforce_keys [
    :target,
    :component_id,
    :base_source_hash,
    :source_hash,
    :source,
    :origin,
    :provenance,
    :descriptor_bytes
  ]
  defstruct @enforce_keys

  @type provenance :: %{optional(binary()) => binary() | boolean()}

  @type t :: %__MODULE__{
          component_id: binary(),
          target: map(),
          base_source_hash: binary(),
          source_hash: binary(),
          source: binary(),
          origin: binary(),
          provenance: provenance() | nil,
          descriptor_bytes: non_neg_integer()
        }

  @type error ::
          :invalid_override_descriptor
          | :invalid_override_source
          | :document_limit_exceeded
          | :json_depth_exceeded
          | :json_node_limit_exceeded
          | :override_source_hash_mismatch
          | :override_base_hash_mismatch
          | :override_component_not_selected
          | {:component_override_path, [PtcRunner.Kernel.CommandPath.segment()],
             :invalid_override_descriptor}

  @doc false
  @spec schema() :: map()
  def schema, do: @descriptor_schema

  @doc """
  Loads and verifies one descriptor, returning the candidate source it names.

  `path` resolves against the invoking process working directory. The source
  path inside the descriptor resolves against the descriptor's canonical
  directory and may not escape it.
  """
  @spec load(binary()) :: {:ok, t()} | {:error, error()}
  def load(path) when is_binary(path) do
    with {:ok, canonical} <- resolve(path),
         directory = Path.dirname(canonical),
         {:ok, raw} <-
           ConfinedFile.read(directory, Path.basename(canonical), @max_descriptor_bytes),
         {:ok, decoded} <- decode(raw),
         :ok <- valid_candidate_name(decoded["path"]),
         {:ok, source} <- read_source(directory, decoded["path"]),
         :ok <- verify_source_hash(source, decoded["source_hash"]) do
      {:ok, override(decoded, raw, source)}
    else
      {:error, {:component_override_path, _path, :invalid_override_descriptor}} = error ->
        error

      {:error, reason} when reason in [:override_source_hash_mismatch] ->
        {:error, reason}

      {:error, :invalid_override_source} ->
        {:error, :invalid_override_source}

      {:error, reason}
      when reason in [
             :document_limit_exceeded,
             :json_depth_exceeded,
             :json_node_limit_exceeded
           ] ->
        {:error, reason}

      {:error, :too_large} ->
        {:error, :document_limit_exceeded}

      _reason ->
        {:error, :invalid_override_descriptor}
    end
  end

  def load(_path), do: {:error, :invalid_override_descriptor}

  @spec load_application(ApplicationSource.t(), binary()) :: {:ok, t()} | {:error, error()}
  @doc false
  def load_application(application_source, descriptor_name),
    do: load_application(application_source, descriptor_name, nil)

  @spec load_application(ApplicationSource.t(), binary(), binary() | nil) ::
          {:ok, t()} | {:error, error()}
  @doc false
  def load_application(%ApplicationSource{} = application_source, descriptor_name, expected_name)
      when is_binary(descriptor_name) and (is_binary(expected_name) or is_nil(expected_name)) do
    with {:ok, descriptor} <-
           ApplicationSource.read(application_source, descriptor_name, @max_descriptor_bytes),
         {:ok, decoded} <- decode(descriptor),
         :ok <- valid_candidate_name(decoded["path"]),
         {:ok, candidate_name} <-
           ApplicationSource.resolve_reference(
             application_source,
             descriptor_name,
             decoded["path"]
           ),
         :ok <- expected_candidate_name(expected_name, candidate_name),
         {:ok, source} <-
           ApplicationSource.read(application_source, candidate_name, @max_source_bytes),
         true <- byte_size(source) > 0,
         :ok <- verify_source_hash(source, decoded["source_hash"]) do
      {:ok, override(decoded, descriptor, source)}
    else
      {:error, {:component_override_path, _path, :invalid_override_descriptor}} = error ->
        error

      {:error, :override_source_hash_mismatch} = error ->
        error

      {:error, :invalid_override_source} = error ->
        error

      {:error, :invalid_override_descriptor} = error ->
        error

      {:error, reason}
      when reason in [
             :document_limit_exceeded,
             :json_depth_exceeded,
             :json_node_limit_exceeded
           ] ->
        {:error, reason}

      {:error, :reference_missing} ->
        {:error, :invalid_override_source}

      {:error, :invalid_logical_name} ->
        {:error, :invalid_override_source}

      false ->
        {:error, :invalid_override_source}

      _reason ->
        {:error, :invalid_override_descriptor}
    end
  end

  def load_application(_application_source, _descriptor_name, _expected_name),
    do: {:error, :invalid_override_descriptor}

  @doc """
  Applies one verified override to a selected component list.

  The named component must already be selected: an override replaces source for
  a component the manifest chose, and never introduces one. Its declared
  dependencies are preserved, so a candidate cannot quietly acquire a new
  dependency — that would change the effective bundle beyond the source under
  evaluation.
  """
  @spec apply([Component.t()], t()) ::
          {:ok, [Component.t()], boolean()} | {:error, error()}
  def apply(components, %__MODULE__{} = override) when is_list(components) do
    case Enum.find(components, &(&1.id == override.component_id)) do
      nil ->
        {:ok, components, false}

      %Component{} = installed ->
        with :ok <- verify_base_hash(installed.source, override.base_source_hash),
             {:ok, replacement} <-
               Component.new(
                 id: installed.id,
                 source: override.source,
                 dependencies: installed.dependencies,
                 origin: override.origin
               ) do
          {:ok, replace(components, replacement), true}
        else
          {:error, :invalid_component} -> {:error, :invalid_override_source}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Returns the safe identity an artifact binds a candidate trial to.

  Hashes and the component ID are safe; candidate source never is.
  """
  @spec identity(t()) :: map()
  def identity(%__MODULE__{} = override) do
    %{
      "target" => override.target,
      "component_id" => override.component_id,
      "base_source_hash" => override.base_source_hash,
      "source_hash" => override.source_hash
    }
  end

  @doc """
  Returns the authorship attribution an artifact records beside the identity.

  This is deliberately separate from `identity/1`. That map is the override
  content record's payload, so anything added to it changes
  `application_content_digest`. Attribution is operator-asserted metadata about
  *who authored* a candidate, not part of *what the candidate is*, and content
  identity must not depend on an asserted timestamp or an acceptance flag.

  Returns an empty map when the descriptor carried no provenance.
  """
  @spec attribution(t()) :: map()
  def attribution(%__MODULE__{provenance: nil}), do: %{}
  def attribution(%__MODULE__{provenance: provenance}), do: provenance

  @doc "Hashes component source with the descriptor's `sha256:` convention."
  @spec hash(binary()) :: binary()
  def hash(source) when is_binary(source),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, source), case: :lower)

  defp resolve(path) do
    case ConfinedFile.resolve_absolute(Path.expand(path)) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, _reason} -> {:error, :invalid_override_descriptor}
    end
  end

  defp override(decoded, descriptor, source) do
    %__MODULE__{
      target: decoded["target"],
      component_id: decoded["component_id"],
      base_source_hash: decoded["base_source_hash"],
      source_hash: decoded["source_hash"],
      source: source,
      origin: "component-override",
      provenance: decoded["provenance"],
      descriptor_bytes: byte_size(descriptor)
    }
  end

  defp decode(raw) do
    case StrictJSON.decode_with_locations(raw) do
      {:ok, value} ->
        decode_value(value)

      {:error, {:duplicate_json_key, path}} ->
        descriptor_violation(safe_descriptor_path(path))

      {:error, reason} when reason in [:json_depth_exceeded, :json_node_limit_exceeded] ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :invalid_override_descriptor}
    end
  end

  defp decode_value(value) when is_map(value) and not is_struct(value) do
    keys = Map.keys(value)

    cond do
      keys -- @keys != [] ->
        descriptor_violation([])

      @required_keys -- keys != [] ->
        descriptor_violation([])

      not valid_target?(value["target"]) ->
        descriptor_violation([{:property, "target"}])

      not valid_provenance?(value) ->
        descriptor_violation([{:property, "provenance"}])

      not valid_component_id?(value["component_id"]) ->
        descriptor_violation([{:property, "component_id"}])

      not valid_hash?(value["base_source_hash"]) ->
        descriptor_violation([{:property, "base_source_hash"}])

      not valid_hash?(value["source_hash"]) ->
        descriptor_violation([{:property, "source_hash"}])

      not is_binary(value["path"]) ->
        descriptor_violation([{:property, "path"}])

      true ->
        {:ok, value}
    end
  end

  defp decode_value(_value), do: descriptor_violation([])

  defp valid_target?(%{"environment" => "workflow"} = target), do: map_size(target) == 1

  defp valid_target?(%{"environment" => "mission", "mission" => name} = target),
    do: map_size(target) == 2 and valid_component_id?(name)

  defp valid_target?(_target), do: false

  defp descriptor_violation(path),
    do: {:error, {:component_override_path, path, :invalid_override_descriptor}}

  defp safe_descriptor_path(path),
    do: SchemaPath.explained_prefix(path, @descriptor_schema)

  # ConfinedFile rejects absolute paths, traversal segments, and symlinks that
  # leave the root, so a descriptor cannot point at source outside its own
  # directory.
  defp read_source(directory, path) do
    case ConfinedFile.read(directory, path, @max_source_bytes) do
      {:ok, source} when byte_size(source) > 0 -> {:ok, source}
      {:error, :too_large} -> {:error, :document_limit_exceeded}
      _reason -> {:error, :invalid_override_source}
    end
  end

  defp valid_candidate_name(path) do
    if ApplicationSource.valid_name?(path),
      do: :ok,
      else: {:error, :invalid_override_source}
  end

  defp expected_candidate_name(nil, _candidate_name), do: :ok
  defp expected_candidate_name(candidate_name, candidate_name), do: :ok

  defp expected_candidate_name(_expected_name, _candidate_name),
    do: {:error, :invalid_override_descriptor}

  defp verify_source_hash(source, expected) do
    if hash(source) == expected, do: :ok, else: {:error, :override_source_hash_mismatch}
  end

  defp verify_base_hash(installed_source, expected) do
    if hash(installed_source) == expected,
      do: :ok,
      else: {:error, :override_base_hash_mismatch}
  end

  defp replace(components, replacement) do
    Enum.map(components, fn component ->
      if component.id == replacement.id, do: replacement, else: component
    end)
  end

  defp valid_component_id?(value), do: is_binary(value) and value =~ @component_id
  defp valid_hash?(value), do: is_binary(value) and value =~ @hash

  # Provenance is optional, but a present object is closed and every supplied
  # key is validated. It is operator-asserted: nothing here proves the run named
  # by `run_id` produced the candidate bytes.
  defp valid_provenance?(value) when not is_map_key(value, "provenance"), do: true

  defp valid_provenance?(%{"provenance" => provenance})
       when is_map(provenance) and not is_struct(provenance) do
    Map.keys(provenance) -- @provenance_keys == [] and
      Enum.all?(provenance, fn {key, entry} -> valid_provenance_entry?(key, entry) end)
  end

  defp valid_provenance?(_value), do: false

  defp valid_provenance_entry?("run_id", value), do: is_binary(value) and value =~ @run_id
  defp valid_provenance_entry?("prompt_hash", value), do: valid_hash?(value)
  defp valid_provenance_entry?("accept_widened_effect", value), do: is_boolean(value)

  defp valid_provenance_entry?("authored_at", value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, 0} -> true
      _other -> false
    end
  end

  defp valid_provenance_entry?(_key, _value), do: false
end
