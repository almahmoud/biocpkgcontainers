# biocpkgcontainers

Container images for individual Bioconductor packages. Each image holds one
package plus everything that package declares in `DESCRIPTION` — `Depends`,
`Imports`, `LinkingTo` **and `Suggests`** — so that vignettes, examples and the
package's own test suite all run inside it.

Two images are built per package, differing only in the base they start from:

| variant | base image | image name |
| --- | --- | --- |
| `bioconductor` | `ghcr.io/bioconductor/bioconductor:<branch>` | `ghcr.io/<owner>/biocpkg-<package>:<branch>` |
| `bioc2u` | `ghcr.io/bioconductor/bioc2u-user:noble` | `ghcr.io/<owner>/biocpkg-bioc2u-<package>:<branch>` |

The package name is lowercased for the registry. Both variants install through
the same `Rscript` path (`docker/install.R`); on the bioc2u base, `bspm`
transparently redirects those calls at the bioc2u/r2u apt binaries.

## How a sweep runs

```
Generate manifest  ->  manifests/<branch>/pkglists/<Package>.txt   (committed)
Dispatch builds    ->  splits the package list into shards
Build shard  x N   ->  one matrix job per package -> build + push
```

A single workflow run is capped at 256 jobs, and there are ~2,400 software
packages per branch, so the sweep cannot be one matrix. `dispatch.yml` shards the
list and fires one `build-shard.yml` run per shard per variant. The built-in
`GITHUB_TOKEN` is sufficient — `workflow_dispatch` is an explicit exception to
the rule that token-triggered events do not start new runs.

### 1. Generate the manifest

Run **Generate manifest** (branch `devel` by default). It runs
`scripts/bioc_pkgs.R` inside `ghcr.io/bioconductor/bioconductor:<branch>` so that
`BiocManager` reports the matching Bioconductor version, and commits the result
under `manifests/<branch>/`:

| file | contents |
| --- | --- |
| `packages.txt` | every package that gets an image |
| `pkglists/<Package>.txt` | the full install list for that one package |
| `manifest.json` | the same data plus CRAN/Bioconductor split and per-package versions |
| `summary.csv` | one row per package: version, install counts |
| `unresolved.txt` | declared dependencies available from neither CRAN nor Bioconductor |

It is on a weekly schedule; devel moves daily, so regenerate before a sweep.

### 2. Dispatch

Run **Dispatch builds**. Useful inputs:

- `variant` — `both` (default), `bioconductor`, or `bioc2u`
- `shard_size` — packages per shard, default 200, hard maximum 255
- `max_parallel` — concurrent builds inside one shard, default 16
- `filter` — regex, to sweep a subset
- `limit` — stop after N packages
- `dispatch_delay` — seconds between dispatches, default 10. The
  `workflow_dispatch` API returns 500 under a rapid burst; each shard is retried
  with backoff, and a shard that never lands fails the run rather than quietly
  disappearing from the sweep. Raise this if you still see 500s.
- `dry_run` — print the plan and dispatch nothing

Start with a dry run, then a small real one:

```
filter = ^DESeq2$|^limma$    variant = both    dry_run = false
```

### 3. Retry

**Build one package** rebuilds a single image. Failed packages are listed in each
shard run's summary and uploaded as `failed-<variant>-<package>` artifacts.

## Dependency semantics

`scripts/bioc_pkgs.R` resolves, for each package:

```r
tools::package_dependencies(pkg, db, which = "most", recursive = "strong")
```

`which = "most"` reads `Depends`, `Imports`, `LinkingTo` and `Suggests` off the
target package; `recursive = "strong"` then follows only `Depends`/`Imports`/
`LinkingTo` down the tree. That is exactly what has to be present for the package
and everything it suggests to load — suggests-of-suggests are not required and
are not pulled in.

The lists are **per package and not deduplicated across packages**. A dependency
shared by fifty packages appears in all fifty lists, because each one becomes its
own image. For Bioconductor devel that is ~2,400 packages and ~286,000
package-install events, a median of 115 and a maximum of 417 packages per image.

Packages shipped with R (`Priority: base`) are excluded. Recommended packages are
not, since they are guaranteed in the Bioconductor image but not in every base.
Anything a package declares that is in no configured repository — archived on
CRAN, deprecated out of Bioconductor — is dropped from the install list and
reported in `unresolved.txt` rather than being allowed to fail the build.

## Running the generator locally

```bash
Rscript scripts/bioc_pkgs.R --outdir=manifests/devel
Rscript scripts/bioc_pkgs.R --outdir=/tmp/m --pkgs=DESeq2,limma   # quick check
```

Building one image locally, using a list the generator produced:

```bash
mkdir -p ctx && cp docker/Dockerfile docker/install.R ctx/
cp manifests/devel/pkglists/DESeq2.txt ctx/pkgs.txt
docker build ctx --build-arg PACKAGE=DESeq2 \
  --build-arg BASE_IMAGE=ghcr.io/bioconductor/bioconductor:devel -t biocpkg-deseq2:devel
```

Every image records what it was asked for at
`/usr/local/share/biocpkgcontainers/` — `requested.txt`, `installed.tsv` and
`missing.txt`.

## Before the first full sweep

- **Registry visibility.** New GHCR packages under a user account are private,
  and GitHub exposes no REST endpoint to change that — it is a per-package
  setting in the UI. At this scale, decide up front whether the images stay
  private and are pulled with a token, or are published under an organisation.
- **Storage.** Roughly 4,800 images per branch. Base layers are shared, but each
  image's R library layer is its own and typically runs to gigabytes. Public
  packages do not count against a storage quota; private ones do.
- **`STRICT`.** Builds fail by default if any requested package does not install,
  so a published image always contains what it claims. Set `strict = false` on a
  dispatch to publish partial images and read `missing.txt` inside them instead.
- **The `bioc2u` base is not branch-tagged.** `:noble` tracks the current devel
  build. To pin it, pass `base_image` (for example
  `ghcr.io/bioconductor/bioc2u-user:noble-bioc-3.23`).
