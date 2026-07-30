defmodule PtcRunner.Kernel.MCPOAuth.BearerChallenge do
  @moduledoc """
  Bounded RFC 9110 challenge parser specialized for MCP Bearer challenges.

  Multiple `WWW-Authenticate` field lines are combined as one list. Other
  schemes are ignored after syntactic segmentation, while zero or one Bearer
  challenge is accepted. Bearer parameter names are case-insensitive and
  duplicate names or multiple Bearer challenges fail closed.
  """

  @max_fields 16
  @max_bytes 16_384
  @max_parameters 32
  @token ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/

  @type challenge :: %{required(binary()) => binary()}

  @spec parse([binary()]) ::
          {:ok, challenge() | nil} | {:error, :invalid_bearer_challenge}
  def parse(fields) when is_list(fields) and length(fields) <= @max_fields do
    with true <- Enum.all?(fields, &valid_field?/1),
         combined = Enum.join(fields, ","),
         true <- byte_size(combined) <= @max_bytes,
         {:ok, segments} <- split_segments(combined),
         {:ok, challenges} <- assemble(segments),
         bearers =
           Enum.filter(challenges, fn challenge ->
             ascii_downcase(challenge.scheme) == "bearer"
           end),
         true <- length(bearers) <= 1 do
      case bearers do
        [] -> {:ok, nil}
        [%{params: params, token68: nil}] -> {:ok, params}
        [_invalid_token68] -> {:error, :invalid_bearer_challenge}
      end
    else
      _invalid -> {:error, :invalid_bearer_challenge}
    end
  end

  def parse(_fields), do: {:error, :invalid_bearer_challenge}

  defp valid_field?(value),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) <= @max_bytes and
        not String.contains?(value, ["\r", "\n", <<0>>])

  defp split_segments(value), do: split_segments(value, [], "", false, false)

  defp split_segments(<<>>, segments, current, false, false) do
    segment = String.trim(current)

    if segment == "" and segments != [],
      do: {:error, :invalid_bearer_challenge},
      else: {:ok, Enum.reverse(if(segment == "", do: segments, else: [segment | segments]))}
  end

  defp split_segments(<<>>, _segments, _current, _quoted?, _escaped?),
    do: {:error, :invalid_bearer_challenge}

  defp split_segments(<<?\\, rest::binary>>, segments, current, true, false),
    do: split_segments(rest, segments, current <> <<?\\>>, true, true)

  defp split_segments(<<byte, rest::binary>>, segments, current, quoted?, true),
    do: split_segments(rest, segments, current <> <<byte>>, quoted?, false)

  defp split_segments(<<?", rest::binary>>, segments, current, quoted?, false),
    do: split_segments(rest, segments, current <> <<?">>, not quoted?, false)

  defp split_segments(<<?,, rest::binary>>, segments, current, false, false) do
    segment = String.trim(current)

    if segment == "",
      do: {:error, :invalid_bearer_challenge},
      else: split_segments(rest, [segment | segments], "", false, false)
  end

  defp split_segments(<<byte, rest::binary>>, segments, current, quoted?, false),
    do: split_segments(rest, segments, current <> <<byte>>, quoted?, false)

  defp assemble(segments) do
    Enum.reduce_while(segments, {:ok, []}, fn segment, {:ok, challenges} ->
      case segment_kind(segment) do
        {:parameter, name, value} ->
          add_parameter(challenges, name, value)

        {:challenge, challenge} ->
          {:cont, {:ok, [challenge | challenges]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, challenges} -> {:ok, Enum.reverse(challenges)}
      {:error, _reason} = error -> error
    end
  end

  defp add_parameter([current | rest], name, value) do
    case put_parameter(current, name, value) do
      {:ok, current} -> {:cont, {:ok, [current | rest]}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp add_parameter([], _name, _value),
    do: {:halt, {:error, :invalid_bearer_challenge}}

  defp segment_kind(segment) do
    with {:ok, first, rest} <- take_token(segment) do
      rest = trim_ows(rest)

      cond do
        String.starts_with?(rest, "=") ->
          with {:ok, value} <- parse_parameter_value(rest),
               do: {:parameter, first, value}

        rest == "" ->
          {:challenge, %{scheme: first, params: %{}, token68: nil}}

        true ->
          first_challenge_parameter(first, rest)
      end
    end
  end

  defp first_challenge_parameter(scheme, rest) do
    if valid_token68?(rest) do
      {:challenge, %{scheme: scheme, params: %{}, token68: rest}}
    else
      case take_token(rest) do
        {:ok, name, after_name} ->
          with true <- String.starts_with?(trim_ows(after_name), "="),
               {:ok, value} <- parse_parameter_value(trim_ows(after_name)),
               {:ok, challenge} <-
                 put_parameter(%{scheme: scheme, params: %{}, token68: nil}, name, value) do
            {:challenge, challenge}
          else
            _invalid -> {:error, :invalid_bearer_challenge}
          end

        {:error, _reason} ->
          {:error, :invalid_bearer_challenge}
      end
    end
  end

  defp put_parameter(%{token68: nil, params: params} = challenge, name, value) do
    key = ascii_downcase(name)

    if map_size(params) < @max_parameters and not Map.has_key?(params, key) do
      {:ok, %{challenge | params: Map.put(params, key, value)}}
    else
      {:error, :invalid_bearer_challenge}
    end
  end

  defp put_parameter(_challenge, _name, _value),
    do: {:error, :invalid_bearer_challenge}

  defp take_token(value) do
    {token, rest} = Enum.split_while(:binary.bin_to_list(value), &token_byte?/1)
    token = IO.iodata_to_binary(token)
    rest = IO.iodata_to_binary(rest)

    if token != "" and token =~ @token,
      do: {:ok, token, rest},
      else: {:error, :invalid_bearer_challenge}
  end

  defp parse_parameter_value("=" <> rest) do
    rest = trim_ows(rest)

    case rest do
      <<?">> <> quoted -> parse_quoted(quoted, "")
      _token -> parse_bare_token(rest)
    end
  end

  defp parse_parameter_value(_rest), do: {:error, :invalid_bearer_challenge}

  defp parse_quoted(<<?">>, decoded), do: {:ok, decoded}

  defp parse_quoted(<<?", rest::binary>>, decoded) do
    if trim_ows(rest) == "",
      do: {:ok, decoded},
      else: {:error, :invalid_bearer_challenge}
  end

  defp parse_quoted(<<?\\, byte, rest::binary>>, decoded)
       when byte in 0x20..0x7E,
       do: parse_quoted(rest, decoded <> <<byte>>)

  defp parse_quoted(<<byte, rest::binary>>, decoded)
       when byte == 0x09 or byte in 0x20..0x21 or byte in 0x23..0x5B or
              byte in 0x5D..0x7E,
       do: parse_quoted(rest, decoded <> <<byte>>)

  defp parse_quoted(_invalid, _decoded), do: {:error, :invalid_bearer_challenge}

  defp parse_bare_token(value) do
    value = trim_ows(value)
    if value =~ @token, do: {:ok, value}, else: {:error, :invalid_bearer_challenge}
  end

  defp valid_token68?(value) do
    value =~ ~r/\A[A-Za-z0-9\-._~+\/]+=*\z/
  end

  defp token_byte?(byte),
    do:
      byte in ?0..?9 or byte in ?A..?Z or byte in ?a..?z or
        byte in ~c"!#$%&'*+-.^_`|~"

  defp trim_ows(value), do: value |> trim_ows_leading() |> trim_ows_trailing()

  defp trim_ows_leading(<<byte, rest::binary>>) when byte in [0x20, 0x09],
    do: trim_ows_leading(rest)

  defp trim_ows_leading(value), do: value

  defp trim_ows_trailing(<<>>), do: <<>>

  defp trim_ows_trailing(value) do
    if :binary.last(value) in [0x20, 0x09] do
      trim_ows_trailing(binary_part(value, 0, byte_size(value) - 1))
    else
      value
    end
  end

  defp ascii_downcase(value) do
    for <<byte <- value>>, into: <<>> do
      if byte in ?A..?Z, do: <<byte + 32>>, else: <<byte>>
    end
  end
end
