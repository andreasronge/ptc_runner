defmodule PtcRunner.Labs.TransportPreflight do
  @moduledoc false

  def require_http_checkout! do
    path = System.get_env("PTC_LLM_HTTP_PATH")

    unless is_binary(path) and String.trim(path) != "" and File.dir?(path),
      do: raise("set PTC_LLM_HTTP_PATH to the tested pilot checkout before running this probe")

    unless Code.ensure_loaded?(PtcLlmHttp.Response) and
             function_exported?(PtcLlmHttp.Response, :finish_reason, 1) and
             Code.ensure_loaded?(PtcLlmHttp.Usage) and
             Map.has_key?(struct(PtcLlmHttp.Usage), :cache_write_tokens),
           do: raise("pilot transport APIs are unavailable; compile with PTC_LLM_HTTP_PATH set")

    path
  end

  def clean_source!(directory) do
    {revision, 0} = System.cmd("git", ["-C", directory, "rev-parse", "HEAD"])

    {status, 0} =
      System.cmd("git", ["-C", directory, "status", "--porcelain", "--untracked-files=normal"])

    unless status == "",
      do: raise("source checkout must be clean before capturing transport evidence")

    %{revision: String.trim(revision), clean: true}
  end

  def verify_source!(directory, identity) do
    unless clean_source!(directory) == identity,
      do: raise("source revision changed during the transport probe")

    identity
  end
end
