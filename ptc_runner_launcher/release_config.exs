%{
  version: "0.1.0",
  tag_prefix: "ptc_runner_launcher-v",
  macos_deployment_target: "15.0",
  precompiled_targets: %{
    {:unix, :darwin} => %{
      "aarch64-apple-darwin" => {"gcc", "g++", "<%= cc %> -arch arm64", "<%= cxx %> -arch arm64"},
      "x86_64-apple-darwin" => {"gcc", "g++", "<%= cc %> -arch x86_64", "<%= cxx %> -arch x86_64"}
    },
    {:unix, :linux} => %{
      "aarch64-linux-gnu" => "aarch64-linux-gnu-",
      "x86_64-linux-gnu" => "x86_64-linux-gnu-"
    }
  }
}
