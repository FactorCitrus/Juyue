import SwiftUI

/// 书源导入须知：条款写死在代码里，商店版每一次导入都得重新勾一次。
///
/// 侧载包是自用包，不计：面板一进来就是勾好的，关掉也不清零。
/// 同意不落盘，只对本次导入有效（商店版）：面板一关就作废，下次进来勾选框还是空的。
/// 只往日志里留一条「什么时候同意过」，条款改了就抬 `currentVersion`。
enum BookSourceDisclaimer {
    /// 条款版本。改文案就加一。
    static let currentVersion = 1

    /// 强制范围：商店包每次导入都要重新勾，侧载包不拦。
    static var requiresConsent: Bool { AppEdition.isAppStoreClean }

    /// 勾选即代表这一次导入的同意；不写 UserDefaults，所以下次导入必须再勾。
    static func accept() {
        AppLog.write("[书源] 已同意导入须知 v\(currentVersion)（本次导入有效）")
    }

    static func revoke() {
        AppLog.write("[书源] 取消勾选导入须知，本次导入不继续")
    }

    struct Clause: Identifiable {
        let id: String
        let lines: [String]
    }

    /// 四条边界：不提供源、源只是规则、授权自负、责任自担。
    static let clauses: [Clause] = [
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
}

/// 导入面板顶部的须知区：读完打勾，勾上才解锁下面三个导入入口。
struct BookSourceDisclaimerContent: View {
    @Binding var agreed: Bool
    @Environment(\.appTheme) private var theme

    /// 勾选即落盘：撤销勾选等于撤回同意，下次进来还是灰的。
    private var consent: Binding<Bool> {
        Binding(
            get: { agreed },
            set: { newValue in
                agreed = newValue
                if newValue {
                    BookSourceDisclaimer.accept()
                } else {
                    BookSourceDisclaimer.revoke()
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(BookSourceDisclaimer.clauses) { clause in
                VStack(alignment: .leading, spacing: 4) {
                    Text(clause.id)
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(theme.palette.ink)
                    ForEach(clause.lines, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundColor(theme.palette.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Toggle(isOn: consent) {
                Text("我已阅读并同意以上须知")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(theme.palette.ink)
            }
        }
        .padding(.vertical, 2)
    }
}
