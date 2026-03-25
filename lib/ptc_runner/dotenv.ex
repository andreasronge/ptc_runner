defmodule PtcRunner.Dotenv do
  @moduledoc """
  Loads environment variables from `.env` files.

  Walks up from a starting directory to find the nearest `.env` file
  and sets variables that aren't already present in the environment.

  ## Examples

      # Load from nearest .env, only once per VM
      PtcRunner.Dotenv.load()

      # Load from a specific file
      PtcRunner.Dotenv.load_file("/path/to/.env")
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

  @doc """
  Load environment variables from a specific `.env` file.

  Only sets variables that aren't already set (existing env vars take precedence).
  Skips empty lines and comments (lines starting with `#`).
  Handles quoted values (double and single quotes).
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

  @doc """
  Find the nearest `.env` file by walking up from the given directory.

  Returns the path to the `.env` file, or `nil` if none is found.
  """
  @spec find_dotenv(String.t()) :: String.t() | nil
  def find_dotenv("/"), do: nil

  def find_dotenv(dir) do
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
