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

## 从仓库拉取开始的完整验证

下面按实际执行顺序验证两个交付仓库：先验证
`volcano-offline-e2e-bundle`，再用 `volcano-performance-guard` 验证固定的
`volcano-test-version` 候选源码。联网准备和离线服务器执行必须分开；离线服务器不得
用 `docker pull`、Go proxy 或在线 Helm 仓库补救缺失资产。

### 1. 联网准备机拉取三个仓库

准备机需要 `git`、`curl` 和 `sha256sum`。三个仓库和对应 Release 均为公开内容，
不需要 `gh`、GitHub 登录或 Personal Access Token。以下两个 `v0.1.0` 是各自仓库的
Release 标签，不是 Volcano 候选版本号：

以下命令按 WSL/Linux Bash 编写。纯 Windows PowerShell 中应使用 `curl.exe` 而不是
可能被映射为 `Invoke-WebRequest` 的 `curl` 别名；也可以用浏览器下载后按后面的目录树
放置，并最终在 WSL 或 Linux 服务器执行 `sha256sum` 校验。

```bash
export PREP_ROOT=$PWD/volcano-trial
mkdir -p "$PREP_ROOT"

git clone --branch v0.1.0 --depth 1 \
  https://github.com/siqiaawa/volcano-offline-e2e-bundle.git \
  "$PREP_ROOT/volcano-offline-e2e-bundle"

git clone --branch main --single-branch \
  https://github.com/siqiaawa/volcano-performance-guard.git \
  "$PREP_ROOT/volcano-performance-guard"

git clone --branch main --single-branch \
  https://github.com/siqiaawa/volcano-test-version.git \
  "$PREP_ROOT/volcano-test-version"
```

固定本轮目录和候选身份：

```bash
export BUNDLE_DIR=$PREP_ROOT/volcano-offline-e2e-bundle
export GUARD_DIR=$PREP_ROOT/volcano-performance-guard
export CANDIDATE_DIR=$PREP_ROOT/volcano-test-version
export COMMIT=d57d10f47129b11f12d875de1195a42c0a53270f
export BENCHMARK_ASSET_DIR=$GUARD_DIR/.work/offline-assets/benchmark-tools/$COMMIT
export GO_MOD_ASSET_DIR=$GUARD_DIR/offline-assets/go-mod/$COMMIT

download_release_asset() {
  local repository="$1" tag="$2" asset="$3" destination="$4"
  mkdir -p "$(dirname "$destination")"
  curl -fL --retry 3 --retry-delay 2 \
    -o "$destination" \
    "https://github.com/$repository/releases/download/$tag/$asset"
}

test "$(git -C "$CANDIDATE_DIR" rev-parse HEAD)" = "$COMMIT"
test -z "$(git -C "$CANDIDATE_DIR" status --porcelain)"
```

任一 `test` 失败都要停止，不能用其他候选源码配合当前固化资产。
Performance Guard 的代码从 `main` 拉取，以获得当前服务器验证说明和修正；其二进制
资产仍从 `v0.1.0` Release 下载，并由候选 commit 与校验清单绑定。

### 2. 下载并还原学长包 Release

GitHub Release 附件是扁平的。7 个镜像 tar 放进 `images/`，两个 Chart 放进
`charts/`，文件名保持不变且不要解压。下面继续使用第 1 步定义的
`download_release_asset` 函数；如果打开了新的 shell，需要先重新执行第 1 步的变量和
函数定义：

```bash
mkdir -p "$BUNDLE_DIR/images" "$BUNDLE_DIR/charts"

for asset in \
  00-runner.tar \
  01-kind-node.tar \
  02-volcano-components.tar \
  03-small-e2e-and-registry.tar \
  04-mpi-tensorflow-e2e.tar \
  10-pytorch-e2e.tar \
  11-ray-e2e.tar; do
  download_release_asset \
    siqiaawa/volcano-offline-e2e-bundle v0.1.0 "$asset" "$BUNDLE_DIR/images/$asset"
done

for asset in kwok-chart-0.3.0.tgz kwok-stage-fast-chart-0.3.0.tgz; do
  download_release_asset \
    siqiaawa/volcano-offline-e2e-bundle v0.1.0 "$asset" "$BUNDLE_DIR/charts/$asset"
done

(cd "$BUNDLE_DIR" && sha256sum -c SHA256SUMS)
```

