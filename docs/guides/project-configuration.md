# Keep a runnable project together

Use `ptc-project.json` as one stable command target for local runs, traces,
results, and the Viewer.

It remembers paths and local artifact preferences but
cannot add a model or tool.

## How do I create a project?

Create and run one:

```console
ptc init my-project
ptc run my-project/ptc-project.json
ptc viewer my-project/ptc-project.json
```

The project document keeps three responsibilities separate:

- `application.path` points to the application manifest;
- `host.path` points to installed providers, and `host.env_file` may name one
  exact environment file;
- `artifacts` and `viewer` describe local outputs and inspection preferences.

Paths resolve from the project document rather than from the caller's current
directory, so the same command works from another directory. Command-line
overrides remain invocation choices and do not rewrite the project.
`ptc viewer PROJECT.json --env-file FILE` overrides `host.env_file` for work
launched from the Live tab; no `.env` path is discovered implicitly.

Commit the project and application configuration when they contain no secrets.
Keep credential values and private run artifacts outside version control. New
projects include the required artifact ignore patterns.

## Where is the complete contract?

Use the [project-configuration reference](../reference/project-files.md)
for the complete document shape, path resolution, override precedence,
artifact layout, and Viewer settings.
