defmodule PtcRunner.Lisp.DefaultLimitsTest do
  # Mutates the global `:ptc_runner` application environment that every sandbox
  # on the node reads, so this case cannot share the scheduler with concurrent
  # ones.
  use ExUnit.Case, async: false

  alias PtcRunner.Lisp

  setup do
    original = Application.fetch_env(:ptc_runner, :default_timeout)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:ptc_runner, :default_timeout, value)
        :error -> Application.delete_env(:ptc_runner, :default_timeout)
      end
    end)

    :ok
  end

  test "run/2 takes its default sandbox timeout from the application environment" do
    Application.put_env(:ptc_runner, :default_timeout, 1)

    assert {:error, result} = Lisp.run("(reduce + (range 20000))")
    assert result.fail.reason == :timeout
    assert result.fail.details.timeout_ms == 1
  end

  test "an explicit :timeout still overrides the configured default" do
    Application.put_env(:ptc_runner, :default_timeout, 1)

    assert {:ok, result} = Lisp.run("(+ 1 2)", timeout: 5_000)
    assert result.return == 3
  end
end
