defmodule PtcRunner.Dotenv do
  @moduledoc """
  Loads environment variables from `.env` files.

  Walks up from a starting directory to find the nearest `.env` file
  and sets variables that aren't already present in the environment.

  ## Examples

      # Load from nearest .env, only once per VM
      PtcRunner.Dotenv.load()

  """

  @dotenv_loaded_key {__MODULE__, :dotenv_loaded}

  @doc """
  Load environment variables from the nearest `.env` file.

  Walks up from the current working directory looking for a `.env` file.
  Only sets variables that aren't already set (existing env vars take precedence).
  Safe to call multiple times — only loads once per VM.
  """
  @spec load() :: :ok
  def load do
    unless :persistent_term.get(@dotenv_loaded_key, false) do
      :persistent_term.put(@dotenv_loaded_key, true)

      case find_dotenv(File.cwd!()) do
        nil -> :ok
        path -> load_file(path)
      end
    end

    :ok
  end

  @spec load_file(String.t()) :: :ok
  defp load_file(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.each(fn line ->
      line
      |> String.trim()
      |> parse_env_line()
    end)
  end

  @spec find_dotenv(String.t()) :: String.t() | nil
  defp find_dotenv("/"), do: nil

  defp find_dotenv(dir) do
    candidate = Path.join(dir, ".env")

    if File.regular?(candidate) do
      candidate
    else
      find_dotenv(Path.dirname(dir))
    end
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
