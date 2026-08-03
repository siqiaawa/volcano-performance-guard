# 服务器离线试验指南

## 1. 目标和结论边界

本指南用于在一台尚未运行过学长离线包的 Ubuntu amd64 服务器上，先验证学长包自身，再验证 Volcano Performance Guard 对候选版本的构建、部署、监控、社区 Benchmark 和报告链路。

当前固化候选 commit：

~~~text
d57d10f47129b11f12d875de1195a42c0a53270f
~~~

本轮试验可以验证：

- 学长包镜像、Runner、Kind、Kubernetes、Helm、参考 Volcano 和本地 registry 能否离线运行；
- 候选源码能否在 GOPROXY=off、Docker --network none 下完成依赖预检、二进制和镜像构建；
- 实际运行的 Volcano Pod 是否来自候选 commit；
- 社区 Pod/Gang Benchmark、KWOK、Prometheus、Grafana、kube-state-metrics 和 Audit Exporter 是否可用；
- 没有宿主机 Python 时，外层 YAML、指标、聚合和报告工具是否仍可用；
- 失败时是否保留诊断，并能按 cluster marker 安全清理。

这不是正式验收声明。完整上游 E2E 矩阵、正式 approved baseline 和伏羲流水线仍不属于本期完成范围。SCHEDULINGBASE 超时只能记录为 incomplete/timeout，不能标记为通过或写入正式 baseline。

## 2. 交付内容和精简原则

建议服务器目录：

~~~text
/srv/volcano-trial/
  volcano-offline-e2e-bundle/
  volcano-performance-guard/
  volcano-test-version/
~~~

学长包必须完整复制。它约 3.5 GiB，主要是不可替代的镜像归档，不能删除 images、runner、source、charts 或 manifest。

Performance Guard 初始交付至少包括：

~~~text
Makefile
adapters/ configs/ contracts/ docs/ profiles/ scripts/ tests/ tools/
offline-assets/go-mod/d57d10f47129b11f12d875de1195a42c0a53270f/
requirements-contract.txt
.gitattributes .gitignore README.md
.work/offline-assets/benchmark-tools/d57d10f47129b11f12d875de1195a42c0a53270f/
  benchmark-images.tar
  manifest.json
  SHA256SUMS
  candidate-commit.txt
  charts/
~~~

imported-manifest.json 和 registry-images.env 可以一并复制，服务器重新导入后会刷新。不要把开发机整个 .work 目录复制过去；reports、clusters、candidates、contract-demo 都是运行时生成物。

如果通过 GitHub Release 交付，Release 页面中的附件是扁平的，不会保留目录。克隆仓库后必须按以下方式还原；文件名不能修改，归档不能提前解压：

~~~text
.work/offline-assets/benchmark-tools/d57d10f47129b11f12d875de1195a42c0a53270f/
  benchmark-images.tar
  manifest.json
  SHA256SUMS
  charts/
    kwok-chart-0.3.0.tgz
    kwok-stage-fast-chart-0.3.0.tgz

offline-assets/go-mod/d57d10f47129b11f12d875de1195a42c0a53270f/
  go-mod-supplement.tar.gz
  go-mod-supplement.tar.gz.sha256
  base-runner-image.txt
  candidate-commit.txt
  missing-modules.txt
~~~

其中 Go module 目录里的后四个元数据文件已经随 Git 仓库提供，Release 下载后补入 `go-mod-supplement.tar.gz` 和 `.sha256` 文件即可。公开仓库可以直接使用 `curl` 下载 Release 附件，也可以用浏览器下载后按目录树放置；准确命令见 `offline-assets/README.md`。

当前体积是合理的：Performance Guard 源码和依赖约 43 MiB，vendored Python 依赖约 2.3 MiB，Benchmark 镜像归档约 800 MiB，候选 Go module 增量包约 40 MiB。工具镜像包含 Python 3.13.5、PyYAML 6.0.1、jsonschema 4.10.3 和 Docker CLI，所以服务器不需要预装 Python；服务器仍需要 Docker daemon、Bash、Git、Make。

