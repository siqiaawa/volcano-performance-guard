# Release 资产

此目录是大型、低频变化资产的唯一存放位置。归档文件被 Git 忽略；
`release.env`、`SHA256SUMS` 和维护脚本进入 Git。GitHub Release 以扁平列表展示
附件，正好与本目录一一对应，不要在这里解压归档。

代码版本和资产版本相互独立。普通代码更新可以继续复用 `release.env` 指向的
旧资产版本；只有 Runtime 或 stable 变化时才重新打包大文件。发布资产时只上传
`release.env` 的 `RELEASE_ASSETS` 列表和 `SHA256SUMS`，不要按目录通配符上传。

完整维护流程见 [`docs/releasing.md`](../docs/releasing.md)。
