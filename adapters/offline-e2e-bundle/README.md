# Offline E2E bundle Adapter

该 Adapter 是性能工程访问学长离线包的唯一边界。

当前已实现的 `inspect.sh` 只读检查实际包结构、`offline.env`、参考源码 commit、归档数量和已知性能工具差集：

```bash
bash adapters/offline-e2e-bundle/inspect.sh \
  --bundle-dir /path/to/volcano-offline-e2e-bundle \
  --output .work/offline-bundle.detected.yaml
```

脚本不执行 `docker load`、Kind、Helm 或 kubectl，也不修改包内 `source/volcano`。

候选模式由本 Adapter 的 `run-candidate.sh` 显式启动包内 Runner 镜像，把独立候选源码只读挂载到 `/workspace/volcano`。不得调用现有 `run-env.sh` 后假设它会使用外部候选源码，因为该脚本固定挂载包内参考工作树并设置 `FORCE_REBUILD=false`。

候选构建、依赖预检、集群准备、候选部署、监控安装、Benchmark、参考版本恢复和 marker 保护的清理编排均已实现。所有变更型操作都保留原包和候选 checkout 不变，并通过参数接收包位置；完整上游 E2E 矩阵、正式 baseline 审批和伏羲流水线不属于本期完成范围。
# Offline E2E bundle Adapter

The Adapter keeps the external bundle and candidate checkout separate from
this repository.

Available entrypoints:

```text
inspect.sh              Read-only bundle inventory and identity check
run-candidate.sh        Read-only candidate mount in the bundle Runner
preflight-candidate.sh  Candidate Git, offline Go cache, and base image check
prepare-candidate-deps.sh  Discover, package, import, and verify candidate Go modules
run-timestamp-benchmark.py  Offline single-iteration Pod timestamp smoke
run-community-benchmark.sh  Upstream Pod/Gang offline performance detection
```

`run-candidate.sh` defaults to Docker network mode `none` and does not expose
the Docker socket unless explicitly requested. Candidate source is always
mounted read-only. Runtime state is written below this repository's `.work/`
directory, never inside the bundle or candidate checkout.

`run-timestamp-benchmark.py` is intentionally an existing-cluster smoke path.
It does not call the candidate benchmark's online KWOK scripts or install the
monitoring stack. Its timestamp latency is second-precision and must not be
used as a sub-second latency gate.

`run-community-benchmark.sh` executes the candidate commit's upstream Pod or
Gang `TestFromConfig` against the existing cluster. It temporarily retains the
benchmark-labelled resources, captures their PodScheduled timestamps and
correctness state, calculates submission-to-completion throughput from
structured `go test -json` events, records scheduler restart deltas, and then
cleans the resources. This path does not require Prometheus or modify the
candidate checkout.

For a new candidate commit, `prepare-candidate-deps.sh` first runs the
read-only preflight against the Runner declared by `offline.env`. If modules
are missing, it fails without network access unless `--allow-network` is
explicit. With that flag it downloads only the reported `path@version` entries,
builds a commit-labelled derived Runner, and repeats the preflight with Docker
network disabled. If the second Go dependency pass reveals another module in
the transitive closure, the supplement is expanded and rebuilt for up to five
iterations. The resulting `CANDIDATE_RUNNER_IMAGE` can be written to an env
file; the bundle and candidate checkout remain unchanged.