## 3. 设置路径和前置检查

~~~bash
export TRIAL_ROOT=/srv/volcano-trial
export BUNDLE_DIR=$TRIAL_ROOT/volcano-offline-e2e-bundle
export GUARD_DIR=$TRIAL_ROOT/volcano-performance-guard
export CANDIDATE_DIR=$TRIAL_ROOT/volcano-test-version
export COMMIT=d57d10f47129b11f12d875de1195a42c0a53270f
export ASSET_DIR=$GUARD_DIR/.work/offline-assets/benchmark-tools/$COMMIT

uname -m
docker version
docker info
command -v bash git make docker
df -h $TRIAL_ROOT
free -h
~~~

要求：

- uname -m 为 x86_64；
- Docker daemon 正常，当前用户可以直接执行 Docker；
- 至少准备 60 GiB 可用磁盘；完整 E2E 建议 8 vCPU、16 GiB 内存以上；
- 试验期间不启用 Go proxy、Helm 公网仓库或 Docker Hub 回退。

如果复制后脚本没有执行权限：

~~~bash
find $BUNDLE_DIR -type f -name '*.sh' -exec chmod +x {} +
find $GUARD_DIR -type f -name '*.sh' -exec chmod +x {} +
~~~

确认候选仓库：

~~~bash
git -C $CANDIDATE_DIR rev-parse HEAD
test "$(git -C $CANDIDATE_DIR rev-parse HEAD)" = "$COMMIT"
test -z "$(git -C $CANDIDATE_DIR status --porcelain)"
~~~

commit 不一致或工作树不干净时必须停止。

## 4. 第一阶段：学长离线包

### 4.1 校验归档和参考源码

从 GitHub 克隆的离线包不包含嵌套的 `source/volcano/.git`。先用同机候选仓库中已有
的完整历史恢复参考提交的 shallow Git 元数据；脚本只写 `.git`，不会改写工作树：

~~~bash
cd $BUNDLE_DIR
./restore-source-git.sh --source-repo $CANDIDATE_DIR
./verify-bundle.sh
~~~

成功标准：

- SHA256SUMS 全部为 OK；
- source/volcano commit 为 1cb0a6359032ad5214143e0c22672f15ac7965c2；
- source/volcano Git 顶层就是 source/volcano，不会向上误读外层 bundle commit；
- 受 Git 管理的参考源码没有修改。

可以查看：

~~~bash
cat offline.env
cat manifest/images-required.txt
~~~

不要用 docker pull 解决校验失败；先重新复制或补齐学长包。

### 4.2 导入镜像并启动 registry

~~~bash
cd $BUNDLE_DIR
./install-offline.sh

curl -fsS http://localhost:15000/v2/
docker ps --filter name=volcano-offline-registry
docker image inspect volcano-offline-runner:1cb0a6359032ad5214143e0c22672f15ac7965c2
docker image inspect kindest/node:v1.36.1
~~~

