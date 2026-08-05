# Volcano Performance Guard

本项目在同一台 Linux 服务器上构建、部署并比较两个 Volcano 版本。项目自带
Runner、Kind、本地 Registry、性能工具和固定 stable 版本的准备逻辑，**不依赖
`volcano-offline-e2e-bundle` 或其他兄弟仓库**。

对外只有一个运行入口：

```bash
./volcano-performance-guard.sh <command> [options]
```

## 能做什么

- `fixed-compare`：将待测版本与项目内置 stable 比较；
- `fixed-compare --baseline-metrics`：只测待测版本，再与已经批准的 stable 指标比较；
- `version-compare`：比较两个通过本地 Git 路径传入的任意 Volcano 版本；
- 每个需要测量的版本执行相同的构建、镜像、Kind、Helm 和采集流程；
- 自动输出 JSON、Markdown、JUnit XML 和 HTML 比较报告。

固定 stable 为：

```text
d57d10f47129b11f12d875de1195a42c0a53270f
```

`1cb0a635...` 仅是 Runtime 组件基础镜像的版本，不是性能比较 stable。

## 目录结构

```text
volcano-performance-guard/
  volcano-performance-guard.sh  一键比较入口
  setup.sh                      首次准备入口
  runtime/                      Runner、Kind、Registry 和 Adapter 逻辑
  stable/                       内置 stable 身份及解包入口
  release-assets/               大型、低频变化的 Release 资产统一落点
  adapters/runtime/             构建、部署、测量的底层实现
  profiles/                     smoke 与正式性能 Profile
  configs/                      阈值和 Runtime 身份
  scripts/                      指标、报告和资产维护脚本
  tests/                        无集群单元测试
  docs/archive/                 v0.1 分步流程和旧离线设计
```

`release-assets/` 中的大型 tar 不进入 Git。GitHub Release 的附件是扁平列表，
下载后直接放在这个目录，不需要再手工分发到多个路径。

## 运行要求

- Linux x86_64/amd64；WSL 只适合开发验证，正式数据应在固定服务器采集；
- Bash、Git、Make、Docker、`curl`、`sha256sum` 和 `tar`；
- Docker daemon 可用，当前用户能访问 `/var/run/docker.sock`；
- 服务器可以访问 `https://goproxy.cn/`，仅用于按需下载 Go 模块；
- 待测 Volcano 必须是干净的本地 Git 工作树。

固定 stable 的二进制构建必须使用与 stable commit 绑定的离线 Go module
supplement。该 supplement 不进入 Git，应提前放在：

```text
.work/offline-assets/go-mod/<stable-commit>/
```

目录至少包含 `go-mod-supplement.tar.gz`、其 SHA-256 文件、
`candidate-commit.txt` 和 `base-runner-image.txt`。首次准备时可以执行一次：

```bash
make stable-prepare-deps ALLOW_NETWORK=1
```

该命令是显式的在线准备阶段。准备完成后，性能比较阶段不会为 stable
访问公网；只有待测版本允许通过 `goproxy.cn` 下载自己的 Go 增量模块。

宿主机不要求安装 Python。项目的性能工具镜像包含 Python 3 和固定依赖。

## 首次准备

```bash
git clone --branch main --single-branch \
  https://github.com/siqiaawa/volcano-performance-guard.git
cd volcano-performance-guard

chmod +x volcano-performance-guard.sh setup.sh
find runtime adapters scripts stable release-assets -type f -name '*.sh' -exec chmod +x {} +

./setup.sh
```

`setup.sh` 会从项目自己的 Release 下载缺失资产、校验 `SHA256SUMS`、加载镜像、
启动本项目专用的 `127.0.0.1:15001` Registry，并将 stable 解包为
`stable/volcano/`。它是
幂等的，已正确准备的内容会复用。

服务器已提前拿到全部 Release 文件时，可完全离线安装：

```bash
./setup.sh --skip-download

make stable-import-deps
```

安装后可检查：

```bash
make inspect-runtime
curl -fsS http://localhost:15001/v2/
git -C stable/volcano rev-parse HEAD
docker image inspect kindest/node:v1.36.1 >/dev/null
```

## 一键比较

### 内置 stable 与待测版本重新测量