最后一条命令的所有项目必须为 `OK`。更详细的文件名见学长包中的
`images/README.md` 和 `charts/README.md`。

### 3. 下载并还原 Performance Guard Release

```bash
mkdir -p "$BENCHMARK_ASSET_DIR/charts" "$GO_MOD_ASSET_DIR"

for asset in benchmark-images.tar manifest.json SHA256SUMS; do
  download_release_asset \
    siqiaawa/volcano-performance-guard v0.1.0 "$asset" "$BENCHMARK_ASSET_DIR/$asset"
done

for asset in kwok-chart-0.3.0.tgz kwok-stage-fast-chart-0.3.0.tgz; do
  download_release_asset \
    siqiaawa/volcano-performance-guard v0.1.0 "$asset" "$BENCHMARK_ASSET_DIR/charts/$asset"
done

for asset in go-mod-supplement.tar.gz go-mod-supplement.tar.gz.sha256; do
  download_release_asset \
    siqiaawa/volcano-performance-guard v0.1.0 "$asset" "$GO_MOD_ASSET_DIR/$asset"
done

(cd "$BENCHMARK_ASSET_DIR" && sha256sum -c SHA256SUMS)
(cd "$GO_MOD_ASSET_DIR" && sha256sum -c go-mod-supplement.tar.gz.sha256)
```

Benchmark 校验必须包含 `benchmark-images.tar`、`manifest.json` 和两个
`charts/*.tgz`。Go module 校验必须报告 `go-mod-supplement.tar.gz: OK`。完整目录树见
[`offline-assets/README.md`](offline-assets/README.md)。

### 4. 传输到离线服务器并检查环境

将准备好的 `volcano-trial/` 整体通过 U 盘、内网文件服务或 `rsync` 复制到服务器，
不要只复制 Git 源码而漏掉 Release 附件。建议最终目录如下：

```text
/srv/volcano-trial/
  volcano-offline-e2e-bundle/
  volcano-performance-guard/
  volcano-test-version/
```

在服务器设置路径并检查资源：

```bash
export TRIAL_ROOT=/srv/volcano-trial
export BUNDLE_DIR=$TRIAL_ROOT/volcano-offline-e2e-bundle
export GUARD_DIR=$TRIAL_ROOT/volcano-performance-guard
export CANDIDATE_DIR=$TRIAL_ROOT/volcano-test-version
export COMMIT=d57d10f47129b11f12d875de1195a42c0a53270f
export BENCHMARK_ASSET_DIR=$GUARD_DIR/.work/offline-assets/benchmark-tools/$COMMIT
export GO_MOD_ASSET_DIR=$GUARD_DIR/offline-assets/go-mod/$COMMIT

uname -m
docker version
docker info
command -v bash
command -v git
command -v make
command -v docker
command -v curl
command -v sha256sum
df -h "$TRIAL_ROOT"
free -h
```

要求 `uname -m` 为 `x86_64`，Docker daemon 可用，至少有 60 GiB 可用磁盘；建议
8 vCPU、16 GiB 内存以上。宿主机不要求安装 Python。通过 Windows 或压缩包传输后，
恢复脚本执行权限：

```bash
find "$BUNDLE_DIR" -type f -name '*.sh' -exec chmod +x {} +
find "$GUARD_DIR" -type f -name '*.sh' -exec chmod +x {} +
```

再次确认源码和资产没有传错：

