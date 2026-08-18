defmodule PtcGateway.HTTP.SSE do
  @moduledoc false

  alias PtcGateway.Errors
  alias PtcGateway.Protocol

  @heartbeat ": \n\n"

  @spec accepted?(Plug.Conn.t()) :: boolean()
  def accepted?(%Plug.Conn{} = conn) do
    conn
    |> Plug.Conn.get_req_header("accept")
    |> Enum.flat_map(&media_ranges/1)
    |> Enum.any?(&event_stream_range?/1)
  end

  def accepted?(_conn), do: false

  @spec send_message(Plug.Conn.t(), binary()) :: Plug.Conn.t()
  def send_message(%Plug.Conn{} = conn, frame) when is_binary(frame) do
    case write(open_stream(conn), data_event(frame)) do
      {:ok, conn} -> conn
      :error -> conn
    end
  end

  @spec stream(Plug.Conn.t(), pid(), pos_integer(), pos_integer()) :: Plug.Conn.t()
  def stream(%Plug.Conn{} = conn, owner, id, heartbeat_ms)
      when is_pid(owner) and is_integer(id) and id > 0 and is_integer(heartbeat_ms) and
             heartbeat_ms > 0 do
    case write(open_stream(conn), @heartbeat) do
      {:ok, conn} -> await(conn, owner, id, heartbeat_ms, Process.monitor(owner))
      :error -> cancel(owner, conn)
    end
  end

  defp media_ranges(header) do
    case tokenize(header, ?,) do
      {:ok, ranges} -> ranges
      :error -> []
    end
  end

  defp event_stream_range?(range) do
    case tokenize(range, ?;) do
      {:ok, [type | params]} ->
        String.downcase(type, :ascii) == "text/event-stream" and quality(params) > 0

      _other ->
        false
    end
  end

  defp tokenize(string, separator) do
    case next_part(string, separator, [], <<>>, :plain) do
      :error ->
        :error

      parts ->
        {:ok, parts |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))}
    end
  end

  defp next_part(<<>>, _separator, _parts, _acc, :quoted), do: :error

  defp next_part(<<>>, _separator, parts, acc, :plain), do: Enum.reverse([acc | parts])

  defp next_part(<<?", rest::binary>>, separator, parts, acc, :plain) do
    next_part(rest, separator, parts, acc <> "\"", :quoted)
  end

  defp next_part(<<?", rest::binary>>, separator, parts, acc, :quoted) do
    next_part(rest, separator, parts, acc <> "\"", :plain)
  end

  defp next_part(<<?\\, next, rest::binary>>, separator, parts, acc, :quoted) do
    next_part(rest, separator, parts, acc <> <<?\\, next>>, :quoted)
  end

  defp next_part(<<char, rest::binary>>, separator, parts, acc, :plain) when char == separator do
    next_part(rest, separator, [acc | parts], <<>>, :plain)
  end

  defp next_part(<<char, rest::binary>>, separator, parts, acc, state) do
    next_part(rest, separator, parts, acc <> <<char>>, state)
  end

  defp quality(params) do
    case Enum.find_value(params, &quality_value/1) do
      nil -> 1.0
      q -> q
    end
  end

  defp quality_value(param) do
    case String.downcase(param, :ascii) do
      "q=" <> value -> parse_quality(value)
      _other -> nil
    end
  end

  defp parse_quality(value) do
    case Float.parse(value) do
      {q, remainder} ->
        if String.trim(remainder) == "" and q >= 0 and q <= 1, do: q, else: 0.0

      :error ->
        0.0
    end
  end

  defp await(conn, owner, id, heartbeat_ms, ref) do
    receive do
      {:request_finished, ^owner, ^id, result} ->
        Process.demonitor(ref, [:flush])
        finish(conn, id, result)

      {:DOWN, ^ref, :process, ^owner, reason} ->
        if reason in [:normal, :shutdown],
          do: conn,
          else: finish(conn, id, {:error, :execution})
    after
      heartbeat_ms ->
        case write(conn, @heartbeat) do
          {:ok, conn} ->
            await(conn, owner, id, heartbeat_ms, ref)

          :error ->
            Process.demonitor(ref, [:flush])
            cancel(owner, conn)
        end
    end
  end

  defp finish(conn, id, result) do
    frame =
      case result do
        {:ok, value} when is_map(value) -> Protocol.encode_call_success(id, value)
        {:error, kind} when is_atom(kind) -> call_error_frame(id, kind)
        _other -> Protocol.encode_call_error(id, :execution)
      end

    case write(conn, data_event(frame)) do
      {:ok, conn} -> conn
      :error -> conn
    end
  end

  defp open_stream(conn) do
    conn
    |> Plug.Conn.put_resp_header("cache-control", "no-cache")
    |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
    |> Plug.Conn.send_chunked(200)
  end

  defp data_event(frame), do: "data: " <> String.trim_trailing(frame, "\n") <> "\n\n"

  defp call_error_frame(id, kind) do
    if Errors.jsonrpc?(kind) do
      Protocol.encode_rpc_error(id, kind)
    else
      Protocol.encode_call_error(id, kind)
    end
  end

  defp write(conn, payload) do
    case Plug.Conn.chunk(conn, payload) do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> :error
    end
  end

  defp cancel(owner, conn) when is_pid(owner) do
    Process.unlink(owner)
    Process.exit(owner, :kill)
    conn
  end
end
