defmodule PtcRunner.TestSupport.MCPStdioTestLauncher do
  @moduledoc false

  def main do
    {:ok, bootstrap} = read_packet()
    write_packet("R")

    cond do
      :binary.match(bootstrap, "fake-cancel-ack") != :nomatch ->
        stall_cancellation_ack()

      :binary.match(bootstrap, "fake-premature-response") != :nomatch ->
        send_premature_response()
    end
  end

  defp stall_cancellation_ack do
    {:ok, <<"D", ack_id::unsigned-big-64, _request::binary>>} = read_packet()
    write_packet(<<"A", ack_id::unsigned-big-64>>)
    {:ok, <<"D", _ack_id::unsigned-big-64, _cancellation::binary>>} = read_packet()
    IO.binread(:stdio, :eof)
  end

  defp send_premature_response do
    {:ok, <<"D", ack_id::unsigned-big-64, _request::binary>>} = read_packet()

    receive do
    after
      1_000 ->
        write_packet(<<"A", ack_id::unsigned-big-64>>)

        write_packet(
          <<"O", ~s({"jsonrpc":"2.0","id":2,"result":{"method":"premature"}}\n)::binary>>
        )
    end

    IO.binread(:stdio, :eof)
  end

  defp read_packet do
    case IO.binread(:stdio, 4) do
      <<length::unsigned-big-32>> -> read_payload(length)
      _eof -> :eof
    end
  end

  defp read_payload(length) do
    case IO.binread(:stdio, length) do
      payload when is_binary(payload) and byte_size(payload) == length -> {:ok, payload}
      _eof -> :eof
    end
  end

  defp write_packet(payload) do
    IO.binwrite(:stdio, [<<byte_size(payload)::unsigned-big-32>>, payload])
  end
end

PtcRunner.TestSupport.MCPStdioTestLauncher.main()