```bash
test "$(git -C "$CANDIDATE_DIR" rev-parse HEAD)" = "$COMMIT"
test -z "$(git -C "$CANDIDATE_DIR" status --porcelain)"
(cd "$BUNDLE_DIR" && sha256sum -c SHA256SUMS)
(cd "$BENCHMARK_ASSET_DIR" && sha256sum -c SHA256SUMS)
(cd "$GO_MOD_ASSET_DIR" && sha256sum -c go-mod-supplement.tar.gz.sha256)
```

### 5. 验证并安装学长离线包

```bash
cd "$BUNDLE_DIR"
./verify-bundle.sh
./install-offline.sh

curl -fsS http://localhost:15000/v2/
docker ps --filter name=volcano-offline-registry
docker image inspect volcano-offline-runner:1cb0a6359032ad5214143e0c22672f15ac7965c2
docker image inspect kindest/node:v1.36.1
```

`verify-bundle.sh` 必须全部通过；registry 探针必须成功。随后先执行学长包最小入口：

```bash
./run-env.sh kind delete cluster --name integration 2>/dev/null || true
./make-e2e.sh
```

最小入口返回 0 后，再根据服务器资源决定是否运行完整矩阵：

```bash
./run-full-e2e.sh
./run-env.sh kind delete cluster --name integration 2>/dev/null || true
```

完整矩阵中的每个目标必须记录 `pass`、`fail` 或 `timeout`；未完成不能写成通过。

### 6. 导入 Benchmark 资产并验证 Guard 自身

先加载 Release 中的工具镜像。这样即使宿主机没有 Python，后续契约、YAML、指标和
报告脚本也能在固定工具容器中运行：

```bash
cd "$GUARD_DIR"

make import-benchmark-assets \
  BUNDLE_DIR="$BUNDLE_DIR" \
  CANDIDATE_EXPECTED_COMMIT="$COMMIT" \
  CANDIDATE_BENCHMARK_ASSET_DIR="$BENCHMARK_ASSET_DIR"

export PERFORMANCE_GUARD_TOOLS_IMAGE=localhost:15000/volcanosh/performance-guard-tools:$COMMIT
docker image inspect "$PERFORMANCE_GUARD_TOOLS_IMAGE"

make inspect-bundle BUNDLE_DIR="$BUNDLE_DIR"
make test
make contract-demo
```

成功标准是导入 6 个 Benchmark 镜像、`make test` 全部通过、生成
`.work/offline-bundle.detected.yaml` 和 `.work/contract-demo/run-plan.json`。

### 7. 导入候选 Go 依赖并执行断网预检

```bash
make import-candidate-deps \
  BUNDLE_DIR="$BUNDLE_DIR" CANDIDATE_DIR="$CANDIDATE_DIR" \
  CANDIDATE_EXPECTED_COMMIT="$COMMIT" \
  CANDIDATE_DEPS_ASSET_DIR="$GO_MOD_ASSET_DIR"

docker image inspect volcano-candidate-runner:$COMMIT \
  --format '{{.Id}} {{index .Config.Labels "io.volcano.performance-guard.candidate.commit"}}'

make candidate-preflight \
  BUNDLE_DIR="$BUNDLE_DIR" CANDIDATE_DIR="$CANDIDATE_DIR" \
  CANDIDATE_EXPECTED_COMMIT="$COMMIT" \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT
```

预检必须显示候选源码干净、Go 依赖离线可用、基础镜像齐全。服务器上发现缺失依赖时
必须停止；只能回到联网准备机执行 `make candidate-prepare-deps ALLOW_NETWORK=1`，为
新 commit 生成独立增量包，不能在服务器临时联网下载。

### 8. 构建并发布候选组件

```bash
make candidate-build-binaries \
  BUNDLE_DIR="$BUNDLE_DIR" CANDIDATE_DIR="$CANDIDATE_DIR" \
  CANDIDATE_EXPECTED_COMMIT="$COMMIT" \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT

make candidate-build-audit-exporter \
  BUNDLE_DIR="$BUNDLE_DIR" CANDIDATE_DIR="$CANDIDATE_DIR" \
  CANDIDATE_EXPECTED_COMMIT="$COMMIT" \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT

make candidate-build-images \
  BUNDLE_DIR="$BUNDLE_DIR" CANDIDATE_DIR="$CANDIDATE_DIR"

make candidate-publish-images \
  CANDIDATE_DIR="$CANDIDATE_DIR" \
  CANDIDATE_BUILD_DIR="$GUARD_DIR/.work/candidates/build"
```

