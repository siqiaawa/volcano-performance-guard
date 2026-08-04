# Runtime Adapter Contract

业务入口只能通过 `adapters/runtime/` 访问 Runner、Kind 和候选源码。核心参数为：

```text
inspect.sh --runtime-dir PATH [--output PATH]
run-candidate.sh --runtime-dir PATH --candidate-dir PATH [options] -- COMMAND
preflight-candidate.sh --runtime-dir PATH --candidate-dir PATH [options]
```

约束：候选源码只读挂载；Docker socket 必须显式请求；Go 联网只允许在组件编译
阶段；Kind 节点从本地 Registry 获取镜像；集群清理必须匹配 `cluster.marker`。
