defmodule GitQuery.Env do
  @moduledoc """
  Loads environment variables from `.env` files.
  """

  @doc """
  Loads the `.env` file from the project root.
  """
  def load do
    # The root .env is 4 levels up from this file's directory:
    # lib/git_query/env.ex -> lib -> git_query -> examples -> ptc_runner
    env_path = Path.expand("../../../../.env", __DIR__)

    if File.exists?(env_path) do
      env_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.each(fn line ->
        case String.split(line, "=", parts: 2) do
          [key, value] ->
            # Remove optional quotes and trim
            key = String.trim(key)
            value = value |> String.trim() |> String.trim("\"") |> String.trim("'")
            System.put_env(key, value)

          _ ->
            :ok
        end
      end)
    else
      :ok
    end
  end
end
