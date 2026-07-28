defmodule PtcRunner.Lisp.RetainedSizeTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.RetainedSize

  test "shared sub-binaries charge their own extents instead of multiplying the parent" do
    parent = :binary.copy(<<0>>, 400_000)

    slices =
      for index <- 0..199 do
        binary_part(parent, index * 2_000, 2_000)
      end

    heap_bytes = :erts_debug.flat_size(slices) * :erlang.system_info(:wordsize)

    assert RetainedSize.bytes(slices) == heap_bytes + 400_000
  end

  test "binary detachment is total for malformed struct-shaped maps" do
    parent = :binary.copy("x", 100_000)
    slice = binary_part(parent, 0, 1_000)
    missing_struct = Module.concat(__MODULE__, MissingStruct)

    for module <- [missing_struct, MapSet] do
      detached =
        RetainedSize.detach_binaries(%{
          __struct__: module,
          value: slice
        })

      assert detached.__struct__ == module
      assert :binary.referenced_byte_size(detached.value) == 1_000
    end

    detached_set = RetainedSize.detach_binaries(MapSet.new([slice]))
    assert [detached_slice] = MapSet.to_list(detached_set)
    assert :binary.referenced_byte_size(detached_slice) == 1_000
  end
end
