defmodule PtcGateway.ServerTest do
  use ExUnit.Case, async: true

  alias PtcGateway.Pipe

  @input_schema %{
    "type" => "object",
    "properties" => %{"n" => %{"type" => "integer"}},
    "required" => ["n"],
    "additionalProperties" => false
  }
  @output_schema %{
    "type" => "object",
    "properties" => %{"answer" => %{"type" => "integer"}},
    "required" => ["answer"],
    "additionalProperties" => false
  }

  test "lists and calls two tools over newline-delimited JSON" do
    {:ok, pipe} = Pipe.start_link()
    {:ok, gateway} = start_gateway(pipe, max_in_flight: 4)

    Pipe.push(pipe, request(1, "server/discover", %{}))
    Pipe.push(pipe, request(2, "tools/list", %{}))
    Pipe.push(pipe, request(3, "tools/call", %{"name" => "echo", "arguments" => %{"n" => 1}}))
    Pipe.push(pipe, request(4, "tools/call", %{"name" => "double", "arguments" => %{"n" => 2}}))

    frames = Pipe.await_frames(pipe, 4)
    decoded = Enum.map(frames, &decode/1)

    assert Enum.any?(
             decoded,
             &(&1["id"] == 1 and &1["result"]["supportedVersions"] == ["2026-07-28"])
           )

    list = Enum.find(decoded, &(&1["id"] == 2))
    names = list["result"]["tools"] |> Enum.map(& &1["name"]) |> Enum.sort()
    assert names == ["double", "echo"]
    refute Enum.any?(frames, &String.contains?(&1, "Content-Length"))

    echo = Enum.find(decoded, &(&1["id"] == 3))
    assert echo["result"]["structuredContent"] == %{"answer" => 1}
    assert echo["result"]["isError"] == false

    double = Enum.find(decoded, &(&1["id"] == 4))
    assert double["result"]["structuredContent"] == %{"answer" => 4}

    PtcGateway.stop(gateway)
  end

  test "unknown tools and input-contract failures use the closed taxonomy" do
    {:ok, pipe} = Pipe.start_link()
    {:ok, gateway} = start_gateway(pipe, max_in_flight: 2)

    Pipe.push(pipe, request(1, "tools/call", %{"name" => "missing", "arguments" => %{}}))

    Pipe.push(
      pipe,
      request(2, "tools/call", %{"name" => "echo", "arguments" => %{"bad" => true}})
    )

    frames = Pipe.await_frames(pipe, 2)
    decoded = Enum.map(frames, &decode/1)

    unknown = Enum.find(decoded, &(&1["id"] == 1))
    assert unknown["error"]["code"] == -32_602
    assert unknown["error"]["message"] == "unknown tool"

    rejected = Enum.find(decoded, &(&1["id"] == 2))
    assert rejected["result"]["isError"] == true
    assert hd(rejected["result"]["content"])["text"] == "input contract rejected"

    PtcGateway.stop(gateway)
  end

  test "in-flight admission rejects without queueing" do
    {:ok, pipe} = Pipe.start_link()
    blocker = self()

    slow = fn arguments ->
      send(blocker, {:blocked, self()})

      receive do
        :continue -> {:ok, %{"answer" => arguments["n"]}}
      end
    end

    {:ok, gateway} =
      start_gateway(pipe,
        max_in_flight: 1,
        echo_call: slow
      )

    Pipe.push(pipe, request(1, "tools/call", %{"name" => "echo", "arguments" => %{"n" => 1}}))
    assert_receive {:blocked, owner}, 1_000

    Pipe.push(pipe, request(2, "tools/call", %{"name" => "echo", "arguments" => %{"n" => 2}}))
    frames = Pipe.await_frames(pipe, 1)
    saturated = frames |> hd() |> decode()
    assert saturated["id"] == 2
    assert saturated["error"]["code"] == -32_000

    send(owner, :continue)
    PtcGateway.stop(gateway)
  end

  test "connection death kills the in-flight request owner" do
    {:ok, pipe} = Pipe.start_link()
    parent = self()

    slow = fn _arguments ->
      send(parent, {:owner, self()})

      receive do
        :never -> {:ok, %{}}
      end
    end

    {:ok, gateway} = start_gateway(pipe, max_in_flight: 1, echo_call: slow)
    Pipe.push(pipe, request(1, "tools/call", %{"name" => "echo", "arguments" => %{"n" => 1}}))
    assert_receive {:owner, owner}, 1_000
    ref = Process.monitor(owner)

    PtcGateway.stop(gateway)
    assert_receive {:DOWN, ^ref, :process, ^owner, _reason}, 1_000
  end

  test "client EOF stops the gateway" do
    {:ok, pipe} = Pipe.start_link()
    {:ok, gateway} = start_gateway(pipe, max_in_flight: 1)
    ref = Process.monitor(gateway)
    Pipe.close(pipe)
    assert_receive {:DOWN, ^ref, :process, ^gateway, _reason}, 1_000
  end

  test "failed connection start does not leak the supervisor" do
    assert {:error, :invalid_gateway_config} =
             PtcGateway.start(
               tools: [
                 %{
                   name: "bad",
                   description: "bad",
                   input_schema: %{},
                   output_schema: %{},
                   meta: %{},
                   call: :not_a_fun
                 }
               ],
               max_in_flight: 1,
               read: fn -> :eof end,
               write: fn _frame -> :ok end
             )

    refute Enum.any?(Process.list(), &owned_gateway_supervisor?/1)
  end

  @tag :capture_log
  test "reader crash stops the gateway" do
    parent = self()
    {:ok, pipe} = Pipe.start_link()

    {:ok, gateway} =
      start_gateway(pipe,
        max_in_flight: 1,
        read: fn ->
          send(parent, {:reader, self()})

          receive do
            :crash -> raise "boom"
          end
        end
      )

    assert_receive {:reader, reader}, 1_000
    ref = Process.monitor(gateway)
    send(reader, :crash)
    assert_receive {:DOWN, ^ref, :process, ^gateway, _reason}, 1_000
  end

  test "duplicate in-flight JSON-RPC ids are rejected" do
    {:ok, pipe} = Pipe.start_link()
    blocker = self()

    slow = fn arguments ->
      send(blocker, {:blocked, self()})

      receive do
        :continue -> {:ok, %{"answer" => arguments["n"]}}
      end
    end

    {:ok, gateway} = start_gateway(pipe, max_in_flight: 2, echo_call: slow)
    Pipe.push(pipe, request(1, "tools/call", %{"name" => "echo", "arguments" => %{"n" => 1}}))
    assert_receive {:blocked, owner}, 1_000

    Pipe.push(pipe, request(1, "tools/call", %{"name" => "echo", "arguments" => %{"n" => 2}}))
    [frame] = Pipe.await_frames(pipe, 1)
    duplicate = decode(frame)
    assert duplicate["id"] == 1
    assert duplicate["error"]["code"] == -32_600
    assert duplicate["error"]["message"] == "invalid request"

    send(owner, :continue)
    frames = Pipe.await_frames(pipe, 2)

    success =
      frames
      |> Enum.map(&decode/1)
      |> Enum.find(&(&1["id"] == 1 and Map.has_key?(&1, "result")))

    assert success["result"]["structuredContent"] == %{"answer" => 1}

    PtcGateway.stop(gateway)
  end

  defp start_gateway(pipe, opts) do
    echo_call =
      Keyword.get(opts, :echo_call, fn arguments -> {:ok, %{"answer" => arguments["n"]}} end)

    tools = [
      %{
        name: "echo",
        description: "Echo n",
        input_schema: @input_schema,
        output_schema: @output_schema,
        meta: %{"ptc/application_content_digest" => "a"},
        call: fn arguments ->
          if Map.has_key?(arguments, "n"),
            do: echo_call.(arguments),
            else: {:error, :input_contract}
        end
      },
      %{
        name: "double",
        description: "Double n",
        input_schema: @input_schema,
        output_schema: @output_schema,
        meta: %{"ptc/application_content_digest" => "b"},
        call: fn arguments -> {:ok, %{"answer" => arguments["n"] * 2}} end
      }
    ]

    PtcGateway.start(
      tools: tools,
      max_in_flight: Keyword.fetch!(opts, :max_in_flight),
      read: Keyword.get(opts, :read, fn -> Pipe.read(pipe) end),
      write: Keyword.get(opts, :write, fn frame -> Pipe.write(pipe, frame) end)
    )
  end

  defp owned_gateway_supervisor?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        Keyword.get(dict, :"$initial_call") == {PtcGateway.Server, :init, 1} and
          self() in Keyword.get(dict, :"$ancestors", [])

      _other ->
        false
    end
  end

  defp request(id, method, params) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })
  end

  defp decode(frame), do: frame |> String.trim_trailing("\n") |> Jason.decode!()
end