install-offline.sh 会加载 images/*.tar，检查 manifest/images-required.txt，启动 volcano-offline-registry，并发布参考 Volcano 和 E2E 镜像。registry 探针应返回 HTTP 200；Runner 和 Kind node image 必须存在。

### 4.3 学长包最小 E2E

第一次建议先运行官方最小入口：

~~~bash
cd $BUNDLE_DIR
./run-env.sh kind delete cluster --name integration 2>/dev/null || true
./make-e2e.sh
~~~

命令返回 0 且没有缺镜像、外网下载或 Go 依赖错误，才算学长包最小路径通过。日志通常位于 source/volcano/volcano-e2e-logs/。

最小路径通过后，按资源情况运行完整矩阵：

~~~bash
./run-full-e2e.sh
~~~

完整矩阵耗时较长。每个 target 都要记录 pass、fail 或 timeout，不能把未完成目标改写为通过。结束后删除参考集群但保留 registry：

~~~bash
./run-env.sh kind delete cluster --name integration 2>/dev/null || true
~~~

## 5. 第二阶段：Guard 契约和工具镜像

~~~bash
cd $GUARD_DIR
make inspect-bundle BUNDLE_DIR=$BUNDLE_DIR
make test
make contract-demo
~~~

成功标准：

- .work/offline-bundle.detected.yaml 生成，参考 commit、镜像数量、Runner 和 registry 与学长包一致；
- make test 全部通过；
- contract-demo 生成 .work/contract-demo/run-plan.json 和聚合指标；
- 不访问 Kubernetes、Helm 或公网。

导入 Benchmark 资产：

~~~bash
cd $GUARD_DIR
cd $ASSET_DIR
sha256sum -c SHA256SUMS
cd $GUARD_DIR

make import-benchmark-assets \
  BUNDLE_DIR=$BUNDLE_DIR \
  CANDIDATE_EXPECTED_COMMIT=$COMMIT \
  CANDIDATE_BENCHMARK_ASSET_DIR=$ASSET_DIR
~~~

成功标准是 Imported 6 Benchmark images into localhost:15000，并生成或刷新 imported-manifest.json、registry-images.env。

工具镜像验证：

~~~bash
export PERFORMANCE_GUARD_TOOLS_IMAGE=localhost:15000/volcanosh/performance-guard-tools:$COMMIT
docker image inspect $PERFORMANCE_GUARD_TOOLS_IMAGE \
  --format '{{.Id}} {{index .Config.Labels "io.volcano.performance-guard.candidate.commit"}}'

PERFORMANCE_GUARD_TOOLS_IMAGE=$PERFORMANCE_GUARD_TOOLS_IMAGE \
  bash scripts/run-performance-tools.sh \
  scripts/validate-contracts.py profile profiles/smoke.yaml profiles/pr-gate.yaml
~~~

如果服务器没有 Python，仍应通过已导入的工具镜像执行。工具镜像缺失时必须先导入资产，不要把宿主 Python 回退作为正式服务器运行方式。

要在具备普通系统工具但不把 python3 放入 PATH 的条件下复现实验，可创建一个临时工具目录：

~~~bash
NO_PYTHON_BIN=$(mktemp -d)
for command_name in bash docker git realpath make awk find sort sed grep sha256sum curl dirname; do
  ln -s "$(command -v "$command_name")" "$NO_PYTHON_BIN/$command_name"
done
PATH=$NO_PYTHON_BIN PERFORMANCE_GUARD_TOOLS_IMAGE=$PERFORMANCE_GUARD_TOOLS_IMAGE \
  bash scripts/run-performance-tools.sh \
  scripts/validate-contracts.py profile profiles/smoke.yaml profiles/pr-gate.yaml
rm -rf "$NO_PYTHON_BIN"
~~~

## 6. 第三阶段：候选依赖、构建和发布

导入当前候选的 Go module 增量包：

~~~bash
cd $GUARD_DIR
make import-candidate-deps \
  BUNDLE_DIR=$BUNDLE_DIR \
  CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_EXPECTED_COMMIT=$COMMIT
~~~

确认 Runner label：

~~~bash
docker image inspect volcano-candidate-runner:$COMMIT \
  --format '{{.Id}} {{index .Config.Labels "io.volcano.performance-guard.candidate.commit"}}'
~~~

执行断网预检：

~~~bash
make candidate-preflight \
  BUNDLE_DIR=$BUNDLE_DIR \
  CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_EXPECTED_COMMIT=$COMMIT \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT
~~~

预检必须显示 trackedSourceClean=true、offlineGoDependencies=true，且候选 Dockerfile 的基础镜像全部可用。如果发现新 Go 模块，服务器不得联网下载；回到有网络的打包机执行：

~~~bash
make candidate-prepare-deps \
  BUNDLE_DIR=$BUNDLE_DIR \
  CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_EXPECTED_COMMIT=$COMMIT \
  ALLOW_NETWORK=1
~~~

重新生成 commit 绑定的增量包和 Runner 后，再复制到服务器。

在服务器构建并发布候选：

~~~bash
make candidate-build-binaries \
  BUNDLE_DIR=$BUNDLE_DIR CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_EXPECTED_COMMIT=$COMMIT \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT

make candidate-build-audit-exporter \
  BUNDLE_DIR=$BUNDLE_DIR CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_EXPECTED_COMMIT=$COMMIT \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT

make candidate-build-images \
  BUNDLE_DIR=$BUNDLE_DIR CANDIDATE_DIR=$CANDIDATE_DIR

make candidate-publish-images \
  CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_BUILD_DIR=$GUARD_DIR/.work/candidates/build
~~~

检查 .work/candidates/build/build-metadata.env 和 registry-images.env。所有候选组件的 tag、label、registry 和 digest 必须指向同一个 COMMIT。

## 7. 第四阶段：候选 Smoke 和社区 Benchmark

### 7.1 Smoke 集群

~~~bash
make candidate-create-cluster \
  BUNDLE_DIR=$BUNDLE_DIR CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-smoke

make candidate-deploy \
  BUNDLE_DIR=$BUNDLE_DIR CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-smoke

make candidate-smoke \
  BUNDLE_DIR=$BUNDLE_DIR CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-smoke
~~~

Smoke 会验证候选 imageID、Volcano 调度 Job、registry 命中和 Kind 节点公网 IPv4 阻断。结果位于：

~~~text
.work/reports/volcano-candidate-smoke/
.work/clusters/volcano-candidate-smoke/cluster.marker
~~~

### 7.2 Pod/Gang Benchmark

~~~bash
make candidate-community-benchmark \
  BUNDLE_DIR=$BUNDLE_DIR CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-smoke \
  COMMUNITY_SCENARIO=pod COMMUNITY_COUNT=10 COMMUNITY_SCHEDULER=volcano

make candidate-community-benchmark \
  BUNDLE_DIR=$BUNDLE_DIR CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-smoke \
  COMMUNITY_SCENARIO=gang COMMUNITY_COUNT=10 \
  COMMUNITY_SCHEDULER=volcano COMMUNITY_USE_KWOK=1
~~~

检查 .work/reports/volcano-candidate-smoke/community-benchmark/result.json 和 summary.md。必须有吞吐、调度率、失败/待调度数量和正确性结果。秒级 Pod 状态时间戳只能保持 latencyGateEligible=false。

### 7.3 Audit 集群和监控

~~~bash
make candidate-create-audit-cluster \
  BUNDLE_DIR=$BUNDLE_DIR CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_AUDIT_CLUSTER_NAME=volcano-candidate-audit

make candidate-deploy \
  BUNDLE_DIR=$BUNDLE_DIR CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-audit \
  CANDIDATE_CLUSTER_STATE=$GUARD_DIR/.work/clusters/volcano-candidate-audit \
  CANDIDATE_REPORT_DIR=$GUARD_DIR/.work/reports/volcano-candidate-audit/deploy

make candidate-install-monitoring \
  BUNDLE_DIR=$BUNDLE_DIR CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_AUDIT_CLUSTER_NAME=volcano-candidate-audit

make candidate-audit-community-benchmark \
  BUNDLE_DIR=$BUNDLE_DIR CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_AUDIT_CLUSTER_NAME=volcano-candidate-audit \
  COMMUNITY_SCENARIO=pod COMMUNITY_COUNT=10 COMMUNITY_SCHEDULER=volcano
~~~

Audit 集群创建后必须先执行上面的 `candidate-deploy`，不能直接跳到监控安装和 Benchmark。Prometheus、Grafana、kube-state-metrics 和 Audit Exporter 必须 rollout 成功，Audit Exporter metrics 必须包含 pod_scheduling_latency_seconds。Audit 报告中的 commit、registry digest 和 cluster marker 必须一致。

### 7.4 Timestamp 和候选 E2E

~~~bash
make candidate-timestamp-profile \
  BUNDLE_DIR=$BUNDLE_DIR CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-smoke
~~~

该路径是功能/吞吐 smoke，不是毫秒级门禁。

需要单独验证候选 E2E 时：

~~~bash
make candidate-create-e2e-cluster \
  BUNDLE_DIR=$BUNDLE_DIR CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_E2E_CLUSTER_NAME=volcano-candidate-e2e

make candidate-e2e \
  BUNDLE_DIR=$BUNDLE_DIR CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_E2E_CLUSTER_NAME=volcano-candidate-e2e \
  E2E_SUITE=SCHEDULINGBASE
~~~

超时必须记录为 incomplete/timeout，不能写入正式 baseline。

## 8. 基线、归档和清理

只有同环境多轮正式运行并获得审批的 baseline 才能用于：

~~~bash
make compare-baseline \
  BASELINE=/srv/approved/volcano-baseline.json
~~~

Smoke、单轮 Benchmark 或被中断的 E2E 结果不能自动覆盖 baseline。

至少归档：

~~~text
学长包/source/volcano/volcano-e2e-logs/
Guard/.work/offline-bundle.detected.yaml
Guard/.work/candidate-preflight.yaml
Guard/.work/candidates/build/
Guard/.work/clusters/*/cluster.marker
Guard/.work/reports/volcano-candidate-smoke/
Guard/.work/reports/volcano-candidate-audit/
Guard/.work/reports/volcano-candidate-e2e/
Guard/.work/offline-assets/benchmark-tools/<commit>/manifest.json
Guard/.work/offline-assets/benchmark-tools/<commit>/imported-manifest.json
~~~

