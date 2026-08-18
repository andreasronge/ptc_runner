defmodule PtcRunner.Kernel.CandidateArtifact do
  @moduledoc """
  Publishes one model-authored candidate as `{candidate.clj, descriptor.json}`.

  This is the trusted host step `ComponentOverride` deliberately excludes. A
  run emits source through channels it already has; an operator carries those
  bytes here. Nothing a run can influence reaches this module, which is what
  keeps the descriptor path unreachable from generated code.

  Candidate source is treated as **private unconditionally**. It may have been
  extracted from a private result artifact, and a world-readable candidate
  would declassify private model output. Publication therefore reuses the same
  primitives as result publication: an exclusively created mode-0700 directory,
  files restricted to 0600 before any content is written, and ancestor
  ownership and permission checks. The exclusive directory create — not a
  rename — is the no-clobber guarantee, because POSIX `rename` may replace an
  existing empty destination directory.

  Publication precedes gating: the gate re-acquires the application through the
  descriptor written here, so it evaluates exactly the bytes an operator would
  later promote. `discard/1` removes the directory when the gate refuses, so a
  refused candidate leaves nothing behind.
  """

  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.PrivateDirectory

  @candidate_name "candidate.clj"
  @descriptor_name "descriptor.json"
  @max_descriptor_bytes 65_536
  @max_source_bytes 1_048_576

  @type error ::
          :candidate_destination_exists
          | :candidate_cleanup_failed
          | :candidate_publication_failed
          | :candidate_source_too_large
          | :descriptor_too_large
          | :invalid_candidate_destination

  @type published :: %{
          directory: binary(),
          candidate: binary(),
          descriptor: binary(),
          descriptor_bytes: non_neg_integer()
        }

  @doc """
  Writes the candidate and its descriptor into a newly created directory.

  `descriptor` is the decoded descriptor map minus `source_hash` and `path`,
  both of which are derived here so the bytes hashed are the bytes written.
  """
  @spec publish(binary(), binary(), map()) :: {:ok, published()} | {:error, error()}
  def publish(directory, source, descriptor)
      when is_binary(directory) and is_binary(source) and is_map(descriptor) do
    with :ok <- bounded_source(source),
         {:ok, anchored} <- anchor(directory),
         {:ok, encoded} <- encode(complete(descriptor, source)),
         :ok <- bounded_descriptor(encoded),
         :ok <- create(anchored) do
      write_pair(anchored, source, encoded)
    end
  end

  def publish(_directory, _source, _descriptor), do: {:error, :invalid_candidate_destination}

  @doc "Removes a published directory after a refused gate, reporting any material residue."
  @spec discard(published() | binary()) :: :ok | {:error, :candidate_cleanup_failed}
  def discard(%{directory: directory}), do: discard(directory)

  def discard(directory) when is_binary(directory) do
    results = [
      remove_file(Path.join(directory, @candidate_name)),
      remove_file(Path.join(directory, @descriptor_name))
    ]

    if Enum.all?(results, &(&1 == :ok)) and remove_directory(directory) == :ok,
      do: :ok,
      else: {:error, :candidate_cleanup_failed}
  end

  defp remove_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :error
    end
  end

  defp remove_directory(path) do
    case File.rmdir(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :error
    end
  end

  @doc "The descriptor filename inside a published directory."
  @spec descriptor_name() :: binary()
  def descriptor_name, do: @descriptor_name

  @doc "The candidate filename a descriptor references."
  @spec candidate_name() :: binary()
  def candidate_name, do: @candidate_name

  # The hash is taken from the bytes this module writes, so a descriptor can
  # never name source that was not published beside it.
  defp complete(descriptor, source) do
    descriptor
    |> Map.put("source_hash", ComponentOverride.hash(source))
    |> Map.put("path", @candidate_name)
  end

  defp write_pair(directory, source, encoded) do
    candidate = Path.join(directory, @candidate_name)
    descriptor = Path.join(directory, @descriptor_name)

    with :ok <- write_private(candidate, source),
         :ok <- write_private(descriptor, encoded) do
      {:ok,
       %{
         directory: directory,
         candidate: candidate,
         descriptor: descriptor,
         descriptor_bytes: byte_size(encoded)
       }}
    else
      {:error, _reason} ->
        discard(directory)
        {:error, :candidate_publication_failed}
    end
  end

  # Restriction happens inside the open callback, before any content is
  # written, so the bytes are never observable at a wider mode than intended.
  defp write_private(path, content) do
    result =
      File.open(path, [:write, :binary, :exclusive], fn device ->
        with :ok <- File.chmod(path, 0o600) do
          IO.binwrite(device, content)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      _unexpected -> {:error, :candidate_publication_failed}
    end
  end

  defp create(directory) do
    case PrivateDirectory.create(directory) do
      :ok -> :ok
      {:error, :private_directory_creation_failed} -> existing_or_failed(directory)
      {:error, _reason} -> {:error, :candidate_publication_failed}
    end
  end

  defp existing_or_failed(directory) do
    if File.exists?(directory),
      do: {:error, :candidate_destination_exists},
      else: {:error, :candidate_publication_failed}
  end

  defp anchor(directory) do
    with {:ok, anchored} <- PrivateDirectory.anchor(directory),
         :ok <- PrivateDirectory.preflight_writable_parent(anchored) do
      {:ok, anchored}
    else
      {:error, _reason} -> {:error, :invalid_candidate_destination}
    end
  end

  defp encode(descriptor) do
    case DeterministicJSON.encode(descriptor) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, :candidate_publication_failed}
    end
  end

  defp bounded_source(source) when byte_size(source) == 0,
    do: {:error, :candidate_publication_failed}

  defp bounded_source(source) when byte_size(source) > @max_source_bytes,
    do: {:error, :candidate_source_too_large}

  defp bounded_source(_source), do: :ok

  # Checked on the bytes actually written: descriptor size is not knowable
  # until path, provenance, and the acceptance decision are all encoded.
  defp bounded_descriptor(encoded) when byte_size(encoded) > @max_descriptor_bytes,
    do: {:error, :descriptor_too_large}

  defp bounded_descriptor(_encoded), do: :ok
end
