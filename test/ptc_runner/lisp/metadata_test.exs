defmodule PtcRunner.Lisp.MetadataTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Metadata

  test "sanitizes invalid UTF-8 even when the value is within the byte bound" do
    assert Metadata.public(%{reason: <<255>>}) == %{"reason" => ""}
  end
end
