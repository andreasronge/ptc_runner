defmodule PtcRunner.Labs.ServingHost do
  @moduledoc false
  alias PtcRunner.Kernel.BoundedWorker

  # Includes cold model/bundle preparation, unlike the workflow evaluator's
  # separate heap ceiling. This is a provisional lab request budget.
  @request_heap_words 32_000_000

  # Loopback framing experiment, not an MCP endpoint. The socket stays owned by
  # the connection process. The callback must execute AND publish in its worker;
  # a sealed outcome cannot survive that worker's exit for later publication.
  # Admission belongs to RunAdmission's execution owner, never this wrapper.
  def serve(socket, run, opts \\ []) do
    connection = self()
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)
    :ok = :inet.setopts(socket, active: :once, send_timeout: 1_000, send_timeout_close: true)

    {owner, ref} =
      spawn_monitor(fn ->
        result =
          BoundedWorker.run(run,
            timeout_ms: timeout_ms,
            max_heap_words: @request_heap_words,
            cancel_with: connection,
            cancel_with_caller: true
          )

        send(connection, {:finished, self(), result})
      end)

    try do
      receive do
        {:tcp_closed, ^socket} -> :ok
        {:tcp_error, ^socket, _} -> :ok
        {:tcp, ^socket, _} -> :ok
        {:finished, ^owner, result} -> respond(socket, result)
        {:DOWN, ^ref, :process, ^owner, _} -> respond(socket, {:error, :worker_failed})
      after
        timeout_ms + 1_000 -> respond(socket, {:error, :timeout})
      end
    after
      Process.exit(owner, :kill)
      Process.demonitor(ref, [:flush])
    end
  end

  defp respond(socket, result) do
    {status, body} =
      case result do
        {:ok, {:ok, value}} ->
          {"200 OK", %{"result" => value}}

        {:ok, {:error, :run_capacity_exhausted}} ->
          {"503 Busy", %{"error" => "run_capacity_exhausted"}}

        {:ok, {:error, :run_admission_unavailable}} ->
          {"503 Unavailable", %{"error" => "run_admission_unavailable"}}

        {:error, :timeout} ->
          {"504 Gateway Timeout", %{"error" => "request_timeout"}}

        _ ->
          {"500 Internal Server Error", %{"error" => "run_failed"}}
      end

    body = Jason.encode!(body)

    :gen_tcp.send(socket, [
      "HTTP/1.1 ",
      status,
      "\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\n\r\n",
      body
    ])
  end
end
