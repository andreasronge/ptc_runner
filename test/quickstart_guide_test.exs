defmodule PtcRunner.QuickstartGuideTest do
  # Each example writes only to its own 0700 temporary directory. Its `mix ptc`
  # child takes Mix's lock on this checkout's build directory and reports any
  # wait on stderr, which the example asserts is empty, so every other test
  # that runs `mix` in this checkout stays `async: false` or `:nightly`. The
  # credentialed examples load the OS environment and live in
  # QuickstartGuideGlobalStateTest.
  use ExUnit.Case, async: true
  @moduletag :operator

  @moduletag timeout: 180_000

  alias PtcRunner.TestSupport.GuideExamples

  require GuideExamples

  GuideExamples.test_registered_examples("test/support/executable_guides.txt",
    credentials: :none
  )
end
