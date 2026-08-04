# Volcano Performance Guard v0.2.0

本版本将 Volcano Performance Guard 整理为可独立安装和运行的性能比较项目，
不再依赖 `volcano-offline-e2e-bundle` 或其他兄弟仓库提供 Runtime、Registry、
Benchmark 资产和固定基准源码。

## 主要变化

- 新增统一入口 `./volcano-performance-guard.sh`；
- 支持内置 stable 与待测版本重新测量后比较；
- 支持候选版本与已有 stable 指标直接比较；
- 支持通过两个本地 Git 工作树路径比较任意 Volcano 版本；
- 新增项目自有 Runner、Kind、Docker 包装器和本地 Registry；
- 新增 `./setup.sh`，自动下载、校验、导入 Release 资产并恢复 stable；
- 固定 stable 为 `d57d10f47129b11f12d875de1195a42c0a53270f`；
- Runtime 基础版本为 `1cb0a6359032ad5214143e0c22672f15ac7965c2`；
- 性能项目 Registry 独立使用 `127.0.0.1:15001`；
- Go module 通过 `https://goproxy.cn/` 按需下载并在 `.work/` 中增量缓存；
- 旧版分步文档、离线补充包设计和完整 E2E Adapter 已归档到 `docs/archive/`。

## Release 附件

本 Release 必须包含以下六个归档和校验文件：

```text
runtime-runner.tar
runtime-kind-node-v1.36.1.tar
runtime-volcano-bases-1cb0a6359032.tar
runtime-support-images.tar
benchmark-images.tar
stable-volcano-d57d10f47129.tar.gz
SHA256SUMS
```

附件总大小约 2.27 GiB，每个附件均低于 GitHub 单文件 2 GiB 限制。

下载后先验证：

```bash
cd volcano-performance-guard/release-assets
sha256sum -c SHA256SUMS
```

## 快速开始

```bash
git clone --branch v0.2.0 --single-branch \
  https://github.com/siqiaawa/volcano-performance-guard.git
cd volcano-performance-guard

chmod +x volcano-performance-guard.sh setup.sh
find runtime adapters scripts stable release-assets \
  -type f -name '*.sh' -exec chmod +x {} +

./setup.sh
```

服务器已经提前拿到全部附件时，可将附件平铺到 `release-assets/`，然后执行：

```bash
./setup.sh --skip-download
```

使用内置 stable 与待测版本比较：

```bash
./volcano-performance-guard.sh fixed-compare \
  --candidate-path /srv/volcano-candidate \
  --output-dir /srv/results/fixed-fresh
```

比较两个本地版本：

```bash
./volcano-performance-guard.sh version-compare \
  --stable-path /srv/volcano-version-a \
  --candidate-path /srv/volcano-version-b \
  --output-dir /srv/results/a-vs-b
```

## 已完成验证

- 57 项单元测试通过；
- 所有 Shell 入口通过 `bash -n` 语法检查；
- 六个 Release 归档通过 `SHA256SUMS` 校验；
- stable 归档提交身份和干净工作树校验通过；
- `./setup.sh --skip-download` 实际执行成功；
- Benchmark 资产成功导入项目 Registry；
- Runtime fingerprint 为
  `sha256:7b84587957ea3ea17e4d53a65f030be219928eacb0a27d3a91338d056c94b95d`。

## 当前范围

本版本提供独立 Runtime、固定基准性能比较、社区 Benchmark 资产、指标聚合和
JSON、Markdown、JUnit XML、HTML 报告。完整上游 Volcano E2E 由独立的
`volcano-offline-e2e-bundle` 项目负责；伏羲流水线接入暂不包含在本版本中。

正式性能数据仍应在目标 Linux 服务器的固定软硬件环境中采集。本版本发布前没有
执行长时间双版本正式 Benchmark，服务器试验应先使用 smoke Profile 验证环境。
