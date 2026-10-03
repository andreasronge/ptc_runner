defmodule PtcRunner.TestSupport.DecisionHTTPFixture do
  @moduledoc false
  alias PtcRunner.TestSupport.HTTPRequest

  def start(response, owner) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    {:ok, task} = Task.start(fn -> serve(listener, response, owner) end)
    %{endpoint: "http://127.0.0.1:#{port}/decisions", listener: listener, task: task}
  end

  def stop(fixture) do
    monitor = Process.monitor(fixture.task)
    :gen_tcp.close(fixture.listener)

    receive do
      {:DOWN, ^monitor, :process, _, _} -> :ok
    after
      2000 -> raise "decision fixture did not stop"
    end
  end

  defp serve(listener, response, owner) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, wire} = HTTPRequest.receive_complete(socket)
        [headers, body] = :binary.split(wire, "\r\n\r\n")
        send(owner, {:decision_http_request, headers, Jason.decode!(body)})
        json = Jason.encode!(response)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(json)}\r\nConnection: close\r\n\r\n#{json}"
          )

        :gen_tcp.close(socket)
        serve(listener, response, owner)

      {:error, :closed} ->
        :ok
    end
  end
end
