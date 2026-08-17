defmodule PtcGateway.Pipe do
  @moduledoc false

  use GenServer

  def start_link do
    GenServer.start_link(__MODULE__, %{
      inbox: :queue.new(),
      outbox: [],
      waiter: nil,
      frame_waiters: [],
      eof: false
    })
  end

  def push(pid, line), do: GenServer.cast(pid, {:push, line})
  def close(pid), do: GenServer.cast(pid, :close)
  def read(pid), do: GenServer.call(pid, :read, 5_000)
  def frames(pid), do: GenServer.call(pid, :frames)
  def write(pid, frame), do: GenServer.cast(pid, {:write, frame})
  def await_frames(pid, count), do: GenServer.call(pid, {:await_frames, count}, 5_000)

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_cast({:push, line}, %{waiter: nil} = state) do
    {:noreply, %{state | inbox: :queue.in(line, state.inbox)}}
  end

  def handle_cast({:push, line}, %{waiter: from} = state) do
    GenServer.reply(from, {:ok, line})
    {:noreply, %{state | waiter: nil}}
  end

  def handle_cast(:close, %{waiter: nil} = state) do
    {:noreply, %{state | eof: true}}
  end

  def handle_cast(:close, %{waiter: from} = state) do
    GenServer.reply(from, :eof)
    {:noreply, %{state | waiter: nil, eof: true}}
  end

  def handle_cast({:write, frame}, state) do
    outbox = state.outbox ++ [frame]

    {ready, rest} =
      Enum.split_with(state.frame_waiters, fn {_from, count} -> length(outbox) >= count end)

    Enum.each(ready, fn {from, _count} -> GenServer.reply(from, outbox) end)
    {:noreply, %{state | outbox: outbox, frame_waiters: rest}}
  end

  @impl GenServer
  def handle_call(:read, from, state) do
    case :queue.out(state.inbox) do
      {{:value, line}, inbox} ->
        {:reply, {:ok, line}, %{state | inbox: inbox}}

      {:empty, _inbox} when state.eof ->
        {:reply, :eof, state}

      {:empty, _inbox} ->
        {:noreply, %{state | waiter: from}}
    end
  end

  def handle_call(:frames, _from, state) do
    {:reply, state.outbox, state}
  end

  def handle_call({:await_frames, count}, from, state) do
    if length(state.outbox) >= count do
      {:reply, state.outbox, state}
    else
      {:noreply, %{state | frame_waiters: [{from, count} | state.frame_waiters]}}
    end
  end
end
