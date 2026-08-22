defmodule PtcRunner.CLILoggerTest do
  @moduledoc """
  Packaged `ptc` and `mix ptc` must keep runtime logger output off stdout so a
  doctor JSON report remains parseable when OTP logs a TLS alert (#1583).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PtcRunner.CLILogger
  alias PtcRunner.MixCommandAdapter

  @notice "TLS :client: In state :certify generated CLIENT ALERT: Fatal - Certificate Expired"

  setup do
    previous_level = Logger.level()
    {:ok, original} = :logger.get_handler_config(:default)
    Logger.configure(level: :notice)

    on_exit(fn ->
      Logger.configure(level: previous_level)
      restore_handler(original)
    end)

    :ok
  end

  test "a TLS-style logger notice lands on stdout until the CLI handler is attached" do
    attach_std_handler(:standard_io)

    {user, stderr} = capture_notice(@notice)

    assert user =~ "Certificate Expired"
    refute stderr =~ "Certificate Expired"
  end

  test "installing the CLI handler keeps a TLS-style notice off stdout" do
    attach_std_handler(:standard_io)
    assert CLILogger.install_stderr_handler() == :ok

    {user, stderr} = capture_notice(@notice)

    refute user =~ "Certificate Expired"
    assert stderr =~ "Certificate Expired"

    report = ~s({"checks":[{"code":"provider_endpoint_tls_failed"}]}\n)

    stdout =
      capture_io(fn ->
        capture_io(:user, fn ->
          capture_io(:stderr, fn ->
            :logger.notice(@notice)
            Logger.flush()
            IO.write(report)
          end)
        end)
      end)

    assert Jason.decode!(String.trim(stdout)) == %{
             "checks" => [%{"code" => "provider_endpoint_tls_failed"}]
           }
  end

  test "mix ptc attaches the default logger to standard_error before running" do
    attach_std_handler(:standard_io)

    capture_io(fn ->
      MixCommandAdapter.run_task(["help"])
    end)

    assert {:ok, %{config: %{type: :standard_error}}} = :logger.get_handler_config(:default)
  end

  defp capture_notice(message) do
    parent = self()

    user =
      capture_io(:user, fn ->
        stderr =
          capture_io(:stderr, fn ->
            :logger.notice(message)
            Logger.flush()
          end)

        send(parent, {:stderr, stderr})
      end)

    assert_received {:stderr, stderr}
    {user, stderr}
  end

  defp attach_std_handler(type) do
    {:ok, config} = :logger.get_handler_config(:default)
    _ = :logger.remove_handler(:default)

    :ok =
      :logger.add_handler(:default, :logger_std_h, %{
        level: config.level,
        filter_default: config.filter_default,
        filters: config.filters,
        formatter: config.formatter,
        config: %{type: type}
      })
  end

  defp restore_handler(%{module: module} = config) do
    _ = :logger.remove_handler(:default)
    type = get_in(config, [:config, :type]) || :standard_io

    _ =
      :logger.add_handler(config.id, module, %{
        level: config.level,
        filter_default: config.filter_default,
        filters: config.filters,
        formatter: config.formatter,
        config: %{type: type}
      })

    :ok
  end
end
