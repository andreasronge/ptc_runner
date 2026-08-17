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
      |> Enum.all?(&safe_codepoint?/1)
  end

  def safe_characters?(_endpoint), do: false

  # ASCII control characters and space, C1 controls, and every Unicode space
  # separator. The last group is not idle strictness: the schema mirror excludes
  # `\s`, so admitting a non-breaking space here would let decoding accept an
  # endpoint the schema refuses — the one direction the mirror must never take.
  defp safe_codepoint?(codepoint) do
    codepoint > 0x20 and codepoint not in 0x7F..0x9F and
      codepoint not in 0x2000..0x200A and
      codepoint not in [0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
  end

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
  def validate(endpoint, allow_insecure_loopback) do
    case diagnose(endpoint, allow_insecure_loopback) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_endpoint}
    end
  end

  @doc false
  @spec diagnose(term(), term()) ::
          :ok
          | {:error,
             :invalid_endpoint
             | :https_required
             | :insecure_loopback_required
             | :literal_loopback_required
             | :insecure_loopback_forbidden}
  def diagnose(endpoint, allow_insecure_loopback)
      when is_binary(endpoint) and is_boolean(allow_insecure_loopback) do
    if safe_characters?(endpoint),
      do: diagnose_origin(endpoint, allow_insecure_loopback),
      else: {:error, :invalid_endpoint}
  end

  def diagnose(_endpoint, _allow_insecure_loopback), do: {:error, :invalid_endpoint}

  defp diagnose_origin(endpoint, allow_insecure_loopback) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil} = uri ->
        diagnose_written_origin(endpoint, uri, scheme, host, allow_insecure_loopback)

      _uri ->
        {:error, :invalid_endpoint}
    end
  end

  defp diagnose_written_origin(endpoint, uri, scheme, host, allow_insecure_loopback) do
    if written_plainly?(endpoint, uri) do
      diagnose_origin_policy(scheme, host, allow_insecure_loopback)
    else
      {:error, :invalid_endpoint}
    end
  end

  defp diagnose_origin_policy("https", _host, true),
    do: {:error, :insecure_loopback_forbidden}

  defp diagnose_origin_policy("https", host, false) when is_binary(host) and host != "",
    do: :ok

  defp diagnose_origin_policy("http", _host, false),
    do: {:error, :insecure_loopback_required}

  defp diagnose_origin_policy("http", host, true) do
    if loopback_host?(host), do: :ok, else: {:error, :literal_loopback_required}
  end

  defp diagnose_origin_policy(scheme, _host, _allow_insecure_loopback)
       when is_binary(scheme),
       do: {:error, :https_required}

  defp diagnose_origin_policy(_scheme, _host, _allow_insecure_loopback),
    do: {:error, :invalid_endpoint}

  # `URI.parse/1` is forgiving in two ways an installed endpoint must not be. It
  # answers with the scheme's default port when it cannot read the one it was
  # given, so `https://mcp.example.test:bad` silently becomes 443 and
  # `http://[::1]:bad` becomes 80; and it lowercases the scheme, so `HTTPS://`
  # parses as `https` while the schema mirror — which cannot fold case in a
  # portable pattern — refuses it.
  #
  # Both are answered the same way: a fixed endpoint has to be written the way
  # it is read. The scheme must already be lowercase, and the authority must be
  # exactly the parsed host, bracketed when it is IPv6, plus at most an explicit
  # in-range port. Comparing the whole authority rather than its tail is what
  # rejects `example.test:bad:443` and `[2001:db8::1]garbage:443`, where a
  # trailing `:443` looks well formed on its own.
  defp written_plainly?(endpoint, %URI{authority: authority, host: host, port: port} = uri)
       when is_binary(authority) and is_binary(host) and is_integer(port) do
    bare = if String.contains?(host, ":"), do: "[" <> host <> "]", else: host

    String.starts_with?(endpoint, uri.scheme <> "://") and
      port in 1..65_535 and
      authority in [bare, bare <> ":" <> Integer.to_string(port)]
  end

  defp written_plainly?(_endpoint, _uri), do: false
end
