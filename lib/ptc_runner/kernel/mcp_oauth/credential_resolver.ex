defmodule PtcRunner.Kernel.MCPOAuth.CredentialResolver do
  @moduledoc """
  Just-in-time confidential-client secret resolution.

  Resolver callbacks receive only a prevalidated binding identifier and the
  caller's absolute local deadline. They may return a bounded binary directly
  or `%{value: binary, release: zero_arity_function}`. The latter release
  callback always runs after the immediate OAuth request.
  """

  @release_cleanup_timeout_ms 100

  @spec with_secret(function(), binary(), integer(), (binary() -> term())) ::
          term() | {:error, atom()}
  def with_secret(resolver, binding, deadline_ms, callback)
      when is_function(resolver, 2) and is_binary(binding) and
             is_integer(deadline_ms) and is_function(callback, 1) do
    with remaining when remaining > 0 <- deadline_ms - System.monotonic_time(:millisecond),
         {:ok, handle} <- safe_resolve(resolver, binding, deadline_ms),
         {:ok, secret, release} <- secret_handle(handle) do
      try do
        if valid_secret?(secret),
          do: callback.(secret),
          else: {:error, :credential_resolution_failed}
      after
        bounded_release(release)
      end
    else
      remaining when is_integer(remaining) and remaining <= 0 -> {:error, :timeout}
      {:error, :timeout} -> {:error, :timeout}
      {:error, _reason} -> {:error, :credential_resolution_failed}
    end
  end

  def with_secret(_resolver, _binding, _deadline_ms, _callback),
    do: {:error, :credential_resolution_failed}

  defp safe_resolve(resolver, binding, deadline_ms) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

    if remaining_ms > 0 do
      task = Task.async(fn -> invoke_resolver(resolver, binding, deadline_ms) end)

      case Task.yield(task, remaining_ms) do
        {:ok, result} ->
          result

        {:exit, _reason} ->
          {:error, :credential_resolution_failed}

        nil ->
          task
          |> Task.shutdown(:brutal_kill)
          |> release_shutdown_result()

          {:error, :timeout}
      end
    else
      {:error, :timeout}
    end
  end

  defp invoke_resolver(resolver, binding, deadline_ms) do
    case resolver.(binding, deadline_ms) do
      {:ok, _handle} = success -> success
      _failure -> {:error, :credential_resolution_failed}
    end
  rescue
    _exception -> {:error, :credential_resolution_failed}
  catch
    _kind, _reason -> {:error, :credential_resolution_failed}
  end

  defp secret_handle(value) when is_binary(value) do
    {:ok, value, fn -> :ok end}
  end

  defp secret_handle(%{value: value, release: release})
       when is_binary(value) and is_function(release, 0) do
    {:ok, value, release}
  end

  defp secret_handle(_handle), do: {:error, :credential_resolution_failed}

  defp release_shutdown_result({:ok, {:ok, handle}}) do
    case secret_handle(handle) do
      {:ok, _secret, release} -> bounded_release(release)
      {:error, :credential_resolution_failed} -> :ok
    end
  end

  defp release_shutdown_result(_result), do: :ok

  defp valid_secret?(value),
    do:
      byte_size(value) in 1..65_536 and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp bounded_release(release) do
    task = Task.async(fn -> invoke_release(release) end)

    case Task.yield(task, @release_cleanup_timeout_ms) do
      {:ok, :ok} -> :ok
      _timeout_or_exit -> Task.shutdown(task, :brutal_kill)
    end
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp invoke_release(release) do
    _result = release.()
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end
end
