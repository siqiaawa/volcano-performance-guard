# Runtime Adapter

此目录是性能项目内部 Runtime 与外部 Volcano Git 工作树之间的唯一执行边界。
Adapter 使用 `--runtime-dir` 读取项目自身的 `runtime/runtime.env`、Runner 包装器和
固定基础镜像；候选源码始终只读挂载。

主入口 `volcano-performance-guard.sh` 已完成下列编排：

- 在线 Go module 增量下载与持久缓存；
- 五个组件二进制及 commit 标签镜像构建；
- 本地 Registry 发布；
- 独立 Kind 集群创建、Volcano Helm 部署和 marker 保护清理；
- Pod Timestamp Profile 测量与报告生成。

Makefile 保留社区 Pod/Gang Benchmark、Audit 监控以及单步构建入口，供排障和
高级验证使用。完整上游 E2E 不属于本仓库，其 v0.1 Adapter 已归档至
`docs/archive/e2e-adapter-v0.1/`。

所有运行产物必须写入 `.work/` 或调用者指定的报告目录，不能写入 Runtime 或
Volcano 源码工作树。
