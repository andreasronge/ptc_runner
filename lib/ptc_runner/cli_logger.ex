defmodule PtcRunner.CLILogger do
  @moduledoc false

  @handler_keys [:level, :filter_default, :filters, :formatter]

  @doc false
  @spec install_stderr_handler() :: :ok
  def install_stderr_handler do
    case :logger.get_handler_config(:default) do
      {:ok, config} -> attach_stderr_handler(config)
      {:error, _reason} -> :ok
    end
  end

  defp attach_stderr_handler(%{module: :logger_std_h, config: %{type: :standard_error}}),
    do: :ok

  defp attach_stderr_handler(%{module: :logger_std_h} = config) do
    _ = :logger.remove_handler(:default)

    handler_config =
      config
      |> Map.take(@handler_keys)
      |> Map.put(:config, %{type: :standard_error})

    case :logger.add_handler(:default, :logger_std_h, handler_config) do
      :ok -> :ok
      {:error, _reason} -> add_fallback_stderr_handler()
    end
  end

  defp attach_stderr_handler(_other), do: :ok

  defp add_fallback_stderr_handler do
    _ =
      :logger.add_handler(:default, :logger_std_h, %{
        formatter: Logger.default_formatter(),
        filters: [remote_gl: {&:logger_filters.remote_gl/2, :stop}],
        filter_default: :log,
        config: %{type: :standard_error}
      })

    :ok
  end
end
