defmodule PtcRunner.Upstream.Transport.McpHttp.SseDecoder do
  @moduledoc false

  @type decode_result ::
          {:ok, map()}
          | {:error, :stream_closed_before_response, String.t()}
          | {:error, :response_too_large, String.t()}

  @spec decode_binary(binary(), keyword()) :: decode_result()
  def decode_binary(bytes, opts) when is_binary(bytes) do
    decode_stream([bytes], opts)
  end

  @spec decode_stream(Enumerable.t(), keyword()) :: decode_result()
  def decode_stream(stream, opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    max_bytes = Keyword.fetch!(opts, :max_bytes)

    init = %{buffer: "", bytes: 0, request_id: request_id, max_bytes: max_bytes}

    case Enum.reduce_while(stream, {:cont, init}, &reduce_chunk/2) do
      {:ok, msg} -> {:ok, msg}
      {:error, _, _} = err -> err
      {:cont, state} -> flush_result(state)
    end
  end

  defp reduce_chunk(chunk, {:cont, state}) do
    chunk = IO.iodata_to_binary(chunk)
    bytes = state.bytes + byte_size(chunk)

    if bytes > state.max_bytes do
      {:halt,
       {:error, :response_too_large,
        "SSE response #{bytes} bytes exceeds max_bytes (#{state.max_bytes})"}}
    else
      state = %{state | bytes: bytes, buffer: state.buffer <> chunk}

      case process_buffer(state) do
        {:done, msg} -> {:halt, {:ok, msg}}
        {:cont, state} -> {:cont, {:cont, state}}
      end
    end
  end

  defp flush_result(state) do
    case flush_remaining(state) do
      {:done, msg} ->
        {:ok, msg}

      :exhausted ->
        {:error, :stream_closed_before_response,
         "SSE stream closed before response with id=#{inspect(state.request_id)} arrived"}
    end
  end

  defp process_buffer(state) do
    case split_event(state.buffer) do
      :no_event ->
        {:cont, state}

      {:event, raw_event, rest} ->
        case dispatch_event(raw_event, state.request_id) do
          {:done, msg} -> {:done, msg}
          :continue -> process_buffer(%{state | buffer: rest})
        end
    end
  end

  defp split_event(buffer) do
    case :binary.match(buffer, ["\n\n", "\r\n\r\n"]) do
      :nomatch ->
        :no_event

      {pos, len} ->
        <<raw_event::binary-size(pos), _boundary::binary-size(len), rest::binary>> = buffer
        {:event, raw_event, rest}
    end
  end

  defp flush_remaining(%{buffer: ""}), do: :exhausted

  defp flush_remaining(state) do
    case dispatch_event(state.buffer, state.request_id) do
      {:done, msg} -> {:done, msg}
      :continue -> :exhausted
    end
  end

  defp dispatch_event(raw_event, request_id) do
    case extract_data_payload(raw_event) do
      :no_data ->
        :continue

      {:ok, payload} ->
        case Jason.decode(payload) do
          {:ok, value} -> dispatch_value(value, request_id)
          {:error, _} -> :continue
        end
    end
  end

  defp extract_data_payload(raw_event) do
    raw_event
    |> :binary.split("\n", [:global])
    |> Enum.map(&strip_cr/1)
    |> Enum.flat_map(&data_line/1)
    |> case do
      [] -> :no_data
      lines -> {:ok, Enum.join(lines, "\n")}
    end
  end

  defp strip_cr(line) do
    case byte_size(line) do
      0 ->
        line

      size ->
        rest_size = size - 1

        case line do
          <<rest::binary-size(rest_size), "\r">> -> rest
          _ -> line
        end
    end
  end

  defp data_line("data:" <> rest), do: [strip_leading_space(rest)]
  defp data_line(_), do: []

  defp strip_leading_space(<<" ", rest::binary>>), do: rest
  defp strip_leading_space(rest), do: rest

  defp dispatch_value(value, request_id) when is_map(value), do: match_message(value, request_id)

  defp dispatch_value(value, request_id) when is_list(value) do
    dispatch_array(value, request_id)
  end

  defp dispatch_value(_other, _request_id), do: :continue
  defp dispatch_array([], _request_id), do: :continue

  defp dispatch_array([head | tail], request_id) do
    case match_message(head, request_id) do
      {:done, msg} -> {:done, msg}
      :continue -> dispatch_array(tail, request_id)
    end
  end

  defp match_message(%{"id" => id} = msg, request_id) when id == request_id, do: {:done, msg}
  defp match_message(_msg, _request_id), do: :continue
end
