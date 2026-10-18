# App Store 发布清单

## 分支与身份

- 商店分支：`appstore-clean`
- Bundle ID：`com.factorcitrus.juyue.reader`
- 显示名：橘阅阅读器
- 版本：由 `VERSION` 与工程 build settings 决定
- 商店版与侧载版使用不同 Bundle ID，可并存，但数据不互通

## 发布前

- [ ] Xcode 选择 Apple Developer Team
- [ ] App Store Connect 新建 App，Bundle ID 用 `com.factorcitrus.juyue.reader`
- [ ] 填公开隐私政策 URL、支持 URL
- [ ] 准备 6.7 / 6.5 / 5.5 英寸截图，只使用公版书或自制样张
- [ ] 年龄分级、类别（图书）、出口合规
- [ ] 审核备注说明：不提供书籍内容；只读用户导入文件与自配 OPDS；无账号、无分析、无广告
- [ ] Archive → Upload to App Store Connect

## 审核备注模板

> 橘阅阅读器是一个本地阅读工具。应用不提供、不内置、不搜索任何书籍内容或第三方书源。用户只能导入自己拥有合法使用权的 TXT / EPUB / PDF，或手动填写自己拥有的 OPDS / Calibre 服务器。应用不创建账号、不收集分析数据、不展示广告。网络仅用于用户主动配置的 OPDS / WebDAV 服务。

## 外部 TestFlight

- 内部测试：App Store Connect 用户，通常不需要 Beta App Review。
- 外部测试：需要 Beta App Review，隐私政策 URL 必填。
- 如审核询问 OPDS，说明它是用户自建书库的标准目录协议，不是内容商店。

## 防克隆

- 先占 App Store 名称与 Bundle ID。
- 注册“橘阅”商标（建议中国区第 9、42 类）。
- 保留图标、截图、UI 的创作证据。
- 监控 App Store 搜索“橘阅”“Legado”，发现冒用按 `TAKEDOWN-TEMPLATES.md` 处理。
- 有服务端后再加 App Attest / DeviceCheck + 收据校验；纯本地版无法阻止界面克隆。

## 已知法律门槛

- 本仓库是 GPLv3。App Store 分发条款与 GPL 存在冲突，需要版权方例外/双许可，或重写相关代码。
- 闭源不能解决 GPL 问题。
