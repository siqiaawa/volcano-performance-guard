# Volcano 内网性能看护工程

本仓库用于把 Volcano 社区性能基准工程、容器镜像和依赖工具整理成可校验的离线压缩包，供内网拉取后导入和部署。

当前阶段已经完成：

- 选定 Volcano 官方 `benchmark/` 为首选社区基线；
- 记录上游项目地址和当前审查提交；
- 新建独立的 `offline-bundles/` 路径，不复用或修改任何现有 Volcano 仓库；
- 建立压缩包、校验清单和依赖清单的目录约定。

## 目录

```text
docs/
  community-projects.md       社区项目调研和选型
offline-bundles/
  archives/                   离线压缩包存放路径
  manifests/
    images.txt                首批镜像清单
    sources.lock.yaml         上游源码及提交锁定
  README.md                   打包、上传和内网使用约定
```

## 社区基线

首选入口：<https://github.com/volcano-sh/volcano/tree/master/benchmark>

该框架已提供 Kind/KWOK 测试环境、Gang 与 Pod 调度场景、Prometheus/Grafana 看板、审计日志指标采集以及 JSON/日志报告，和本任务目标最接近。详细说明见 [docs/community-projects.md](docs/community-projects.md)。

## 下一阶段

1. 固定 Kind、Kubernetes node、Prometheus 和 Grafana 等目前仍未固定的版本。
2. 在外网环境执行镜像拉取与 `docker save`，生成分卷压缩包和 SHA-256 清单。
3. 编写内网一键导入、部署、运行用例及基线波动判定脚本。
4. 对接伏羲流水线。

