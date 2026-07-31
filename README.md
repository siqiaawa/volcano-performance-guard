# Volcano 离线 E2E 与性能看护

本仓库负责连接三个彼此独立的对象：

1. `volcano-offline-e2e-bundle`：提供离线 Runner、Kind、本地 registry、参考 Volcano 和 E2E 资产；
2. 独立的候选 Volcano 仓库：提供待测 commit、组件源码和同 commit 部署材料；
3. 本仓库：提供 Adapter、Profile、性能负载、指标契约、基线比较和流水线编排。

本仓库不保存 Volcano 业务源码，不复制离线包的参考源码，也不保存 Docker 镜像 tar。当前候选 commit 的 Go module 补充包是经过 commit、基础 Runner 和 SHA-256 绑定的例外离线制品，保存在 `offline-assets/go-mod/`；它不是 Docker 镜像，也不替代仍应通过独立 Release 交付的性能工具镜像。

## 当前状态

离线包阶段 A 检查已经完成：

- 参考 Volcano commit：`1cb0a6359032ad5214143e0c22672f15ac7965c2`；
- Kubernetes `v1.36.1`、Kind `v0.32.0`、Ginkgo `v2.28.1`；
- 7 个镜像归档、23 个必需镜像标签、2 个 KWOK Chart；
- 断公网 Kind 节点上的集群、KWOK、Volcano 和 Volcano 调度冒烟任务均通过；
- 部署窗口没有 Docker `pull` 事件，运行时镜像请求命中本地 registry；
- `run-env.sh` 固定挂载参考源码，不原生支持候选源码目录参数。

详细证据见 `docs/offline-bundle-analysis.md`，机器可读检测结果见 `configs/offline-bundle.detected.yaml`。

候选 commit `d57d10f47129b11f12d875de1195a42c0a53270f` 已在专用 Kind 集群中完成离线构建、发布、同 commit Helm 部署、Volcano 调度冒烟，以及社区 Pod/Gang 和离线 KWOK Pod/Gang smoke。完整监控资产包已经在本机生成、校验并导入本地 registry：`.work/offline-assets/benchmark-tools/<commit>/`，包含 6 个固定镜像（含 `performance-guard-tools`）、2 个 KWOK Chart、`manifest.json`、`SHA256SUMS` 和导入清单；audit-enabled Pod/Gang Benchmark 已完成真实离线联调。导入该包后，外层指标、报告和 YAML 校验通过工具镜像执行，不要求宿主机安装 Python。完整上游 E2E 矩阵和正式 approved baseline 仍未完成，不能由 smoke 或单轮 Benchmark 结果代替。

当前 commit 的 Go module 补充包固化在 `offline-assets/go-mod/d57d10f47129b11f12d875de1195a42c0a53270f/`。执行 `make import-candidate-deps` 后，可以在无网络条件下构建派生 Runner；该命令会校验补充包 SHA-256、候选 commit 和离线包的基础 Runner 身份。固定候选版本的离线构建、部署和 timestamp smoke 使用这个 Runner。其他候选 commit 必须使用独立目录和新的补充包，不能复用此目录。

## 快速检查

在 WSL 中执行：

```bash
cd /mnt/g/~CODE/2026_7_29TOOLS/volcano-performance-guard

make inspect-bundle \
  BUNDLE_DIR=/mnt/g/~CODE/2026_7_29TOOLS/volcano-offline-e2e-bundle

make candidate-preflight \
  BUNDLE_DIR=/mnt/g/~CODE/2026_7_29TOOLS/volcano-offline-e2e-bundle \
  CANDIDATE_DIR=/mnt/g/~CODE/2026_7_29TOOLS/volcano-master \
  CANDIDATE_EXPECTED_COMMIT=d57d10f47129b11f12d875de1195a42c0a53270f

make contract-demo
make test
```

目标服务器的完整试验顺序、学长离线包验收、候选构建部署、监控 Benchmark、结果归档和清理步骤见 [`docs/server-trial-guide.md`](docs/server-trial-guide.md)。

`inspect-bundle` 只读取离线包，不加载镜像、创建集群或修改参考源码。输出写入 `.work/offline-bundle.detected.yaml`。

`candidate-preflight` 将候选源码只读挂载到离线 Runner，并使用 Docker
`--network none`、`GOPROXY=off` 和 `GOSUMDB=off` 验证 Go 依赖缓存；同时检查
候选组件 Dockerfile 引用的全部基础镜像。任一资产缺失都会明确失败，不会访问公网。

第一次在离线机器上使用当前固化候选版本时，先导入仓库内补充包：

```bash
make import-candidate-deps \
  BUNDLE_DIR=/mnt/g/~CODE/2026_7_29TOOLS/volcano-offline-e2e-bundle
```

随后 `candidate-preflight`、`candidate-build-binaries`、`candidate-build-images`、`candidate-deploy` 与 `candidate-timestamp-profile` 默认使用 `volcano-candidate-runner:d57d10f47129b11f12d875de1195a42c0a53270f`。更换候选 commit 时，必须显式同时覆盖 `CANDIDATE_EXPECTED_COMMIT`、`CANDIDATE_DEPS_ASSET_DIR` 和 `CANDIDATE_RUNNER_IMAGE`。

对于尚未固化依赖的新候选 commit，可以用一个入口自动完成依赖发现和增量补充：

```bash
make candidate-prepare-deps \
  CANDIDATE_DIR=/mnt/g/path/to/volcano \
  CANDIDATE_EXPECTED_COMMIT=<candidate-commit>

# 只有发现缺失模块并确认允许联网下载时才执行：
make candidate-prepare-deps \
  CANDIDATE_DIR=/mnt/g/path/to/volcano \
  CANDIDATE_EXPECTED_COMMIT=<candidate-commit> \
  ALLOW_NETWORK=1
source .work/candidate-runner.env
```

