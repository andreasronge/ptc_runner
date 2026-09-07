defmodule PtcRunner.Labs.TLSProxy do
  @moduledoc false

  # Adds verified TLS to the existing HTTP fixture without a second HTTP parser.
  # Every tunnel is supervised and both sockets are owned by that tunnel.
  def start(endpoint, server_options) do
    port = URI.parse(endpoint).port

    {:ok, listener} =
      :ssl.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}] ++ server_options)

    {:ok, {_, tls_port}} = :ssl.sockname(listener)
    {:ok, supervisor} = Task.Supervisor.start_link(max_children: 16)

    {:ok, _} =
      Task.Supervisor.start_child(supervisor, fn -> accept(listener, supervisor, port) end)

    %{
      endpoint: "https://localhost:#{tls_port}/mcp",
      close: fn ->
        :ssl.close(listener)

        try do
          Supervisor.stop(supervisor)
        catch
          :exit, _ -> :ok
        end
      end
    }
  end

  defp accept(listener, supervisor, port) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        case Task.Supervisor.start_child(supervisor, fn ->
               receive do
                 {:socket, socket} -> tunnel(socket, port)
               end
             end) do
          {:ok, worker} ->
            :ok = :ssl.controlling_process(socket, worker)
            send(worker, {:socket, socket})

          {:error, _} ->
            :ssl.close(socket)
        end

        accept(listener, supervisor, port)

      {:error, _} ->
        :ok
    end
  end

  defp tunnel(socket, port) do
    try do
      with {:ok, socket} <- :ssl.handshake(socket, 5_000),
           {:ok, tcp} <-
             :gen_tcp.connect(
               {127, 0, 0, 1},
               port,
               [:binary, active: false, send_timeout: 1_000, send_timeout_close: true],
               5_000
             ) do
        try do
          :ok = :ssl.setopts(socket, send_timeout: 1_000, send_timeout_close: true)
          forward(socket, tcp)
        after
          :gen_tcp.close(tcp)
        end
      end
    after
      :ssl.close(socket)
    end
  end

  defp forward(ssl, tcp) do
    :ok = :ssl.setopts(ssl, active: :once)
    :ok = :inet.setopts(tcp, active: :once)

    receive do
      {:ssl, ^ssl, data} ->
        if :gen_tcp.send(tcp, data) == :ok, do: forward(ssl, tcp)

      {:tcp, ^tcp, data} ->
        if :ssl.send(ssl, data) == :ok, do: forward(ssl, tcp)

      {:ssl_closed, ^ssl} ->
        :ok

      {:tcp_closed, ^tcp} ->
        :ok

      {:ssl_error, ^ssl, _} ->
        :ok

      {:tcp_error, ^tcp, _} ->
        :ok
    after
      30_000 -> :ok
    end
  end
end
