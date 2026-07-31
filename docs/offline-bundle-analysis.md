# 离线 E2E 包实包分析

检查日期：2026-07-30。

## 固定身份

```text
参考 Volcano commit: 1cb0a6359032ad5214143e0c22672f15ac7965c2
Kubernetes:            v1.36.1
Kind:                  v0.32.0
Ginkgo:                v2.28.1
平台:                  linux/amd64
```

包内 `source/volcano` 是该 commit 的干净 shallow checkout。它是环境参考源码，不是候选开发工作区。

## 资产

- 7 个 Docker 镜像归档及各自 SHA-256；
- 23 个必需镜像标签；
- KWOK v0.7.0、v0.8.0 镜像；
- KWOK 0.3.0 和 stage-fast 0.3.0 Chart；
- Kind node、Runner、本地 registry、参考 Volcano 组件和 E2E 工作负载镜像。

必需镜像清单未包含 Prometheus、Grafana、kube-state-metrics 和 kube-apiserver-audit-exporter。它们是否进入性能工具增量包，仍要以最终性能代码引用和内网 registry 清单做差集，不能沿用旧扫描结果直接出包。

## 入口行为

`verify-bundle.sh` 校验镜像归档、Chart、环境清单和参考源码 commit/cleanliness。

`install-offline.sh` 执行 `docker load`，启动 `volcano-offline-registry`，并把必需镜像推送到本地 registry；脚本中没有 `docker pull`。

`run-env.sh` 启动预构建 Runner，并固定：

```text
FORCE_REBUILD=false
GOPROXY=off
GOSUMDB=off
GOTOOLCHAIN=local
<bundle>/source/volcano -> /workspace/volcano
Docker socket -> /var/run/docker.sock
```

包内 Kind wrapper 在建集群后为 `docker.io`、`registry-1.docker.io` 和 `registry.k8s.io` 写入本地 registry mirror。Helm wrapper 把 KWOK 在线仓库操作替换为包内 Chart。

`make e2e` 依赖 `images`；上游 Makefile 在 `FORCE_REBUILD=false` 且同 tag 镜像已存在时跳过构建。候选模式必须由外层 Adapter 改挂独立候选源码，并显式强制构建。

## 部署验证

已经完成一次专用 Kind 集群部署冒烟：

- 1 个 control-plane 和 4 个 worker 全部 Ready；
- KWOK、Volcano admission、controller 和 scheduler 正常；
- Helm release 与 CRD 注册正常；
- 所有 Kind 节点拒绝公网 IPv4 连接，但可访问本地 registry；
- Docker 事件审计未出现镜像 pull；
- 使用 Volcano scheduler 和 `imagePullPolicy: Always` 的 BusyBox Job 完成；
- registry 日志记录了该镜像 manifest/blob 的本地请求。

测试后已删除专用集群和临时测试文件，保留本地 registry 与导入镜像。该结果证明部署链路可离线运行，不代表完整 E2E 矩阵已经通过。

## Adapter 结论

当前包没有外部候选源码目录参数。Candidate 模式应由 `adapters/offline-e2e-bundle` 自行启动同一 Runner 镜像并提供以下挂载：

```text
独立候选源码 -> /workspace/volcano
性能看护仓库 -> /workspace/performance-guard（只读代码，工作目录另挂）
包内 state/home -> /root
包内 state/go-build -> /root/.cache/go-build
Docker socket -> /var/run/docker.sock
```

不得覆盖包内 `source/volcano`，也不得把候选源码复制进性能仓库。
