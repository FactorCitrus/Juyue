# WebDAVService 规格

用途：把书架、书源、阅读进度同步到 WebDAV，并兼容安卓版备份包。

## 公开接口（签名不得漂移）

| 成员 | 说明 |
|---|---|
| `WebDAVConfig(url:username:password:remotePath:deviceName:lastSyncTime:)` | 默认 `https://dav.jianguoyun.com/dav/`、`remotePath = "legado"` |
| `WebDAVConfig.directoryURL` | 无 scheme 补 `https://`，服务器地址与 remotePath 都补尾斜杠 |
| `WebDAVConfig.serverRootURL` | 同上但不拼 remotePath |
| `WebDAVConfig.sendCredentialsInClear` | `http://` 为真 |
| `WebDAVConfig.basicAuthHeader` | 明文 HTTP 返回空串，否则 `Basic base64(user:pass)` |
| `WebDAVConfig.generateBackupFileName(date:deviceName:)` | `backupYYYY-MM-DD-设备名.zip`，设备名去 `/\:*?"<>|`，全空则省略设备段 |
| `WebDAVService.shared` / `init(session:)` | 共享实例 / 注入 URLSession |
| `loadConfig()` / `saveConfig(_:)` | 密码只存钥匙串；配置里的 password 恒为空串 |
| `testConnection(config:)` | PROPFIND Depth 0；404 → MKCOL 后返回「已创建」；405 → GET 回退；其它非 2xx 报错 |
| `createDirectoryIfNeeded(config:)` / `(url:config:)` | MKCOL；200/201/204/405 视为成功，5xx 抛 `custom` |
| `sanitizeFileName(_:)` | `\/:*?"<>|` → `_` |
| `uploadBookProgress(book:config:)` | PUT `bookProgress/书名_作者.json`，prettyPrinted；401/403 抛错，其它失败静默 |
| `createBackupZip(books:sources:deviceName:date:settingsJSON:)` | 返回 `(data, fileName)`；zip 条目 `bookshelf.json`、`bookSource.json`、可选 `settings.json` |
| `backup(books:sources:config:settingsJSON:)` | PUT zip 必须 2xx；再补 PUT 两份散 JSON（失败不致命）；更新 `lastSyncTime` |
| `listRemoteBackups(config:)` | PROPFIND Depth 1；非 2xx 返回空数组；401/403 抛错 |
| `parseBackupsFromPropfindXML(_:baseURL:)` | 只留 `backup*.zip`；href 先解百分号编码；按 `getlastmodified` 降序（差 ≤1 秒时按文件名降序） |
| `restore(config:backupFileName:)` | ①指定/最新 zip ②散装 `bookshelf.json` ③bookProgress 并发合并；全空抛 `backupNotFound` |
| `restoreFromZip(data:)` / `(fileUrl:)` | 后者会合并同目录 `bookProgress/` |
| `extractSettingsJSON(fromZip:)` / `(fromZipFileUrl:)` / `(from:)` | 精确 `settings.json`，否则后缀匹配 |
| `parseArchive(_:)` | 同 zip 结构；包内 `bookProgress/*.json` 按 `书名_作者` 合并 |
| `applyBookProgress(books:fromDirectory:)` | 目录内 `*.json` 全读，按 `书名_作者` 合并 |

## 行为契约

1. **凭据**：明文 HTTP 一律不发 Authorization，宁可 401 也不裸传密码。
2. **进度合并**：章节下标更大者胜；同章位置更大者胜；远端旧数据不得把本地往回拖（浏览器端拉取要求位置 `>=`，包内/目录合并不额外卡位置）。
3. **恢复优先级**：zip > 散 JSON；zip 解不出书才降级。
4. **错误语义**：401/403 统一 `unauthorized`；MKCOL 与 PUT zip 的非成功码必须报错，散 JSON 与进度上传允许静默失败。
5. **时间**：`getlastmodified` 使用 RFC 822（`EEE, dd MMM yyyy HH:mm:ss zzz`，`en_US_POSIX` + GMT）。

## 测试映射

`Tests/LegadoCoreTests/WebDAVServiceCleanRoomTests.swift`，16 条：URL 拼接 3、凭据 2、命名 3、PROPFIND 4、zip 往返 3、进度合并 2（含倒退保护）。
