# 社区性能项目选择

第一版优先复用 Volcano 官方仓库中的 `benchmark/`，因为它直接提供 Gang/Pod 调度场景、KWOK、大规模节点模拟和 Volcano 指标采集逻辑：

- 项目：<https://github.com/volcano-sh/volcano>
- Benchmark：<https://github.com/volcano-sh/volcano/tree/master/benchmark>
- 性能调优文档：<https://github.com/volcano-sh/volcano/blob/master/docs/user-guide/how_to_tune_volcano_performance.md>

具体 Benchmark 内容必须来自待测候选 commit 或经过独立版本化的性能测试代码，不能固定到一次过时的预研 checkout，也不能直接使用社区脚本再创建一套绕开离线包的 Kind 环境。

学长离线包已经提供 Kind、KWOK 镜像与 Chart，因此这些资产不是默认增量。Prometheus、Grafana、kube-state-metrics、Audit Exporter 和工作负载镜像要依据实际 Benchmark 引用、包内清单和内网 registry 清单计算差集。

`kube-burner` 与 Kubernetes `perf-tests` 可作为后续集群/API Server 维度补充，MVP 不引入，避免混淆 Volcano 调度性能和 Kubernetes 通用性能。