检查 `.work/candidates/build/build-metadata.env` 和 `registry-images.env`。所有组件的
tag、label 和 digest 必须绑定同一个 `$COMMIT`。

### 9. 创建候选 Smoke 集群并部署

```bash
make candidate-create-cluster \
  BUNDLE_DIR="$BUNDLE_DIR" CANDIDATE_DIR="$CANDIDATE_DIR" \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-smoke

make candidate-deploy \
  BUNDLE_DIR="$BUNDLE_DIR" CANDIDATE_DIR="$CANDIDATE_DIR" \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-smoke

make candidate-smoke \
  BUNDLE_DIR="$BUNDLE_DIR" CANDIDATE_DIR="$CANDIDATE_DIR" \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-smoke
```

Smoke 必须验证候选 image ID、候选 Helm 部署、Volcano 调度 Job、本地 registry 命中
以及 Kind 节点公网 IPv4 阻断。

### 10. 运行社区 Pod、Gang 和 Timestamp Benchmark

```bash
make candidate-community-benchmark \
  BUNDLE_DIR="$BUNDLE_DIR" CANDIDATE_DIR="$CANDIDATE_DIR" \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-smoke \
  COMMUNITY_SCENARIO=pod COMMUNITY_COUNT=10 COMMUNITY_SCHEDULER=volcano

make candidate-community-benchmark \
  BUNDLE_DIR="$BUNDLE_DIR" CANDIDATE_DIR="$CANDIDATE_DIR" \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-smoke \
  CANDIDATE_BENCHMARK_ASSET_DIR="$BENCHMARK_ASSET_DIR" \
  COMMUNITY_SCENARIO=gang COMMUNITY_COUNT=10 \
  COMMUNITY_SCHEDULER=volcano COMMUNITY_USE_KWOK=1

make candidate-timestamp-profile \
  BUNDLE_DIR="$BUNDLE_DIR" CANDIDATE_DIR="$CANDIDATE_DIR" \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-smoke
```

重点检查 `.work/reports/volcano-candidate-smoke/community-benchmark/result.json` 和
`summary.md`。Timestamp 和普通 Pod 状态时间戳只有秒级精度，必须保持
`latencyGateEligible=false`，不能作为正式延迟门禁。

### 11. 运行 Audit 监控 Benchmark

Audit 集群是独立集群。创建后必须先把候选 Volcano 部署到这个集群，再安装监控：

```bash
make candidate-create-audit-cluster \
  BUNDLE_DIR="$BUNDLE_DIR" CANDIDATE_DIR="$CANDIDATE_DIR" \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_BENCHMARK_ASSET_DIR="$BENCHMARK_ASSET_DIR" \
  CANDIDATE_AUDIT_CLUSTER_NAME=volcano-candidate-audit

make candidate-deploy \
  BUNDLE_DIR="$BUNDLE_DIR" CANDIDATE_DIR="$CANDIDATE_DIR" \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-audit \
  CANDIDATE_CLUSTER_STATE="$GUARD_DIR/.work/clusters/volcano-candidate-audit" \
  CANDIDATE_REPORT_DIR="$GUARD_DIR/.work/reports/volcano-candidate-audit/deploy"

make candidate-install-monitoring \
  BUNDLE_DIR="$BUNDLE_DIR" CANDIDATE_DIR="$CANDIDATE_DIR" \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_BENCHMARK_ASSET_DIR="$BENCHMARK_ASSET_DIR" \
  CANDIDATE_AUDIT_CLUSTER_NAME=volcano-candidate-audit

make candidate-audit-community-benchmark \
  BUNDLE_DIR="$BUNDLE_DIR" CANDIDATE_DIR="$CANDIDATE_DIR" \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_AUDIT_CLUSTER_NAME=volcano-candidate-audit \
  COMMUNITY_SCENARIO=pod COMMUNITY_COUNT=10 COMMUNITY_SCHEDULER=volcano
```