这是默认且最容易保持环境一致的方式：

```bash
./volcano-performance-guard.sh fixed-compare \
  --candidate-path /srv/volcano-candidate \
  --output-dir /srv/results/fixed-fresh
```

默认从 `.work/offline-assets/go-mod/<stable-commit>/` 加载 stable supplement；
也可以显式指定位置：

```bash
./volcano-performance-guard.sh fixed-compare \
  --stable-deps-dir /srv/release-assets/stable-go-mod \
  --candidate-path /srv/volcano-candidate \
  --output-dir /srv/results/fixed-fresh
```

无需传 stable 路径。脚本依次测量 `stable/volcano` 和候选版本，两个版本都通过
统一流程重新构建，不复用 Runtime 基础版本的组件镜像。

### 待测版本与已有 stable 指标比较

```bash
./volcano-performance-guard.sh fixed-compare \
  --candidate-path /srv/volcano-candidate \
  --baseline-metrics /srv/approved/stable/metrics.json \
  --output-dir /srv/results/fixed-existing
```

历史指标必须由相同 Profile、Runtime、测试代码和主机环境生成，否则返回
`BASELINE_INCOMPATIBLE`。

已有两份指标时可只重新生成报告，不需要 Docker 或 Release 资产：

```bash
./volcano-performance-guard.sh fixed-compare \
  --candidate-metrics /srv/results/candidate/metrics.json \
  --baseline-metrics /srv/results/stable/metrics.json \
  --output-dir /srv/results/recheck
```

### 指定两个本地版本比较

```bash
./volcano-performance-guard.sh version-compare \
  --stable-path /srv/volcano-version-a \
  --candidate-path /srv/volcano-version-b \
  --output-dir /srv/results/a-vs-b
```

`--stable-path` 是比较基准，`--candidate-path` 是待测版本。两者使用完全相同的
Profile、Runtime、Registry 和构建流程。

## Profile 和结果

默认 `profiles/performance-compare.yaml` 对每个版本执行 1 次预热和 3 次正式
测试，每轮调度 100 个 Pod，正式轮次以中位数聚合。只验证流程时使用：

```bash
./volcano-performance-guard.sh fixed-compare \
  --candidate-path /srv/volcano-candidate \
  --profile "$PWD/profiles/offline-timestamp-smoke.yaml"
```

结果默认写入：

```text
.work/comparisons/<run-id>/
  stable/report/timestamp-profile/metrics.json
  candidate/report/timestamp-profile/metrics.json
  comparison/comparison.json
  comparison/comparison.md
  comparison/comparison.junit.xml
  comparison/comparison.html
```

退出码 `0` 表示 `PASS` 或 `WARNING`，`2` 表示性能回退、直接失败或基线不
兼容，其他非零值表示输入、资产、构建、部署、测量或清理失败。

## 网络边界

Go 编译阶段使用：

```text
GOPROXY=https://goproxy.cn,direct
GOTOOLCHAIN=auto
GOFLAGS=-mod=mod
```

stable 的 Go module supplement 在比较前离线导入派生 Runner；待测版本的模块
缓存在 `.work/candidate-state/go-mod/`，后续版本通常只下载新增或变化的模块。
镜像构建、Kind、Helm 部署和 Benchmark 不会从公网兜底下载。两个源码目录均
只读挂载，脚本不会改写待测仓库。

## 维护与 Release

代码版本可以继续复用既有资产版本，不必重复上传约 2.27 GiB 大文件。只有
Runtime 或 stable 变化时才生成新的资产版本；生成、校验、GitHub 网页上传和
`curl` API 上传步骤见
[`docs/releasing.md`](docs/releasing.md)。Release 资产只在 Runner、Kind、基础镜像、
性能工具或 stable 发生变化时重新生成，普通候选版本只增加 Go module 缓存。

底层社区 Benchmark、Audit 监控和单步故障入口保留在 Makefile 与
[`adapters/runtime/README.md`](adapters/runtime/README.md)。上游完整 E2E 已由独立的
`volcano-offline-e2e-bundle` 项目负责，本项目不再携带其 MPI、Ray、PyTorch 等
大镜像。伏羲流水线仍按当前范围标记为暂不完成。
