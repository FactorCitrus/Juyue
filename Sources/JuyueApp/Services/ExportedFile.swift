import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 往「文件」里存东西用的一次性包装（书源导出、备份包导出都走它）。
/// SwiftUI 的 fileExporter 只认 FileDocument，这里就做个纯数据壳。
struct ExportedFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .zip, .data] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
