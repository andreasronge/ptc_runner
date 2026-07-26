defmodule PtcRunner.Kernel.ProviderResources do
  @moduledoc false

  @type close :: (-> term())

  @spec close([close()]) :: :ok | {:error, :provider_cleanup_failed}
  def close(resources) when is_list(resources) do
    Enum.reduce(resources, :ok, fn close, result ->
      case close_resource(close) do
        :ok -> result
        {:error, :provider_cleanup_failed} -> {:error, :provider_cleanup_failed}
      end
    end)
  end

  defp close_resource(close) do
    case close.() do
      :ok -> :ok
      _non_success -> {:error, :provider_cleanup_failed}
    end
  rescue
    _exception -> {:error, :provider_cleanup_failed}
  catch
    _kind, _reason -> {:error, :provider_cleanup_failed}
  end
end
