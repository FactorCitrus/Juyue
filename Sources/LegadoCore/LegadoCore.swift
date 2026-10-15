public struct LegadoCore {
    public private(set) var text = "Hello, World!"

    public init() {
    }
}

/// Core 层不依赖 App 层，日志出口用运行时注入：App 启动时把真正写盘的那份装进来。
/// 没装之前（比如跑 swift test）只在 Debug 下打到控制台。
public enum LegadoLog {
    public static var handler: ((String) -> Void)?

    public static func log(_ message: String) {
        if let handler {
            handler(message)
        } else {
            #if DEBUG
            print(message)
            #endif
        }
    }
}
