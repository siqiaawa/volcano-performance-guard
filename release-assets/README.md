# Release 资产

此目录是大型、低频变化资产的唯一存放位置。归档文件被 Git 忽略；
`release.env`、`SHA256SUMS` 和维护脚本进入 Git。GitHub Release 以扁平列表展示
附件，正好与本目录一一对应，不要在这里解压归档。

代码版本和资产版本相互独立。普通代码更新可以继续复用 `release.env` 指向的
旧资产版本；只有 Runtime 或 stable 变化时才重新打包大文件。发布资产时只上传
`release.env` 的 `RELEASE_ASSETS` 列表和 `SHA256SUMS`，不要按目录通配符上传。

完整维护流程见 [`docs/releasing.md`](../docs/releasing.md)。

固定 stable 的 Go module supplement 也属于低频、体积较大的 Release 资产。
它应以 stable commit 绑定的目录格式发布，下载后放入
`.work/offline-assets/go-mod/<stable-commit>/`；不要把 module cache 提交到 Git。
当前代码 Release 未包含该 supplement 时，`fixed-compare` 会在构建前明确报错，
不会让 stable 构建偷偷访问公网。
