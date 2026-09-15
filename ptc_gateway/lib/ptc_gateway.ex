defmodule PtcGateway do
  @moduledoc """
  Explicit gateway startup. `start_link/2` anchors configuration and `:env_file`
  to the caller's directory once, then starts one immutable supervised domain.
  No listener binds until configuration, all templates and pins, audit storage,
  admission, and captured credentials are ready. Returns only closed errors.
  Stop the returned owner to close its listener and infrastructure.

  The gateway reference documents safe commands for application content and
  provider pins. The application command uses the host's installed limits,
  omits selected input, and never executes or resolves credentials.
  """
  @spec start_link(binary(), keyword()) :: {:ok, pid()} | {:error, atom()}
  def start_link(path, opts \\ []) do
    if is_binary(path) and Keyword.keyword?(opts) and Keyword.keys(opts) -- [:env_file] == [] and
         length(opts) <= 1 and (opts[:env_file] == nil or is_binary(opts[:env_file])) do
      anchored = if opts[:env_file], do: Path.expand(opts[:env_file])

      case DynamicSupervisor.start_child(
             PtcGateway.Supervisor,
             {PtcGateway.Domain, {Path.expand(path), anchored}}
           ) do
        {:ok, _} = ok -> ok
        {:error, code} -> {:error, PtcGateway.StartupError.normalize(code)}
      end
    else
      {:error, :config_invalid}
    end
  end
end
