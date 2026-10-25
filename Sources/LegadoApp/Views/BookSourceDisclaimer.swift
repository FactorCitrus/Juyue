import SwiftUI

/// 书源导入须知：商店版首次导入前必须明确同意，侧载版只做展示。
///
/// 做法照开元阅读：不内置目录，导入前把责任边界讲清楚，并留一份可撤回的记录。
/// 同意状态存 `UserDefaults`，文案改了就抬 `currentVersion`，已同意的人会被再问一次。
enum BookSourceDisclaimer {
    /// 文案版本。改条款就加一。
    static let currentVersion = 1
    private static let key = "juyue.bookSourceDisclaimer.version"

    /// 侧载版是自用包，不拦；商店版必须过这一关。
    static var requiresConsent: Bool { AppEdition.isAppStoreClean }

    static var acceptedVersion: Int { UserDefaults.standard.integer(forKey: key) }
    static var hasAccepted: Bool { acceptedVersion >= currentVersion }
    static var needsConsent: Bool { requiresConsent && !hasAccepted }

    static var statusText: String {
        guard requiresConsent else { return "侧载版不强制" }
        return hasAccepted ? "已同意" : "首次导入需同意"
    }

    static func accept() {
        UserDefaults.standard.set(currentVersion, forKey: key)
        AppLog.write("[书源] 已同意导入须知 v\(currentVersion)")
    }

    static func revoke() {
        UserDefaults.standard.removeObject(forKey: key)
        AppLog.write("[书源] 撤回导入须知同意")
    }
}

/// 须知正文。条款写死在代码里，跟着版本号一起审阅。
struct BookSourceDisclaimerSheet: View {
    /// 点了「同意并继续」时回调；为 nil 表示只读查看。
    var onAccept: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    private struct Clause: Identifiable {
        let id: String
        let lines: [String]
    }

    private let clauses: [Clause] = [
        Clause(id: "一、本 App 不提供书源", lines: [
            "应用不内置、不推荐、不自动更新任何书源目录，也不存储、不缓存书籍正文。",
            "你看到的每一条书源，都是你自己寻找并导入的。"
        ]),
        Clause(id: "二、书源只是解析规则", lines: [
            "书源是一段网址与选择器规则，本身不含正文；实际内容来自该书源指向的第三方站点。",
            "第三方站点的可用性、内容与合法性，均与本 App 无关。"
        ]),
        Clause(id: "三、授权由你确认", lines: [
            "请只导入你有权访问与使用的内容，并遵守《中华人民共和国著作权法》等法律法规及你所在地区的规定。",
            "不得导入用于传播侵权、盗版、淫秽或其他违法内容的书源。"
        ]),
        Clause(id: "四、责任由导入者承担", lines: [
            "因导入、使用书源产生的任何后果与法律责任，由导入者自行承担。",
            "权利人如认为内容侵权，应直接向对应站点主张；本 App 只提供中立的解析工具，你可以在书源管理里随时清空全部书源。"
        ])
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("书源导入须知")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(theme.palette.ink)
                    Text("导入前请读完这四条。点「同意并继续」才会打开导入面板。")
                        .font(.footnote)
                        .foregroundColor(theme.palette.secondaryInk)

                    ForEach(clauses) { clause in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(clause.id)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(theme.palette.ink)
                            ForEach(clause.lines, id: \.self) { line in
                                Text(line)
                                    .font(.footnote)
                                    .foregroundColor(theme.palette.secondaryInk)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if BookSourceDisclaimer.hasAccepted {
                        Button("撤回同意（下次导入需重新确认）") {
                            BookSourceDisclaimer.revoke()
                            dismiss()
                        }
                        .font(.footnote)
                        .foregroundColor(.red)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("书源导入须知")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let accept = onAccept {
                        Button("同意并继续") {
                            BookSourceDisclaimer.accept()
                            accept()
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
