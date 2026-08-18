defmodule PtcGateway.HTTP.SecretTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PtcGateway.HTTP.Secret

  @token "gateway-token-fixture"

  test "process status and crash logs do not carry the token" do
    {:ok, pid} = Secret.start_link([])
    :ok = Secret.install(pid, @token)
    Process.unlink(pid)
    refute inspect(:sys.get_status(pid)) =~ @token
    assert Secret.matches?(pid, @token)

    log =
      capture_log(fn ->
        ref = Process.monitor(pid)
        Process.exit(pid, :oops)
        assert_receive {:DOWN, ^ref, :process, ^pid, :oops}
      end)

    refute log =~ @token
  end
end
