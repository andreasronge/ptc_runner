defmodule PtcRunner.Kernel.HostRuntimePoisonTest do
  use ExUnit.Case, async: false

  @moduletag :slow

  test "owner death poisons later owner creation and dispatch in an isolated VM" do
    env =
      System.get_env()
      |> Map.put("MIX_ENV", "test")
      |> Map.put("PTC_HOST_RUNTIME_POISON", "1")
      |> Enum.to_list()

    {output, status} =
      System.cmd(
        "elixir",
        [
          "-S",
          "mix",
          "run",
          "--no-start",
          "-e",
          poison_script()
        ],
        cd: File.cwd!(),
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "POISON_OK"
  end

  defp poison_script do
    ~S"""
    Process.flag(:trap_exit, true)
    {:ok, _} = Application.ensure_all_started(:ptc_runner)

    {:ok, _pid} = PtcRunner.Kernel.HostRuntime.start_link([])
    owner = Process.whereis(PtcRunner.Kernel.ProviderAdmission)
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)

    receive do
      {:DOWN, ^ref, :process, ^owner, _reason} -> :ok
    after
      2_000 -> raise "admission owner did not die"
    end

    true = PtcRunner.Kernel.ProviderAdmission.claimed?()
    {:error, :poisoned} = PtcRunner.Kernel.ProviderAdmission.checkout(self())

    case PtcRunner.Kernel.HostRuntime.start_link([]) do
      {:error, :admission_owner_dead} -> :ok
      {:error, {:already_started, pid}} ->
        Supervisor.stop(pid)

        case PtcRunner.Kernel.HostRuntime.start_link([]) do
          {:error, :admission_owner_dead} -> :ok
          other -> raise "expected admission_owner_dead after restart, got: #{inspect(other)}"
        end

      other ->
        raise "expected admission_owner_dead, got: #{inspect(other)}"
    end

    IO.puts("POISON_OK")
    """
  end
end
