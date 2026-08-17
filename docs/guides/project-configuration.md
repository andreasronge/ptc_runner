# Keep a runnable project together

> **Audience:** application authors and operators who want one stable command
> for local runs, traces, results, and the Viewer.

`ptc-project.json` remembers paths and local artifact preferences. It is not an
application manifest and cannot grant model or tool authority.

Create and run one:

```console
ptc init my-project
ptc run my-project/ptc-project.json
ptc viewer my-project/ptc-project.json
```

The project document keeps three responsibilities separate:

- `application.path` points to the application manifest;
- `host.path` and an optional environment-file path belong to the operator;
- `artifacts` and `viewer` describe local outputs and inspection preferences.

Paths resolve from the project document rather than from the caller's current
directory, so the same command works from another directory. Command-line
overrides remain invocation choices and do not rewrite the project.

Commit the project and application configuration when they contain no secrets.
Keep credential values and private run artifacts outside version control. New
projects include the required artifact ignore patterns.

Use the [project-configuration reference](../reference/project-files.md)
for the complete document shape, path resolution, override precedence,
artifact layout, and Viewer settings.
