# 社区项目调研与选型

调研日期：2026-07-29。提交号用于保证后续打包可复现；正式出包时仍应优先选择经过验证的 release/tag。

## 首选：Volcano 官方 Benchmark Framework

- 项目主页：<https://github.com/volcano-sh/volcano>
- 性能框架：<https://github.com/volcano-sh/volcano/tree/master/benchmark>
- 使用说明：<https://github.com/volcano-sh/volcano/blob/master/benchmark/README.md>
- 性能调优文档：<https://github.com/volcano-sh/volcano/blob/master/docs/user-guide/how_to_tune_volcano_performance.md>
- 当前审查提交：`d40caf9d3cb605df0babbb84e0221dd2c2e0b0a9`
- 许可证：Apache-2.0

它直接覆盖当前任务的大部分基础能力：

- 可创建 Kind 集群，并用 KWOK 模拟大量节点；
- 包含 Gang Scheduling 和裸 Pod 调度性能场景；
- 可从本地源码构建 Volcano 镜像，或安装指定 release；
- 部署 Prometheus、Grafana、kube-state-metrics 和 audit-exporter；
- 输出调度延迟报告、Pod 时间戳报告和测试日志；
- 支持真实集群、已有 Volcano、跳过 KWOK/监控等组合。

因此建议基于它做“离线化适配 + 伏羲流水线适配 + 产品基线对比”，不另起一套性能用例框架。

## 直接依赖

### KWOK

- 地址：<https://github.com/kubernetes-sigs/kwok>
- 用途：模拟大量 Kubernetes Node，适合调度器规模与性能测试。
- Volcano benchmark 当前默认版本：`v0.7.0`
- 当前主线提交：`3ddf36cdfc50b6c5bbca4d57b83929a1bc9d4d38`
- 许可证：Apache-2.0

### Kind

- 地址：<https://github.com/kubernetes-sigs/kind>
- 用途：在 Docker 中创建测试 Kubernetes 集群。
- Volcano benchmark 要求：`kind >= 0.20.0`，正式出包前必须固定具体版本及对应 node 镜像。
- 当前主线提交：`50a78d4ca5fae02609b75b2b409b445e7dd4bcf9`
- 许可证：Apache-2.0

## 可选补充项目

### kube-burner

- 地址：<https://github.com/kube-burner/kube-burner>
- 用途：Kubernetes 性能与规模测试编排，可用于后续补充通用资源创建、Prometheus 指标索引和阈值检查。
- 当前主线提交：`63ff6081d8c34e52df66e686954c980116df64ec`
- 许可证：Apache-2.0

现阶段不建议把它作为主框架，因为 Volcano 官方 benchmark 已包含更直接的 Volcano 用例和指标。

### Kubernetes perf-tests / ClusterLoader2

- 地址：<https://github.com/kubernetes/perf-tests>
- 用途：Kubernetes 官方规模与性能测试，适合作为集群/API Server 层面的补充基线。
- 当前主线提交：`c0b99a08484364ceaa64d72c87c95995feff194a`
- 许可证：Apache-2.0

现阶段仅作为扩展参考，不加入第一版离线包。

## 结论

第一版采用如下组合：

```text
Volcano 官方 benchmark
  ├─ Kind：本地 Kubernetes 测试集群
  ├─ KWOK：大规模模拟节点
  ├─ Volcano：被测调度器与控制器
  ├─ Prometheus/Grafana：指标与看板
  └─ audit-exporter：高精度调度延迟
```

`kube-burner` 和 `perf-tests` 留作第二阶段补充，不在首包中引入额外复杂度。

