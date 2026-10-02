defmodule PtcRunner.LiveStatus.Config do
  @moduledoc false

  @derive {Inspect, except: [:token]}
  defstruct [:url, :token]

  def read do
    %__MODULE__{
      url: System.get_env("PTC_VIEWER_URL"),
      token: System.get_env("PTC_VIEWER_TOKEN")
    }
  end
end
