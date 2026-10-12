import SwiftUI
#if canImport(LegadoCore)
import LegadoCore
#endif

public struct SettingsView: View {
    @ObservedObject var bookStore = BookStore.shared
    @ObservedObject var readerConfig = ReaderConfig.shared

    @AppStorage("legado_app_theme") private var appTheme: String = "system"

    @State private var showRestoreAlert: Bool = false
    @State private var restoreSuccessMessage: String? = nil
    @State private var showClearCacheAlert: Bool = false
    @State private var clearCacheMessage: String? = nil

    public init() {}

    public var body: some View {
        NavigationView {
            Form {
                // Section 0: App Appearance (Dark Mode)
                Section(header: Text("外观模式")) {
                    Picker("外观模式", selection: $appTheme) {
                        Text("跟随系统").tag("system")
                        Text("浅色模式").tag("light")
                        Text("深色模式").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }

                // Section 1: Reading Display Settings
                Section(header: Text("阅读器显示设置")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("正文字号")
                            Spacer()
                            Text("\(Int(readerConfig.fontSize)) pt")
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("A-")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Slider(value: $readerConfig.fontSize, in: 12...32, step: 1)
                            Text("A+")
                                .font(.body.bold())
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("段落行距")
                            Spacer()
                            Text("\(Int(readerConfig.lineSpacing)) pt")
                                .foregroundColor(.secondary)
                        }

                        Slider(value: $readerConfig.lineSpacing, in: 4...24, step: 1)
                    }
                    .padding(.vertical, 4)

                    Picker("阅读背景主题", selection: $readerConfig.theme) {
                        ForEach(ReaderTheme.allCases) { theme in
                            Text(theme.rawValue).tag(theme)
                        }
                    }

                    // Live theme preview box
                    VStack(alignment: .leading, spacing: 6) {
                        Text("排版预览")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("这是示例文本，天地玄黄，宇宙洪荒。日月盈昃，辰宿列张。")
                            .font(.system(size: readerConfig.fontSize))
                            .lineSpacing(readerConfig.lineSpacing)
                            .foregroundColor(readerConfig.theme.textColor)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(readerConfig.theme.backgroundColor)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .padding(.vertical, 4)
                }

                // Section 2: Bookshelf & Storage
                Section(header: Text("书架与存储")) {
                    HStack {
                        Text("书架藏书")
                        Spacer()
                        Text("\(bookStore.bookshelf.count) 本")
                            .foregroundColor(.secondary)
                    }

                    Button(role: .destructive) {
                        showClearCacheAlert = true
                    } label: {
                        HStack {
                            Text("清理阅读缓存")
                            Spacer()
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                    }
                }

                // Section 3: Data & Cloud Sync (WebDAV)
                Section(header: Text("数据与云备份")) {
                    NavigationLink(destination: WebDAVSyncView()) {
                        HStack {
                            Label("WebDAV 云同步", systemImage: "icloud.and.arrow.up")
                            Spacer()
                            if WebDAVService.shared.loadConfig().lastSyncTime != nil {
                                Text("已同步")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("未配置")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // Section 4: Book Sources
                Section(header: Text("书源管理")) {
                    NavigationLink(destination: SourceManagerView()) {
                        HStack {
                            Text("管理全部网络书源")
                            Spacer()
                            Text("\(bookStore.sources.filter { $0.enabled != false }.count) / \(bookStore.sources.count) 个可用")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Button {
                        showRestoreAlert = true
                    } label: {
                        HStack {
                            Text("恢复预装默认书源")
                            Spacer()
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.accentColor)
                        }
                    }
                }

                // Section 4: About
                Section(header: Text("关于 Legado iOS")) {
                    HStack {
                        Text("应用名称")
                        Spacer()
                        Text("Legado iOS (开源阅读)")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("当前版本")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("内核引擎")
                        Spacer()
                        Text("Swift 原生 + JavaScriptCore")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("设置")
            .alert("恢复默认书源", isPresented: $showRestoreAlert) {
                Button("取消", role: .cancel) {}
                Button("确定恢复", role: .destructive) {
                    bookStore.loadBundledSources(forceReset: true)
                    restoreSuccessMessage = "已恢复预装书源"
                }
            } message: {
                Text("确定要将书源列表恢复为预装默认状态吗？自定义导入的书源可能被覆盖。")
            }
            .alert("清理阅读缓存", isPresented: $showClearCacheAlert) {
                Button("取消", role: .cancel) {}
                Button("确定清理", role: .destructive) {
                    clearCacheMessage = "缓存已成功清理"
                }
            } message: {
                Text("确定要清理临时章节与图片缓存吗？书架书籍与阅读进度将保留。")
            }
        }
    }
}
