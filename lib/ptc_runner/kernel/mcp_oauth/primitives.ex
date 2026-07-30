defmodule PtcRunner.Kernel.MCPOAuth.Primitives do
  @moduledoc """
  Small, auditable OAuth authorization-code primitives owned by PtcRunner.

  State and PKCE verifiers are generated independently from 32 random bytes
  and encoded as 43-byte unpadded Base64URL values. Endpoint construction
  retains unrelated query bytes exactly and rejects malformed or colliding
  pre-existing parameters before appending PtcRunner-owned form values.
  """

  @authorization_parameters MapSet.new(~w(
    response_type response_mode client_id redirect_uri scope resource
    code_challenge code_challenge_method state request request_uri
  ))
  @token_parameters MapSet.new(~w(
    grant_type code redirect_uri code_verifier refresh_token client_id
    client_secret scope resource
  ))
  @verifier ~r/\A[A-Za-z0-9\-._~]{43,128}\z/

  @type flow :: %{
          required(:state) => binary(),
          required(:verifier) => binary(),
          required(:challenge) => binary()
        }

  @doc "Generates independent state and S256 PKCE material."
  @spec new_flow() :: flow()
  def new_flow do
    state = random_base64url()
    verifier = random_base64url()

    %{
      state: state,
      verifier: verifier,
      challenge: s256_challenge(verifier)
    }
  end

  @doc "Returns whether a verifier has the RFC 7636 unreserved grammar."
  @spec valid_verifier?(term()) :: boolean()
  def valid_verifier?(verifier), do: is_binary(verifier) and verifier =~ @verifier

  @doc "Builds the exact unpadded S256 challenge for a validated verifier."
  @spec s256_challenge(binary()) :: binary()
  def s256_challenge(verifier) when is_binary(verifier) do
    verifier
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  @doc "Compares two bounded state values without content-dependent early exit."
  @spec state_equal?(term(), term()) :: boolean()
  def state_equal?(left, right)
      when is_binary(left) and is_binary(right) and byte_size(left) <= 256 and
             byte_size(right) <= 256 do
    :crypto.hash_equals(:crypto.hash(:sha256, left), :crypto.hash(:sha256, right))
  end

  def state_equal?(_left, _right), do: false

  @doc "Encodes ordered OAuth form parameters deterministically."
  @spec form_encode([{binary(), binary()}]) :: {:ok, binary()} | {:error, :invalid_parameters}
  def form_encode(parameters) when is_list(parameters) do
    with true <- length(parameters) <= 64,
         true <-
           Enum.all?(parameters, fn
             {name, value} when is_binary(name) and is_binary(value) ->
               byte_size(name) in 1..256 and byte_size(value) <= 16_384 and
                 String.valid?(name) and String.valid?(value)

             _invalid ->
               false
           end),
         names = Enum.map(parameters, &elem(&1, 0)),
         true <- names == Enum.uniq(names) do
      {:ok, Enum.map_join(parameters, "&", &encode_parameter/1)}
    else
      _invalid -> {:error, :invalid_parameters}
    end
  end

  def form_encode(_parameters), do: {:error, :invalid_parameters}

  @doc """
  Appends authorization parameters while retaining unrelated endpoint query
  bytes and order.
  """
  @spec authorization_url(binary(), [{binary(), binary()}], keyword()) ::
          {:ok, binary()} | {:error, :invalid_endpoint | :invalid_parameters}
  def authorization_url(endpoint, parameters, opts \\ []),
    do: append_parameters(endpoint, parameters, @authorization_parameters, opts)

  @doc "Validates an authorization endpoint without appending parameters."
  @spec authorization_endpoint(binary(), keyword()) ::
          {:ok, binary()} | {:error, :invalid_endpoint}
  def authorization_endpoint(endpoint, opts \\ []) do
    with {:ok, _query} <- validated_query(endpoint, @authorization_parameters, opts),
         do: {:ok, endpoint}
  end

  @doc """
  Validates a token endpoint's retained query against token form names.

  The returned endpoint is byte-identical because token parameters belong in
  the POST form body.
  """
  @spec token_endpoint(binary(), keyword()) :: {:ok, binary()} | {:error, :invalid_endpoint}
  def token_endpoint(endpoint, opts \\ []) do
    with {:ok, _query} <- validated_query(endpoint, @token_parameters, opts),
         do: {:ok, endpoint}
  end

  @doc "Constructs RFC 6749 client_secret_basic from independently form-encoded values."
  @spec client_secret_basic(binary(), binary()) ::
          {:ok, binary()} | {:error, :invalid_client_credentials}
  def client_secret_basic(client_id, client_secret)
      when is_binary(client_id) and is_binary(client_secret) do
    if valid_credential_part?(client_id) and valid_credential_part?(client_secret) do
      encoded =
        Base.encode64(URI.encode_www_form(client_id) <> ":" <> URI.encode_www_form(client_secret))

      {:ok, "Basic " <> encoded}
    else
      {:error, :invalid_client_credentials}
    end
  end

  def client_secret_basic(_client_id, _client_secret),
    do: {:error, :invalid_client_credentials}

  defp random_base64url do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp append_parameters(endpoint, parameters, owned, opts) do
    with {:ok, query} <- validated_query(endpoint, owned, opts),
         {:ok, encoded} <- form_encode(parameters),
         true <- encoded != "" do
      separator =
        cond do
          is_nil(query) -> "?"
          query == "" -> ""
          true -> "&"
        end

      {:ok, endpoint <> separator <> encoded}
    else
      {:error, :invalid_parameters} = error -> error
      _invalid -> {:error, :invalid_endpoint}
    end
  end

  defp validated_query(endpoint, owned, opts) when is_binary(endpoint) and is_list(opts) do
    allow_insecure_loopback = Keyword.get(opts, :allow_insecure_loopback, false)

    with true <- byte_size(endpoint) in 1..16_384 and String.valid?(endpoint),
         true <- safe_endpoint_characters?(endpoint),
         %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil} <-
           URI.parse(endpoint),
         true <- is_binary(host) and host != "",
         true <-
           scheme == "https" or
             (allow_insecure_loopback and scheme == "http" and
                host in ["127.0.0.1", "::1"]),
         true <- Keyword.keys(opts) -- [:allow_insecure_loopback] == [],
         {:ok, query} <- raw_query(endpoint),
         :ok <- validate_existing_query(query, owned) do
      {:ok, query}
    else
      _invalid -> {:error, :invalid_endpoint}
    end
  end

  defp validated_query(_endpoint, _owned, _opts), do: {:error, :invalid_endpoint}

  defp safe_endpoint_characters?(endpoint) do
    endpoint
    |> String.to_charlist()
    |> Enum.all?(fn codepoint ->
      codepoint > 0x20 and codepoint not in 0x7F..0x9F
    end)
  end

  defp raw_query(endpoint) do
    case :binary.match(endpoint, "?") do
      :nomatch ->
        {:ok, nil}

      {index, 1} ->
        offset = index + 1
        {:ok, binary_part(endpoint, offset, byte_size(endpoint) - offset)}
    end
  end

  defp validate_existing_query(nil, _owned), do: :ok
  defp validate_existing_query("", _owned), do: :ok

  defp validate_existing_query(query, owned) do
    if byte_size(query) <= 8_192 do
      query
      |> :binary.split("&", [:global])
      |> Enum.reduce_while(:ok, fn part, :ok ->
        name = parameter_name(part)

        with :ok <- valid_percent_encoding(part),
             {:ok, decoded_name} <- decode_www_form(name),
             false <- MapSet.member?(owned, decoded_name) do
          {:cont, :ok}
        else
          _invalid -> {:halt, {:error, :invalid_endpoint}}
        end
      end)
    else
      {:error, :invalid_endpoint}
    end
  end

  defp valid_percent_encoding(value), do: valid_percent_encoding(value, 0)

  defp valid_percent_encoding(value, offset) when offset >= byte_size(value), do: :ok

  defp valid_percent_encoding(value, offset) do
    case :binary.at(value, offset) do
      ?% ->
        if offset + 2 < byte_size(value) and hex?(:binary.at(value, offset + 1)) and
             hex?(:binary.at(value, offset + 2)) do
          valid_percent_encoding(value, offset + 3)
        else
          {:error, :invalid_endpoint}
        end

      _byte ->
        valid_percent_encoding(value, offset + 1)
    end
  end

  defp decode_www_form(value) do
    {:ok, URI.decode_www_form(value)}
  rescue
    _exception -> {:error, :invalid_endpoint}
  end

  defp parameter_name(part) do
    case :binary.match(part, "=") do
      :nomatch -> part
      {index, 1} -> binary_part(part, 0, index)
    end
  end

  defp encode_parameter({name, value}),
    do: URI.encode_www_form(name) <> "=" <> URI.encode_www_form(value)

  defp valid_credential_part?(value),
    do:
      byte_size(value) in 1..8_192 and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp hex?(byte), do: byte in ?0..?9 or byte in ?A..?F or byte in ?a..?f
end
