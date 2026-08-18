defmodule PtcRunner.Dotenv do
  @moduledoc """
  Loads environment variables from an explicitly named dotenv file.

  Existing process environment variables take precedence over file values.
  Command frontends use `--env-file FILE` to choose the exact file; this module
  does not search the invocation directory or its parents implicitly.

  ## Examples

      PtcRunner.Dotenv.load_file(".env")

  """

  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.ConfinedFile

  @max_bytes 1_000_000

  @type file_error ::
          :environment_file_not_found
          | :environment_file_not_regular
          | :environment_file_unreadable
          | :environment_file_too_large
          | :environment_file_invalid_utf8

  @doc """
  Parse `path` as a `.env` file and set the variables it declares.

  Lines are `KEY=VALUE`; blank lines and `#` comments are ignored. Surrounding
  single or double quotes are stripped from the value. Existing environment
  variables are never overwritten.
  """
  @spec load_file(String.t()) :: :ok | {:error, file_error()}
  def load_file(path) when is_binary(path) do
    with {:ok, canonical} <- ConfinedFile.resolve_absolute(Path.expand(path)),
         {:ok, bytes} <-
           ConfinedFile.read(Path.dirname(canonical), Path.basename(canonical), @max_bytes),
         :ok <- parse(bytes) do
      :ok
    else
      {:error, reason} -> {:error, file_error(reason)}
    end
  rescue
    _exception -> {:error, :environment_file_unreadable}
  catch
    _kind, _reason -> {:error, :environment_file_unreadable}
  end

  def load_file(_path), do: {:error, :environment_file_unreadable}

  @doc false
  @spec parse(binary()) :: :ok | {:error, :environment_file_invalid}
  def parse(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    if String.valid?(bytes) do
      bytes
      |> String.split("\n")
      |> Enum.each(fn line ->
        line
        |> String.trim()
        |> parse_env_line()
      end)
    else
      {:error, :environment_file_invalid}
    end
  end

  def parse(_bytes), do: {:error, :environment_file_invalid}

  @doc false
  @spec attach_environment(CommandRuntime.t(), keyword()) ::
          {:ok, CommandRuntime.t()} | {:error, :invalid_command_runtime}
  def attach_environment(%CommandRuntime{} = runtime, frontend_options)
      when is_list(frontend_options) do
    case Keyword.fetch(frontend_options, :env_file) do
      {:ok, path} when is_binary(path) ->
        # Classified here rather than by the runtime, which cannot tell this
        # callback from an embedding host's own and would relabel any caller
        # that happened to answer with a dotenv parse reason.
        CommandRuntime.with_environment(runtime, fn ->
          load_file(path)
        end)

      :error ->
        {:ok, runtime}

      _invalid ->
        {:error, :invalid_command_runtime}
    end
  end

  def attach_environment(_runtime, _frontend_options), do: {:error, :invalid_command_runtime}

  @doc false
  @spec with_file_scope(binary(), (-> result)) :: result when result: term()
  def with_file_scope(path, fun) when is_binary(path) and is_function(fun, 0) do
    # The ordinary CLI is one-shot, but Viewer launches share a long-lived VM.
    # Remember only names declared by this file so values loaded for one launch
    # cannot become the inherited baseline of the next launch. The fixed lock
    # also prevents two scoped launches from restoring over each other.
    case declared_keys(path) do
      {:ok, keys} ->
        :global.trans({__MODULE__, :file_scope}, fn ->
          previous = Map.new(keys, &{&1, System.get_env(&1)})

          try do
            fun.()
          after
            restore_environment(previous)
          end
        end)

      {:error, _reason} ->
        # Execute normally so the command's deferred environment setup retains
        # its canonical public diagnostic for a missing or malformed file.
        fun.()
    end
  end

  def with_file_scope(_path, fun) when is_function(fun, 0), do: fun.()

  defp file_error(:not_found), do: :environment_file_not_found
  defp file_error(:not_regular), do: :environment_file_not_regular
  defp file_error(:unreadable), do: :environment_file_unreadable
  defp file_error(:too_large), do: :environment_file_too_large
  defp file_error(:invalid_utf8), do: :environment_file_invalid_utf8
  defp file_error(:environment_file_invalid), do: :environment_file_invalid_utf8
  defp file_error(_reason), do: :environment_file_unreadable

  defp declared_keys(path) do
    with {:ok, canonical} <- ConfinedFile.resolve_absolute(Path.expand(path)),
         {:ok, bytes} <-
           ConfinedFile.read(Path.dirname(canonical), Path.basename(canonical), @max_bytes),
         true <- String.valid?(bytes) do
      keys =
        bytes
        |> String.split("\n")
        |> Enum.reduce([], fn line, keys ->
          case String.trim(line) do
            "" -> keys
            "#" <> _comment -> keys
            assignment -> declared_key(assignment, keys)
          end
        end)

      {:ok, Enum.reverse(keys)}
    else
      _invalid -> {:error, :invalid_environment_file}
    end
  rescue
    _exception -> {:error, :invalid_environment_file}
  catch
    _kind, _reason -> {:error, :invalid_environment_file}
  end

  defp declared_key(assignment, keys) do
    case String.split(assignment, "=", parts: 2) do
      [key, _value] ->
        key = String.trim(key)
        if key in keys, do: keys, else: [key | keys]

      _invalid ->
        keys
    end
  end

  defp restore_environment(previous) do
    Enum.each(previous, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp parse_env_line(""), do: :ok
  defp parse_env_line("#" <> _), do: :ok

  defp parse_env_line(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)
        value = value |> String.trim() |> String.trim("\"") |> String.trim("'")
        if System.get_env(key) == nil, do: System.put_env(key, value)

      _ ->
        :ok
    end
  end
end
