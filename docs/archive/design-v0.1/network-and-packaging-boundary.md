# Network and packaging boundary

The project has two deliberately separate execution zones. A proxy on a developer workstation may help the connected zone, but it is never an internal runtime prerequisite.

## Connected packaging zone

This zone may be a temporary developer workstation, a dedicated packaging runner, or another approved host that can reach GitHub and public registries. It is responsible for:

1. Reading the pinned raw dependency inventory.
2. Resolving the exact `linux/amd64` manifest digest for every selected image.
3. Subtracting images already supplied by the senior base-environment bundle and the internal registry.
4. Pulling only the approved `performance-tools` difference set by immutable digest.
5. Exporting images as an OCI or runtime-compatible archive.
6. Packaging matching offline manifests or Charts, a versioned manifest and `SHA256SUMS`.
7. Publishing the checksummed archive through the approved GitHub repository or Release transport.

Host-specific proxy addresses, credentials and certificate paths must not be committed. Standard proxy environment variables may be used temporarily by packaging commands, but they are not part of any artifact contract.

For candidate `d57d10f47129b11f12d875de1195a42c0a53270f`, the senior bundle inventory and candidate Benchmark dependencies have been evaluated. The resulting local asset directory contains six images, including the candidate-bound `performance-guard-tools` image, two KWOK Charts, a manifest and `SHA256SUMS`. A different candidate commit must repeat dependency scanning and packaging; it must not reuse this commit-bound artifact without verification.

## Internal execution zone

The internal runner is responsible for:

1. Pulling project code and approved archives from the available GitHub path.
2. Verifying archive, manifest and individual artifact SHA-256 values before use.
3. Preparing Kubernetes through the real base-environment Adapter.
4. Importing performance-tool images from local archives or using verified internal-registry copies.
5. Building candidate Volcano images from current source using base images already supplied by the base environment or internal registry.
6. Deploying the candidate with deployment materials from the same source commit.
7. Running benchmarks, comparing independent baseline data, reporting and restoring the stable release or destroying the cluster.

The internal workflow must not call a public registry, GitHub release URL outside the approved pull step, Go proxy, Helm repository or arbitrary download URL. Missing offline content is a hard failure. There is no public-network fallback.

The imported `performance-guard-tools` image supplies Python 3 and the pinned PyYAML/jsonschema runtime for the guard scripts. The internal host therefore does not need a separately installed Python runtime. Docker, Bash, Git and Make remain host prerequisites, along with the Kubernetes tooling required by the senior base-environment bundle.

## Required offline acceptance

Acceptance must be run with public egress disabled and empty relevant runtime caches. A successful result must prove that checksums validate, all required images import, manifests install, candidate builds use only approved internal inputs, the benchmark completes, and cleanup or recovery succeeds.

The packaging and internal logs should record artifact versions and hashes, but must not record proxy credentials or host-specific secrets.
