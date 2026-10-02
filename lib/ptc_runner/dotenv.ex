defmodule PtcRunner.Dotenv do
  @moduledoc """
  Loads environment variables from an explicitly named dotenv file.

  File values take precedence over existing process environment variables.
  Command frontends use `--env-file FILE` to choose the exact file; this module
  does not search the invocation directory or its parents implicitly. Scoped
  commands read and validate one snapshot, use it for deferred loading, and
  restore every declared name when the command exits, including on failure.

  ## Examples

      PtcRunner.Dotenv.load_file(".env")

  """

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandFailureCause
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.ConfinedFile

  @max_bytes 1_000_000

  @type file_error ::
          :environment_file_not_found
          | :environment_file_not_regular
          | :environment_file_unreadable
          | :environment_file_too_large
          | :environment_file_invalid_utf8
          | :environment_file_invalid

  @doc """
  Parse `path` as a `.env` file and set the variables it declares.

  Lines are `KEY=VALUE`; blank lines and `#` comments are ignored. Surrounding
  single or double quotes have exactly one matching pair stripped. Keys must
  match `[A-Za-z_][A-Za-z0-9_]*`; malformed lines and NUL bytes are rejected
  before any variables are set. PATH, HOME, LD_* and DYLD_* overrides emit a
  warning on standard error without disclosing values. Declared values
  overwrite existing environment variables.
  """
  @spec load_file(String.t()) :: :ok | {:error, file_error()}
  def load_file(path) when is_binary(path) do
    with {:ok, values} <- snapshot(path), do: apply_environment(values)
  end

  def load_file(_path), do: {:error, :environment_file_unreadable}

  @doc false
  @spec parse(binary()) :: :ok | {:error, :environment_file_invalid}
  def parse(bytes) do
    with {:ok, values} <- parse_snapshot(bytes), do: apply_environment(values)
  end

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
        CommandRuntime.with_environment(runtime, fn -> load_file_diagnostic(path) end)

      :error ->
        {:ok, runtime}

      _invalid ->
        {:error, :invalid_command_runtime}
    end
  end

  def attach_environment(_runtime, _frontend_options), do: {:error, :invalid_command_runtime}

  defp load_file_diagnostic(path) do
    case load_file(path) do
      :ok ->
        :ok

      {:error, reason} ->
        cause =
          if reason == :environment_file_invalid,
            do: :invalid_configuration,
            else: CommandFailureCause.from_reason(reason)

        {:error, CommandDiagnostic.new!(:local_preflight, reason, cause: cause)}
    end
  end

  @doc false
  @spec with_file_scope(binary() | nil, (-> result)) :: result when result: term()
  def with_file_scope(path, fun) when is_binary(path) and is_function(fun, 0) do
    scoped(path, fn _snapshot -> fun.() end)
  end

  def with_file_scope(_path, fun) when is_function(fun, 0), do: fun.()

  @doc "Loads one exact file snapshot, runs startup capture, and restores its declared names."
  @spec with_loaded_file(binary() | nil, (-> result)) :: result | {:error, file_error()}
        when result: term()
  def with_loaded_file(nil, fun) when is_function(fun, 0),
    do: with_environment_lock(fun)

  def with_loaded_file(path, fun) when is_binary(path) and is_function(fun, 0) do
    scoped(path, fn result ->
      with {:ok, values} <- result, :ok <- apply_environment(values), do: fun.()
    end)
  end

  defp scoped(path, fun) do
    with_environment_lock(fn ->
      path = Path.expand(path)
      result = snapshot(path)
      cache_key = {__MODULE__, path}
      # Deferred setup runs in this command process. Keep even failed reads in
      # its dictionary so nested frontend scopes cannot reread a changed file.
      old_snapshot = Process.get(cache_key)
      Process.put(cache_key, result)

      previous =
        case result do
          {:ok, values} -> Map.new(values, fn {key, _value} -> {key, System.get_env(key)} end)
          {:error, _reason} -> %{}
        end

      try do
        fun.(result)
      after
        restore_environment(previous)
        if old_snapshot, do: Process.put(cache_key, old_snapshot), else: Process.delete(cache_key)
      end
    end)
  end

  defp with_environment_lock(fun) do
    lock_key = {__MODULE__, :environment_lock}

    if Process.get(lock_key, false) do
      fun.()
    else
      :global.trans({__MODULE__, self()}, fn ->
        # Nested frontend scopes must not release the outer command's lock.
        Process.put(lock_key, true)

        try do
          fun.()
        after
          Process.delete(lock_key)
        end
      end)
    end
  end

  defp snapshot(path) do
    case Process.get({__MODULE__, Path.expand(path)}) do
      nil -> read_snapshot(path)
      result -> result
    end
  end

  defp read_snapshot(path) do
    with {:ok, canonical} <- ConfinedFile.resolve_absolute(Path.expand(path)),
         {:ok, bytes} <-
           ConfinedFile.read(Path.dirname(canonical), Path.basename(canonical), @max_bytes),
         true <- String.valid?(bytes),
         {:ok, values} <- parse_snapshot(bytes) do
      {:ok, values}
    else
      false -> {:error, :environment_file_invalid_utf8}
      {:error, reason} -> {:error, file_error(reason)}
    end
  rescue
    _exception -> {:error, :environment_file_unreadable}
  catch
    _kind, _reason -> {:error, :environment_file_unreadable}
  end

  defp file_error(:not_found), do: :environment_file_not_found
  defp file_error(:not_regular), do: :environment_file_not_regular
  defp file_error(:unreadable), do: :environment_file_unreadable
  defp file_error(:too_large), do: :environment_file_too_large
  defp file_error(:invalid_utf8), do: :environment_file_invalid_utf8
  defp file_error(:environment_file_invalid), do: :environment_file_invalid
  defp file_error(_reason), do: :environment_file_unreadable

  defp parse_snapshot(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    if String.valid?(bytes) and not String.contains?(bytes, <<0>>) do
      bytes
      |> String.split("\n")
      |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, values} ->
        case parse_env_line(String.trim(line)) do
          :skip -> {:cont, {:ok, values}}
          {:ok, key, value} -> {:cont, {:ok, Map.put(values, key, value)}}
          :invalid -> {:halt, {:error, :environment_file_invalid}}
        end
      end)
    else
      {:error, :environment_file_invalid}
    end
  end

  defp parse_snapshot(_bytes), do: {:error, :environment_file_invalid}

  defp apply_environment(values) do
    if Enum.any?(values, fn {key, _} -> sensitive_key?(key) end) do
      IO.puts(
        :stderr,
        "warning: environment file overrides PATH, HOME, LD_* or DYLD_*; these values can affect child processes"
      )
    end

    System.put_env(values)
  end

  defp sensitive_key?(key),
    do: key in ["PATH", "HOME"] or String.starts_with?(key, ["LD_", "DYLD_"])

  defp restore_environment(previous) do
    Enum.each(previous, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp parse_env_line(""), do: :skip
  defp parse_env_line("#" <> _), do: :skip

  defp parse_env_line(line) do
    with [key, value] <- String.split(line, "=", parts: 2),
         key = String.trim(key),
         true <- Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, key),
         {:ok, value} <- unquote_value(String.trim(value)) do
      {:ok, key, value}
    else
      _invalid -> :invalid
    end
  end

  defp unquote_value(<<quote, rest::binary>>) when quote in [?', ?"] do
    if byte_size(rest) > 0 and :binary.last(rest) == quote do
      {:ok, binary_part(rest, 0, byte_size(rest) - 1)}
    else
      :invalid
    end
  end

  defp unquote_value(value) do
    if String.ends_with?(value, ["'", "\""]), do: :invalid, else: {:ok, value}
  end
end
