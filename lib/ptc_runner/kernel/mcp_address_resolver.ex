defmodule PtcRunner.Kernel.MCPAddressResolver do
  @moduledoc false

  @type family :: :inet | :inet6
  @type resolution :: {:ok, [:inet.ip_address()]} | {:error, term()}
  @type family_resolver :: (charlist(), family() -> resolution())

  @spec resolve(binary() | :inet.ip_address()) ::
          {:ok, [:inet.ip_address()]} | {:error, :nxdomain | :resolution_failed}
  def resolve(address) when is_tuple(address) do
    if :inet.is_ip_address(address), do: {:ok, [address]}, else: {:error, :resolution_failed}
  end

  def resolve(address) when is_binary(address) do
    char_address = String.to_charlist(address)

    case :inet.parse_address(char_address) do
      {:ok, parsed} -> {:ok, [parsed]}
      {:error, :einval} -> resolve_hostname(char_address, &resolve_family/2)
    end
  end

  def resolve(_address), do: {:error, :resolution_failed}

  @doc false
  @spec resolve_hostname(charlist(), family_resolver()) ::
          {:ok, [:inet.ip_address()]} | {:error, :nxdomain | :resolution_failed}
  def resolve_hostname(hostname, resolver)
      when is_list(hostname) and is_function(resolver, 2) do
    results =
      [:inet6, :inet]
      |> Task.async_stream(&resolver.(hostname, &1),
        ordered: true,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, _reason} -> {:error, :resolution_failed}
      end)

    classify_results(results)
  end

  @doc false
  @spec resolve_family(charlist(), family()) :: resolution()
  def resolve_family(hostname, family) when is_list(hostname) and family in [:inet, :inet6],
    do: :inet.getaddrs(hostname, family)

  @doc false
  @spec start_family_queries(charlist(), pid(), reference(), family_resolver()) ::
          MapSet.t(pid())
  def start_family_queries(
        hostname,
        recipient,
        ref,
        resolver \\ &resolve_family/2
      )
      when is_list(hostname) and is_pid(recipient) and is_reference(ref) and
             is_function(resolver, 2) do
    MapSet.new(
      for family <- [:inet6, :inet] do
        spawn_link(fn -> resolve_family(recipient, ref, resolver, hostname, family) end)
      end
    )
  end

  defp resolve_family(recipient, ref, resolver, hostname, family) do
    result = resolver.(hostname, family)
    send(recipient, {ref, :resolved, self(), result})
  rescue
    _exception -> send(recipient, {ref, :resolved, self(), {:error, :resolution_failed}})
  catch
    _kind, _reason -> send(recipient, {ref, :resolved, self(), {:error, :resolution_failed}})
  end

  @doc false
  @spec classify_results([{:ok, [:inet.ip_address()]} | {:error, term()}]) ::
          {:ok, [:inet.ip_address()]} | {:error, :nxdomain | :resolution_failed}
  def classify_results(results) when is_list(results) do
    addresses =
      results
      |> Enum.flat_map(fn
        {:ok, values} when is_list(values) -> values
        _failure -> []
      end)
      |> Enum.uniq()

    cond do
      addresses != [] and Enum.all?(addresses, &:inet.is_ip_address/1) ->
        {:ok, interleave_families(addresses)}

      addresses != [] ->
        {:error, :resolution_failed}

      Enum.all?(results, &match?({:error, :nxdomain}, &1)) ->
        {:error, :nxdomain}

      true ->
        {:error, :resolution_failed}
    end
  end

  def classify_results(_results), do: {:error, :resolution_failed}

  defp interleave_families(addresses) do
    {ipv4, ipv6} = Enum.split_with(addresses, &(tuple_size(&1) == 4))
    interleave(ipv6, ipv4, [])
  end

  defp interleave([ipv6 | ipv6_rest], [ipv4 | ipv4_rest], acc),
    do: interleave(ipv6_rest, ipv4_rest, [ipv4, ipv6 | acc])

  defp interleave(ipv6, ipv4, acc), do: Enum.reverse(acc) ++ ipv6 ++ ipv4
end
