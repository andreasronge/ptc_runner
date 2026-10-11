defmodule PtcRunner.Kernel.ManifestReplLease do
  @moduledoc false

  # Token-bearing cleanup protocol; resource ownership and caller authentication
  # stay in the opening process, independent of startup orchestration.

  @enforce_keys [:pid, :token]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{pid: pid(), token: reference()}

  @spec new(pid(), reference()) :: t()
  def new(pid, token) when is_pid(pid) and is_reference(token),
    do: %__MODULE__{pid: pid, token: token}

  @doc false
  @spec await(t()) :: {:ok, pid(), reference()} | {:error, term()}
  def await(%__MODULE__{pid: pid, token: token}) do
    GenServer.call(pid, {token, :await}, :infinity)
  catch
    :exit, _reason -> {:error, :manifest_repl_unavailable}
  end

  @doc false
  @spec close_provider_session(t()) ::
          :ok | {:error, :provider_cleanup_failed | :manifest_repl_unavailable}
  def close_provider_session(%__MODULE__{pid: pid, token: token}) do
    GenServer.call(pid, {token, :close_provider_session}, :infinity)
  catch
    :exit, _reason -> {:error, :provider_cleanup_failed}
  end

  @doc false
  @spec release(t()) :: :ok | {:error, :manifest_repl_unavailable}
  def release(%__MODULE__{pid: pid, token: token}) do
    GenServer.call(pid, {token, :release}, :infinity)
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{pid: pid, token: token}),
    do: is_pid(pid) and is_reference(token) and Process.alive?(pid)

  def valid?(_opening), do: false

  @doc false
  @spec pid(t()) :: pid()
  def pid(%__MODULE__{pid: pid}), do: pid
end
