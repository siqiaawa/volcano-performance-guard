# Remaining open questions

离线包自身的结构、版本、镜像、KWOK、registry mirror 和部署链路已经确认。当前真正未解决的接口是：

- 用户候选 Volcano 仓库地址、分支和流水线 commit 输入方式；
- 候选 commit 相对 Runner cache 缺失的 Go module；
- 候选 Dockerfile 所需但离线包/内网 registry 缺失的基础镜像；
- 内网 registry 地址、认证和已有资产清单；
- 最终采用的社区 Benchmark commit 或独立性能测试代码版本；
- Prometheus 等性能工具的最终版本、digest、Chart 和离线安装方式；
- 产品认可的参考 Volcano 版本、硬件环境、Profile 和阈值；
- 伏羲地址、资源池、Secret、制品、JUnit 和 always/finally 语法。

这些信息缺失时应返回明确的环境不兼容或配置错误，不得回退公网、伪造指标、自动更新基线或猜测伏羲配置。
