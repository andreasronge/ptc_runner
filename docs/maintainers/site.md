# ptc-runner.dev

> **Audience:** whoever owns the domain and the GitHub repository settings.

`ptc-runner.dev` exists to serve one thing the runtime already depends on: the
JSON Schemas whose `$id` values are compiled into `lib/ptc_runner/kernel/` and
written into every example project file. Everything else on the site is static
introduction.

| Piece | Where |
| --- | --- |
| Page content | `site/` |
| Published schemas | `priv/schemas/ptc-*.schema.json`, copied at build time |
| Assembly and verification | `scripts/build_site.sh` |
| Deployment | `.github/workflows/pages.yml` |

## The invariant

Four schemas declare an absolute `$id` under this origin:

```
https://ptc-runner.dev/schemas/ptc-project-config.schema.json
https://ptc-runner.dev/schemas/ptc-application-manifest.schema.json
https://ptc-runner.dev/schemas/ptc-host-config.schema.json
https://ptc-runner.dev/schemas/ptc-command-envelope-v2.schema.json
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

## The authority diagram

`site/authority-narrows.webp` is image-model output, not a hand-drawn asset, so
the prompt below is its source. Keep them together: without it the diagram can
only be replaced, never amended.

> A clean flat vector technical diagram, editorial infographic style, on a warm
> off-white background (#FBFAF8). Composition: a centered vertical funnel of
> three stages, each visibly narrower than the one above it, with generous white
> space and wide margins. Title, top left, large bold dark ink: "Authority only
> narrows". Stage 1 (widest, full width): a rounded rectangle with a thin
> deep-navy outline. Bold label "OPERATOR". Below it in monospace:
> "ptc-host.json". Below that, smaller warm grey: "credentials · endpoints ·
> outer ceilings". A short downward rust-orange arrow to stage 2, with small
> italic text beside it: "selects from, never adds to". Stage 2 (about 75%
> width): same rounded rectangle style. Bold label "AUTHOR". Monospace:
> "ptc.json". Smaller warm grey: "aliases · missions · limits". A second
> downward rust-orange arrow, with small italic text beside it: "splits, never
> merges". Stage 3 (about 55% width): two rounded rectangles side by side,
> separated by one thick vertical rust-orange line. Left box: bold "WORKFLOW",
> then "trusted policy", then "holds the model". Right box: bold "MISSION", then
> "model-written program", then "holds the tools". Style: flat 2D vector,
> technical documentation aesthetic, thin 2px strokes, no gradients, no 3D, no
> drop shadows, no glow. Palette strictly deep navy (#1F3A5F), rust orange
> (#9A4A1E), warm grey (#6B6459) on warm off-white. Crisp geometric shapes,
> precise alignment, correctly spelled text. 16:9 aspect ratio.

The generated PNG was 1672x941 and 969 KB. What ships is
`cwebp -q 92 <original>.png -o site/authority-narrows.webp` — 83 KB, verified
free of ringing on the smallest text at 2x. Re-encode from an original rather
than from the WebP if the diagram is ever regenerated.

Two things to check on any replacement, because both are load-bearing rather
than cosmetic:

- **Every label must be spelled exactly.** The filenames `ptc-host.json` and
  `ptc.json` are the whole point; a dropped hyphen is wrong on a page about
  exact documents.
- **The two bottom boxes may share the width of the box above them.** That is
  not a failed funnel. The author selects both `providers.workflow` and
  `providers.mission`, so the split divides that authority into two disjoint
  halves, each narrower than what was selected. A strict funnel would wrongly
  imply the two environments draw from one shrinking pool.

The image carries a light background in both themes. A dark-mode variant would
need a second render with the background at `#16150F` and text at `#ECE7DD`,
served through `<picture>` with `prefers-color-scheme`.

## Local preview

```console
scripts/build_site.sh
python3 -m http.server -d _site 8000
```

The pages use absolute links (`/schemas/...`), which resolve correctly under
that server and under Pages, but not through `file://`.

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
