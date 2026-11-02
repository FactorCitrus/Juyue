import Foundation

/// 书源准入闸。
///
/// 书源规则可以带 `@js:` 片段，运行时经 JavaScriptCore 执行；App Review 2.5.2
/// 不允许 App 下载并执行改变功能的代码。商店包因此不接收任何书源——导入、
/// WebDAV 恢复、设置回灌、以及从侧载包升级带过来的旧数据，四条路一起堵。
/// 侧载包原样放行。
public enum BookSourceGate {
    /// 返回真正可以进内存的书源；`nil` 表示这次不接收。
    public static func admitted(_ sources: [BookSource]?, appStore: Bool) -> [BookSource]? {
        appStore ? nil : sources
    }
}
