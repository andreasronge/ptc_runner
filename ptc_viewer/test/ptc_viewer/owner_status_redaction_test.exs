defmodule PtcViewer.OwnerStatusRedactionTest do
  use ExUnit.Case, async: true

  alias PtcViewer.OwnerStatusRedaction

  test "both projections discard every supplied status field" do
    status = %{
      state: "private-state",
      authority: "private-authority",
      message: "private-message",
      reason: "private-reason",
      log: ["private-log"],
      unexpected_private_field: "private-extra"
    }

    assert OwnerStatusRedaction.format(status) == %{
             state: :redacted,
             message: :redacted,
             reason: :redacted,
             log: []
           }

    assert OwnerStatusRedaction.format(:terminate, [[], status]) ==
             [data: [{~c"State", :redacted}]]
  end
end
