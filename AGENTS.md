## 干活前的固定动作（用户要求，2026-10-14 起）

1. **先查本地技能再动手**：接到任务先扫一遍可用技能（`~/.codex/skills`、`~/.agents/skills`、`superpowers` 插件里的那套），有对得上的直接用，并在回复里说明用了哪个、为什么用。
   - 这个项目最常用到的：`verification-before-completion`（声明完成前先拿证据）、`investigate-first`（原因不明先定位再改）、`surgical-patch`（改动落在最窄一层）、`systematic-debugging`、`requesting-code-review`。
2. **UI 改动先在模拟器里跑一遍再出包**：`xcodebuild` 编过不等于对——死参数、没生效的开关这类编译零警告，只有跑起来才看得见。编完装进模拟器，点进受影响那一屏，截图确认过再发包。
   - 模拟器编法（百度 SDK 只有真机架构，链不上模拟器）：
     `mv Vendor/BaiduSpeech/libBDSpeechTTSBaseKit.a /tmp/baidu_real.a` → 建空归档 `ar rcs Vendor/BaiduSpeech/libBDSpeechTTSBaseKit.a /tmp/empty.o` → `xcodebuild … -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/legado-simdd SWIFT_OBJC_BRIDGING_HEADER="" SWIFT_ACTIVE_COMPILATION_CONDITIONS="NO_BAIDU_TTS"` → 编完 `mv /tmp/baidu_real.a Vendor/BaiduSpeech/libBDSpeechTTSBaseKit.a` 立刻还原。
   - 驱动模拟器：`xcrun simctl` 装/启/截图，CUA（`cua_repl`）点 UI；模拟器 GUI 要用完整路径打开：`open /Volumes/APFS/Xcode.app/Contents/Developer/Applications/Simulator.app`。
   - 书架是空的进不去阅读页时，可往容器写一本假书：`xcrun simctl spawn booted defaults write io.legado.ios legado_bookshelf_v1 -data <JSON 的 hex>`（键名见 `BookStore.bookshelfKey`）。
3. **根因不明的崩溃先定位再改**：用应用内 `AppLog` 面包屑把范围切到具体分节/具体块，拿到日志再改。禁止猜着改、连发几版让用户试。
4. **出包链路固定**：版本号三处同步（pbxproj 的 `CURRENT_PROJECT_VERSION`、根目录 `VERSION`、workflow 里的兜底 tag）→ Release 归档 → Payload 打 zip 改名 .ipa → 企业微信发用户 → `git commit` + `push`。
5. **两条线不要同时改同一个工作副本**：微信那条线和桌面这条线都要是「只从一条线提交」。