Smoke 集群清理：

~~~bash
make candidate-cleanup \
  BUNDLE_DIR=$BUNDLE_DIR CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-smoke
~~~

Audit 和 E2E 集群分别清理：

~~~bash
make candidate-cleanup \
  BUNDLE_DIR=$BUNDLE_DIR CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-audit \
  CANDIDATE_CLUSTER_STATE=$GUARD_DIR/.work/clusters/volcano-candidate-audit

make candidate-cleanup \
  BUNDLE_DIR=$BUNDLE_DIR CANDIDATE_DIR=$CANDIDATE_DIR \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-e2e \
  CANDIDATE_CLUSTER_STATE=$GUARD_DIR/.work/clusters/volcano-candidate-e2e
~~~

清理前先复制报告；清理失败时保留 cluster.marker 和诊断，不要手工删除状态目录后再删除未知集群。

最终检查：

~~~bash
kind get clusters
docker ps --format '{{.Names}}'
~~~

不再进行试验时才删除本地 registry：

~~~bash
docker rm -f volcano-offline-registry
~~~

## 9. 通过标准速查

| 阶段 | 通过条件 | 失败处理 |
| --- | --- | --- |
| 学长包校验 | SHA256 全部 OK、参考 commit 正确 | 重新复制或补齐学长包 |
| 学长最小 E2E | make-e2e.sh 返回 0 | 保留日志，先修复学长包 |
| Guard 契约 | make test、make contract-demo 通过 | 检查工具镜像和路径 |
| 候选预检 | clean、Go offline、基础镜像齐全 | 回打包机补齐增量依赖 |
| 候选 Smoke | imageID、Job、无公网 pull | 检查 build metadata、registry、marker |
| 社区 Benchmark | result.json 完整且资源清理成功 | 记录失败，不补零 |
| Audit 监控 | 四类组件 ready、metrics 存在 | 检查 asset manifest、端口、audit |
| 完整 E2E | 每个 suite 明确 pass/fail/timeout | timeout 保持未完成 |
| 正式性能结论 | 同环境多轮和独立 baseline | 不满足时只输出试验结论 |

完成这些步骤后，可以称为“服务器离线试运行链路已验证”；完整 E2E、稳定 baseline 和后续审批完成后，才能称为“正式性能验收完成”。
