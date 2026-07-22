defimpl Inspect, for: PtcRunner.Kernel.Program do
  def inspect(program, _opts) do
    "#PtcRunner.Kernel.Program<byte_size: #{safe_byte_size(program)}, " <>
      "digest: #{safe_digest(program)}>"
  end

  defp safe_byte_size(%{byte_size: byte_size}) when is_integer(byte_size) and byte_size >= 0,
    do: byte_size

  defp safe_byte_size(_program), do: "unknown"

  defp safe_digest(%{digest: digest}) when is_binary(digest) and byte_size(digest) == 64 do
    if String.valid?(digest) and digest =~ ~r/\A[0-9a-f]{64}\z/,
      do: "sha256:" <> digest,
      else: "invalid"
  end

  defp safe_digest(_program), do: "invalid"
end
