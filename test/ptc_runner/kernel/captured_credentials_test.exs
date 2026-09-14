defmodule PtcRunner.Kernel.CapturedCredentialsTest do
  use ExUnit.Case, async: false
  alias PtcRunner.Kernel.CapturedCredentials

  test "capture resolves the exact union once and later permits only selected subsets" do
    parent = self()
    token = String.duplicate("bearer-token", 4)

    resolver = fn names ->
      send(parent, {:resolved, names})
      {:ok, %{"bearer" => token, "first" => "provider-secret", "second" => "other-secret"}}
    end

    {:ok, owner} =
      CapturedCredentials.start_link(resolver, ["first", "second", "first"], "bearer")

    on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner) end)
    assert_receive {:resolved, ["bearer", "first", "second"]}
    assert {:ok, %{"first" => "provider-secret"}} = CapturedCredentials.resolve(owner, ["first"])
    assert {:ok, %{}} = CapturedCredentials.resolve(owner, [])
    assert {:error, :credential_unavailable} = CapturedCredentials.resolve(owner, ["bearer"])
    assert {:error, :credential_unavailable} = CapturedCredentials.resolve(owner, ["unknown"])
    assert CapturedCredentials.authenticate(owner, token)
    refute CapturedCredentials.authenticate(owner, String.duplicate("wrong", 10))
    refute inspect(:sys.get_status(owner)) =~ "secret"
    refute inspect(:sys.get_status(owner)) =~ token
    refute_receive {:resolved, _}
  end
end
