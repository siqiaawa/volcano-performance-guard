# Offline Assets

This directory contains version-pinned assets required to run a verified
candidate without downloading Go modules during the build.

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
`benchmark-images.tar`, and `imported-manifest.json` are required for
cross-machine transfer. The package has been generated, checksum-verified,
and imported into the local registry; it is not yet a published Release
archive.

Never overwrite one commit directory with an asset made for another commit.
For a new candidate, run the missing-module preflight, package its delta only
on an approved networked packaging machine, and create a new full-commit
directory with its checksum and metadata.
