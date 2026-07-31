# 离线 E2E 包 Adapter 契约

所有针对 `volcano-offline-e2e-bundle` 的访问都必须经过 `adapters/offline-e2e-bundle/`。业务脚本不得散落包内私有路径，也不得修改包内参考源码。

## 当前已实现

```text
inspect.sh --bundle-dir PATH [--output PATH]
run-candidate.sh --bundle-dir PATH --candidate-dir PATH [options] -- COMMAND
preflight-candidate.sh --bundle-dir PATH --candidate-dir PATH [options]
```

`inspect.sh` 只读检查目录、版本清单、参考 commit、资产数量与候选性能工具差集。
`run-candidate.sh` 将外部候选源码只读挂载到包内 Runner，默认使用 `--network none`
且默认不挂载 Docker socket。`preflight-candidate.sh` 在这一边界中检查候选 Git
身份、离线 Go 依赖和组件 Dockerfile 基础镜像。退出码为 0 才表示对应检查通过。

## 统一环境输出

未来 `prepare` 完成后必须输出经过 Schema 校验的 `environment.json`。Shell 兼容文件只能由 `scripts/export-environment.py` 从该 JSON 生成，不能直接 source 外部包产生的任意文件。

包身份字段定义：

```text
BUNDLE_NAME
BUNDLE_VERSION             # 当前目录交付物为空
BUNDLE_FINGERPRINT         # 必填，由受校验清单确定性生成
BUNDLE_ARCHIVE_SHA256      # 仅单归档交付时存在
```

未知字段使用 `null` 或 false，禁止伪造语义版本、归档哈希、内网 registry 或恢复能力。

## 候选运行约束

包内 `run-env.sh` 固定挂载参考源码并设置 `FORCE_REBUILD=false`，因此不能直接作为 Candidate 模式入口。后续 `run-container` 必须：

1. 使用包内 `RUNNER_IMAGE`；
2. 把独立候选源码挂载为 `/workspace/volcano`；
3. 复用 Docker socket 与受控 cache；
4. 设置 `GOPROXY=off`、`GOSUMDB=off`、`GOTOOLCHAIN=local`；
5. 对候选镜像构建显式设置 `FORCE_REBUILD=true`；
6. 不给包内参考源码写权限。

候选计划必须有安全终态：优先销毁本次专用集群并按参考模式重建；只有验证完整参考材料和 CRD 回退兼容后，才允许原地恢复稳定参考 release。

镜像替换不是默认能力。只有组件集合、CRD、Chart、ConfigMap、RBAC、参数和 Webhook 均有兼容证据时，才允许对特定候选使用 image-only 策略。
