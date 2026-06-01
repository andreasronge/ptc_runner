defmodule PtcRunner.Upstream.ResponseCap do
  @moduledoc false

  # Shared `Req` streaming-response byte cap. Used by the HTTP-based upstream
  # transports (`OpenAPI`, `Transport.McpHttp`) to bound how much of a response
  # body is buffered, halting the stream once the cap is exceeded instead of
  # reading an unbounded payload into memory.

  @doc """
  Build a `Req` `:into` collector that accumulates the response body up to `cap`
  bytes. Once the cap is exceeded the stream is halted and the captured state is
  marked as overflowed (see `extract_body/1`).
  """
  @spec collector(non_neg_integer()) :: (term(), {term(), term()} ->
                                           {:cont | :halt, {term(), term()}})
  def collector(cap) do
    fn {:data, data}, {req, resp} ->
      state =
        resp.private
        |> Map.get(:cap_state, %{bytes: 0, chunks: [], overflow: false})
        |> Map.put(:cap, cap)

      new_size = state.bytes + byte_size(data)

      cond do
        state.overflow ->
          {:halt, {req, resp}}

        new_size > cap ->
          {:halt, {req, put_in(resp.private[:cap_state], %{state | overflow: true})}}

        true ->
          {:cont,
           {req,
            put_in(resp.private[:cap_state], %{
              state
              | bytes: new_size,
                chunks: [state.chunks, data]
            })}}
      end
    end
  end

  @doc """
  Extract `{body, overflow?}` from a response whose body was captured by
  `collector/1`. Returns `{"", false}` when no capture state is present.
  """
  @spec extract_body(map()) :: {binary(), boolean()}
  def extract_body(%{private: private}) do
    case Map.get(private, :cap_state) do
      nil -> {"", false}
      %{chunks: chunks, overflow: overflow?} -> {IO.iodata_to_binary(chunks), overflow?}
    end
  end
end
