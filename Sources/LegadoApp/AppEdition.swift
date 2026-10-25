import Foundation

/// 发行形态开关。
///
/// 默认是侧载全功能版；商店包只在编译时加 `JUYUE_APPSTORE`。
/// 两种包共用同一份源码，区别只落在编译条件和打包用的 Info.plist / bundle id 上。
public enum AppEdition {
    public static var isAppStoreClean: Bool {
        #if JUYUE_APPSTORE
        return true
        #else
        return false
        #endif
    }

    /// 商店版是否允许用户导入并启用书源。开元档：允许——书源由用户自行提供，
    /// App 不内置目录、不推荐、不对外分发。
    public static var allowsBookSources: Bool { true }

    /// 是否允许把书源复制/分享/导出出去。商店版关闭，免得 App 自己变成分发渠道。
    public static var allowsSourceExport: Bool { !isAppStoreClean }
}