该入口先用学长包 Runner 在断网条件下预检；在线阶段只下载预检报告列出的缺失
`path@version` 模块，随后构建并校验绑定候选 commit 的派生 Runner，再次以
`Docker --network none` 完成预检。如果二次 Go 解析发现新的传递依赖，入口会合并
列表并重新打包，最多迭代五轮；它不会把新版本依赖写入学长包，也不会修改候选源码。

`contract-demo` 只使用仓库内 fixture，验证环境、候选发布、Profile、单轮指标和聚合指标契约，并生成 dry-run 执行计划。它不会调用 Docker、Helm 或 kubectl。

## 候选部署与 Timestamp Smoke

在候选的依赖预检、二进制和镜像构建已经完成后，以下入口会发布候选镜像，创建由 marker 保护的专用 Kind 集群，并从候选 checkout 的 Helm Chart 部署组件：

```bash
make candidate-publish-images \
  CANDIDATE_DIR=/mnt/g/~CODE/2026_7_29TOOLS/volcano-master \
  CANDIDATE_BUILD_DIR=.work/candidates/<candidate-commit>

make candidate-create-cluster candidate-deploy candidate-smoke \
  CANDIDATE_DIR=/mnt/g/~CODE/2026_7_29TOOLS/volcano-master \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:<candidate-commit>

make candidate-timestamp-profile \
  CANDIDATE_DIR=/mnt/g/~CODE/2026_7_29TOOLS/volcano-master \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:<candidate-commit> \
  TIMESTAMP_PROFILE=profiles/offline-timestamp-smoke.yaml
```

`candidate-timestamp-profile` uses `busybox:latest` from the verified base bundle registry and gathers `Created -> PodScheduled` timestamps plus kubelet summary CPU/memory samples. The timestamp source is second-precision, so its latency percentiles are explicitly marked `latencyGateEligible: false`; it is a functional and throughput smoke, not a substitute for the audit-exporter/Prometheus performance gate.

社区 Benchmark 的最小离线路径使用：

```bash
make candidate-community-benchmark \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-smoke \
  COMMUNITY_SCENARIO=pod COMMUNITY_COUNT=10 COMMUNITY_SCHEDULER=volcano

make candidate-community-benchmark \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-smoke \
  COMMUNITY_SCENARIO=gang COMMUNITY_COUNT=10 COMMUNITY_SCHEDULER=volcano \
  COMMUNITY_USE_KWOK=1
```

`COMMUNITY_USE_KWOK=1` 只使用资产包内的 KWOK Chart，不调用候选源码中的 GitHub manifest URL。结果写入 `.work/reports/<cluster>/community-benchmark/`，包括：

- 上游 `go test -json` 原始事件和可读测试日志；
- 测试结束、清理之前采集的 Benchmark Pod/VCJob JSON；
- scheduler 测试前后状态；
- 包含延迟分位数、提交到完成耗时、Pod/s 吞吐、调度率、失败/待调度数量和 scheduler 重启增量的 `result.json`；
- 人工可读的 `summary.md`。

Adapter 通过上游已有的 `DRY_RUN=true` 生命周期开关临时保留带 `volcano.sh/benchmark=true` 标签的资源，采集完成后仍主动清理；候选源码不会被修改。Pod 延迟来自 Kubernetes 状态时间戳，只有秒级精度，`result.json` 固定标记 `latencyGateEligible: false`。该路径可用于离线功能、吞吐和粗粒度性能检测；精确 latency gate 仍要求带 API Server audit logging 的独立集群。

`make package-benchmark-assets ALLOW_NETWORK=1 INCLUDE_OPTIONAL=1` 已用于生成完整监控资产包，`make import-benchmark-assets` 已在无公网运行时校验并导入本地 registry。该命令会先加载包含 `performance-guard-tools` 的归档，再通过 Docker socket 执行导入校验；离线工具容器不依赖宿主机 Python。跨机器交付时必须保留该 commit 目录中的 `manifest.json`、`SHA256SUMS`、`benchmark-images.tar`、两个 KWOK Chart 和 `imported-manifest.json`；当前目录是本机工作区制品，尚未发布为独立 Release 压缩包。`make scan-benchmark-deps` 仍可用于后续候选版本的依赖差集扫描。`make compare-baseline BASELINE=/approved/baseline.json` 只比较候选聚合结果和独立审批的稳定 baseline，并写出 JSON、Markdown、JUnit 和 HTML 报告。默认 `configs/timestamp-thresholds.example.yaml` 刻意排除延迟分位数；只有导入并审批了亚秒级测量栈后，才可使用包含 latency gate 的阈值。

## 保留边界

- `adapters/offline-e2e-bundle/`：实际离线包的检查与后续接入边界；
- `adapters/mock/`：无副作用的契约测试 Adapter；
- `contracts/`：版本化 JSON Schema；
- `profiles/`：尚待真实环境校准的 Profile；
- `scripts/`：执行计划、环境导出和指标聚合；
- `tests/`：契约和核心逻辑测试；
- `reports/`：运行时生成物，不提交具体测试报告。

当前离线试运行阶段已经实现外部候选源码挂载、`GOPROXY=off` 依赖预检、候选镜像强制构建、同 commit 部署校验、监控资产导入和社区 Benchmark。下一阶段应在目标服务器完成完整上游 E2E 矩阵、采集多轮稳定数据并审批正式 baseline；伏羲流水线按本期范围暂不完成，不在仓库中猜测内部 YAML 语法。
