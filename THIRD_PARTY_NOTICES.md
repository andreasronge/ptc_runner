# Third-party notices

## Model Context Protocol wire schema

Two files derive from
`modelcontextprotocol/modelcontextprotocol@5f5440bb26a62e2cf3440b92da5a667efa03b267`:
`site/schemas/mcp-2026-07-28.schema.json`, the published wire schema, and
`priv/schemas/mcp-input-request-2026-07-28.schema.json`, the `InputRequest`
dependency closure the runtime validates against.
At that commit the upstream project states that new specification contributions
and relicensed contributions are Apache-2.0, while contributions whose authors
had not consented to relicensing remain MIT.

Copyright (c) 2024-2025 Model Context Protocol a Series of LF Projects, LLC.

The Apache-2.0 terms are in `LICENSES/Apache-2.0.txt`. The MIT terms applicable
to upstream portions are:

> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

Both files restore JSON numbers and nulls to `JSONValue` from the canonical
TypeScript definition, which the generated upstream schema narrows to integer
and omits null. The published wire schema additionally adds `$id`, `title`, and
provenance metadata, and the `PtcRunnerJSONRPCErrorResponse` overlay; the
input-request file is the extracted closure of `InputRequest`. Each file's own
`$comment` states its changes.

The wire schema is published at
<https://ptc-runner.dev/schemas/mcp-2026-07-28.schema.json> and is in neither
the Hex package nor the standalone release. The input-request closure is
compiled into the runtime and ships in both.
