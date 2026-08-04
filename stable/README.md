# Stable Volcano

`stable/volcano/` 是 `fixed-compare` 默认使用的基准源码。它由 `stable.env`
声明的固定版本 Release 归档恢复，并故意排除在本仓库 Git 历史之外，避免把完整
Volcano 源码和 Git 元数据塞入性能工具仓库。

执行 `./setup.sh` 或 `./stable/prepare-stable.sh` 即可恢复；脚本会校验提交必须与
`STABLE_COMMIT` 完全一致，且工作树必须干净。
