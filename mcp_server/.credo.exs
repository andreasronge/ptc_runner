# Inherits the spirit of the root project's defaults.
# This file is the minimum needed to enable `mix credo --strict`
# inside the mcp_server/ project.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "test/"
        ],
        excluded: []
      },
      strict: true,
      checks: %{
        disabled: [
          # Allow TODO/FIXME comments without failing the build.
          {Credo.Check.Design.TagTODO, []},
          {Credo.Check.Design.TagFIXME, []}
        ]
      }
    }
  ]
}
