defmodule PtcRunnerMcp.StdioLifecycleTest do
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Stdio

  test "stdin EOF notifies observer with :eof and stops cleanly" do
    {:ok, io} = StringIO.open(<<>>, capture_prompt: false)

    {:ok, stdio} =
      Stdio.start_link(
        io: io,
        observer: self(),
        auto_read: true,
        name: :"stdio_eof_#{System.unique_integer([:positive])}"
      )

    ref = Process.monitor(stdio)

    assert_receive {Stdio, {:exited, :eof}}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^stdio, :normal}, 1_000

    StringIO.close(io)
  end

  test "exit notification stops the loop without calling System.stop" do
    {:ok, io} = StringIO.open(<<>>, capture_prompt: false)

    {:ok, stdio} =
      Stdio.start_link(
        io: io,
        observer: self(),
        auto_read: false,
        name: :"stdio_exit_#{System.unique_integer([:positive])}"
      )

    bytes = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "exit"}) <> "\n"
    :ok = Stdio.feed(stdio, bytes)

    assert_receive {Stdio, {:exited, :exit_method}}, 1_000

    GenServer.stop(stdio, :normal)
    StringIO.close(io)
  end
end
