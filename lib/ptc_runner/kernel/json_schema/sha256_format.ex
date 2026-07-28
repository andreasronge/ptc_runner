defmodule PtcRunner.Kernel.JSONSchema.SHA256Format do
  @moduledoc false

  @behaviour JSV.FormatValidator

  @impl true
  def supported_formats, do: ["sha256"]

  @impl true
  def applies_to_type?("sha256", value), do: is_binary(value)

  @impl true
  def validate_cast("sha256", <<"sha256:", digest::binary-size(64)>> = value) do
    if Enum.all?(:binary.bin_to_list(digest), &(&1 in ?0..?9 or &1 in ?a..?f)),
      do: {:ok, value},
      else: {:error, :invalid_sha256}
  end

  def validate_cast("sha256", _value), do: {:error, :invalid_sha256}
end
