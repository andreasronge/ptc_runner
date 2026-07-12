defmodule PtcRunner.Kernel do
  @moduledoc """
  Bounded programmable Kernel entry point.

  Hosts compile frozen component bundles, construct explicit workflow and
  mission environments, and execute one workflow expression with `run/2`.
  """

  alias PtcRunner.Kernel.BundleCompiler
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.Error
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.Result
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.Runner

  @doc "Compiles an explicit component-ID addressed source bundle."
  @spec compile_bundle([Component.t()]) :: {:ok, FrozenBundle.t()} | {:error, map()}
  def compile_bundle(components), do: BundleCompiler.compile(components)

  @doc "Runs one bounded workflow entry expression."
  @spec run(binary(), RunConfig.t()) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(entry_source, %RunConfig{} = config), do: Runner.run(entry_source, config)
end
