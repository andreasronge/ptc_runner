# ptc-runner.dev

> **Audience:** whoever owns the domain and the GitHub repository settings.

`ptc-runner.dev` exists to serve one thing the runtime already depends on: the
JSON Schemas whose `$id` values are compiled into `lib/ptc_runner/kernel/` and
written into every example project file. Everything else on the site is static
introduction.

| Piece | Where |
| --- | --- |
| Page content | `site/` |
| Guide pages | `site/guides/`, generated from `docs/guides/` by `mix ptc.gen_site_guides` |
| Published schemas | `priv/schemas/ptc-*.schema.json`, copied at build time |
| Assembly and verification | `scripts/build_site.sh` |
| Deployment | `.github/workflows/pages.yml` |

## The invariant

Four schemas declare an absolute `$id` under this origin:

```
https://ptc-runner.dev/schemas/ptc-project-config.schema.json
https://ptc-runner.dev/schemas/ptc-application-manifest.schema.json
https://ptc-runner.dev/schemas/ptc-host-config.schema.json
https://ptc-runner.dev/schemas/ptc-command-envelope-v4.schema.json
```

Those paths are a shipped contract. Every `*.ptc-project.json` under
`examples/` names one in `$schema`, so an editor resolves it while a user is
authoring, and the reference documentation quotes them. They cannot move.

`mix ptc.gen_docs` owns the schema bytes and `mix precommit` fails on a stale
one, so the site never regenerates a schema — it copies the file the repository
already proved current. That is why `site/` contains no schema copy of its own:
a second copy would drift silently, and the first symptom would be a user's
editor validating against a document the runtime rejects.

`scripts/build_site.sh` enforces the rest. It refuses to publish when a
schema's declared `$id` does not match the URL it is being served from, and
when a hand-written reference in `site/` names a file that is not published.
References are extracted by parsing the HTML, not by matching a pattern: a
regex over `href="..."` silently ignores `href = '...'` and uppercase tags,
which leaves a guard that appears to run while checking nothing.

The script deletes its output directory, so it will only delete one it created
itself — proven by the `.build-site-artifact` marker it leaves behind. An
existing directory without that marker is refused, and you remove it by hand if
it really is the intended output. This is deliberately a positive test: asking
git whether the target holds tracked files looks equivalent but has two
destructive false negatives, since a case-insensitive filesystem hides
`SITE` from `git ls-files` while still resolving it to `site/`, and any path
outside the repository makes git exit 128 with empty output — indistinguishable
from "nothing tracked here", which made a repository *ancestor* look safest of
all.

## The documentation pages

`site/guides/`, `site/installation/`, and `site/reference/` hold one generated
page per published document plus the directory page at `site/guides/`. The
same discipline as the schemas applies, one step earlier: the pages are
committed HTML that `mix ptc.gen_site_guides` renders from `docs/`
(`mix ptc.gen_docs` runs it), and `mix precommit` fails on a stale, missing, or
orphaned page. The Pages workflow stays Elixir-free because it only ever copies
what the repository already proved current. Never edit the HTML by hand — edit
the source Markdown or the generator. The landing page is the exception: it is
hand-written, loads only `style.css` and `landing.css`, and does not share the
guide shell or sidebar.

The sidebar sections are read from the documentation groups in `mix.exs`
(`:docs` → `:groups_for_extras`), the same configuration that groups the
HexDocs sidebar, so the two navigations cannot drift. The generator publishes
only the groups named in its `@published_roots` — maintainer and conformance
material stays on GitHub. Page order within a section follows `:extras`, and
the generator refuses a group whose declared order disagrees.

The renderer (`dev/ptc_runner/site_guides/markdown_html.ex`) fails closed:
an element, attribute, or parser warning outside its whitelist aborts
generation rather than publishing something silently wrong. Relative links to
a published page become site links; every other relative link must name a file
that exists in the repository and becomes a GitHub link. Heading anchors use
the ExDoc slug scheme the repository's hand-authored fragment links were
written against, and every internal fragment link is validated against the
target page's actual ids. A typo therefore fails `mix ptc.gen_docs --check`
instead of shipping as a dead link, and `scripts/build_site.sh` re-validates
the root-relative references in the assembled artifact.

