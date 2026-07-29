# 离线包存放路径

`archives/` 是本仓库专门用于保存内网交付压缩包的新增路径。不要把压缩包放到源码或文档目录。

建议的交付结构：

```text
offline-bundles/
  archives/
    <bundle-version>/
      volcano-performance-bundle-<version>.tar.zst.part-001
      volcano-performance-bundle-<version>.tar.zst.part-002
      SHA256SUMS
  manifests/
    images.txt
    sources.lock.yaml
```

## 压缩包内容建议

```text
bin/                 kind、kubectl、helm、jq 等工具
images/              `docker save` / OCI 导出的镜像包
manifests/           KWOK、监控和 Volcano 安装文件
source/              锁定提交的 Volcano benchmark 源码
scripts/             内网导入、部署和验收脚本
checksums/           SHA-256 校验文件
```

## GitHub 存储注意事项

- GitHub 普通 Git 对象不适合大型镜像包，单文件超过普通 Git 限制时推送会失败。
- 本仓库已为常见压缩格式配置 Git LFS；上传前应运行 `git lfs install` 并用 `git lfs ls-files` 确认。
- 大包应分卷，并在 `SHA256SUMS` 中记录每个分卷的 SHA-256。
- 内网必须同时验证能访问 Git LFS 下载地址；若只能访问 GitHub Release，则改用 Release assets，并在本路径保存版本说明和校验清单。
- 不允许使用 `latest` 作为正式交付版本；镜像和工具必须固定 tag，最好同时记录 digest。

当前目录只建立存放约定，尚未加入真实镜像包。

