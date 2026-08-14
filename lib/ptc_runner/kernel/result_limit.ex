defmodule PtcRunner.Kernel.ResultLimit do
  @moduledoc false

  alias PtcRunner.Lisp.RetainedSize

  @spec validate(term(), pos_integer()) :: :ok | {:error, :result_limit_exceeded}
  def validate(value, limit) when is_integer(limit) and limit > 0 do
    with retained when is_integer(retained) and retained <= limit <-
           RetainedSize.bytes_with_cap(value, limit),
         {:ok, encoded} <- Jason.encode(value),
         true <- byte_size(encoded) <= limit do
      :ok
    else
      _ -> {:error, :result_limit_exceeded}
    end
  end

  def validate(_value, _limit), do: {:error, :result_limit_exceeded}

  @spec within?(term(), pos_integer()) :: boolean()
  def within?(value, limit), do: validate(value, limit) == :ok
end
