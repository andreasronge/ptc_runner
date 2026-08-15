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

  @doc """
  Parse `path` as a `.env` file and set the variables it declares.

  Lines are `KEY=VALUE`; blank lines and `#` comments are ignored. Surrounding
  single or double quotes are stripped from the value. Existing environment
  variables are never overwritten.
  """
  @spec load_file(String.t()) :: :ok | {:error, :environment_file_invalid}
  def load_file(path) when is_binary(path) do
    with {:ok, canonical} <- ConfinedFile.resolve_absolute(Path.expand(path)),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(canonical),
         {:ok, bytes} <-
           ConfinedFile.read(Path.dirname(canonical), Path.basename(canonical), @max_bytes) do
      parse(bytes)
    else
      _failure -> {:error, :environment_file_invalid}
    end
  rescue
    _exception -> {:error, :environment_file_invalid}
  catch
    _kind, _reason -> {:error, :environment_file_invalid}
  end

  def load_file(_path), do: {:error, :environment_file_invalid}

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
          with {:error, _reason} <- load_file(path), do: {:error, :environment_file_unavailable}
        end)

      :error ->
        {:ok, runtime}

      _invalid ->
        {:error, :invalid_command_runtime}
    end
  end

  def attach_environment(_runtime, _frontend_options), do: {:error, :invalid_command_runtime}

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
