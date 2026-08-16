defmodule PtcRunner.Kernel.MCPOAuth.NetworkPolicy do
  @moduledoc """
  Resolve-and-pin egress policy for MCP OAuth HTTP requests.

  An endpoint must use an installed origin. Every candidate address is
  classified before connection; one denied address rejects the complete DNS
  answer. Callers race the returned addresses while preserving the original
  hostname and verify the connected peer against the same approved set before
  sending request bytes.
  """

  alias PtcRunner.Kernel.MCPAddressResolver
  alias PtcRunner.Kernel.MCPOAuth.Authority

  @max_addresses 16
  @non_public_ipv4_ranges [
    {0x00000000, 0x00FFFFFF},
    {0x0A000000, 0x0AFFFFFF},
    {0x64400000, 0x647FFFFF},
    {0x7F000000, 0x7FFFFFFF},
    {0xA9FE0000, 0xA9FEFFFF},
    {0xAC100000, 0xAC1FFFFF},
    {0xC0000000, 0xC00000FF},
    {0xC0000200, 0xC00002FF},
    {0xC0A80000, 0xC0A8FFFF},
    {0xC6120000, 0xC613FFFF},
    {0xC6336400, 0xC63364FF},
    {0xCB007100, 0xCB0071FF},
    {0xE0000000, 0xFFFFFFFF}
  ]

  @type address :: :inet.ip_address()

  @spec resolve(binary(), Authority.t(), keyword()) ::
          {:ok,
           %{
             addresses: [address()],
             hostname: binary(),
             port: :inet.port_number(),
             origin: binary()
           }}
          | {:error, :egress_denied | :name_not_resolved | :resolution_failed}
  def resolve(url, authority, opts \\ [])

  def resolve(url, %Authority{} = authority, opts)
      when is_binary(url) and is_list(opts) do
    resolver = Keyword.get(opts, :resolver, &default_resolver/1)

    deadline_ms =
      Keyword.get(
        opts,
        :deadline_ms,
        System.monotonic_time(:millisecond) + authority.authorization_timeout_ms
      )

    with true <- is_function(resolver, 1),
         true <- is_integer(deadline_ms),
         :live <- deadline_state(deadline_ms),
         {:ok, target} <- target(url),
         true <- origin_allowed?(target.origin, authority),
         {:ok, addresses} <- safe_resolve(resolver, target.hostname, deadline_ms),
         true <- length(addresses) in 1..@max_addresses,
         true <- addresses == Enum.uniq(addresses),
         true <- Enum.all?(addresses, &:inet.is_ip_address/1),
         private_allowed? <- private_origin?(target.origin, authority),
         true <- private_allowed? or Enum.all?(addresses, &public_address?/1) do
      {:ok, Map.put(target, :addresses, addresses)}
    else
      {:error, reason} = error when reason in [:name_not_resolved, :resolution_failed] -> error
      :expired -> {:error, :resolution_failed}
      _denied -> {:error, :egress_denied}
    end
  end

  def resolve(_url, _authority, _opts), do: {:error, :egress_denied}

  # An already-expired deadline is a resolution-time failure, not an egress
  # verdict: the clock running out before DNS is consulted is
  # indistinguishable from resolution timing out one instruction later, and
  # classifying it the same way keeps the error deterministic under
  # scheduling delay instead of depending on where the caller was preempted.
  defp deadline_state(deadline_ms) do
    if deadline_ms > System.monotonic_time(:millisecond), do: :live, else: :expired
  end

  @doc "Builds a connected-peer verifier for one approved DNS answer."
  @spec peer_verifier([address()]) :: (address() -> :ok | {:error, :peer_rejected})
  def peer_verifier(addresses) when is_list(addresses) do
    approved = MapSet.new(addresses)

    fn address ->
      if MapSet.member?(approved, address),
        do: :ok,
        else: {:error, :peer_rejected}
    end
  end

  @spec public_address?(address()) :: boolean()
  def public_address?({_, _, _, _} = address), do: public_ipv4_address?(address)

  def public_address?({_, _, _, _, _, _, _, _} = address),
    do: public_ipv6_address?(address)

  def public_address?(_address), do: false

  @doc "Returns whether an endpoint uses an origin installed for the authority."
  @spec endpoint_allowed?(binary(), Authority.t()) :: boolean()
  def endpoint_allowed?(url, %Authority{} = authority) when is_binary(url) do
    with {:ok, %{origin: origin}} <- target(url),
         do: origin_allowed?(origin, authority)
  end

  def endpoint_allowed?(_url, _authority), do: false

  defp origin_allowed?(origin, authority) do
    origins = [
      origin_of(authority.resource),
      origin_of(authority.issuer)
      | Enum.map(
          authority.additional_origins ++ authority.private_network_origins,
          &origin_of/1
        )
    ]

    origin in origins
  end

  defp public_ipv4_address?({a, b, c, d}) do
    encoded = a * 16_777_216 + b * 65_536 + c * 256 + d

    not Enum.any?(@non_public_ipv4_ranges, fn {first, last} ->
      encoded in first..last
    end)
  end

  defp public_ipv6_address?({a, b, c, d, e, f, g, h}) do
    cond do
      {a, b, c, d, e} == {0, 0, 0, 0, 0} and f == 0xFFFF ->
        public_address?(
          {Bitwise.bsr(g, 8), Bitwise.band(g, 0xFF), Bitwise.bsr(h, 8), Bitwise.band(h, 0xFF)}
        )

      # Be deliberately conservative: ordinary global unicast currently lives
      # in 2000::/3. Exclude the special-purpose allocations inside that block
      # rather than treating every non-ULA address as Internet-routable.
      a not in 0x2000..0x3FFF ->
        false

      a == 0x2001 and b <= 0x01FF ->
        false

      a == 0x2001 and b == 0x0DB8 ->
        false

      a == 0x2002 ->
        false

      Bitwise.band(a, 0xFFF0) == 0x3FF0 ->
        false

      true ->
        true
    end
  end

  defp target(url) do
    case URI.parse(url) do
      %URI{
        scheme: scheme,
        host: host,
        port: port,
        userinfo: nil,
        fragment: nil
      }
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             is_integer(port) ->
        {:ok,
         %{
           hostname: host,
           port: port,
           origin: canonical_origin(scheme, host, port)
         }}

      _invalid ->
        {:error, :egress_denied}
    end
  end

  defp private_origin?(origin, authority),
    do: origin in Enum.map(authority.private_network_origins, &origin_of/1)

  defp origin_of(url) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(url)
    canonical_origin(scheme, host, port)
  end

  defp canonical_origin(scheme, host, port) do
    default? = (scheme == "https" and port == 443) or (scheme == "http" and port == 80)
    host = String.downcase(host)
    host = if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
    scheme <> "://" <> host <> if(default?, do: "", else: ":" <> Integer.to_string(port))
  end

  defp safe_resolve(resolver, hostname, deadline_ms) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

    if remaining_ms > 0 do
      task = Task.async(fn -> invoke_resolver(resolver, hostname) end)

      case Task.yield(task, remaining_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, addresses}} when is_list(addresses) -> {:ok, addresses}
        {:ok, {:error, :nxdomain}} -> {:error, :name_not_resolved}
        _failure -> {:error, :resolution_failed}
      end
    else
      {:error, :resolution_failed}
    end
  end

  defp invoke_resolver(resolver, hostname) do
    resolver.(hostname)
  rescue
    _exception -> {:error, :resolution_failed}
  catch
    _kind, _reason -> {:error, :resolution_failed}
  end

  defp default_resolver(hostname), do: MCPAddressResolver.resolve(hostname)
end
