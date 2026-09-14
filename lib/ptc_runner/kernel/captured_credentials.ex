defmodule PtcRunner.Kernel.CapturedCredentials do
  @moduledoc """
  Startup-only, status-redacted owner of a closed credential binding set.

  Capture inside the host's environment scope, then restore that scope before
  readiness. Resolution accepts only a selected subset of provider bindings.
  The bearer binding is available only to `authenticate/2`. Rotation of files,
  environment variables or literals requires restarting the whole host runtime.
  No status API exposes values. This is a trusted-host boundary, not protection
  against VM memory inspection.
  """
  use GenServer
  use PtcRunner.Kernel.OwnerStatusRedaction

  @spec start_link((list(binary()) -> term()), list(binary()), binary()) :: GenServer.on_start()
  def start_link(resolver, provider_names, bearer_binding)
      when is_function(resolver, 1) and is_list(provider_names) and is_binary(bearer_binding),
      do: GenServer.start_link(__MODULE__, {resolver, Enum.uniq(provider_names), bearer_binding})

  @spec resolve(pid(), list(binary())) :: {:ok, map()} | {:error, :credential_unavailable}
  def resolve(owner, names), do: call(owner, {:resolve, names}, {:error, :credential_unavailable})

  @spec authenticate(pid(), binary()) :: boolean()
  def authenticate(owner, candidate)
      when is_binary(candidate) and byte_size(candidate) in 32..4096,
      do: call(owner, {:authenticate, candidate}, false)

  def authenticate(_, _), do: false

  @spec ready?(pid()) :: boolean()
  def ready?(owner), do: call(owner, :ready, false)

  @impl true
  def init({resolver, providers, bearer}) do
    names = Enum.uniq([bearer | providers])

    with {:ok, values} when is_map(values) <- resolver.(names),
         true <- Enum.sort(Map.keys(values)) == Enum.sort(names),
         true <-
           Enum.all?(values, fn {_name, value} -> is_binary(value) and byte_size(value) > 0 end),
         token when is_binary(token) <- values[bearer],
         true <-
           byte_size(token) in 32..4096 and Regex.match?(~r/\A[A-Za-z0-9\-._~+\/]+=*\z/, token) do
      {:ok, %{values: values, providers: MapSet.new(providers), bearer: bearer}}
    else
      _ -> {:stop, :credential_unavailable}
    end
  rescue
    _ -> {:stop, :credential_unavailable}
  catch
    _, _ -> {:stop, :credential_unavailable}
  end

  @impl true
  def handle_call(:ready, _, state), do: {:reply, true, state}

  def handle_call({:resolve, names}, _, state) do
    if is_list(names) and Enum.all?(names, &MapSet.member?(state.providers, &1)),
      do: {:reply, {:ok, Map.take(state.values, names)}, state},
      else: {:reply, {:error, :credential_unavailable}, state}
  end

  def handle_call({:authenticate, candidate}, _, state) do
    expected = :crypto.hash(:sha256, state.values[state.bearer])
    actual = :crypto.hash(:sha256, candidate)
    {:reply, :crypto.hash_equals(expected, actual), state}
  end

  defp call(owner, message, fallback) do
    GenServer.call(owner, message)
  catch
    :exit, _ -> fallback
  end
end
