import Foundation
import ObjectiveC

/// 让百度离线引擎看到「真正的」包名。
///
/// 百度把序列号绑在 APP ID + 包名上，引擎内部走 `bds::BDSAppInfoIOS::get_bundle_id()`，
/// 那是 `[[NSBundle mainBundle] bundleIdentifier]` 的一层皮。侧载容器（LiveContainer）
/// 会把主包的 bundleIdentifier 换成自己的，比如 `com.kdt.livecontainer.AW8DRY2ATD`，
/// 引擎拿这串去换授权，服务端一比对就是「包名不符」。
///
/// 做法：交换 `-[NSBundle bundleIdentifier]`，只在引擎调用期间、且问的是主包时，
/// 返回钉死的名字；别的一概照原样。窗口开得很窄，容器自己的路径查询拿到的还是真值。
///
/// 引擎那次取包名会缓存，所以只要第一次调用落在窗口里，后面就一直对。
enum BaiduBundleShim {
    /// 百度控制台里登记的包名。改这里等于改授权对象，别随手动。
    static let pinned = "com.factorcitrus.juyue"

    private static let lock = NSLock()
    private static var overrideDepth = 0
    private static var installed = false

    static var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return overrideDepth > 0
    }

    /// 装一次就够。重复调用直接返回。
    static func install() {
        lock.lock()
        let already = installed
        installed = true
        lock.unlock()
        guard !already else { return }

        let cls: AnyClass = Bundle.self
        guard let original = class_getInstanceMethod(cls, #selector(getter: Bundle.bundleIdentifier)),
              let replacement = class_getInstanceMethod(cls, #selector(Bundle.juyue_shim_bundleIdentifier))
        else {
            NSLog("[BaiduShim] 交换失败：找不到 bundleIdentifier 方法")
            return
        }
        method_exchangeImplementations(original, replacement)
        NSLog("[BaiduShim] 已安装，钉住 %@", pinned)
    }

    /// 进窗口。成对调用，用 defer 收尾。
    static func begin() {
        lock.lock(); overrideDepth += 1; lock.unlock()
    }

    static func end() {
        lock.lock(); overrideDepth = max(0, overrideDepth - 1); lock.unlock()
    }

    static func withOverride<T>(_ body: () -> T) -> T {
        begin()
        defer { end() }
        return body()
    }
}

extension Bundle {
    /// 交换之后，这个选择子指向系统原实现——所以第一行是「调原函数」，不是递归。
    @objc func juyue_shim_bundleIdentifier() -> String? {
        let real = juyue_shim_bundleIdentifier()
        guard BaiduBundleShim.isActive else { return real }
        // 只骗主包；框架、扩展、资源包照旧
        guard bundlePath == Bundle.main.bundlePath else { return real }
        return BaiduBundleShim.pinned
    }
}
