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
}
