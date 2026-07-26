defmodule PtcRunner.Kernel.ComponentOverride do
  @moduledoc """
  Replaces one already-selected component with trusted candidate source.

  This is host CLI authority, not manifest authority. A manifest cannot name an
  override, and a generated program cannot produce one: the descriptor arrives
  only through `--component-override-descriptor`, and its source is read from a
  path confined to the descriptor's own directory. Evaluating a candidate is a
  deliberate operator act, so the candidate bytes must not be reachable through
  anything a run can influence.

  The descriptor carries exactly `component_id`, `base_source_hash`,
  `source_hash`, and `path`. Verification is deliberately two-sided. The
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

  Nothing here writes. Materializing a candidate is a separate trusted host
  step, and promotion stays an explicit human decision.
  """

  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.ConfinedFile
  alias PtcRunner.Kernel.StrictJSON

  @max_descriptor_bytes 65_536
  @max_source_bytes 1_048_576
  @keys ~w(component_id base_source_hash source_hash path)
  @hash ~r/\Asha256:[0-9a-f]{64}\z/
  @component_id ~r/\A[a-z][a-z0-9._-]{0,127}\z/

  @enforce_keys [:component_id, :base_source_hash, :source_hash, :source, :origin]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          component_id: binary(),
          base_source_hash: binary(),
          source_hash: binary(),
          source: binary(),
          origin: binary()
        }

  @type error ::
          :invalid_override_descriptor
          | :invalid_override_source
          | :override_source_hash_mismatch
          | :override_base_hash_mismatch
          | :override_component_not_selected

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
         {:ok, source} <- read_source(directory, decoded["path"]),
         :ok <- verify_source_hash(source, decoded["source_hash"]) do
      {:ok,
       %__MODULE__{
         component_id: decoded["component_id"],
         base_source_hash: decoded["base_source_hash"],
         source_hash: decoded["source_hash"],
         source: source,
         origin: "component-override"
       }}
    else
      {:error, reason} when reason in [:override_source_hash_mismatch] -> {:error, reason}
      {:error, :invalid_override_source} -> {:error, :invalid_override_source}
      _reason -> {:error, :invalid_override_descriptor}
    end
  end

  def load(_path), do: {:error, :invalid_override_descriptor}

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
      "component_id" => override.component_id,
      "base_source_hash" => override.base_source_hash,
      "source_hash" => override.source_hash
    }
  end

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

  defp decode(raw) do
    with {:ok, value} <- StrictJSON.decode(raw),
         true <- is_map(value) and not is_struct(value),
         true <- Enum.sort(Map.keys(value)) == Enum.sort(@keys),
         true <- valid_component_id?(value["component_id"]),
         true <- valid_hash?(value["base_source_hash"]),
         true <- valid_hash?(value["source_hash"]),
         true <- is_binary(value["path"]) do
      {:ok, value}
    else
      _reason -> {:error, :invalid_override_descriptor}
    end
  end

  # ConfinedFile rejects absolute paths, traversal segments, and symlinks that
  # leave the root, so a descriptor cannot point at source outside its own
  # directory.
  defp read_source(directory, path) do
    case ConfinedFile.read(directory, path, @max_source_bytes) do
      {:ok, source} when byte_size(source) > 0 -> {:ok, source}
      _reason -> {:error, :invalid_override_source}
    end
  end

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
end
