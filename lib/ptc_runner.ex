defmodule PtcRunner do
  @moduledoc """
  BEAM-native runtime for bounded PTC-Lisp workflows.

  Host applications compile immutable Lisp bundles, assemble explicit workflow
  and mission environments, and execute entry programs through
  `PtcRunner.Kernel`.

  ## Core Components

  | Component | Purpose |
  |-----------|---------|
  | `PtcRunner.Kernel` | Bounded workflow owner and public execution boundary |
  | `PtcRunner.Lisp` | PTC-Lisp interpreter |
  | `PtcRunner.Sandbox` | Isolated execution with timeout/memory limits |
  | `PtcRunner.Kernel.RunBuilder` | Manifest-backed environment assembly |
  | `PtcRunner.Kernel.ReplSession` | Stateful bounded evaluator continuation |

  ## Guides

  - [Kernel contract](plans/lisp-kernel/kernel-contract.md)
  - [PTC-Lisp specification](ptc-lisp-specification.md)
  - [Function reference](function-reference.md)
  """
end
