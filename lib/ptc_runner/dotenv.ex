defmodule PtcRunner.Dotenv do
  @moduledoc """
  Loads environment variables from an explicitly named dotenv file.

  Existing process environment variables take precedence over file values.
  Command frontends use `--env-file FILE` to choose the exact file; this module
  does not search the invocation directory or its parents implicitly.

  ## Examples

      PtcRunner.Dotenv.load_file(".env")

  """

  @doc """
  Parse `path` as a `.env` file and set the variables it declares.

  Lines are `KEY=VALUE`; blank lines and `#` comments are ignored. Surrounding
  single or double quotes are stripped from the value. Existing environment
  variables are never overwritten.
  """
  @spec load_file(String.t()) :: :ok
  def load_file(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.each(fn line ->
      line
      |> String.trim()
      |> parse_env_line()
    end)
  end

  @doc false
  @spec environment_setup_option(keyword()) :: keyword()
  def environment_setup_option(frontend_options) when is_list(frontend_options) do
    case Keyword.fetch(frontend_options, :env_file) do
      {:ok, path} when is_binary(path) -> [environment_setup: fn -> load_file(path) end]
      _missing_or_invalid -> []
    end
  end

  def environment_setup_option(_frontend_options), do: []

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
