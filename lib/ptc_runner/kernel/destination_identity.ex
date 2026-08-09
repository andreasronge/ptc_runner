defmodule PtcRunner.Kernel.DestinationIdentity do
  @moduledoc false

  alias PtcRunner.Kernel.PrivateDirectory

  @type filesystem_identity ::
          {:filesystem, non_neg_integer(), non_neg_integer(), non_neg_integer(), [binary()]}
  @type identity :: filesystem_identity() | {:lexical, binary()}

  @spec key(binary()) :: identity()
  def key(path) when is_binary(path) do
    path = Path.expand(path)

    case existing_ancestor(Path.dirname(path), [Path.basename(path)]) do
      {:ok, identity, suffix} ->
        {:filesystem, elem(identity, 0), elem(identity, 1), elem(identity, 2), fold(suffix)}

      :error ->
        {:lexical, PrivateDirectory.casefold_name(path)}
    end
  rescue
    _exception -> {:lexical, PrivateDirectory.casefold_name(path)}
  end

  @spec within?(binary(), binary()) :: boolean()
  def within?(candidate, directory) when is_binary(candidate) and is_binary(directory) do
    case {directory_key(directory), directory_key(candidate)} do
      {{:filesystem, major, minor, inode, prefix},
       {:filesystem, major, minor, inode, candidate_suffix}} ->
        prefix?(candidate_suffix, prefix)

      {{:lexical, directory}, {:lexical, candidate}} ->
        candidate == directory or String.starts_with?(candidate, directory <> "/")

      _different_roots ->
        false
    end
  end

  def within?(_candidate, _directory), do: false

  @doc false
  @spec first_collision([{atom(), binary()}]) :: {atom(), atom()} | nil
  def first_collision(destinations) when is_list(destinations) do
    Enum.reduce_while(destinations, %{}, fn {destination, path}, identities ->
      identity = key(path)

      case Map.fetch(identities, identity) do
        {:ok, ^destination} ->
          {:cont, identities}

        {:ok, first} ->
          {:halt, {first, destination}}

        :error ->
          {:cont, Map.put(identities, identity, destination)}
      end
    end)
    |> case do
      %{} -> nil
      collision -> collision
    end
  end

  defp directory_key(path) do
    path = Path.expand(path)

    case existing_ancestor(path, []) do
      {:ok, identity, suffix} ->
        {:filesystem, elem(identity, 0), elem(identity, 1), elem(identity, 2), fold(suffix)}

      :error ->
        {:lexical, PrivateDirectory.casefold_name(path)}
    end
  rescue
    _exception -> {:lexical, PrivateDirectory.casefold_name(path)}
  end

  defp existing_ancestor(path, suffix) do
    case File.stat(path, time: :posix) do
      {:ok,
       %{
         type: :directory,
         major_device: major,
         minor_device: minor,
         inode: inode
       }}
      when is_integer(major) and is_integer(minor) and is_integer(inode) ->
        {:ok, {major, minor, inode}, suffix}

      _unavailable ->
        parent = Path.dirname(path)

        if path == parent,
          do: :error,
          else: existing_ancestor(parent, [Path.basename(path) | suffix])
    end
  end

  defp fold(parts), do: Enum.map(parts, &PrivateDirectory.casefold_name/1)

  defp prefix?(candidate, prefix), do: Enum.take(candidate, length(prefix)) == prefix
end
