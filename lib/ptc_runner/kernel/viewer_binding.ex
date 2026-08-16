defmodule PtcRunner.Kernel.ViewerBinding do
  @moduledoc """
  Closed `ptc viewer` listener vocabulary.

  The strict parser and the Viewer frontend share this module so a bind address
  is decided in exactly one place. Loopback is the default and the only address
  reachable without naming it; the single non-loopback value is the wildcard,
  which publishes an unauthenticated trace browser to every host that can reach
  the port. A general address parser would turn a typo into a different
  exposure, so the vocabulary is closed rather than parsed.
  """

  @loopback {127, 0, 0, 1}
  @wildcard {0, 0, 0, 0}
  @addresses %{"127.0.0.1" => @loopback, "0.0.0.0" => @wildcard}

  @type address :: :inet.ip4_address()

  @doc "The address bound when `--listen` is absent."
  @spec loopback() :: address()
  def loopback, do: @loopback

  @doc "Accepted `--listen` spellings, for help and diagnostics."
  @spec addresses() :: [binary()]
  def addresses, do: @addresses |> Map.keys() |> Enum.sort()

  @doc "True for every address this command may bind."
  @spec address?(term()) :: boolean()
  def address?(address), do: address in Map.values(@addresses)

  @doc "True when the address exposes the Viewer beyond this host."
  @spec exposed?(term()) :: boolean()
  def exposed?(@wildcard), do: true
  def exposed?(_address), do: false

  @doc "Resolves one `--listen` value; an absent value is loopback."
  @spec address(binary() | nil) :: {:ok, address()} | :error
  def address(nil), do: {:ok, @loopback}

  def address(value) when is_binary(value), do: Map.fetch(@addresses, value)

  def address(_value), do: :error

  @doc """
  Resolves one `--port` value.

  `0` is accepted and asks the operating system for an ephemeral port, matching
  the project configuration schema.
  """
  @spec port(binary()) :: {:ok, 0..65_535} | :error
  def port(value) when is_binary(value) do
    case Integer.parse(value) do
      {port, ""} when port in 0..65_535 -> {:ok, port}
      _invalid -> :error
    end
  end

  def port(_value), do: :error
end
