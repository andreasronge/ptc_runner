defmodule PtcRunner.Kernel.MCPEndpoint do
  @moduledoc false

  # The one origin rule for MCP streamable-HTTP endpoints and for the OAuth
  # identifiers derived from them.
  #
  # An endpoint requires HTTPS. Plain HTTP is admitted only against a literal
  # loopback address, and only when the caller explicitly asked for it.
  # `localhost` is deliberately not a loopback address here: it is a name that
  # resolves wherever the resolver says it does, so admitting it would make the
  # exception depend on `/etc/hosts` and on DNS search order rather than on the
  # address the operator wrote down.
  #
  # Two callers need different amounts of this rule.
  #
  # `validate/2` is the whole policy, including its consistency half: an
  # allowance set against an HTTPS endpoint is refused rather than ignored,
  # because a declaration granting an exception it does not need is stale
  # configuration, and refusing it catches the edit that moved an endpoint to
  # TLS without removing the allowance. Transport declarations use this.
  #
  # `origin_allowed?/3` is the predicate alone, without that consistency half.
  # The OAuth issuer, resource, and metadata identifiers are canonicalized with
  # the allowance carried over from the transport that produced them, and
  # `PtcRunner.Kernel.MCPOAuth.Authority.valid?/1` re-derives an HTTPS authority
  # with it set, so refusing the redundant combination there would reject
  # authorities that are correct.

  @loopback_hosts ["127.0.0.1", "::1"]

  @doc "Returns whether `host` is a literal loopback address."
  @spec loopback_host?(term()) :: boolean()
  def loopback_host?(host), do: host in @loopback_hosts

  @doc """
  Returns whether an endpoint is free of whitespace and control characters.

  `URI.parse/1` puts anything it cannot place into the path, so a CRLF in an
  endpoint survives every scheme, host, userinfo, and fragment check and only
  fails when Mint refuses the request target. That is a static fault in a fixed
  configuration value, so it is settled with the rest of the endpoint rather
  than surfacing later as a transport failure.
  """
  @spec safe_characters?(term()) :: boolean()
  def safe_characters?(endpoint) when is_binary(endpoint) do
    String.valid?(endpoint) and
      endpoint
      |> String.to_charlist()
      |> Enum.all?(fn codepoint -> codepoint > 0x20 and codepoint not in 0x7F..0x9F end)
  end

  def safe_characters?(_endpoint), do: false

  @doc """
  Returns whether an origin may be contacted.

  HTTPS is always admissible. Plain HTTP is admissible only against a literal
  loopback address with `allow_insecure_loopback` set.
  """
  @spec origin_allowed?(term(), term(), boolean()) :: boolean()
  def origin_allowed?("https", host, _allow_insecure_loopback),
    do: is_binary(host) and host != ""

  def origin_allowed?("http", host, true), do: loopback_host?(host)
  def origin_allowed?(_scheme, _host, _allow_insecure_loopback), do: false

  @doc """
  Validates one fixed transport endpoint against the whole policy.

  Userinfo and fragments are rejected on both schemes. `allow_insecure_loopback`
  both permits plain-HTTP loopback and requires it: an HTTPS endpoint must not
  carry the allowance.
  """
  @spec validate(term(), boolean()) :: :ok | {:error, :invalid_endpoint}
  def validate(endpoint, allow_insecure_loopback)
      when is_binary(endpoint) and is_boolean(allow_insecure_loopback) do
    if safe_characters?(endpoint),
      do: validate_origin(endpoint, allow_insecure_loopback),
      else: {:error, :invalid_endpoint}
  end

  def validate(_endpoint, _allow_insecure_loopback), do: {:error, :invalid_endpoint}

  defp validate_origin(endpoint, allow_insecure_loopback) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil} = uri ->
        if origin_allowed?(scheme, host, allow_insecure_loopback) and
             allow_insecure_loopback == (scheme == "http") and port_written_plainly?(uri),
           do: :ok,
           else: {:error, :invalid_endpoint}

      _uri ->
        {:error, :invalid_endpoint}
    end
  end

  # `URI.parse/1` answers with the scheme's default port when it cannot read the
  # one it was given, so `https://mcp.example.test:bad` silently becomes 443 and
  # `http://[::1]:bad` becomes 80. An installed endpoint has to mean what it
  # says, so a written port must round-trip and land in range.
  defp port_written_plainly?(%URI{authority: authority, port: port})
       when is_binary(authority) and is_integer(port) do
    case Regex.run(~r/:([^\]:]*)\z/, authority) do
      nil -> true
      [_match, written] -> written == Integer.to_string(port) and port in 1..65_535
    end
  end

  defp port_written_plainly?(_uri), do: false
end
