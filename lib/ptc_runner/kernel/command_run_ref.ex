defmodule PtcRunner.Kernel.CommandRunRef do
  @moduledoc "Generates the fixed V1 command reference from 128 bits of entropy."

  import Bitwise

  @alphabet "0123456789abcdefghjkmnpqrstvwxyz"
  @pattern ~r/\Acmd-[0-7][0-9abcdefghjkmnpqrstvwxyz]{25}\z/

  @spec generate() :: {:ok, binary()} | {:error, :entropy_unavailable}
  def generate do
    {:ok, encode(:crypto.strong_rand_bytes(16))}
  rescue
    _exception -> {:error, :entropy_unavailable}
  catch
    _kind, _reason -> {:error, :entropy_unavailable}
  end

  @spec encode(<<_::128>>) :: binary()
  def encode(<<integer::unsigned-big-128>>) do
    encoded =
      for group <- 25..0//-1, into: "" do
        index = band(integer >>> (group * 5), 0x1F)
        binary_part(@alphabet, index, 1)
      end

    "cmd-" <> encoded
  end

  @spec valid?(term()) :: boolean()
  def valid?(value), do: is_binary(value) and value =~ @pattern
end
