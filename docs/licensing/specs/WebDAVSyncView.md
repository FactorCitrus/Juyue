# WebDAVSyncView 规格

用途：WebDAV 设置、探活、备份、恢复，以及本地 zip 导入导出。

## 界面结构（视觉不得漂移）

| 区域 | 内容 |
|---|---|
| 头部 | `TerminalPageHeader(code: "DATA / SYNC", title: "WebDAV 云同步", detail: "备份 / 恢复 / 远端版本")` |
| 服务器设置 | 服务器地址 / 账号 / 密码 / 远程目录 / 设备名称；三个预设按钮（坚果云、InfiniCLOUD、Nextcloud） |
| 同步状态 | 上次同步时间、本地书架本数、本地书源个数 |
| 同步操作 | 测试连接、立即备份、选择云端备份、从 WebDAV 恢复最新（destructive） |
| 本地备份 | 导出到「文件」、导入 Android zip、说明文字 |

## 行为

1. **单一忙碌态**：`Activity { idle, testing, backingUp, restoring, fetchingBackups }`；非 idle 时所有操作按钮禁用。
2. **需要账号的操作**：备份、取列表、恢复要求 `username` 非空；测试连接只要求 `url`。
3. **提示**：统一 `Notice(title:message:)`；动作成功但无需提示（例如列表直接开 sheet）返回 `nil`，不得弹空框。
4. **恢复确认**：先弹「从 WebDAV 恢复」，两个选项分别落 `RestoreMode.replace` 与 `.merge`，弹窗前先 `saveConfig()`。
5. **本地导入**：`startAccessingSecurityScopedResource` 成对调用；成功提示包含书架/书源计数与设置合并摘要。
6. **文件导出**：先 `createBackupZip`，文件名取返回值，失败弹「导出失败」。

## 测试

界面层无自动化测试；验收靠两种配置编译 + 真机走查（连接测试、备份、列表、恢复、导出、导入六条路径）。