## The build stamp

The front page footer names the version from `mix.exs`, the commit being
published, and the UTC build time. The values are not checked in: `site/`
carries `@BUILD_VERSION@`, `@BUILD_COMMIT@`, `@BUILD_COMMIT_SHORT@`, and
`@BUILD_TIMESTAMP@`, and `scripts/build_site.sh` resolves them in the assembled
copy. Stamping the source instead would put a rewritten `index.html` in every
diff and make each deploy a commit.

Read the stamp as *when the site was built*, not as *the tip of `main`*. Pages
deploys on changes to `site/`, the published schemas, the build script, and its
own workflow, so a commit that touches neither leaves the stamp where it was —
correctly, because nothing being served changed.

The substitution is verified rather than assumed. The build fails when no page
carried a token, which is what a renamed or deleted placeholder looks like, and
when any `@BUILD_*@` token survives into the artifact. Without those two checks
a page could publish a footer that quietly lost half its stamp.

## Landing-page images

The landing page uses product diagrams for concepts and a real Viewer capture
for the supporting interface. Do not add stock art or a generic agent image:
each image should explain something that the nearby text cannot show as well.

### The loop diagram

The diagram is image-model output, not a hand-drawn asset, so the prompt below
is its source. Without the prompt, the diagram can only be replaced, never
amended.

### `site/loop-is-a-library.webp`

