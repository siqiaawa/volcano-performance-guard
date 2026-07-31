# Vendored Python tooling dependencies

This directory contains the pure-Python runtime files for the pinned
`PyYAML==6.0.1` and `jsonschema==4.10.3` tool dependencies. Native extension
files are intentionally omitted so the tools image uses the Python runtime
provided by the offline Runner base image on the target architecture.

The files are copied from the Ubuntu amd64 packaging environment during the
online packaging phase and are included in the immutable performance-tools
image. The image is candidate-commit labelled and imported from the Benchmark
asset archive before any offline command is run.
