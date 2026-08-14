defmodule PtcRunner.TestSupport.MixBackstop do
  @moduledoc """
  A permanent no-op `mix` that stops a stubbed `mix` from falling through to
  the real one.

  Tests that drive `scripts/ci/*.sh` or the pre-push hook stub `mix` by putting
  a fake executable first on `PATH`, in a temporary directory that `on_exit`
  removes. That is safe only while the spawned script cannot outlive its test,
  and under load it can: if the `System.cmd/3` call exceeds ExUnit's timeout,
  ExUnit runs `on_exit` and deletes the stub while the script is still running.
  The script's next `mix` call then resolves past the deleted stub to the
  developer's real `mix`, so an orphaned `scripts/ci/core-tests.sh` starts a
  real `mix test` — which runs this suite, which stubs `mix` again, and each
  round multiplies.

  Inserting this directory between the stub and the inherited `PATH` closes
  that path: once the stub is gone the orphan finds a `mix` that exits 0 and
  stops. `ci_gates_test` covers it directly by deleting a stub and asserting
  the gate script still exits without output. This never shadows the real `mix`
  for ordinary work, because only these fixtures put it on `PATH`.
  """

  @doc """
  Builds the `PATH` a fixture should pass to `System.cmd/3`.

  The test's own stub directory comes first, this backstop second, and the
  inherited `PATH` last.
  """
  @spec stub_path(Path.t()) :: String.t()
  def stub_path(stub_directory) do
    Enum.join([stub_directory, directory(), System.fetch_env!("PATH")], ":")
  end

  @doc """
  Returns a directory holding a `mix` that does nothing and succeeds.
  """
  @spec directory() :: Path.t()
  def directory do
    directory = Path.join([Mix.Project.build_path(), "tmp", "mix-backstop"])
    executable = Path.join(directory, "mix")

    unless File.regular?(executable) do
      File.mkdir_p!(directory)
      install(executable)
    end

    directory
  end

  # Staged under a unique name and renamed into place, so concurrent test files
  # racing to create it can never expose a half-written executable.
  defp install(executable) do
    staged = "#{executable}.#{System.unique_integer([:positive, :monotonic])}"

    File.write!(staged, "#!/bin/sh\nexit 0\n")
    File.chmod!(staged, 0o755)
    File.rename!(staged, executable)
  end
end
