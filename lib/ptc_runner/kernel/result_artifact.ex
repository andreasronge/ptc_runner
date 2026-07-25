defmodule PtcRunner.Kernel.ResultArtifact do
  @moduledoc """
  Persists one run result as a standalone JSON artifact.

  A multi-run application passes values between ordinary runs. Scraping them
  from stdout is not good enough: terminal output interleaves with logs, has no
  atomicity, and cannot express that a value must never be published. This
  writer gives a run one explicit destination instead.

  Persistence is atomic and refuses to clobber. Content is written to an
  exclusive temporary sibling, linked into place, and the temporary removed, so
  a reader never observes a partial artifact and an existing destination fails
  rather than being overwritten. A private artifact is restricted to `0600`
  before any content is written, never after.

  The private/normal distinction is authority, not formatting. A private result
  may only reach a private destination; the caller decides the class and this
  module refuses to write a private value to a normal artifact.
  """

  @type class :: :normal | :private

  @type error ::
          :result_destination_exists
          | :result_persistence_failed
          | :invalid_result_destination
          | :private_result_requires_private_destination

  @doc """
  Writes `value` to `path` as JSON.

  `class` is the effective class of the value and `destination` is the class of
  the artifact being written. A `:private` value written to a `:normal`
  destination fails before the destination is created.
  """
  @spec persist(binary(), term(), class(), class()) :: :ok | {:error, error()}
  def persist(path, value, class, destination)
      when is_binary(path) and class in [:normal, :private] and
             destination in [:normal, :private] do
    with :ok <- compatible(class, destination),
         :ok <- validate_destination(path),
         {:ok, encoded} <- encode(value) do
      persist_new(path, encoded, destination)
    end
  end

  def persist(_path, _value, _class, _destination), do: {:error, :invalid_result_destination}

  defp compatible(:private, :normal), do: {:error, :private_result_requires_private_destination}
  defp compatible(_class, _destination), do: :ok

  defp validate_destination(path) do
    cond do
      path == "" or String.contains?(path, <<0>>) -> {:error, :invalid_result_destination}
      not String.valid?(path) -> {:error, :invalid_result_destination}
      File.exists?(path) -> {:error, :result_destination_exists}
      true -> :ok
    end
  end

  defp encode(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, :result_persistence_failed}
    end
  end

  # `File.ln/2` fails when the destination exists, so the no-clobber guarantee
  # survives a race between the check above and the link.
  defp persist_new(path, encoded, destination) do
    temporary = path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    try do
      with {:ok, :ok} <- write_temporary(temporary, encoded, destination),
           :ok <- File.ln(temporary, path) do
        :ok
      else
        {:error, :eexist} -> {:error, :result_destination_exists}
        {:error, _reason} -> {:error, :result_persistence_failed}
      end
    after
      _ = File.rm(temporary)
    end
  end

  defp write_temporary(temporary, encoded, destination) do
    File.open(temporary, [:write, :binary, :exclusive], fn device ->
      with :ok <- restrict(temporary, destination) do
        IO.binwrite(device, encoded)
      end
    end)
  end

  defp restrict(temporary, :private), do: File.chmod(temporary, 0o600)
  defp restrict(_temporary, :normal), do: :ok
end
