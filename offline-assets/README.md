# Offline Assets

This directory contains version-pinned assets required to run a verified
candidate without downloading Go modules during the build.

## Restoring flattened GitHub Release assets

GitHub displays Release assets in one flat list and does not preserve the
directories required by the import commands. For Release `v0.1.0`, restore the
assets for candidate `d57d10f47129b11f12d875de1195a42c0a53270f` to this
layout. Keep every filename unchanged and do not extract the image or Go module
archives:

```text
.work/offline-assets/benchmark-tools/d57d10f47129b11f12d875de1195a42c0a53270f/
  benchmark-images.tar
  manifest.json
  SHA256SUMS
  charts/
    kwok-chart-0.3.0.tgz
    kwok-stage-fast-chart-0.3.0.tgz

offline-assets/go-mod/d57d10f47129b11f12d875de1195a42c0a53270f/
  base-runner-image.txt
  candidate-commit.txt
  go-mod-supplement.tar.gz
  go-mod-supplement.tar.gz.sha256
  missing-modules.txt
```

Only `go-mod-supplement.tar.gz` is missing from the cloned Go module directory;
its identity and checksum metadata are tracked in Git. The Benchmark directory
is generated under the ignored `.work/` tree and must be reconstructed from
the Release assets.

When using a browser, place the downloaded files according to the tree above.
With GitHub CLI, run these commands from the repository root:

```bash
export COMMIT=d57d10f47129b11f12d875de1195a42c0a53270f
export BENCHMARK_ASSET_DIR=.work/offline-assets/benchmark-tools/$COMMIT
export GO_MOD_ASSET_DIR=offline-assets/go-mod/$COMMIT

mkdir -p "$BENCHMARK_ASSET_DIR/charts" "$GO_MOD_ASSET_DIR"

gh release download v0.1.0 \
  --repo siqiaawa/volcano-performance-guard \
  --pattern 'benchmark-images.tar' \
  --pattern 'manifest.json' \
  --pattern 'SHA256SUMS' \
  --dir "$BENCHMARK_ASSET_DIR"

gh release download v0.1.0 \
  --repo siqiaawa/volcano-performance-guard \
  --pattern '*.tgz' \
  --dir "$BENCHMARK_ASSET_DIR/charts"

gh release download v0.1.0 \
  --repo siqiaawa/volcano-performance-guard \
  --pattern 'go-mod-supplement.tar.gz' \
  --pattern 'go-mod-supplement.tar.gz.sha256' \
  --dir "$GO_MOD_ASSET_DIR"
```

Verify both independent asset sets before running any import:

```bash
(cd "$BENCHMARK_ASSET_DIR" && sha256sum -c SHA256SUMS)
(cd "$GO_MOD_ASSET_DIR" && sha256sum -c go-mod-supplement.tar.gz.sha256)
```

The first command must report `OK` for the Benchmark archive, manifest, and
both charts. The second must report `OK` for the Go module supplement.

## Go module supplements

Each candidate has its own `go-mod/<full-commit>/` directory. It contains:

- `go-mod-supplement.tar.gz`: Go module-cache delta;
- `go-mod-supplement.tar.gz.sha256`: archive integrity check;
- `candidate-commit.txt`: candidate source identity;
- `base-runner-image.txt`: required offline Runner identity;
- `missing-modules.txt`: reviewed module-version delta.

`make import-candidate-deps` verifies the archive and both identities before
creating `volcano-candidate-runner:<commit>` with Docker networking disabled.
The imported Runner sets `GOPROXY=off` and `GOSUMDB=off`.

The current Go supplement is sufficient for the candidate's offline Go build,
candidate image build, candidate Helm deployment, scheduler smoke, and the
implemented Pod timestamp smoke, when the external offline E2E bundle is also
present. The separate `.work/offline-assets/benchmark-tools/<commit>/` package
contains the verified full Benchmark monitoring assets: the candidate-bound
`performance-guard-tools` image, BusyBox, Prometheus, Grafana, kube-state-
metrics, the commit-labelled Audit Exporter, and the bundle's KWOK charts. The
tools image contains Python 3 plus the pinned PyYAML and jsonschema runtime and
is used through `scripts/run-performance-tools.sh`; the target host therefore
does not need Python. Its `manifest.json`, `SHA256SUMS`,
`benchmark-images.tar`, and `imported-manifest.json` are used by the local
packaging and import workflow. For cross-machine transfer, publish only
`benchmark-images.tar`, `manifest.json`, `SHA256SUMS`, and the two chart files;
`imported-manifest.json` and `registry-images.env` are regenerated after import.

Never overwrite one commit directory with an asset made for another commit.
For a new candidate, run the missing-module preflight, package its delta only
on an approved networked packaging machine, and create a new full-commit
directory with its checksum and metadata.
