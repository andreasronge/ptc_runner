defmodule PtcRunner.Kernel.MCPAddressResolverTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.MCPAddressResolver

  test "keeps literal addresses on their written family" do
    assert {:ok, [{127, 0, 0, 1}]} = MCPAddressResolver.resolve("127.0.0.1")
    assert {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}]} = MCPAddressResolver.resolve("::1")
  end

  test "distinguishes name absence from temporary and mixed-family resolver failures" do
    assert {:error, :nxdomain} =
             MCPAddressResolver.classify_results([
               {:error, :nxdomain},
               {:error, :nxdomain}
             ])

    for results <- [
          [{:error, :timeout}, {:error, :nxdomain}],
          [{:error, :servfail}, {:error, :econnrefused}],
          [{:ok, [:not_an_address]}, {:error, :nxdomain}]
        ] do
      assert {:error, :resolution_failed} = MCPAddressResolver.classify_results(results)
    end

    ipv6 = {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}
    ipv4 = {1, 1, 1, 1}

    assert {:ok, [^ipv6, ^ipv4]} =
             MCPAddressResolver.classify_results([
               {:ok, [ipv6]},
               {:ok, [ipv4]}
             ])
  end

  test "publishes one family without waiting for the other resolver" do
    parent = self()
    ref = make_ref()
    ipv6 = {0, 0, 0, 0, 0, 0, 0, 1}
    ipv4 = {127, 0, 0, 1}

    resolver = fn
      _hostname, :inet6 ->
        {:ok, [ipv6]}

      _hostname, :inet ->
        send(parent, {:ipv4_query_waiting, self()})

        receive do
          :finish_ipv4_query -> {:ok, [ipv4]}
        end
    end

    pids = MCPAddressResolver.start_family_queries(~c"example.test", self(), ref, resolver)

    assert_receive {:ipv4_query_waiting, ipv4_resolver}
    assert_receive {^ref, :resolved, ipv6_resolver, {:ok, [^ipv6]}}
    assert MapSet.member?(pids, ipv6_resolver)
    assert MapSet.member?(pids, ipv4_resolver)

    send(ipv4_resolver, :finish_ipv4_query)
    assert_receive {^ref, :resolved, ^ipv4_resolver, {:ok, [^ipv4]}}
  end
end
