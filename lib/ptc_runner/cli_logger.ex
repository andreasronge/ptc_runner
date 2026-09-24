defmodule PtcRunner.CLILogger do
  @moduledoc false

  require Logger

  @handler_keys [:level, :filter_default, :filters, :formatter]
  @publication_event [:ptc_runner, :publication, :destination_unavailable]
  @publication_handler "ptc-publication-destination-unavailable"

  @doc false
  @spec install_stderr_handler() :: :ok
  @spec install_stderr_handler(:logger | :stderr) :: :ok
  def install_stderr_handler(publication_output \\ :logger)
      when publication_output in [:logger, :stderr] do
    case :logger.get_handler_config(:default) do
      {:ok, config} -> attach_stderr_handler(config)
      {:error, _reason} -> :ok
    end

    install_publication_handler(publication_output)
  end

  defp install_publication_handler(output) do
    {:ok, _started} = Application.ensure_all_started(:telemetry)

    case :telemetry.attach(
           @publication_handler,
           @publication_event,
           &__MODULE__.publication_failure/4,
           output
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def publication_failure(_event, _measurements, metadata, output)
      when output in [:logger, :stderr] do
    with %{operation: operation, kind: kind, cause: {tag, value}} <- metadata,
         true <- is_atom(operation) and is_atom(kind) and is_atom(value),
         true <- tag in [:reason, :exception] do
      message =
        "destination unavailable: operation=#{operation} kind=#{kind} cause=#{tag}:#{value}"

      message =
        case metadata do
          %{run_ref: "cmd-" <> _ = run_ref} -> "#{message} run_ref=#{run_ref}"
          _ -> message
        end

      case output do
        :logger -> Logger.warning(message)
        :stderr -> IO.puts(:stderr, message)
      end
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