> A clean flat vector technical diagram, editorial infographic style, on a warm
> off-white background (#FBFAF8). Landscape, three columns, generous margins.
> Title, top left, large bold dark ink: "The loop is a library, not the
> runtime". LEFT COLUMN, headed "WORKFLOW PRELUDE" in bold deep navy, with the
> smaller grey subtitle "compiled from selected components". Inside it, a
> vertical stack of five small rounded boxes in monospace, connected by thin
> downward arrows: "agent.main", "agent.core", "agent.prompt", "agent.retry",
> "llm". A rust-orange dashed outline around the stack, tagged in rust italic:
> "replaceable". MIDDLE COLUMN, a circular loop of four labelled steps drawn as
> arrows forming a ring, each in a small box: "1 prompt", "2 model writes
> PTC-Lisp", "3 evaluate", "4 observation". Above the ring, the small grey
> caption: "agent.core drives this". RIGHT COLUMN, headed "MISSION PRELUDE" in
> bold deep navy, with the smaller grey subtitle "a separate compiled
> aggregate". Inside it, one box in monospace labelled "the generated program",
> and below it two smaller stacked boxes labelled "your domain components" and
> "prompt-visible exports". ACROSS THE BOTTOM, spanning the full width, one wide
> rust-orange bordered bar containing the single bold line: "every tool:
> requirement is checked against the assembled providers — never granted by
> them". Style: flat 2D vector, technical documentation aesthetic, thin 2px
> strokes, no gradients, no 3D, no drop shadows, no glow. Palette strictly deep
> navy (#1F3A5F), rust orange (#9A4A1E), warm grey (#6B6459) on warm off-white.
> Crisp geometric shapes, precise alignment, correctly spelled text. 16:9 aspect
> ratio.

The generated PNG was 1672x941 and 1.2 MB; `cwebp -q 92` brings it to 126 KB.

Three things to check on any replacement, each of which would make the picture
wrong rather than merely ugly:

- **The two preludes must read as separate aggregates**, not one shared pool. A
  mission gets its own compiled bundle, and `agent.core` is not in it.
- **The dashed `replaceable` outline belongs around the component stack**, never
  around the bottom bar. Components are swappable; the capability check is not.
- **The bottom bar must read as a gate, not a supply line.** An arrow feeding
  capabilities *into* the preludes inverts the mechanic — the reference is
  explicit that requirements "validate authority; they never create it".

One vocabulary trap: a prelude is not a file. It is the immutable compiled
aggregate of the components selected for one environment, including their
dependency closure, frozen for the run. A component is the file.

### The Viewer screenshot

`site/ptc-viewer-latest.webp` is a capture of the real Viewer, not a mockup. It
shows the `01-orders` step of the kernel tutorial, a deterministic workflow
that selects no provider, so the capture contains no user data, private
prompts, or live credentials. The tutorial project keeps the result artifact
off, so recreate the capture from a copy of its project file:

```console
sed 's/"open": true/"open": false/; s/"result": false/"result": true/' \
  examples/kernel-tutorial/01-orders.ptc-project.json \
  > examples/kernel-tutorial/01-orders.capture.ptc-project.json
mix ptc run examples/kernel-tutorial/01-orders.capture.ptc-project.json
mix ptc viewer examples/kernel-tutorial/01-orders.capture.ptc-project.json --port 8769
```

Open the run in a 1280-pixel-wide window and capture the column from the trace
summary card down to the observed-run card, leaving out the run list above it
and the browser scrollbar. Convert the capture with
`cwebp -q 85 capture.png -o site/ptc-viewer-latest.webp` and update the
`width` and `height` attributes on the landing page to the new pixel size.
Delete the copied project file and the generated
`examples/kernel-tutorial/01-orders/.ptc/` directory afterwards; both are local
artifacts, not part of the site.

## Local preview

```console
scripts/build_site.sh
python3 -m http.server -d _site 8000
```

The pages use absolute links (`/schemas/...`), which resolve correctly under
that server and under Pages, but not through `file://`.

The stylesheets follow the operating system's colour scheme. To check the
other theme without changing that setting, set `data-theme="light"` on the
root element from the browser's developer tools; the dark rules are guarded
on its absence. The brand mark is an image file and keeps following the system
scheme, so its ring looks wrong under that override and only there.

## One-time setup

1. **Register the domain.** As of 2026-08-17 `ptc-runner.dev` is unregistered:
   it has no NS records and RDAP returns 404. Until it is registered, every
   `$schema` URL in the examples resolves to nothing.

2. **Enable Pages.** Repository *Settings → Pages → Source: GitHub Actions*.
   The workflow deploys through `actions/deploy-pages`, so no `gh-pages`
   branch and no `/docs` folder mode is involved — `docs/` in this repository
   stays maintainer documentation.

3. **Point DNS at GitHub.** For the apex domain, four A and four AAAA records:

   ```
   A     @    185.199.108.153
   A     @    185.199.109.153
   A     @    185.199.110.153
   A     @    185.199.111.153
   AAAA  @    2606:50c0:8000::153
   AAAA  @    2606:50c0:8001::153
   AAAA  @    2606:50c0:8002::153
   AAAA  @    2606:50c0:8003::153
   CNAME www  andreasronge.github.io.
   ```

4. **Set the custom domain** to `ptc-runner.dev` in *Settings → Pages*, then
   enable **Enforce HTTPS** once the certificate is issued. `.dev` is an
   HSTS-preloaded TLD, so plain HTTP is not a fallback — the site is
   unreachable in browsers until the certificate exists. GitHub provisions it
   automatically a few minutes after DNS resolves.

   The Pages settings are the only place the domain is stored. This repository
   deliberately ships no `CNAME` file: a custom Actions workflow is the
   publishing path here, and for that path GitHub's documentation states that
   "no `CNAME` file is created, and any existing `CNAME` file is ignored and is
   not required". One was committed here at first, on the belief that it kept
   the domain across redeploys. It does not, and an inert file that looks
   load-bearing is worse than no file.

## Why GitHub Pages

The schemas need to be fetchable by editors and by browser-based validators.
GitHub Pages serves `.json` as `application/json; charset=utf-8` with
`access-control-allow-origin: *`, with no configuration — the two properties
that would otherwise justify a host allowing custom response headers. It is
free for this public repository and requires no account beyond the one that
owns the code.

Reach for a different host when the site needs redirects, cache-control
tuning, or per-path headers. None of that is required to serve a schema.
