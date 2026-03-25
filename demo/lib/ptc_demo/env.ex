defmodule PtcDemo.Env do
  @moduledoc """
  Environment variable loading for demo scripts.

  Walks up from the current working directory to find the nearest `.env` file
  and loads its variables (only if not already set). Safe to call multiple times.
  """

  @dotenv_loaded_key {__MODULE__, :dotenv_loaded}

  @doc """
  Load environment variables from the nearest `.env` file.

  Only loads once per VM. Existing env vars take precedence.
  """
  @spec load_dotenv() :: :ok
  def load_dotenv do
    unless :persistent_term.get(@dotenv_loaded_key, false) do
      :persistent_term.put(@dotenv_loaded_key, true)

      case find_dotenv(File.cwd!()) do
        nil -> :ok
        path -> apply_dotenv(path)
      end
    end

    :ok
  end

  defp find_dotenv("/"), do: nil

  defp find_dotenv(dir) do
    candidate = Path.join(dir, ".env")

    if File.regular?(candidate) do
      candidate
    else
      find_dotenv(Path.dirname(dir))
    end
  end

  defp apply_dotenv(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.each(fn line ->
      line = String.trim(line)

      unless line == "" or String.starts_with?(line, "#") do
        case String.split(line, "=", parts: 2) do
          [key, value] ->
            key = String.trim(key)
            value = value |> String.trim() |> String.trim("\"") |> String.trim("'")

            if System.get_env(key) == nil do
              System.put_env(key, value)
            end

          _ ->
            :ok
        end
      end
    end)
  end
end