Prometheus、Grafana、kube-state-metrics 和 Audit Exporter 必须 rollout 成功；Audit
Exporter metrics 必须包含 `pod_scheduling_latency_seconds`。

### 12. 运行候选上游 E2E

候选 E2E 使用独立的 1 control-plane、4 worker 集群：

```bash
make candidate-create-e2e-cluster \
  BUNDLE_DIR="$BUNDLE_DIR" CANDIDATE_DIR="$CANDIDATE_DIR" \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_E2E_CLUSTER_NAME=volcano-candidate-e2e

make candidate-e2e \
  BUNDLE_DIR="$BUNDLE_DIR" CANDIDATE_DIR="$CANDIDATE_DIR" \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_BENCHMARK_ASSET_DIR="$BENCHMARK_ASSET_DIR" \
  CANDIDATE_E2E_CLUSTER_NAME=volcano-candidate-e2e \
  E2E_SUITE=SCHEDULINGBASE
```

`SCHEDULINGBASE` 或其他套件超时必须记录为 `incomplete/timeout`，不能标记为通过或
写入正式 baseline。完整矩阵可按服务器资源逐个运行，不要求一次并行完成。

### 13. 比较正式基线、归档结果并清理

只有已经独立审批的多轮稳定基线才能执行：

```bash
make compare-baseline BASELINE=/srv/approved/volcano-baseline.json
```

至少归档 `.work/offline-bundle.detected.yaml`、`.work/candidate-preflight.yaml`、
`.work/candidates/build/`、`.work/clusters/*/cluster.marker` 和 `.work/reports/`。先复制
报告，再通过 marker 保护的入口逐个清理：

```bash
make candidate-cleanup \
  BUNDLE_DIR="$BUNDLE_DIR" CANDIDATE_DIR="$CANDIDATE_DIR" \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-smoke

make candidate-cleanup \
  BUNDLE_DIR="$BUNDLE_DIR" CANDIDATE_DIR="$CANDIDATE_DIR" \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-audit \
  CANDIDATE_CLUSTER_STATE="$GUARD_DIR/.work/clusters/volcano-candidate-audit"

make candidate-cleanup \
  BUNDLE_DIR="$BUNDLE_DIR" CANDIDATE_DIR="$CANDIDATE_DIR" \
  CANDIDATE_RUNNER_IMAGE=volcano-candidate-runner:$COMMIT \
  CANDIDATE_CLUSTER_NAME=volcano-candidate-e2e \
  CANDIDATE_CLUSTER_STATE="$GUARD_DIR/.work/clusters/volcano-candidate-e2e"
```

不要先手工删除 `.work/clusters/*/cluster.marker`，否则会失去安全清理的身份校验。
更详细的成功判据、失败保留和服务器资源说明见
[`docs/server-trial-guide.md`](docs/server-trial-guide.md)。

## 保留边界

- `adapters/offline-e2e-bundle/`：实际离线包的检查与后续接入边界；
- `adapters/mock/`：无副作用的契约测试 Adapter；
- `contracts/`：版本化 JSON Schema；
- `profiles/`：尚待真实环境校准的 Profile；
- `scripts/`：执行计划、环境导出和指标聚合；
- `tests/`：契约和核心逻辑测试；
- `reports/`：运行时生成物，不提交具体测试报告。

当前离线试运行阶段已经实现外部候选源码挂载、`GOPROXY=off` 依赖预检、候选镜像强制构建、同 commit 部署校验、监控资产导入和社区 Benchmark。下一阶段应在目标服务器完成完整上游 E2E 矩阵、采集多轮稳定数据并审批正式 baseline；伏羲流水线按本期范围暂不完成，不在仓库中猜测内部 YAML 语法。
