defmodule PtcRunner.Kernel.MCPAddressResolverTest do
  use ExUnit.Case, async: false

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

  test "resolves both families concurrently on a single scheduler" do
    parent = self()
    gate = make_ref()
    original_schedulers = :erlang.system_info(:schedulers_online)

    resolver = fn _hostname, family ->
      send(parent, {gate, :started, family, self()})

      receive do
        {^gate, :release} -> {:error, :nxdomain}
      end
    end

    try do
      :erlang.system_flag(:schedulers_online, 1)

      task =
        Task.async(fn ->
          MCPAddressResolver.resolve_hostname(~c"example.test", resolver)
        end)

      assert_receive {^gate, :started, :inet6, ipv6_resolver}
      assert_receive {^gate, :started, :inet, ipv4_resolver}

      send(ipv6_resolver, {gate, :release})
      send(ipv4_resolver, {gate, :release})

      assert Task.await(task) == {:error, :nxdomain}
    after
      :erlang.system_flag(:schedulers_online, original_schedulers)
    end
  end
end
