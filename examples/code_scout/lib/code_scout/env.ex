defmodule CodeScout.Env do
  @moduledoc """
  Loads environment variables from `.env` files.
  """

  @doc """
  Loads the nearest `.env` file by walking up from the current directory.

  Delegates to `PtcRunner.Dotenv.load/0`.
  """
  defdelegate load, to: PtcRunner.Dotenv
end
