# 发布下一版本

本项目区分“代码版本”和“资产版本”。普通脚本、阈值或报告逻辑更新可以发布新的
代码 tag，但继续复用现有 `v0.2.0` 资产；只有大型 Runtime 或 stable 内容变化时，
才创建新的资产版本并重新上传大文件。

当前 `v0.2.0` 可直接粘贴到 GitHub 的发布说明见
[`release-notes-v0.2.0.md`](release-notes-v0.2.0.md)。

## 何时需要重打资产

普通待测 Volcano 更新只会让 `.work/candidate-state/go-mod/` 增加新的 Go 模块缓存，
不需要新 Release。仅当下列内容变化时重打大型附件：Runner、Kind/Kubernetes、
组件基础镜像、性能工具/监控镜像或内置 stable。

## 1. 先判断是否需要新的资产版本

如果 Runner、Kind/Kubernetes、组件基础镜像、性能工具、监控镜像和内置 stable
都没有变化，不要修改下面三个文件，也不需要重新上传约 2.27 GiB 附件：

```text
runtime/runtime.env
stable/stable.env
release-assets/release.env
```

例如代码发布 `v0.2.1` 时仍可让 `release-assets/release.env` 指向资产版本
`v0.2.0`。用户克隆 `v0.2.1` 后执行 `./setup.sh`，仍会自动下载并校验 `v0.2.0`
的大型附件。

只有资产确实变化时，才继续执行后面的打包和上传步骤。

## 2. 更新资产版本身份

更新以下文件并保持三者一致：

```text
runtime/runtime.env       RUNTIME_RELEASE_TAG 和各归档名
stable/stable.env         STABLE_COMMIT、STABLE_ARCHIVE
release-assets/release.env RELEASE_TAG 和 RELEASE_ASSETS
```

stable 工作树必须干净且位于 `stable/volcano/`，也可通过 `--stable-dir` 指定。
更新后执行下面的检查，确认旧提交、旧附件名和旧 tag 没有残留在当前配置中：

```bash
rg -n '旧提交完整值|旧提交前 12 位|旧资产版本 tag' \
  runtime stable release-assets configs Makefile tools docs/releasing.md
```

## 3. 生成扁平附件

在已加载所需 Docker 镜像的 Linux/WSL 准备机执行：

```bash
cd /path/to/volcano-performance-guard

./scripts/package-release-assets.sh \
  --stable-dir /path/to/stable-volcano \
  --benchmark-archive .work/offline-assets/benchmark-tools/<stable-commit>/benchmark-images.tar

(cd release-assets && sha256sum -c SHA256SUMS)
```

脚本会覆盖 `release-assets/` 中以下附件：

```text
runtime-runner.tar
runtime-kind-node-v1.36.1.tar
runtime-volcano-bases-1cb0a6359032.tar
runtime-support-images.tar
benchmark-images.tar
stable-volcano-d57d10f47129.tar.gz
SHA256SUMS
```

实际文件名以 `release-assets/release.env` 为准。不要再上传 v0.1 的
`go-mod-supplement.tar.gz`；服务器现在通过 `goproxy.cn` 自动维护增量缓存。

## 4. 提交代码并创建资产 Release

先提交并推送不含大型 tar 的代码，再在 GitHub 仓库页面进入：

```text
Releases -> Draft a new release
```

创建与 `RELEASE_TAG` 一致的 tag，例如 `v0.2.0`，将上面六个归档和
`SHA256SUMS` 全部拖入附件区域。GitHub Release 是扁平附件，正好对应
`release-assets/`，无需创建子目录。发布后在空目录验证：

```bash
./release-assets/download-release-assets.sh
./setup.sh --skip-download
```

## 5. 不使用 gh 的 API 上传方式

公开仓库下载不需要登录；上传 Release 一定需要写权限。公司电脑没有 `gh` 时，
可以使用 GitHub 网页，或创建只授予该仓库 `Contents: write` 的 fine-grained token。
将 token 放进环境变量，不要写进脚本、命令历史或仓库：

```bash
read -rsp 'GitHub token: ' GITHUB_TOKEN; echo
export GITHUB_TOKEN
```

先通过 GitHub 网页创建空的 `v0.2.0` Release，再逐个上传。下面的 Python 只在
发布工作站解析 GitHub API 返回值，不是服务器运行依赖：

```bash
REPO=siqiaawa/volcano-performance-guard
source release-assets/release.env
TAG=$RELEASE_TAG
RELEASE_ID=$(curl -fsS \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/$REPO/releases/tags/$TAG" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')

for name in $RELEASE_ASSETS SHA256SUMS; do
  file=release-assets/$name
  test -f "$file"
  name=$(basename "$file")
  curl -fsS --retry 3 -X POST \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H 'Accept: application/vnd.github+json' \
    -H 'Content-Type: application/octet-stream' \
    --data-binary "@$file" \
    "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$name"
done
unset GITHUB_TOKEN
```

这里按 `RELEASE_ASSETS` 精确上传，不要用 `release-assets/*.tar*` 通配符；目录中
即使保留了旧资产，也不会被误传到新 Release。上传前必须先执行：

```bash
(cd release-assets && sha256sum -c SHA256SUMS)
```

GitHub 单个 Release 附件上限为 2 GiB。本项目当前按镜像职责拆分，单个附件应
低于该限制；上传前使用 `ls -lh release-assets/` 再确认。
